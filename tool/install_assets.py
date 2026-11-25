"""Builds assets/models/siglip_b16 from the downloaded SigLIP export.

Run first (inside the tool venv, which has onnx/onnxruntime):
  tool/.venv/Scripts/python -I tool/fetch_models.py siglip_b16   # fp32 export, ~815 MB, sha256-verified
  tool/.venv/Scripts/python -I tool/quantize_siglip.py           # int8 encoders -> tool/.cache/siglip_b16_int8
then:
  tool/.venv/Scripts/python -I tool/install_assets.py

Bundled files:
  siglip_b16_vision_int8.onnx   vision encoder, int8 transformer weights
  siglip_b16_text_int8.onnx     text encoder, int8 transformer weights
  spiece_vocab.tsv              Unigram vocabulary, one `score<TAB>piece` per
                                line in id order (what lib/ml/siglip/siglip_tokenizer.dart
                                reads; verified against tokenizer.json below)
  preprocessor_config.json      image preprocessing of the export
  LICENSE_APACHE_2.0.txt        licence of the SigLIP weights (google/siglip-base-patch16-224)
  NOTICE.txt                    origin of the files

Also removes the MobileCLIP-S0 assets of earlier versions.
"""
import json
import os
import shutil
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SRC = os.path.join(ROOT, "tool", ".cache", "siglip_b16_int8")
DST = os.path.join(ROOT, "assets", "models", "siglip_b16")
OLD = os.path.join(ROOT, "assets", "models", "mobileclip_s0")
APACHE = "https://www.apache.org/licenses/LICENSE-2.0.txt"
APACHE_CACHE = os.path.join(ROOT, "tool", ".cache", "LICENSE-2.0.txt")

NOTICE = """SigLIP base patch16-224 (Google), image and text encoders.
Weights: google/siglip-base-patch16-224, Apache License 2.0
(https://huggingface.co/google/siglip-base-patch16-224).
ONNX export: Xenova/siglip-base-patch16-224 (Hugging Face).
Modifications: transformer weight matrices quantised to int8 with ONNX Runtime
dynamic quantisation (tool/quantize_siglip.py); vocabulary converted from
tokenizer.json to a tab-separated list (tool/install_assets.py).
"""


def main():
    if not os.path.isdir(SRC):
        raise SystemExit("run tool/quantize_siglip.py first")
    os.makedirs(DST, exist_ok=True)
    tok = json.load(open(os.path.join(SRC, "tokenizer.json"), encoding="utf-8"))
    model = tok["model"]
    if model["type"] != "Unigram" or model.get("byte_fallback"):
        raise SystemExit("unexpected tokenizer model")
    vocab = model["vocab"]
    for piece, _ in vocab:
        if "\t" in piece or "\n" in piece or "\r" in piece:
            raise SystemExit(f"piece cannot be stored as TSV: {piece!r}")
    with open(os.path.join(DST, "spiece_vocab.tsv"), "w", encoding="utf-8", newline="\n") as f:
        for piece, score in vocab:
            f.write(f"{score!r}\t{piece}\n")
    for src, dst in [
        ("onnx/vision_model.onnx", "siglip_b16_vision_int8.onnx"),
        ("onnx/text_model.onnx", "siglip_b16_text_int8.onnx"),
        ("preprocessor_config.json", "preprocessor_config.json"),
    ]:
        shutil.copyfile(os.path.join(SRC, src), os.path.join(DST, dst))
    if not os.path.exists(APACHE_CACHE):
        req = urllib.request.Request(APACHE, headers={"User-Agent": "gallery-asset-build/1.0"})
        with urllib.request.urlopen(req, timeout=60) as r:
            open(APACHE_CACHE, "wb").write(r.read())
    shutil.copyfile(APACHE_CACHE, os.path.join(DST, "LICENSE_APACHE_2.0.txt"))
    with open(os.path.join(DST, "NOTICE.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(NOTICE)
    if os.path.isdir(OLD):
        shutil.rmtree(OLD)
    for n in sorted(os.listdir(DST)):
        print(f"{os.path.getsize(os.path.join(DST, n)):>10}  {n}")


if __name__ == "__main__":
    main()
