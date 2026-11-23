"""Builds assets/models/mobileclip_s0 from the downloaded MobileCLIP-S0 export.

Run tool/fetch_models.py first, inside the tool venv (needs `onnx`):
  tool/.venv/Scripts/python -I tool/install_assets.py

Models (see tool/compress_weights.py for why not the published int8 files):
  mobileclip_s0_vision_fp16w.onnx  fp32 graph, weights stored as fp16
  mobileclip_s0_text_w8.onnx       fp32 graph, weights int8 per channel/row
 The tokenizer is bundled as its BPE merge list
only (bpe_merges.txt, one merge per line): the CLIP vocabulary is fully
determined by the merges (256 byte symbols, the same with '</w>', one token per
merge, then the two special tokens), which this script verifies against
tokenizer.json before writing.

Usage: py -3.13 tool/install_assets.py
"""
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SRC = os.path.join(ROOT, "tool", ".cache", "mobileclip_s0")
DST = os.path.join(ROOT, "assets", "models", "mobileclip_s0")


def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("\xa1"), ord("\xac") + 1)) + list(range(ord("\xae"), ord("\xff") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return [chr(c) for c in cs]


def main():
    os.makedirs(DST, exist_ok=True)
    tok = json.load(open(os.path.join(SRC, "tokenizer.json"), encoding="utf-8"))
    merges = [m if isinstance(m, str) else " ".join(m) for m in tok["model"]["merges"]]
    sym = bytes_to_unicode()
    vocab = sym + [s + "</w>" for s in sym] + [m.replace(" ", "") for m in merges] + ["<|startoftext|>", "<|endoftext|>"]
    if {t: i for i, t in enumerate(vocab)} != tok["model"]["vocab"]:
        raise SystemExit("vocab is not derivable from merges; bundle tokenizer.json instead")
    with open(os.path.join(DST, "bpe_merges.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(merges) + "\n")
    compress = os.path.join(ROOT, "tool", "compress_weights.py")
    for src, dst, mode in [
        ("onnx/vision_model.onnx", "mobileclip_s0_vision_fp16w.onnx", "fp16"),
        ("onnx/text_model.onnx", "mobileclip_s0_text_w8.onnx", "int8"),
    ]:
        subprocess.check_call([sys.executable, "-I", compress, os.path.join(SRC, src), os.path.join(DST, dst), "--mode", mode])
    for old in ("vision_model_int8.onnx", "text_model_int8.onnx"):
        if os.path.exists(os.path.join(DST, old)):
            os.remove(os.path.join(DST, old))
    for rel, name in [
        ("preprocessor_config.json", "preprocessor_config.json"),
        ("LICENSE", "LICENSE_XENOVA_EXPORT.txt"),
    ]:
        shutil.copyfile(os.path.join(SRC, rel), os.path.join(DST, name))
    for n in sorted(os.listdir(DST)):
        print(f"{os.path.getsize(os.path.join(DST, n)):>10}  {n}")


if __name__ == "__main__":
    main()
