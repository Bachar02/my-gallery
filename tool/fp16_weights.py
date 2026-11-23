"""Stores the float32 weights of an ONNX model as float16 to halve its size,
while keeping all computation in float32.

Every float32 initializer with at least MIN_ELEMS elements is replaced by a
float16 initializer followed by a Cast(to=float) node that produces the original
tensor name. ONNX Runtime constant-folds these Casts when the session is
created, so inference runs the original fp32 graph with weights rounded to fp16
(relative error ~5e-4), unlike dynamic int8 quantisation, which breaks the
MobileCLIP-S0 image encoder (see docs/AI_PIPELINE.md).

Usage: tool/.venv/Scripts/python -I tool/fp16_weights.py IN.onnx OUT.onnx
"""
import sys

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

MIN_ELEMS = 16


def main(src, dst):
    model = onnx.load(src)
    g = model.graph
    new_inits, cast_nodes = [], []
    converted = 0
    for init in g.initializer:
        if init.data_type == TensorProto.FLOAT and int(np.prod(init.dims)) >= MIN_ELEMS:
            arr = numpy_helper.to_array(init)
            if np.abs(arr).max() > 65000:  # would overflow fp16; keep as is
                new_inits.append(init)
                continue
            h = numpy_helper.from_array(arr.astype(np.float16), init.name + "__fp16")
            new_inits.append(h)
            cast_nodes.append(helper.make_node("Cast", [h.name], [init.name], to=TensorProto.FLOAT, name=init.name + "__cast"))
            converted += 1
        else:
            new_inits.append(init)
    del g.initializer[:]
    g.initializer.extend(new_inits)
    nodes = list(g.node)
    del g.node[:]
    g.node.extend(cast_nodes + nodes)
    onnx.checker.check_model(model)
    onnx.save(model, dst)
    print(f"converted {converted} initializers -> {dst}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
