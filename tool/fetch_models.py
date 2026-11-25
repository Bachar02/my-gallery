"""Downloads ONNX image-text model exports from Hugging Face.

Uses parallel HTTP range requests (single streams are slow on some links) and
verifies the SHA-256 published by the Hugging Face LFS metadata.

Usage:  py -3.13 tool/fetch_models.py [model ...] [--dest DIR]
Models: see MODELS below (default: mobileclip_s0, the model the app bundles).
Each model goes to tool/.cache/<model>/ (gitignored). Then run
tool/install_assets.py to build the bundled files in assets/models/.
Candidates other than the bundled model are only used by the offline
evaluation in tool/eval/.
"""
import concurrent.futures as cf
import hashlib
import json
import os
import sys
import urllib.request

REV = "main"
_CLIP_FILES = [
    "onnx/vision_model.onnx",
    "onnx/text_model.onnx",
    "tokenizer.json",
    "preprocessor_config.json",
    "tokenizer_config.json",
    "config.json",
]
# name -> (Hugging Face repo, files). fp32 sources; the app bundles compressed
# copies (tool/install_assets.py).
MODELS = {
    # Apple MobileCLIP-S0 (weights: Apple ML Research licence, research only).
    "mobileclip_s0": ("Xenova/mobileclip_s0", _CLIP_FILES + ["LICENSE", "README.md"]),
    # Google SigLIP base, patch 16, 224 px (Apache-2.0).
    "siglip_b16": ("Xenova/siglip-base-patch16-224", _CLIP_FILES + ["special_tokens_map.json"]),
    # OpenAI CLIP ViT-B/16 (MIT).
    "clip_b16": ("Xenova/clip-vit-base-patch16", _CLIP_FILES),
}
CHUNK = 2 * 1024 * 1024
WORKERS = 8


def api_tree(repo, path=""):
    url = f"https://huggingface.co/api/models/{repo}/tree/{REV}/{path}"
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def fetch_range(url, start, end, out_path):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
            if len(data) != end - start + 1:
                raise IOError(f"short read {len(data)}")
            with open(out_path, "r+b") as f:
                f.seek(start)
                f.write(data)
            return len(data)
        except Exception as e:  # retry flaky chunks
            last = e
    raise last


def download(repo, rel, size, sha, dest):
    out = os.path.join(dest, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.exists(out) and os.path.getsize(out) == size and sha and sha256(out) == sha:
        print("ok (cached)", rel)
        return
    url = f"https://huggingface.co/{repo}/resolve/{REV}/{rel}"
    with open(out, "wb") as f:
        f.truncate(size)
    ranges = [(s, min(s + CHUNK, size) - 1) for s in range(0, size, CHUNK)]
    done = 0
    with cf.ThreadPoolExecutor(WORKERS) as ex:
        for n in ex.map(lambda r: fetch_range(url, r[0], r[1], out), ranges):
            done += n
            print(f"\r{rel}: {done * 100 // max(size, 1)}%", end="", flush=True)
    print()
    if sha and sha256(out) != sha:
        raise SystemExit(f"checksum mismatch for {rel}")
    print("ok", rel, size)


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main():
    args = sys.argv[1:]
    dest_root = os.path.join(os.path.dirname(__file__), ".cache")
    if "--dest" in args:
        i = args.index("--dest")
        dest_root = args[i + 1]
        del args[i:i + 2]
    names = args or ["mobileclip_s0"]
    for name in names:
        if name not in MODELS:
            raise SystemExit(f"unknown model {name}; known: {', '.join(MODELS)}")
        repo, files = MODELS[name]
        meta = {e["path"]: e for e in api_tree(repo) + api_tree(repo, "onnx")}
        for rel in files:
            if rel not in meta:
                print("skip (not in repo)", rel)
                continue
            e = meta[rel]
            download(repo, rel, e["size"], e.get("lfs", {}).get("oid"), os.path.join(dest_root, name))


if __name__ == "__main__":
    main()
