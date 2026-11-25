"""Builds the photo half of the search evaluation corpus.

Source: Open Images V7 (Google), validation and test splits. Every image is
CC BY 2.0 (the manifest keeps author, licence and source page for each one);
labels are CC BY 4.0 and human-verified: Confidence 1 = present, 0 = verified
absent. The test split tops up classes the validation split has few of
(menus, receipts, beaches, sunsets, whiteboards).

Images are downscaled to a longest side of 1024 px (JPEG q90) into
tool/eval/.data/photos/ (gitignored). tool/eval/photos_manifest.json (committed)
lists id, file, labels, capture date and attribution.

Usage: tool/.venv/Scripts/python -I tool/eval/fetch_photos.py [--offline]
--offline rebuilds the manifest from already downloaded files only.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import csv
import io
import json
import random
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "tool" / "eval" / ".data"
OI = DATA / "oi"
PHOTOS = DATA / "photos"
MANIFEST = ROOT / "tool" / "eval" / "photos_manifest.json"
UA = "gallery-search-eval/1.0 (offline evaluation script)"
MAX_SIDE = 1024

_GCS = "https://storage.googleapis.com/openimages"
OI_FILES = {
    "oidv7-class-descriptions.csv": f"{_GCS}/v7/oidv7-class-descriptions.csv",
    "oidv7-val-annotations-human-imagelabels.csv": f"{_GCS}/v7/oidv7-val-annotations-human-imagelabels.csv",
    "validation-images-with-rotation.csv": f"{_GCS}/2018_04/validation/validation-images-with-rotation.csv",
    "oidv7-test-annotations-human-imagelabels.csv": f"{_GCS}/v7/oidv7-test-annotations-human-imagelabels.csv",
    "test-images-with-rotation.csv": f"{_GCS}/2018_04/test/test-images-with-rotation.csv",
}
OI_IMAGE = "https://s3.amazonaws.com/open-images-dataset/{split}/{id}.jpg"

# Label vocabulary kept in the manifest (Open Images display names).
VOCAB = [
    "Man", "Woman", "Boy", "Girl", "Person", "Human face", "Car", "Dog", "Cat", "Pizza", "Food", "Cake",
    "Beach", "Sunset", "Mountain", "Snow", "Flower", "Bicycle", "Menu", "Receipt", "Whiteboard", "Sea",
    "Boat", "Building", "Airplane", "Dessert", "Hamburger", "Map", "Poster", "Text", "Horse", "Bird",
    "Guitar", "Laptop", "Book", "Crowd", "Sky", "Tree", "Plate", "Dish", "Bus", "Truck", "Motorcycle",
]

# Validation split: label -> how many images to sample with that label present.
VAL_QUOTA = {
    "Man": 50, "Woman": 40, "Boy": 15, "Girl": 20, "Car": 30, "Dog": 20, "Cat": 15, "Pizza": 15,
    "Food": 30, "Cake": 15, "Beach": 11, "Mountain": 12, "Snow": 12, "Flower": 20, "Bicycle": 15,
    "Menu": 5, "Receipt": 3, "Whiteboard": 10, "Sea": 12, "Boat": 12, "Building": 20, "Airplane": 10,
    "Hamburger": 8, "Map": 10, "Poster": 15, "Text": 20, "Horse": 8, "Bird": 10, "Guitar": 8,
    "Laptop": 8, "Book": 8,
}
VAL_RANDOM = 30  # unconstrained images (realistic background clutter)
# Test split top-up for thin classes.
TEST_QUOTA = {"Menu": 25, "Receipt": 12, "Beach": 12, "Sunset": 12, "Whiteboard": 6}


def fetch(url: str, retries: int = 6) -> bytes:
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503) or attempt == retries - 1:
                raise
            time.sleep(int(e.headers.get("Retry-After", "0") or 0) or 4 * (attempt + 1))
        except (urllib.error.URLError, TimeoutError):
            if attempt == retries - 1:
                raise
            time.sleep(3 * (attempt + 1))
    raise RuntimeError("unreachable")


def save_resized(data: bytes, out: Path, rotation: str) -> None:
    img = Image.open(io.BytesIO(data)).convert("RGB")
    if rotation and float(rotation) != 0:
        img = img.rotate(-float(rotation), expand=True)
    img.thumbnail((MAX_SIDE, MAX_SIDE), Image.LANCZOS)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, "JPEG", quality=90)


def capture_date(rng: random.Random) -> str:
    start = datetime(2024, 3, 1)
    t = start + timedelta(minutes=rng.randrange(int((datetime(2026, 11, 20) - start).total_seconds() // 60)))
    return t.isoformat(timespec="seconds")


def read_split(prefix: str, vocab_ids: dict[str, str]) -> tuple[dict, dict]:
    labels: dict[str, dict[str, int]] = {}
    for r in csv.DictReader(open(OI / f"oidv7-{prefix}-annotations-human-imagelabels.csv", encoding="utf-8")):
        n = vocab_ids.get(r["LabelName"])
        if n is not None:
            labels.setdefault(r["ImageID"], {})[n] = 1 if r["Confidence"] == "1" else 0
    split = "validation" if prefix == "val" else prefix
    meta = {r["ImageID"]: r for r in csv.DictReader(open(OI / f"{split}-images-with-rotation.csv", encoding="utf-8"))}
    return labels, meta


def sample(labels, meta, quota, n_random, rng, taken) -> dict[str, str]:
    chosen: dict[str, str] = {}
    ids = sorted(labels)
    for label, n in quota.items():
        pool = [i for i in ids if labels[i].get(label) == 1 and i not in chosen and i not in taken]
        rng.shuffle(pool)
        for i in pool[:n]:
            chosen[i] = label
    if n_random:
        pool = [i for i in sorted(meta) if i not in chosen and i not in taken]
        rng.shuffle(pool)
        for i in pool[:n_random]:
            chosen[i] = "random"
    return chosen


def build_items(offline: bool) -> list[dict]:
    OI.mkdir(parents=True, exist_ok=True)
    for name, url in OI_FILES.items():
        if not (OI / name).exists():
            if offline:
                raise SystemExit(f"missing {name}")
            (OI / name).write_bytes(fetch(url))
    names = {r[0]: r[1] for r in csv.reader(open(OI / "oidv7-class-descriptions.csv", encoding="utf-8"))}
    vocab_ids = {k: v for k, v in names.items() if v in VOCAB}
    items = []
    taken: set[str] = set()
    for prefix, split, quota, n_random, seed in (
        ("val", "validation", VAL_QUOTA, VAL_RANDOM, 20261125),
        ("test", "test", TEST_QUOTA, 0, 20261126),
    ):
        labels, meta = read_split(prefix, vocab_ids)
        chosen = sample(labels, meta, quota, n_random, random.Random(seed), taken)
        taken |= set(chosen)
        for i, why in chosen.items():
            m = meta[i]
            lab = labels.get(i, {})
            items.append({
                "id": f"oi_{i}",
                "file": f"photos/oi_{i}.jpg",
                "kind": "photo",
                "source": f"openimages-v7-{split}",
                "sampled_for": why,
                "positive": sorted(k for k, v in lab.items() if v == 1),
                "negative": sorted(k for k, v in lab.items() if v == 0),
                "author": m["Author"],
                "license": m["License"],
                "source_url": m["OriginalLandingURL"],
                "_download": OI_IMAGE.format(split=split, id=i),
                "_rotation": m.get("Rotation") or "",
            })
    return items


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true")
    args = ap.parse_args()
    items = build_items(args.offline)

    def get(it: dict) -> dict | None:
        out = DATA / it["file"]
        if not out.exists():
            if args.offline:
                return None
            try:
                save_resized(fetch(it["_download"]), out, it["_rotation"])
            except Exception as e:
                print("download failed:", it["id"], e)
                return None
        with Image.open(out) as im:
            it["width"], it["height"] = im.size
        return it

    with cf.ThreadPoolExecutor(8) as ex:
        done = [r for r in ex.map(get, items) if r is not None]
    done.sort(key=lambda x: x["id"])
    date_rng = random.Random(7)
    for it in done:
        it["date"] = capture_date(date_rng)
        it.pop("_download", None)
        it.pop("_rotation", None)
    # Files from earlier corpus versions are removed so the device push and
    # the embeddings match the manifest exactly.
    keep = {DATA / it["file"] for it in done}
    for f in PHOTOS.glob("*.jpg"):
        if f not in keep:
            f.unlink()
    MANIFEST.write_text(json.dumps(done, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    by: dict[str, int] = {}
    for it in done:
        by[it["sampled_for"]] = by.get(it["sampled_for"], 0) + 1
    print(len(done), "photos", by)


if __name__ == "__main__":
    main()
