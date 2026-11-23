"""Builds a realistic test gallery for end-to-end search checks on an emulator.

Renders phone-sized chat/receipt screenshots containing known text and copies
real photos (from tool/.cache/calib, see calibrate_clip.py) with EXIF capture
dates, so queries like "conversation with Jamie", "bank details" or "restaurant
menu last summer" have a known correct answer.

Usage:
    python tool/fixtures/make_fixtures.py            # writes tool/fixtures/out/
    python tool/fixtures/make_fixtures.py --push     # also adb-pushes + media-scans

Writes tool/fixtures/out/expected.json: query -> filenames that should match.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tool" / "fixtures" / "out"
CALIB = ROOT / "tool" / ".cache" / "calib"
FONT = "C:/Windows/Fonts/segoeui.ttf"
FONT_BOLD = "C:/Windows/Fonts/segoeuib.ttf"
W, H = 1080, 2400


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_BOLD if bold else FONT, size)


def wrap(draw: ImageDraw.ImageDraw, text: str, f, max_w: int) -> list[str]:
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=f) <= max_w:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def chat(contact: str, messages: list[tuple[bool, str]], dark: bool = False) -> Image.Image:
    """messages: (sent_by_me, text). Generic messenger look, no real app branding."""
    bg, fg = ((18, 18, 20), (235, 235, 240)) if dark else ((236, 229, 221), (20, 20, 20))
    me_bubble = (0, 92, 75) if dark else (217, 253, 211)
    them_bubble = (38, 45, 49) if dark else (255, 255, 255)
    img = Image.new("RGB", (W, H), bg)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 90], fill=(0, 0, 0) if dark else (240, 240, 240))
    d.text((40, 22), "12:41", font=font(40), fill=fg)
    d.rectangle([0, 90, W, 260], fill=(31, 44, 52) if dark else (0, 128, 105))
    d.ellipse([110, 120, 220, 230], fill=(120, 144, 156))
    d.text((150, 140), contact[0], font=font(56, True), fill=(255, 255, 255))
    d.text((250, 125), contact, font=font(52, True), fill=(255, 255, 255))
    d.text((250, 190), "online", font=font(36), fill=(220, 240, 235))
    y = 320
    f = font(44)
    for mine, text in messages:
        lines = wrap(d, text, f, 700)
        bw = max(d.textlength(l, font=f) for l in lines) + 60
        bh = len(lines) * 60 + 50
        x = W - 40 - bw if mine else 40
        d.rounded_rectangle([x, y, x + bw, y + bh], 28, fill=me_bubble if mine else them_bubble)
        for i, l in enumerate(lines):
            d.text((x + 30, y + 22 + i * 60), l, font=f, fill=fg)
        y += bh + 36
    d.rounded_rectangle([30, H - 170, W - 30, H - 60], 55, fill=them_bubble)
    d.text((80, H - 145), "Message", font=font(44), fill=(140, 140, 140))
    return img


def receipt() -> Image.Image:
    img = Image.new("RGB", (W, H), (250, 250, 250))
    d = ImageDraw.Draw(img)
    rows = ["Order confirmation", "Order #48213-AX", "", "2x Flat white          7.80",
            "1x Croissant           3.20", "1x Orange juice        4.50", "",
            "Subtotal              15.50", "VAT                     1.55", "Total                 17.05",
            "", "Paid with card ending 4417", "Thank you for your order!"]
    y = 300
    for i, r in enumerate(rows):
        d.text((90, y), r, font=font(58 if i == 0 else 48, i == 0), fill=(30, 30, 30))
        y += 95
    return img


def settings_screen() -> Image.Image:
    img = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(img)
    d.text((60, 160), "Battery", font=font(72, True), fill=(20, 20, 20))
    for i, r in enumerate(["Battery saver", "Adaptive battery", "Battery percentage",
                           "Usage since full charge", "Screen  3 h 12 min"]):
        d.text((60, 400 + i * 160), r, font=font(50), fill=(40, 40, 40))
    return img


def save_with_exif(src: Path, dst: Path, taken: datetime) -> None:
    im = Image.open(src).convert("RGB")
    exif = Image.Exif()
    stamp = taken.strftime("%Y:%m:%d %H:%M:%S")
    exif[0x0132] = stamp  # DateTime
    ifd = exif.get_ifd(0x8769)
    ifd[0x9003] = stamp  # DateTimeOriginal
    ifd[0x9004] = stamp  # DateTimeDigitized
    # Without an offset, Android's scanner only trusts the EXIF date when it is
    # close to the file mtime, so set both.
    ifd[0x9010] = ifd[0x9011] = ifd[0x9012] = "+01:00"
    im.save(dst, "JPEG", quality=90, exif=exif)
    ts = taken.timestamp()
    os.utime(dst, (ts, ts))


def build() -> dict[str, list[str]]:
    if OUT.exists():
        shutil.rmtree(OUT)
    shots, photos = OUT / "Screenshots", OUT / "Camera"
    shots.mkdir(parents=True)
    photos.mkdir(parents=True)

    chat("Jamie", [
        (False, "Are we still on for dinner on Friday?"),
        (True, "Yes! 7:30 at the usual place"),
        (False, "Perfect, I'll book a table for four"),
        (True, "Great, see you then Jamie"),
    ]).save(shots / "Screenshot_20261102-194112.png")
    chat("Sam", [
        (False, "So for our trip to Germany, Berlin first or Munich?"),
        (True, "Berlin first, then the train to Munich on Thursday"),
        (False, "I found flights for 89 euros each"),
        (True, "Book them! Can't wait for the trip"),
    ], dark=True).save(shots / "Screenshot_20261015-101530.png")
    chat("Alex", [
        (True, "Can you send me the details for the rent?"),
        (False, "Sure, here are my bank details:"),
        (False, "IBAN: DE89 3704 0044 0532 0130 00 BIC: COBADEFFXXX Account holder: Alex Morgan"),
        (True, "Thanks, transferring now"),
    ]).save(shots / "Screenshot_20261020-090210.png")
    receipt().save(shots / "Screenshot_20261101-083000.png")
    settings_screen().save(shots / "Screenshot_20261105-220000.png")

    # Real photos with controlled capture dates.
    dated = {
        "menu": datetime(2026, 7, 18, 20, 15),       # last summer (relative to Nov 2026)
        "red_car": datetime(2026, 9, 3, 11, 0),
        "beach": datetime(2026, 8, 2, 16, 30),
        "dog": datetime(2026, 3, 10, 9, 0),
        "mountain": datetime(2025, 12, 28, 13, 0),
        "pizza": datetime(2026, 10, 1, 19, 0),
        "cat": datetime(2026, 11, 20, 18, 0),
    }
    for cat, when in dated.items():
        for i, src in enumerate(sorted((CALIB / cat).glob("*.jpg"))[:2]):
            save_with_exif(src, photos / f"IMG_{when:%Y%m%d}_{cat}_{i}.jpg", when)

    expected = {
        "Find the screenshot of my conversation with Jamie": ["Screenshot_20261102-194112.png"],
        "Find the conversation where we discussed our trip to Germany": ["Screenshot_20261015-101530.png"],
        "Find the screenshot where someone sent me their bank details": ["Screenshot_20261020-090210.png"],
        "Show me the picture of the restaurant menu I took last summer": ["IMG_20260718_menu_0.jpg", "IMG_20260718_menu_1.jpg"],
        "Show me the picture of the red car": ["IMG_20260903_red_car_0.jpg", "IMG_20260903_red_car_1.jpg"],
        "receipt total": ["Screenshot_20261101-083000.png"],
        "zebra crossing in tokyo": [],
    }
    (OUT / "expected.json").write_text(json.dumps(expected, indent=2))
    return expected


def push() -> None:
    adb = Path.home() / "AppData/Local/Android/Sdk/platform-tools/adb.exe"
    run = lambda *a: subprocess.run([str(adb), *a], check=True)
    run("shell", "rm", "-rf", "/sdcard/Pictures/Screenshots/Screenshot_2026*", "/sdcard/DCIM/Camera/IMG_2026*")
    run("shell", "mkdir", "-p", "/sdcard/Pictures/Screenshots", "/sdcard/DCIM/Camera")
    for f in (OUT / "Screenshots").iterdir():
        run("push", str(f), "/sdcard/Pictures/Screenshots/")
    for f in (OUT / "Camera").iterdir():
        run("push", "-a", str(f), "/sdcard/DCIM/Camera/")  # -a keeps mtime
    run("shell", "content", "call", "--method", "scan_volume", "--uri", "content://media",
        "--arg", "external_primary")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--push", action="store_true")
    args = p.parse_args()
    exp = build()
    print(f"wrote {sum(1 for _ in OUT.rglob('*.*'))} files to {OUT}")
    if args.push:
        push()
        print("pushed and scanned")
