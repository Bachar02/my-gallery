"""Shrinks an fp32 ONNX model by storing its weights in fewer bits while keeping
all arithmetic in fp32 (weight-only compression).

Why not the published *_int8.onnx files? Those use dynamic activation
quantisation (ConvInteger / MatMulInteger). For MobileCLIP-S0 that destroys the
image encoder (cosine 0.10-0.18 against fp32) and degrades the text encoder
(cosine 0.86-0.97), and it is slower on CPU. See docs/AI_PIPELINE.md.

Rewrites (all standard ONNX ops):
  * Embedding tables (Gather data input, 2-D): int8 with one scale per row;
    at runtime  Gather(table_q, ids) -> Cast(float) -> Mul(Gather(scale, ids)).
    The table stays int8 in memory.
  * MatMul weights (2-D, [in, out]):  int8, one scale per output column.
  * Conv weights (4-D, [out, in, kh, kw]): int8, one scale per output channel.
    For these two the dequantisation is Cast(int8 -> float) -> Mul(scale) on
    constant inputs, which ONNX Runtime constant-folds at session creation,
    so inference runs the plain fp32 graph.
  * Any other float32 initializer with >= 16 elements: stored as fp16 + Cast.
  * --mode fp16 stores every eligible weight as fp16 + Cast instead.

Usage: tool/.venv/Scripts/python -I tool/compress_weights.py IN.onnx OUT.onnx [--mode int8|fp16]
"""
import argparse
from collections import defaultdict

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

MIN_ELEMS = 16
MIN_INT8_ELEMS = 4096


def q_int8(w, axis):
    """Symmetric per-channel int8 along all axes except [axis]."""
    red = tuple(i for i in range(w.ndim) if i != axis)
    amax = np.abs(w).max(axis=red, keepdims=True)
    scale = np.where(amax > 0, amax / 127.0, 1.0).astype(np.float32)
    q = np.clip(np.rint(w / scale), -127, 127).astype(np.int8)
    return q, scale


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--mode", choices=["int8", "fp16"], default="int8")
    a = ap.parse_args()

    model = onnx.load(a.src)
    g = model.graph
    consumers = defaultdict(list)
    for n in g.node:
        for i, name in enumerate(n.input):
            consumers[name].append((n, i))

    inits = {i.name: i for i in g.initializer}
    keep, pre_nodes, stats = [], [], defaultdict(int)
    for name, init in inits.items():
        if init.data_type != TensorProto.FLOAT or int(np.prod(init.dims)) < MIN_ELEMS:
            keep.append(init)
            continue
        w = numpy_helper.to_array(init)
        uses = consumers.get(name, [])
        kinds = {(n.op_type, i) for n, i in uses}
        big = w.size >= MIN_INT8_ELEMS and a.mode == "int8"

        if big and w.ndim == 2 and kinds == {("Gather", 0)}:
            q, s = q_int8(w, axis=0)  # one scale per row (token)
            qi = numpy_helper.from_array(q, name + "__q")
            si = numpy_helper.from_array(s, name + "__scale")  # [V, 1]
            keep += [qi, si]
            for n, _ in uses:
                ids = n.input[1]
                out = n.output[0]
                base = n.name or out
                gq, gs, gf = out + "__gq", out + "__gs", out + "__gf"
                # replace the Gather in place with: Gather(q) Cast Gather(scale) Mul
                axis_attr = [at for at in n.attribute if at.name == "axis"]
                axis = axis_attr[0].i if axis_attr else 0
                if axis != 0:
                    raise SystemExit(f"unexpected Gather axis on {name}")
                n.input[0] = qi.name
                n.output[0] = gq
                extra = [
                    helper.make_node("Cast", [gq], [gf], to=TensorProto.FLOAT, name=base + "__cast"),
                    helper.make_node("Gather", [si.name, ids], [gs], axis=0, name=base + "__gscale"),
                    helper.make_node("Mul", [gf, gs], [out], name=base + "__deq"),
                ]
                # insert right after the gather
                idx = list(g.node).index(n)
                for k, e in enumerate(extra):
                    g.node.insert(idx + 1 + k, e)
            stats["embedding_int8"] += 1
            continue

        axis = None
        if big and w.ndim == 2 and kinds <= {("MatMul", 1)}:
            axis = 1
        elif big and w.ndim == 4 and kinds <= {("Conv", 1)}:
            axis = 0
        if axis is not None:
            q, s = q_int8(w, axis)
            qi = numpy_helper.from_array(q, name + "__q")
            si = numpy_helper.from_array(s, name + "__scale")
            keep += [qi, si]
            pre_nodes += [
                helper.make_node("Cast", [qi.name], [name + "__f"], to=TensorProto.FLOAT, name=name + "__cast"),
                helper.make_node("Mul", [name + "__f", si.name], [name], name=name + "__deq"),
            ]
            stats["weight_int8"] += 1
            continue

        if np.abs(w).max() <= 65000:
            h = numpy_helper.from_array(w.astype(np.float16), name + "__fp16")
            keep.append(h)
            pre_nodes.append(helper.make_node("Cast", [h.name], [name], to=TensorProto.FLOAT, name=name + "__cast"))
            stats["fp16"] += 1
        else:
            keep.append(init)
            stats["fp32_kept"] += 1

    del g.initializer[:]
    g.initializer.extend(keep)
    nodes = list(g.node)
    del g.node[:]
    g.node.extend(pre_nodes + nodes)
    onnx.checker.check_model(model)
    onnx.save(model, a.dst)
    print(dict(stats), "->", a.dst)


if __name__ == "__main__":
    main()
