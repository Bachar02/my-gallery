"""Renders the launcher icon PNGs (legacy, pre-Android 8) and a preview.

The adaptive icon itself (Android 8+) is the vector drawable
android/app/src/main/res/drawable/ic_launcher_foreground.xml on the colour
@color/ic_launcher_background; this script draws the same geometry so both
match. Geometry is in the 108x108 adaptive-icon coordinate space.

Usage: tool/.venv/Scripts/python -I tool/branding/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "android" / "app" / "src" / "main" / "res"

TEAL = (27, 107, 115)       # brand seed #1B6B73
TEAL_DARK = (16, 77, 84)    # #104D54
MINT = (143, 211, 207)      # #8FD3CF
SUN = (242, 182, 109)       # #F2B66D
WHITE = (255, 255, 255)

SCALE = 0.8
SHIFT = 2.0

DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def draw_foreground(d: ImageDraw.ImageDraw, s: float, ox: float = 0, oy: float = 0) -> None:
    """Draws the 108-unit foreground scaled by s with offset."""
    # Same transform as the vector's <group>: scale 0.8 about the centre, then
    # shift up-left so the magnifier handle stays inside the circular safe zone.
    t = lambda v: 54 + (v - 54) * SCALE - SHIFT
    p = lambda x, y: (ox + t(x) * s, oy + t(y) * s)
    k = SCALE  # stroke/radius scale
    # Photo card.
    d.rounded_rectangle([p(27, 31), p(75, 71)], radius=7 * s * k, fill=WHITE)
    # Landscape inside the card.
    d.polygon([p(31, 67), p(44, 50), p(52, 58), p(60, 47), p(71, 67)], fill=MINT)
    d.ellipse([p(59, 36), p(67, 44)], fill=SUN)
    # Magnifier: filled lens with a white ring, plus handle.
    d.line([p(76, 76), p(85, 85)], fill=WHITE, width=round(6.5 * s * k))
    cx, cy = p(85, 85)
    r = 3.25 * s * k  # round cap: half the stroke width
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=WHITE)
    d.ellipse([p(58, 58), p(80, 80)], fill=WHITE)
    d.ellipse([p(62.5, 62.5), p(75.5, 75.5)], fill=TEAL_DARK)


def render(size: int, round_mask: bool) -> Image.Image:
    ss = 4  # supersampling for clean edges
    big = size * ss
    img = Image.new("RGBA", (big, big), TEAL + (255,))
    d = ImageDraw.Draw(img)
    # Legacy icons show the full 108-unit canvas cropped to the 72-unit
    # visible area of adaptive icons: scale so 18..90 fills the bitmap.
    s = big / 72
    draw_foreground(d, s, ox=-18 * s, oy=-18 * s)
    mask = Image.new("L", (big, big), 0)
    m = ImageDraw.Draw(mask)
    if round_mask:
        m.ellipse([0, 0, big - 1, big - 1], fill=255)
    else:
        m.rounded_rectangle([0, 0, big - 1, big - 1], radius=big * 0.22, fill=255)
    img.putalpha(mask)
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    for name, px in DENSITIES.items():
        folder = RES / f"mipmap-{name}"
        folder.mkdir(exist_ok=True)
        render(px, round_mask=False).save(folder / "ic_launcher.png")
        render(px, round_mask=True).save(folder / "ic_launcher_round.png")
    # 512 px store icon (square, Play applies its own mask).
    store = render(512, round_mask=False)
    store.save(ROOT / "tool" / "branding" / "play_store_icon_512.png")
    print("icons written")


if __name__ == "__main__":
    main()
