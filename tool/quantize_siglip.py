"""Builds the int8 SigLIP encoders bundled by the app.

ONNX Runtime dynamic quantisation with per-channel int8 weights for the
transformer blocks' weight matrices (q/k/v/out projections, MLP fc1/fc2):
they run as int8 MatMulInteger at inference time, so each encoder needs about
100-120 MB of memory (folding compressed weights back to fp32 would need
~800 MB for both towers, too much for a phone). Everything sensitive stays
fp32: attention products (activation x activation), the attention-pooling
head, patch embedding, layer norms. The token-embedding table is stored int8.

Measured on the evaluation corpus (tool/eval/eval_models.py): image
embeddings vs fp32 cosine median 0.987 (min 0.958); quantising every MatMul
instead gave median 0.958 (min 0.845).

Usage: tool/.venv/Scripts/python -I tool/quantize_siglip.py [src_dir] [dst_dir]
Defaults: tool/.cache/siglip_b16 -> tool/.cache/siglip_b16_int8
"""
import os
import shutil
import sys

import onnx
from onnxruntime.quantization import QuantType, quantize_dynamic

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def weight_matmuls(path: str) -> tuple[list[str], list[str]]:
    m = onnx.load(path, load_external_data=False)
    nodes = [n.name for n in m.graph.node if n.op_type in ("MatMul", "Gemm", "Gather")]
    keep = [n for n in nodes if "layers" in n and ("_proj/" in n or "/fc1/" in n or "/fc2/" in n)]
    keep += [n for n in nodes if "token_embedding" in n]
    return keep, [n for n in nodes if n not in keep]


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "tool", ".cache", "siglip_b16")
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "tool", ".cache", "siglip_b16_int8")
    os.makedirs(os.path.join(dst, "onnx"), exist_ok=True)
    for name in ("vision_model.onnx", "text_model.onnx"):
        path = os.path.join(src, "onnx", name)
        keep, exclude = weight_matmuls(path)
        quantize_dynamic(
            path,
            os.path.join(dst, "onnx", name),
            weight_type=QuantType.QInt8,
            per_channel=True,
            op_types_to_quantize=["MatMul", "Gemm", "Gather"],
            nodes_to_exclude=exclude,
        )
        size = os.path.getsize(os.path.join(dst, "onnx", name)) / 1e6
        print(f"{name}: {len(keep)} weight ops int8, {len(exclude)} kept fp32, {size:.1f} MB")
    for f in os.listdir(src):
        if f.endswith(".json") or f.endswith(".model"):
            shutil.copyfile(os.path.join(src, f), os.path.join(dst, f))


if __name__ == "__main__":
    main()
