"""Calibrates the visual-match thresholds of HybridSearchEngine.

1. Downloads a small labelled image set from Wikimedia Commons (search per
   category, 330 px thumbnails, ~2 MB) into tool/.cache/calib/ (gitignored)
   and generates a few synthetic phone screenshots (chats, settings, lists),
   because real galleries are full of screenshots that must NOT match photo
   queries.
2. Embeds every image exactly like the app (thumbnail with longest side 256,
   then the CLIP preprocessing) with the bundled ONNX models, and every
   query with the app's prompt template ("a photo of <query>").
3. Prints positive/negative cosine distributions and evaluates candidate
   (floor, margin) pairs with the same rule the app uses:
   keep hit if sim >= floor and sim >= best_sim_for_query - margin.

Usage: tool/.venv/Scripts/python -I tool/calibrate_clip.py [--no-download]
Labels come from search results and are somewhat noisy; numbers in
docs/AI_PIPELINE.md were produced by this script.
"""
import argparse
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
import clip_reference as cr  # noqa: E402
from tokenizers import Tokenizer  # noqa: E402

ROOT = cr.ROOT
CACHE = os.path.join(ROOT, "tool", ".cache", "calib")
UA = "gallery-calibration/1.0 (offline research script)"

# category -> (commons search, queries the user might type)
CATEGORIES = {
    "red_car": ("red car", ["red car", "a red car parked on the street"]),
    "cat": ("cat portrait", ["cat", "my cat"]),
    "dog": ("dog park", ["dog", "a dog playing"]),
    "menu": ("restaurant menu", ["restaurant menu", "menu"]),
    "beach": ("beach sand sea", ["beach", "the beach"]),
    "mountain": ("mountain landscape", ["mountains", "mountain landscape"]),
    "cake": ("birthday cake", ["birthday cake", "cake"]),
    "pizza": ("pizza", ["pizza"]),
    "receipt": ("receipt paper shop", ["receipt", "shopping receipt"]),
    "night_city": ("city street at night", ["city at night", "street at night"]),
    "flowers": ("flowers garden", ["flowers", "flower garden"]),
    "bicycle": ("bicycle", ["bicycle", "bike"]),
    "whiteboard": ("whiteboard", ["whiteboard", "notes on a whiteboard"]),
    "concert": ("concert stage crowd", ["concert", "live music concert"]),
    "airplane": ("airplane airport", ["airplane", "plane at the airport"]),
    "snow": ("snow winter landscape", ["snow", "snowy landscape"]),
}
PER_CATEGORY = 5


def fetch(url):
    """GET with polite retries (Commons rate-limits bursts with HTTP 429)."""
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 5:
                raise
            time.sleep(int(e.headers.get("Retry-After", "0") or 0) or 5 * (attempt + 1))


def commons_search(query, n):
    params = {
        "action": "query", "format": "json", "generator": "search", "gsrnamespace": "6",
        "gsrlimit": str(n * 3), "gsrsearch": query + " filetype:bitmap",
        "prop": "imageinfo", "iiprop": "url|mime", "iiurlwidth": "330",
    }
    url = "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params)
    data = json.loads(fetch(url))
    pages = sorted(data.get("query", {}).get("pages", {}).values(), key=lambda p: p.get("index", 0))
    out = []
    for p in pages:
        ii = p["imageinfo"][0]
        if ii.get("mime") in ("image/jpeg", "image/png") and ii.get("thumburl"):
            out.append(ii["thumburl"])
        if len(out) >= n:
            break
    return out


def download():
    for cat, (q, _) in CATEGORIES.items():
        d = os.path.join(CACHE, cat)
        os.makedirs(d, exist_ok=True)
        if len([f for f in os.listdir(d) if f.endswith(".jpg")]) >= PER_CATEGORY:
            continue
        for i, url in enumerate(commons_search(q, PER_CATEGORY)):
            data = fetch(url)
            with open(os.path.join(d, f"{i}.jpg"), "wb") as f:
                f.write(data)
            time.sleep(1.0)
        print("downloaded", cat)


def synth_screenshots():
    d = os.path.join(CACHE, "screenshot")
    os.makedirs(d, exist_ok=True)
    rnd = random.Random(7)
    font = ImageFont.load_default(size=12)
    words = "hey see you at the station tomorrow thanks sure what time works for you ok great " \
            "invoice total settings wifi bluetooth battery display sound order shipped tracking".split()
    for k in range(12):
        w, h = 144, 320
        bg = rnd.choice([(255, 255, 255), (245, 245, 245), (18, 18, 18)])
        fg = (230, 230, 230) if bg[0] < 50 else (20, 20, 20)
        img = Image.new("RGB", (w, h), bg)
        dr = ImageDraw.Draw(img)
        dr.rectangle([0, 0, w, 28], fill=rnd.choice([(18, 140, 126), (33, 150, 243), (90, 90, 90)]))
        y = 36
        kind = k % 3
        while y < h - 30:
            text = " ".join(rnd.choice(words) for _ in range(rnd.randint(2, 4)))
            if kind == 0:  # chat bubbles
                mine = rnd.random() < 0.5
                x0 = 60 if mine else 6
                dr.rounded_rectangle([x0, y, x0 + 78, y + 22], 6, fill=(220, 248, 198) if mine else (230, 230, 230))
                dr.text((x0 + 4, y + 5), text[:12], fill=(20, 20, 20), font=font)
                y += 30
            elif kind == 1:  # settings list
                dr.text((10, y), text[:18], fill=fg, font=font)
                dr.line([0, y + 20, w, y + 20], fill=(200, 200, 200))
                y += 26
            else:  # article
                dr.text((6, y), text[:22], fill=fg, font=font)
                y += 16
        img.save(os.path.join(d, f"{k}.png"))


def load_images():
    items = []
    for cat in list(CATEGORIES) + ["screenshot"]:
        d = os.path.join(CACHE, cat)
        for f in sorted(os.listdir(d)):
            if f.endswith((".jpg", ".png")):
                items.append((cat, os.path.join(d, f)))
    return items


def app_tensor(path):
    img = Image.open(path).convert("RGB")
    scale = 256 / max(img.size)
    if scale < 1:  # the app embeds a thumbnail whose longest side is ~256
        img = img.resize((max(1, round(img.size[0] * scale)), max(1, round(img.size[1] * scale))), Image.BILINEAR)
    return cr.to_tensor(cr.preprocess(img))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-download", action="store_true")
    a = ap.parse_args()
    if not a.no_download:
        download()
    synth_screenshots()

    so = ort.SessionOptions()
    so.intra_op_num_threads = 4
    vis = ort.InferenceSession(os.path.join(cr.MODEL_DIR, "mobileclip_s0_vision_fp16w.onnx"), so)
    txt = ort.InferenceSession(os.path.join(cr.MODEL_DIR, "mobileclip_s0_text_w8.onnx"), so)
    tok = Tokenizer.from_file(os.path.join(ROOT, "tool", ".cache", "mobileclip_s0", "tokenizer.json"))
    tok.enable_truncation(77)
    tok.enable_padding(length=77, pad_id=0, pad_token="!")

    items = load_images()
    E = np.stack([cr.l2n(vis.run(None, {"pixel_values": app_tensor(p)})[0][0]) for _, p in items])
    labels = [c for c, _ in items]
    queries = [(cat, q) for cat, (_, qs) in CATEGORIES.items() for q in qs]
    queries += [(None, q) for q in ["purple elephant", "a giraffe", "fireworks", "a wedding dress", "a chess board"]]

    pos, neg, neg_shot = [], [], []
    per_query = []
    for cat, q in queries:
        t = cr.l2n(txt.run(None, {"input_ids": np.array([tok.encode("a photo of " + q).ids], dtype=np.int64)})[0][0])
        sims = E @ t
        per_query.append((cat, q, sims))
        for lab, s in zip(labels, sims):
            if lab == cat:
                pos.append(s)
            elif lab == "screenshot":
                neg_shot.append(s)
            else:
                neg.append(s)
    pos, neg, neg_shot = map(np.array, (pos, neg, neg_shot))

    def pct(x, p):
        return float(np.percentile(x, p))

    print(f"images: {len(items)} ({sum(1 for l in labels if l == 'screenshot')} synthetic screenshots), queries: {len(queries)}")
    print(f"positives   n={len(pos):4d} mean={pos.mean():.3f} p5={pct(pos, 5):.3f} p25={pct(pos, 25):.3f} median={pct(pos, 50):.3f}")
    print(f"negatives   n={len(neg):4d} mean={neg.mean():.3f} p95={pct(neg, 95):.3f} p99={pct(neg, 99):.3f} max={neg.max():.3f}")
    print(f"screenshots n={len(neg_shot):4d} mean={neg_shot.mean():.3f} p95={pct(neg_shot, 95):.3f} max={neg_shot.max():.3f}")

    print("\nfloor  margin  recall  precision  empty-for-unmatched-queries")
    for floor in [0.15, 0.17, 0.18, 0.19, 0.20, 0.21, 0.22]:
        for margin in [0.03, 0.05, 0.07, 0.10]:
            tp = fp = fn = 0
            empty_ok = 0
            unmatched = 0
            for cat, q, sims in per_query:
                best = sims.max()
                keep = (sims >= floor) & (sims >= best - margin)
                for lab, k in zip(labels, keep):
                    if cat is None:
                        continue
                    if lab == cat:
                        tp += int(k)
                        fn += int(not k)
                    else:
                        fp += int(k)
                if cat is None:
                    unmatched += 1
                    empty_ok += int(not keep.any())
            prec = tp / max(tp + fp, 1)
            rec = tp / max(tp + fn, 1)
            print(f"{floor:.2f}   {margin:.2f}    {rec:.2f}    {prec:.2f}       {empty_ok}/{unmatched}")

    print("\nper-query best match (unmatched queries should stay below the floor):")
    for cat, q, sims in per_query:
        order = np.argsort(-sims)[:3]
        top = ", ".join(f"{labels[i]}:{sims[i]:.3f}" for i in order)
        print(f"  {q!r:38} -> {top}")


if __name__ == "__main__":
    main()
