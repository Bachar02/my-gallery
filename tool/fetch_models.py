"""Downloads the MobileCLIP-S0 ONNX export used by the app.

Uses parallel HTTP range requests (single streams are slow on some links) and
verifies the SHA-256 published by the Hugging Face LFS metadata.

Usage:  py -3.13 tool/fetch_models.py [dest_dir]
Default dest: tool/.cache/mobileclip_s0 (gitignored). Then run
tool/install_assets.py to build the bundled files in assets/models/.
"""
import concurrent.futures as cf
import hashlib
import json
import os
import sys
import urllib.request

REPO = "Xenova/mobileclip_s0"
REV = "main"
FILES = [
    # fp32 sources (~215 MB); tool/install_assets.py compresses them to ~66 MB.
    "onnx/vision_model.onnx",
    "onnx/text_model.onnx",
    "tokenizer.json",
    "preprocessor_config.json",
    "tokenizer_config.json",
    "config.json",
    "LICENSE",
    "README.md",
]
CHUNK = 2 * 1024 * 1024
WORKERS = 8


def api_tree(path=""):
    url = f"https://huggingface.co/api/models/{REPO}/tree/{REV}/{path}"
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


def download(rel, size, sha, dest):
    out = os.path.join(dest, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.exists(out) and os.path.getsize(out) == size and sha and sha256(out) == sha:
        print("ok (cached)", rel)
        return
    url = f"https://huggingface.co/{REPO}/resolve/{REV}/{rel}"
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
    dest = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".cache", "mobileclip_s0")
    meta = {e["path"]: e for e in api_tree() + api_tree("onnx")}
    for rel in FILES:
        e = meta[rel]
        sha = e.get("lfs", {}).get("oid")
        download(rel, e["size"], sha, dest)


if __name__ == "__main__":
    main()
