"""Reference outputs for the on-device SigLIP implementation.

Runs the exact ONNX files bundled in assets/models/siglip_b16 with desktop
onnxruntime and writes fixtures the Dart code is tested against:

  test/ml/fixtures/siglip_tokenizer_cases.json  text -> 64 token ids (HF tokenizer)
  test/ml/fixtures/reference_images/*.png       small test images (CC0 / generated)
  test/ml/fixtures/siglip_preprocess.json       pixel tensor checks per image
  test/ml/fixtures/siglip_embeddings.json       image/text embeddings + similarities
  integration_test/ml/siglip_fixtures.dart      the same data for the on-device test

Usage (from the repo root, inside the tool venv):
  tool/.venv/Scripts/python -I tool/siglip_reference.py [--fp32-vision PATH]

Preprocessing mirrors preprocessor_config.json: RGB, resize to 224x224 (PIL
bicubic, antialiased, aspect ratio not kept), scale to [0,1], normalise with
mean 0.5 / std 0.5, CHW float32.
"""
import argparse
import base64
import hashlib
import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageDraw, ImageFont
from tokenizers import Tokenizer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MODEL_DIR = os.path.join(ROOT, "assets", "models", "siglip_b16")
SRC_IMAGES = os.path.join(ROOT, "tool", ".cache", "images")
FIX_DIR = os.path.join(ROOT, "test", "ml", "fixtures")
IMG_FIX_DIR = os.path.join(FIX_DIR, "reference_images")
IT_DART = os.path.join(ROOT, "integration_test", "ml", "siglip_fixtures.dart")

THUMB = 256
SIZE = 224
CONTEXT = 64

# CC0 / public-domain Wikimedia Commons photos (330 px thumbnails), see
# test/ml/fixtures/reference_images/SOURCES.md.
PHOTOS = ["red_car", "cat", "menu", "beach"]

TEXTS = [
    "a red car",
    "a cat sleeping on a keyboard",
    "a restaurant menu",
    "a beach at sunset",
    "a screenshot of a chat conversation",
    "a dog playing in the snow",
]

TOKENIZER_CASES = TEXTS + [
    "",
    "Find the screenshot of my conversation with Jamie!",
    "Show me the picture of the restaurant menu I took last summer",
    "it's 2024's best café, isn't it?",
    "  multiple   spaces\tand\nnewlines  ",
    "emoji \U0001F600 test ❤️",
    "don't-stop e-mail foo@bar.com https://example.org/a?b=c",
    "IBAN: DE89 3704 0044 0532 0130 00",
    "über straße naïve résumé Ångström",
    "COVID-19 vaccine 3.14159 $5,000 #hashtag @user",
    "日本語のテキスト and русский",
    " ".join(["word%d" % i for i in range(60)]),
    "supercalifragilisticexpialidocious antidisestablishmentarianism",
]


def preprocess(img: Image.Image) -> np.ndarray:
    img = img.convert("RGB").resize((SIZE, SIZE), resample=Image.BICUBIC)
    return np.asarray(img, dtype=np.uint8)


def to_tensor(arr_u8: np.ndarray) -> np.ndarray:
    return ((arr_u8.astype(np.float32) / 255.0 - 0.5) / 0.5).transpose(2, 0, 1)[None]


def l2n(v):
    v = np.asarray(v, dtype=np.float64)
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def make_chat_screenshot(path):
    """A synthetic phone chat screenshot (generated, no third-party content)."""
    w, h = 180, 320
    img = Image.new("RGB", (w, h), (245, 245, 245))
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.load_default(size=11)
        bold = ImageFont.load_default(size=13)
    except TypeError:
        font = bold = ImageFont.load_default()
    d.rectangle([0, 0, w, 34], fill=(18, 140, 126))
    d.text((10, 10), "Jamie", fill=(255, 255, 255), font=bold)
    msgs = [
        (False, "Hey! Are we still on for Berlin?"),
        (True, "Yes! Flight lands at 10:40"),
        (False, "Great, I booked the hotel"),
        (True, "Can you send the address?"),
        (False, "Alexanderplatz 7, 10178 Berlin"),
        (True, "Thanks, see you Friday"),
    ]
    y = 46
    for mine, text in msgs:
        tw = d.textlength(text, font=font)
        bw = min(int(tw) + 14, w - 30)
        x0 = w - bw - 8 if mine else 8
        d.rounded_rectangle([x0, y, x0 + bw, y + 24], radius=7, fill=(220, 248, 198) if mine else (255, 255, 255))
        d.text((x0 + 7, y + 6), text, fill=(20, 20, 20), font=font)
        y += 36
    d.rectangle([0, h - 34, w, h], fill=(255, 255, 255))
    d.text((10, h - 24), "Message", fill=(150, 150, 150), font=font)
    img.save(path, optimize=True)


def build_images():
    os.makedirs(IMG_FIX_DIR, exist_ok=True)
    names = []
    for name in PHOTOS:
        src = Image.open(os.path.join(SRC_IMAGES, name + ".jpg")).convert("RGB")
        # Match what the app feeds the model: a thumbnail whose longest side is 256.
        scale = THUMB / max(src.size)
        th = src.resize((round(src.size[0] * scale), round(src.size[1] * scale)), Image.BILINEAR)
        th.save(os.path.join(IMG_FIX_DIR, name + ".png"), optimize=True)
        names.append(name)
    make_chat_screenshot(os.path.join(IMG_FIX_DIR, "chat_screenshot.png"))
    names.append("chat_screenshot")
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fp32-vision", help="optional fp32 vision model to compare compression error")
    args = ap.parse_args()

    tok = Tokenizer.from_file(os.path.join(ROOT, "tool", ".cache", "siglip_b16", "tokenizer.json"))
    tok.enable_truncation(CONTEXT)
    tok.enable_padding(length=CONTEXT, pad_id=1, pad_token="</s>")
    cases = [{"text": t, "ids": tok.encode(t).ids} for t in TOKENIZER_CASES]
    os.makedirs(FIX_DIR, exist_ok=True)
    with open(os.path.join(FIX_DIR, "siglip_tokenizer_cases.json"), "w", encoding="utf-8") as f:
        json.dump(cases, f, ensure_ascii=False, indent=0)

    names = build_images()

    so = ort.SessionOptions()
    so.intra_op_num_threads = 4
    vis = ort.InferenceSession(os.path.join(MODEL_DIR, "siglip_b16_vision_int8.onnx"), so)
    txt = ort.InferenceSession(os.path.join(MODEL_DIR, "siglip_b16_text_int8.onnx"), so)
    vis32 = ort.InferenceSession(args.fp32_vision, so) if args.fp32_vision else None

    pre = {}
    img_emb = {}
    t0 = time.perf_counter()
    for n in names:
        arr = preprocess(Image.open(os.path.join(IMG_FIX_DIR, n + ".png")))
        chw = arr.transpose(2, 0, 1).reshape(-1)
        pre[n] = {
            "sha256_chw_u8": hashlib.sha256(chw.tobytes()).hexdigest(),
            "mean_rgb": [float(arr[..., c].mean() / 255.0) for c in range(3)],
            "samples": [[int(i), int(chw[i])] for i in range(0, chw.size, 997)],
        }
        x = to_tensor(arr)
        e = vis.run(["pooler_output"], {"pixel_values": x})[0][0]
        img_emb[n] = l2n(e)
        if vis32 is not None:
            e32 = l2n(vis32.run(["pooler_output"], {"pixel_values": x})[0][0])
            print(f"bundled vs fp32 vision cosine [{n}]: {float(img_emb[n] @ e32):.4f}")
    t_img = (time.perf_counter() - t0) / len(names)

    t0 = time.perf_counter()
    txt_emb = {}
    for t in TEXTS:
        ids = np.array([tok.encode(t).ids], dtype=np.int64)
        txt_emb[t] = l2n(txt.run(["pooler_output"], {"input_ids": ids})[0][0])
    t_txt = (time.perf_counter() - t0) / len(TEXTS)

    sims = {n: {t: float(img_emb[n] @ txt_emb[t]) for t in TEXTS} for n in names}
    print("\nimage \\ text cosine similarity")
    print(" " * 16 + " ".join(f"{t[:14]:>14}" for t in TEXTS))
    for n in names:
        print(f"{n:>16}" + " ".join(f"{sims[n][t]:14.3f}" for t in TEXTS))
    print(f"\ndesktop latency: image {t_img * 1000:.1f} ms, text {t_txt * 1000:.1f} ms")

    with open(os.path.join(FIX_DIR, "siglip_preprocess.json"), "w", encoding="utf-8") as f:
        json.dump(pre, f, indent=1)
    emb = {
        "model": "siglip_b16 (Xenova ONNX export, int8 by tool/quantize_siglip.py)",
        "images": {n: [round(float(v), 6) for v in img_emb[n]] for n in names},
        "texts": {t: [round(float(v), 6) for v in txt_emb[t]] for t in TEXTS},
        "similarity": sims,
    }
    with open(os.path.join(FIX_DIR, "siglip_embeddings.json"), "w", encoding="utf-8") as f:
        json.dump(emb, f)

    write_integration_fixtures(names, emb)


def write_integration_fixtures(names, emb):
    os.makedirs(os.path.dirname(IT_DART), exist_ok=True)
    out = [
        "// GENERATED by tool/siglip_reference.py - do not edit.",
        "// Reference embeddings computed with desktop onnxruntime on the bundled",
        "// SigLIP ONNX files (assets/models/siglip_b16).",
        "",
        "const Map<String, String> kFixtureImagesBase64 = {",
    ]
    for n in names:
        with open(os.path.join(IMG_FIX_DIR, n + ".png"), "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        out.append(f"  '{n}': '{b64}',")
    out.append("};")
    out.append("")
    out.append("const Map<String, List<double>> kExpectedImageEmbeddings = {")
    for n in names:
        out.append(f"  '{n}': [{', '.join(repr(v) for v in emb['images'][n])}],")
    out.append("};")
    out.append("")
    out.append("const Map<String, List<double>> kExpectedTextEmbeddings = {")
    for t in TEXTS:
        out.append(f"  '{t}': [{', '.join(repr(v) for v in emb['texts'][t])}],")
    out.append("};")
    out.append("")
    with open(IT_DART, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))


if __name__ == "__main__":
    sys.exit(main())
