"""Deterministic generator of synthetic phone screenshots for the search-quality eval.

Renders ~150 phone-sized (1080x2400) Android-style screenshots - chats in four
generic messenger layouts, maps, web pages, shops, social feeds, settings,
receipts, email, delivery-app menus, notes and calendars - including hard
distractors (name prefixes, "men"/"menu"/"restaurant" words, people mentioned
in body text instead of the chat header).

Usage:  tool/.venv/Scripts/python -I tool/eval/make_screens.py
Output: tool/eval/.data/screens/<id>.png  (gitignored)
        tool/eval/screens_manifest.json   (ground truth: tags, texts, dates)
"""
from __future__ import annotations

import datetime as dt
import json
import random
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 1080, 2400
SB_H, NAV_H = 100, 60
HERE = Path(__file__).resolve().parent
OUT_DIR = HERE / ".data" / "screens"
MANIFEST = HERE / "screens_manifest.json"
FONT_DIR = "C:/Windows/Fonts/"
WHITE, BLACK = (255, 255, 255), (0, 0, 0)

# --------------------------------------------------------------------------- text

_FONTS: dict = {}
_FILES = {("segoe", False): "segoeui.ttf", ("segoe", True): "segoeuib.ttf",
          ("arial", False): "arial.ttf", ("arial", True): "arialbd.ttf",
          ("emoji", False): "seguiemj.ttf", ("sym", False): "seguisym.ttf"}


def font(kind: str, size: int, bold: bool = False):
    key = (kind, bold if kind in ("segoe", "arial") else False)
    k2 = key + (size,)
    if k2 not in _FONTS:
        _FONTS[k2] = ImageFont.truetype(FONT_DIR + _FILES[key], size)
    return _FONTS[k2]


def char_kind(ch: str) -> str:
    o = ord(ch)
    if o in (0xFE0F, 0x200D):
        return "skip"
    if o >= 0x1F000 or ch in "⚽☕⛽":
        return "emoji"
    if 0x2190 <= o <= 0x2BFF:
        return "sym"
    return "text"


def runs(s: str):
    out: list = []
    for ch in s:
        k = char_kind(ch)
        if k == "skip":
            continue
        if out and out[-1][0] == k:
            out[-1][1] += ch
        else:
            out.append([k, ch])
    return out


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


class Canvas:
    """Image + draw handle that records every rendered string with a role."""

    def __init__(self, theme: str, rnd: random.Random, when: dt.datetime):
        self.dark = theme == "dark"
        self.rnd, self.when = rnd, when
        self.img = Image.new("RGB", (W, H), (18, 18, 20) if self.dark else WHITE)
        self.d = ImageDraw.Draw(self.img)
        self.texts: list = []
        self.role = "body"
        self.sb_bg = None       # status bar fill (None = transparent)
        self.sb_fg = None
        self.nav_bg = None
        self.vis = (0, H - NAV_H)  # rows where recorded text is actually visible

    def rec(self, s, y):
        if s.strip() and self.vis[0] <= y and y + 20 <= self.vis[1]:
            self.texts.append((s, self.role))

    def _f(self, k, size, bold, face):
        return font(k if k != "text" else face, size, bold)

    def tw(self, s, size, bold=False, face="segoe"):
        return sum(self._f(k, size, bold, face).getlength(t) for k, t in runs(s))

    def text(self, x, y, s, size, fill, bold=False, face="segoe", align="l",
             record=True, stroke=0, sfill=None, vc=False):
        """Draw s with its top at y (or vertically centred on y when vc)."""
        w = self.tw(s, size, bold, face)
        x = x - w / 2 if align == "m" else x - w if align == "r" else x
        if vc:
            y = y - int(size * 0.68)
        base = y + size
        for k, t in runs(s):
            f = self._f(k, size, bold, face)
            if k == "emoji":
                self.d.text((x, base), t, font=f, anchor="ls", embedded_color=True)
            else:
                self.d.text((x, base), t, fill=fill, font=f, anchor="ls",
                            stroke_width=stroke, stroke_fill=sfill)
            x += f.getlength(t)
        if record:
            self.rec(s, y)
        return w

    def wrap(self, s, size, maxw, bold=False):
        lines = []
        for para in s.split("\n"):
            cur = ""
            for word in para.split(" "):
                t = f"{cur} {word}" if cur else word
                if self.tw(t, size, bold) <= maxw or not cur:
                    cur = t
                else:
                    lines.append(cur)
                    cur = word
            lines.append(cur)
        return lines

    def para(self, x, y, s, size, maxw, fill, bold=False, lh=None, max_lines=99):
        lh = lh or int(size * 1.36)
        lines = self.wrap(s, size, maxw, bold)[:max_lines]
        for i, line in enumerate(lines):
            self.text(x, y + i * lh, line, size, fill, bold, record=False)
        self.rec(s, y)
        return len(lines) * lh

    def ellipsize(self, s, size, maxw, bold=False):
        if self.tw(s, size, bold) <= maxw:
            return s
        while s and self.tw(s + "…", size, bold) > maxw:
            s = s[:-1]
        return s + "…"

    # shapes
    def rr(self, box, r, fill=None, outline=None, width=1):
        self.d.rounded_rectangle(box, r, fill=fill, outline=outline, width=width)

    def circle(self, cx, cy, r, fill=None, outline=None, width=1):
        self.d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill, outline=outline, width=width)

    def gradient(self, box, c1, c2, r=0, horizontal=False):
        x0, y0, x1, y1 = [int(v) for v in box]
        w, h = x1 - x0, y1 - y0
        g = Image.linear_gradient("L").resize((w, h))
        if horizontal:
            g = g.rotate(90, expand=False).resize((w, h))
        tile = Image.composite(Image.new("RGB", (w, h), c2), Image.new("RGB", (w, h), c1), g)
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), r, fill=255)
        self.img.paste(tile, (x0, y0), mask)


# --------------------------------------------------------------------------- icons & chrome

AV_COLORS = [(233, 30, 99), (103, 58, 183), (3, 155, 229), (0, 137, 123), (124, 179, 66),
             (251, 140, 0), (141, 110, 99), (84, 110, 122), (229, 57, 53), (57, 73, 171)]


def avatar(c, cx, cy, r, name, ring=None):
    col = AV_COLORS[sum(map(ord, name)) % len(AV_COLORS)]
    if ring:
        c.circle(cx, cy, r + 8, fill=ring)
        c.circle(cx, cy, r + 4, fill=WHITE if not c.dark else BLACK)
    c.circle(cx, cy, r, fill=col)
    letter = next((ch for ch in name if ch.isalpha()), None)
    if letter:
        c.text(cx, cy, letter.upper(), int(r * 0.95), WHITE, bold=True, align="m", vc=True, record=False)
    else:  # silhouette for unknown numbers
        c.circle(cx, cy - r * 0.25, r * 0.32, fill=WHITE)
        c.d.pieslice((cx - r * 0.6, cy + r * 0.15, cx + r * 0.6, cy + r * 1.3), 180, 360, fill=WHITE)


def ic_back(c, x, y, col, w=5):
    c.d.line((x, y, x + 44, y), fill=col, width=w)
    c.d.line((x, y, x + 20, y - 20), fill=col, width=w)
    c.d.line((x, y, x + 20, y + 20), fill=col, width=w)


def ic_dots(c, x, y, col):
    for i in (-18, 0, 18):
        c.circle(x, y + i, 5, fill=col)


def ic_search(c, x, y, col, s=1.0):
    c.circle(x - 6 * s, y - 6 * s, 17 * s, outline=col, width=int(5 * s))
    c.d.line((x + 6 * s, y + 6 * s, x + 22 * s, y + 22 * s), fill=col, width=int(6 * s))


def ic_video(c, x, y, col):
    c.rr((x - 30, y - 18, x + 10, y + 18), 6, fill=col)
    c.d.polygon([(x + 12, y), (x + 32, y - 16), (x + 32, y + 16)], fill=col)


def ic_phone(c, x, y, col):
    f = ImageFont.truetype(FONT_DIR + "segmdl2.ttf", 50)  # handset glyph from the system icon font
    c.d.text((x, y), "", font=f, fill=col, anchor="mm")


def ic_camera(c, x, y, col, filled=False):
    c.rr((x - 28, y - 18, x + 28, y + 22), 8, outline=col, width=5, fill=col if filled else None)
    c.rr((x - 10, y - 26, x + 10, y - 16), 3, fill=col)
    c.circle(x, y + 2, 10, outline=col if not filled else WHITE, width=5)


def ic_mic(c, x, y, col):
    c.rr((x - 10, y - 26, x + 10, y + 6), 10, fill=col)
    c.d.arc((x - 20, y - 14, x + 20, y + 16), 0, 180, fill=col, width=4)
    c.d.line((x, y + 16, x, y + 26), fill=col, width=4)


def ic_plus(c, x, y, col, s=22, w=5):
    c.d.line((x - s, y, x + s, y), fill=col, width=w)
    c.d.line((x, y - s, x, y + s), fill=col, width=w)


def ic_smile(c, x, y, col):
    c.circle(x, y, 22, outline=col, width=4)
    c.circle(x - 8, y - 6, 3, fill=col)
    c.circle(x + 8, y - 6, 3, fill=col)
    c.d.arc((x - 12, y - 8, x + 12, y + 12), 20, 160, fill=col, width=3)


def ic_image(c, x, y, col):
    c.rr((x - 24, y - 20, x + 24, y + 20), 6, outline=col, width=4)
    c.d.polygon([(x - 18, y + 14), (x - 4, y - 4), (x + 6, y + 8), (x + 12, y + 2), (x + 20, y + 14)], fill=col)


def ic_wifi(c, x, y, col, r=26, level=4):
    """Wi-Fi fan; arcs above `level` are drawn faded."""
    for i in range(4):
        rr_ = r * (1 - i * 0.24)
        fill = col if 4 - i <= level else mix(col, c.img.getpixel((int(x), int(y + 4))), .7)
        c.d.pieslice((x - rr_, y - rr_, x + rr_, y + rr_), 225, 315, fill=fill)


def ic_lock(c, x, y, col):
    c.rr((x - 10, y - 2, x + 10, y + 14), 3, fill=col)
    c.d.arc((x - 7, y - 14, x + 7, y + 4), 180, 360, fill=col, width=3)


def ic_heart(c, x, y, col, size=48):
    c.text(x, y, "♡", size, col, align="m", vc=True, record=False)


def lum(col):
    return 0.299 * col[0] + 0.587 * col[1] + 0.114 * col[2]


def status_bar(c):
    if c.sb_bg is not None:
        c.d.rectangle((0, 0, W, SB_H), fill=c.sb_bg)
    ref = c.sb_bg if c.sb_bg is not None else c.img.getpixel((540, 50))
    fg = c.sb_fg or (BLACK if lum(ref) > 140 else WHITE)
    prev, c.role = c.role, "chrome"
    c.text(52, 50, c.when.strftime("%H:%M"), 36, fg, vc=True)
    for i in range(c.rnd.randint(0, 2)):  # notification glyphs
        x = 175 + i * 46
        c.rr((x, 36, x + 28, 64), 6, outline=fg, width=3)
    c.rr((W - 96, 36, W - 48, 64), 5, outline=fg, width=3)
    pct = c.rnd.randint(18, 99)
    c.d.rectangle((W - 91, 41, W - 91 + int(38 * pct / 100), 59), fill=fg)
    c.d.rectangle((W - 47, 44, W - 43, 56), fill=fg)
    c.text(W - 108, 50, f"{pct}%", 32, fg, align="r", vc=True)
    x = W - 250
    c.d.polygon([(x, 66), (x + 36, 66), (x + 36, 30)], fill=fg)
    c.d.pieslice((x - 78, 24, x - 22, 80), 225, 315, fill=fg)
    c.role = prev


def nav_bar(c):
    bg = c.nav_bg if c.nav_bg is not None else c.img.getpixel((540, H - NAV_H - 2))
    c.d.rectangle((0, H - NAV_H, W, H), fill=bg)
    c.rr((W // 2 - 115, H - 34, W // 2 + 115, H - 22), 6, fill=(30, 30, 30) if lum(bg) > 140 else (220, 220, 220))


# --------------------------------------------------------------------------- chats

def chat_theme(style, dark):
    if style == "whatsapp_like":
        return dict(bar=(31, 44, 52), bg=(11, 20, 26), inb=(32, 44, 51), outb=(0, 92, 75), fg=(233, 237, 239),
                    meta=(134, 150, 160), barfg=(233, 237, 239), barsub=(134, 150, 160), inp=(31, 44, 52),
                    btn=(0, 168, 132), sep=(24, 34, 41)) if dark else \
            dict(bar=(0, 128, 105), bg=(236, 229, 221), inb=WHITE, outb=(217, 253, 211), fg=(17, 27, 33),
                 meta=(102, 119, 129), barfg=WHITE, barsub=(214, 240, 233), inp=WHITE, btn=(0, 168, 132),
                 sep=(225, 242, 251))
    if style == "messenger_like":
        return dict(bg=BLACK, inb=(48, 48, 50), outb=(0, 132, 255), fg=(240, 240, 240), meta=(150, 150, 155),
                    acc=(0, 132, 255), inp=(48, 48, 50)) if dark else \
            dict(bg=WHITE, inb=(240, 240, 242), outb=(0, 132, 255), fg=(5, 5, 5), meta=(101, 103, 107),
                 acc=(0, 132, 255), inp=(240, 240, 242))
    if style == "instagram_like":
        return dict(bg=BLACK, inb=(38, 38, 40), fg=(245, 245, 245), meta=(168, 168, 168), acc=(55, 151, 240),
                    line=(60, 60, 62)) if dark else \
            dict(bg=WHITE, inb=(239, 239, 239), fg=(10, 10, 10), meta=(115, 115, 115), acc=(55, 151, 240),
                 line=(219, 219, 219))
    return dict(bg=(17, 20, 25), inb=(48, 50, 54), outb=(0, 74, 119), fg=(227, 227, 227), outfg=(211, 227, 253),
                meta=(150, 155, 160), acc=(168, 199, 250), inp=(40, 42, 46), bar=(17, 20, 25)) if dark else \
        dict(bg=WHITE, inb=(233, 236, 240), outb=(211, 227, 253), fg=(31, 31, 31), outfg=(4, 30, 73),
             meta=(95, 99, 104), acc=(11, 87, 208), inp=(238, 241, 246), bar=WHITE)


def parse_msgs(src: str, end: dt.datetime, rnd):
    raw = [ln.strip() for ln in src.strip().split("\n") if ln.strip()]
    msgs, t = [], end - dt.timedelta(minutes=rnd.randint(0, 3))
    for ln in reversed(raw):
        side = {">": "in", "<": "out", "=": "sep"}[ln[0]]
        body, sender = ln[1:].strip(), None
        if side == "in" and "|" in body.split(" ")[0] + " ":
            sender, body = body.split("|", 1)
            body = body.strip()
        msgs.append(dict(side=side, text=body, sender=sender, t=t))
        if side != "sep":
            t -= dt.timedelta(minutes=rnd.choice([0, 0, 1, 1, 2, 3, 5, 8, 12]))
    msgs.reverse()
    for i, m in enumerate(msgs):  # separators take the time of the next message
        if m["side"] == "sep":
            nxt = next((n for n in msgs[i + 1:] if n["side"] != "sep"), m)
            m["text"] = m["text"].replace("{t}", nxt["t"].strftime("%H:%M"))
    return msgs


SENDER_COLS = [(229, 57, 53), (0, 137, 123), (57, 73, 171), (251, 140, 0), (142, 36, 170), (3, 155, 229)]


def draw_bubbles(c, msgs, top, bottom, P):
    fs, lh, px, py = P["fs"], P["lh"], P["padx"], P["pady"]
    maxin = P["maxw"] - 2 * px
    items = []
    for i, m in enumerate(msgs):
        nxt = msgs[i + 1] if i + 1 < len(msgs) else None
        prv = msgs[i - 1] if i else None
        m["last"] = not nxt or (nxt["side"], nxt["sender"]) != (m["side"], m["sender"])
        m["first"] = not prv or (prv["side"], prv["sender"]) != (m["side"], m["sender"])
        if m["side"] == "sep":
            items.append((m, 96, 0, []))
            continue
        lines = c.wrap(m["text"], fs, maxin)
        lw = [c.tw(x, fs) for x in lines]
        h, w = len(lines) * lh + 2 * py, max(lw)
        if m["sender"] and P.get("senders") and m["first"]:
            h += lh - 4
            w = max(w, c.tw(m["sender"], fs - 6, True))
        if P.get("time_in"):
            m["tl"] = m["t"].strftime("%H:%M") + ("  ✓✓" if m["side"] == "out" else "")
            tw = c.tw(m["tl"], 30) + 18
            if lw[-1] + tw <= maxin:
                w = max(w, lw[-1] + tw)
            else:
                h += 38
                w = max(w, tw)
        extra = 46 if P.get("time_below") and m["last"] else 0
        items.append((m, h + extra, w + 2 * px, lines))
    y, placed = bottom, []
    for m, h, w, lines in reversed(items):
        y -= h
        placed.append((m, y, h, w, lines))
        y -= 10 if not m["first"] else 30
        if y < top - 300:
            break
    c.vis = (top, bottom + 200)
    for m, y, h, w, lines in placed:
        if m["side"] == "sep":
            tw = c.tw(m["text"], 30, P.get("sep_bold", False))
            if P.get("sep_bg"):
                c.rr((W / 2 - tw / 2 - 24, y + 18, W / 2 + tw / 2 + 24, y + 78), 14, fill=P["sep_bg"])
            c.text(W / 2, y + 48, m["text"], 30, P["sep_fg"], P.get("sep_bold", False), align="m", vc=True)
            continue
        bh = h - (46 if P.get("time_below") and m["last"] else 0)
        out = m["side"] == "out"
        x0 = W - P["edge"] - w if out else P["inx"]
        fill = P["outb"](y) if out and callable(P["outb"]) else P["outb"] if out else P["inb"]
        r = P["r"]
        c.rr((x0, y, x0 + w, y + bh), r, fill=fill)
        if P.get("tails") and m["first"]:
            if out:
                c.d.polygon([(x0 + w - 30, y), (x0 + w + 18, y), (x0 + w - 4, y + 26)], fill=fill)
                c.d.rectangle((x0 + w - 30, y, x0 + w, y + 20), fill=fill)
            else:
                c.d.polygon([(x0 + 30, y), (x0 - 18, y), (x0 + 4, y + 26)], fill=fill)
                c.d.rectangle((x0, y, x0 + 30, y + 20), fill=fill)
        ty = y + py
        if m["sender"] and P.get("senders") and m["first"]:
            col = SENDER_COLS[sum(map(ord, m["sender"])) % len(SENDER_COLS)]
            c.text(x0 + px, ty - 2, m["sender"], fs - 6, col, bold=True)
            ty += lh - 4
        fg = P["outfg"] if out else P["fg"]
        for i, ln in enumerate(lines):
            c.text(x0 + px, ty + i * lh, ln, fs, fg, record=False)
        if any(top <= ty + i * lh for i in range(len(lines))):  # at least one line below the header
            c.texts.append((m["text"], "body"))
        if P.get("time_in"):
            meta = P["meta_out"] if out else P["meta"]
            tx = x0 + w - px + 4
            if out:
                c.text(tx, y + bh - 44, "✓✓", 28, P["tick"], align="r", record=False)
                tx -= c.tw("✓✓", 28) + 10
            c.text(tx, y + bh - 44, m["t"].strftime("%H:%M"), 28, meta, align="r")
        if P.get("avatar_in") and not out and m["last"]:
            avatar(c, P["inx"] - 46, y + bh - 30, 28, m["sender"] or P["avatar_in"])
        if P.get("time_below") and m["last"]:
            lab = m["t"].strftime("%H:%M") + (" · Read" if out else "")
            c.text(x0 + w if out else x0 + 8, y + bh + 8, lab, 28, P["meta"], align="r" if out else "l")
    c.vis = (0, H)


def chat_screen(c, style, title, msgs, sub=None, group=False):
    T = chat_theme(style, c.dark)
    rnd = c.rnd
    msgs = parse_msgs(msgs, c.when, rnd)
    c.img.paste(T["bg"], (0, 0, W, H))
    first = title.split(" ")[0].lower()
    if sub is None:
        if style == "whatsapp_like":
            seen = (c.when - dt.timedelta(minutes=rnd.randint(20, 300))).strftime("%H:%M")
            sub = rnd.choice(["online", f"last seen today at {seen}", "typing…", "online"])
        elif style == "messenger_like":
            sub = rnd.choice(["Active now", "Active 5m ago", "Active 1h ago"])
        elif style == "instagram_like":
            sub = re.sub(r"[^a-z]", "", first) + rnd.choice([".r", "_", ".m", "x", ".k"])
        else:
            sub = ""
    if style == "whatsapp_like":
        if not c.dark:  # subtle wallpaper doodles
            for _ in range(140):
                x, y = rnd.randint(0, W), rnd.randint(280, H - 200)
                c.circle(x, y, rnd.randint(6, 16), outline=(222, 214, 204), width=3)
        P = dict(fs=38, lh=50, padx=26, pady=16, maxw=800, r=20, inx=34, edge=34, inb=T["inb"], outb=T["outb"],
                 fg=T["fg"], outfg=T["fg"], time_in=True, meta=T["meta"], meta_out=T["meta"],
                 tick=(83, 189, 235), tails=True, senders=group, sep_bg=T["sep"], sep_fg=T["meta"])
        bar_bot, inp_top = 280, H - NAV_H - 140
        draw_bubbles(c, msgs, bar_bot, inp_top - 16, P)
        c.role = "header"
        c.d.rectangle((0, 0, W, bar_bot), fill=T["bar"])
        c.sb_bg = T["bar"]
        ic_back(c, 34, 190, T["barfg"])
        avatar(c, 150, 190, 54, title)
        c.text(228, 108 + (40 if not sub else 18), c.ellipsize(title, 46, 520, True), 46, T["barfg"], bold=True)
        if sub:
            c.text(228, 188, c.ellipsize(sub, 32, 520), 32, T["barsub"])
        ic_video(c, 800, 190, T["barfg"])
        ic_phone(c, 920, 190, T["barfg"])
        ic_dots(c, 1030, 190, T["barfg"])
        c.role = "body"
        y = inp_top + 14
        c.rr((24, y, W - 160, y + 112), 56, fill=T["inp"])
        ic_smile(c, 90, y + 56, T["meta"])
        c.text(140, y + 56, "Message", 38, T["meta"], vc=True)
        c.d.line((W - 300, y + 76, W - 270, y + 36), fill=T["meta"], width=5)
        ic_camera(c, W - 220, y + 56, T["meta"])
        c.circle(W - 82, y + 56, 56, fill=T["btn"])
        ic_mic(c, W - 82, y + 56, WHITE)
    elif style == "messenger_like":
        P = dict(fs=38, lh=50, padx=34, pady=22, maxw=760, r=40, inx=116, edge=34, inb=T["inb"], outb=T["outb"],
                 fg=T["fg"], outfg=WHITE, avatar_in=title, sep_fg=T["meta"], senders=group)
        bar_bot, inp_top = 280, H - NAV_H - 140
        draw_bubbles(c, msgs, bar_bot, inp_top - 10, P)
        c.role = "header"
        c.d.rectangle((0, 0, W, bar_bot), fill=T["bg"])
        c.d.line((0, bar_bot, W, bar_bot), fill=T["inb"], width=2)
        ic_back(c, 34, 190, T["acc"])
        avatar(c, 152, 190, 50, title)
        if "now" in sub:
            c.circle(190, 228, 13, fill=(49, 162, 76), outline=T["bg"], width=4)
        c.text(226, 128, c.ellipsize(title, 44, 520, True), 44, T["fg"], bold=True)
        c.text(226, 190, sub, 30, T["meta"])
        ic_phone(c, 860, 190, T["acc"])
        ic_video(c, 980, 190, T["acc"])
        c.role = "body"
        y = inp_top + 20
        ic_plus(c, 54, y + 50, T["acc"])
        ic_camera(c, 140, y + 50, T["acc"], filled=True)
        ic_image(c, 230, y + 50, T["acc"])
        ic_mic(c, 315, y + 50, T["acc"])
        c.rr((370, y, W - 130, y + 100), 50, fill=T["inp"])
        c.text(410, y + 50, "Aa", 38, T["meta"], vc=True)
        c.text(W - 70, y + 50, "👍", 54, T["acc"], align="m", vc=True, record=False)
    elif style == "instagram_like":
        def grad(y):
            t = max(0.0, min(1.0, (y - 300) / 1800))
            return mix((161, 54, 240), (55, 110, 245), t)
        P = dict(fs=38, lh=50, padx=34, pady=22, maxw=760, r=44, inx=110, edge=30, inb=T["inb"], outb=grad,
                 fg=T["fg"], outfg=WHITE, avatar_in=title, sep_fg=T["meta"], senders=group, sep_bold=True)
        bar_bot, inp_top = 290, H - NAV_H - 150
        draw_bubbles(c, msgs, bar_bot, inp_top - 10, P)
        c.role = "header"
        c.d.rectangle((0, 0, W, bar_bot), fill=T["bg"])
        ic_back(c, 34, 195, T["fg"])
        avatar(c, 150, 195, 50, title)
        c.text(222, 128, c.ellipsize(title, 42, 540, True), 42, T["fg"], bold=True)
        c.text(222, 190, sub, 32, T["meta"])
        ic_phone(c, 880, 195, T["fg"])
        ic_video(c, 990, 195, T["fg"])
        c.role = "body"
        y = inp_top + 20
        c.rr((24, y, W - 24, y + 116), 58, fill=T["bg"], outline=T["line"], width=3)
        c.circle(88, y + 58, 42, fill=T["acc"])
        ic_camera(c, 88, y + 58, WHITE)
        c.text(152, y + 58, "Message...", 38, T["meta"], vc=True)
        ic_mic(c, W - 260, y + 58, T["fg"])
        ic_image(c, W - 170, y + 58, T["fg"])
        ic_smile(c, W - 86, y + 58, T["fg"])
    else:  # sms_like
        P = dict(fs=38, lh=50, padx=32, pady=22, maxw=780, r=36, inx=116, edge=34, inb=T["inb"], outb=T["outb"],
                 fg=T["fg"], outfg=T["outfg"], avatar_in=title, sep_fg=T["meta"], meta=T["meta"], time_below=True, senders=group)
        bar_bot, inp_top = 270, H - NAV_H - 150
        draw_bubbles(c, msgs, bar_bot, inp_top - 10, P)
        c.role = "header"
        c.d.rectangle((0, 0, W, bar_bot), fill=T["bar"])
        ic_back(c, 34, 185, T["fg"])
        avatar(c, 150, 185, 46, title)
        if sub:
            c.text(220, 126, title, 44, T["fg"])
            c.text(220, 188, sub, 30, T["meta"])
        else:
            c.text(220, 185, c.ellipsize(title, 46, 560), 46, T["fg"], vc=True)
        ic_phone(c, 860, 185, T["fg"])
        ic_video(c, 950, 185, T["fg"])
        ic_dots(c, 1040, 185, T["fg"])
        c.role = "body"
        y = inp_top + 20
        c.circle(70, y + 56, 44, fill=T["inp"])
        ic_plus(c, 70, y + 56, T["fg"], 18, 4)
        c.rr((132, y, W - 140, y + 112), 56, fill=T["inp"])
        c.text(176, y + 56, c.rnd.choice(["Text message", "RCS message"]), 36, T["meta"], vc=True)
        ic_smile(c, W - 280, y + 56, T["meta"])
        ic_image(c, W - 200, y + 56, T["meta"])
        c.circle(W - 76, y + 56, 52, fill=T["outb"])
        ic_mic(c, W - 76, y + 56, T["outfg"])
    c.nav_bg = T["bg"] if style != "whatsapp_like" else (T["bg"] if c.dark else WHITE)


# --------------------------------------------------------------------------- scenes & products

def scene(c, box, kind, r=0):
    rnd = c.rnd
    x0, y0, x1, y1 = [int(v) for v in box]
    w, h = x1 - x0, y1 - y0
    sub = Canvas("light", rnd, c.when)
    sub.img = Image.new("RGB", (w, h), WHITE)
    sub.d = ImageDraw.Draw(sub.img)
    if kind in ("sunset", "sky"):
        a, b = ((255, 179, 71), (128, 52, 140)) if kind == "sunset" else ((120, 180, 240), (225, 240, 255))
        sub.gradient((0, 0, w, h), b, a)
        sub.circle(w * rnd.uniform(0.3, 0.7), h * 0.55, h * 0.12, fill=(255, 226, 140) if kind == "sunset" else WHITE)
        for i, col in enumerate([(70, 40, 90), (40, 25, 60)] if kind == "sunset" else [(90, 120, 150), (60, 90, 110)]):
            pts = [(0, h)] + [(x, h * (0.6 + 0.12 * i) - rnd.randint(0, int(h * 0.2))) for x in range(0, w + 120, 120)] + [(w, h)]
            sub.d.polygon(pts, fill=col)
    elif kind == "food":
        sub.d.rectangle((0, 0, w, h), fill=rnd.choice([(196, 140, 92), (92, 64, 51), (230, 210, 180)]))
        sub.circle(w / 2, h / 2, min(w, h) * 0.38, fill=(250, 250, 248))
        for _ in range(9):
            sub.circle(w / 2 + rnd.randint(-int(w * .2), int(w * .2)), h / 2 + rnd.randint(-int(h * .2), int(h * .2)),
                       rnd.randint(int(min(w, h) * .04), int(min(w, h) * .1)),
                       fill=rnd.choice([(214, 69, 65), (241, 196, 15), (39, 174, 96), (230, 126, 34), (155, 89, 50)]))
    elif kind == "city":
        sub.gradient((0, 0, w, h), (40, 50, 90), (240, 140, 90))
        x = 0
        while x < w:
            bw, bh = rnd.randint(60, 160), rnd.randint(int(h * .25), int(h * .75))
            sub.d.rectangle((x, h - bh, x + bw, h), fill=(30, 30, 45))
            for wy in range(h - bh + 20, h - 20, 40):
                for wx in range(x + 12, x + bw - 20, 30):
                    if rnd.random() < .45:
                        sub.d.rectangle((wx, wy, wx + 12, wy + 18), fill=(255, 210, 120))
            x += bw + 6
    elif kind == "river":
        sub.d.rectangle((0, 0, w, h), fill=(110, 160, 90))
        sub.d.polygon([(0, h * .35), (w, h * .2), (w, h * .65), (0, h * .8)], fill=(70, 130, 180))
        sub.d.rectangle((0, 0, w, h * .18), fill=(190, 215, 235))
    elif kind == "stadium":
        sub.d.rectangle((0, 0, w, h), fill=(56, 142, 60))
        for i in range(0, w, 120):
            sub.d.rectangle((i, 0, i + 60, h), fill=(67, 160, 71))
        sub.d.rectangle((40, 40, w - 40, h - 40), outline=WHITE, width=6)
        sub.d.line((w / 2, 40, w / 2, h - 40), fill=WHITE, width=6)
        sub.circle(w / 2, h / 2, h * .18, outline=WHITE, width=6)
    else:  # abstract
        sub.gradient((0, 0, w, h), tuple(rnd.randint(60, 230) for _ in range(3)), tuple(rnd.randint(60, 230) for _ in range(3)))
        for _ in range(6):
            sub.circle(rnd.randint(0, w), rnd.randint(0, h), rnd.randint(40, 200),
                       fill=tuple(rnd.randint(80, 255) for _ in range(3)))
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), r, fill=255)
    c.img.paste(sub.img, (x0, y0), mask)


def product(c, box, kind, col):
    x0, y0, x1, y1 = box
    c.rr(box, 20, fill=(236, 236, 238) if not c.dark else (44, 44, 48))
    cx, cy, s = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 480
    P = lambda pts: [(cx + px * s, cy + py * s) for px, py in pts]
    dark_col = mix(col, BLACK, .3)
    if kind in ("tshirt", "jacket", "hoodie"):
        long = kind != "tshirt"
        body = [(-90, -170), (-40, -185), (0, -165), (40, -185), (90, -170), (170, -100 if not long else 60),
                (150 if not long else 140, -60 if not long else 80), (110, -100), (110, 180), (-110, 180),
                (-110, -100), (-150 if not long else -140, -60 if not long else 80), (-170, -100 if not long else 60)]
        c.d.polygon(P(body), fill=col)
        if kind == "jacket":
            c.d.line(P([(0, -165), (0, 180)]), fill=dark_col, width=6)
            c.d.polygon(P([(-40, -185), (0, -120), (40, -185), (0, -165)]), fill=dark_col)
        if kind == "hoodie":
            c.d.ellipse(P([(-50, -210), (50, -140)]), outline=dark_col, width=10)
    elif kind == "shoe":
        c.d.polygon(P([(-180, 40), (-170, -40), (-60, -60), (-20, -120), (40, -120), (60, -50), (170, 0), (190, 60), (-180, 60)]), fill=col)
        c.d.rectangle(P([(-185, 60), (195, 90)]), fill=(245, 245, 245))
        for i in range(4):
            c.d.line(P([(-10 + i * 18, -100 + i * 12), (40 + i * 18, -90 + i * 12)]), fill=WHITE, width=5)
    else:  # dress / bag
        c.d.polygon(P([(-50, -170), (50, -170), (60, -60), (150, 180), (-150, 180), (-60, -60)]), fill=col)


# --------------------------------------------------------------------------- maps

MAP_LIGHT = dict(land=(245, 242, 235), block=(236, 232, 224), park=(197, 232, 197), water=(170, 218, 255),
                 road=WHITE, border=(214, 210, 204), major=(255, 228, 142), mborder=(233, 196, 106),
                 label=(90, 90, 96), halo=(245, 242, 235))
MAP_DARK = dict(land=(36, 40, 46), block=(42, 46, 53), park=(32, 58, 44), water=(22, 40, 66), road=(70, 76, 86),
                border=(28, 30, 34), major=(110, 98, 70), mborder=(60, 55, 40), label=(170, 178, 188), halo=(36, 40, 46))
STREETS = ["Rue de la Paix", "Baker Street", "Elm Ave", "Market St", "Kingsway", "Via Roma", "Linden Rd",
           "Harbour Rd", "Park Lane", "Station Rd", "Rue Mercière", "Oak Street", "Canal St", "Victoria Ave"]
POIS = ["Café Lune", "City Museum", "Central Park", "St Mary's Church", "Pharmacy", "Old Town Hall",
        "Bakery Dupont", "Fitness Hub", "Book Corner", "Riverside Market"]


def draw_map(c, top=0, bottom=H):
    M = MAP_DARK if c.dark else MAP_LIGHT
    rnd = c.rnd
    c.d.rectangle((0, top, W, bottom), fill=M["land"])
    vx = sorted(rnd.sample(range(60, W - 40, 30), 5))
    hy = sorted(rnd.sample(range(top + 80, bottom - 60, 40), 9))
    for _ in range(40):
        x, y = rnd.randint(0, W), rnd.randint(top, bottom)
        c.d.rectangle((x, y, x + rnd.randint(60, 180), y + rnd.randint(40, 140)), fill=M["block"])
    for _ in range(2):
        x, y = rnd.randint(0, W - 300), rnd.randint(top, bottom - 300)
        c.rr((x, y, x + rnd.randint(200, 380), y + rnd.randint(160, 340)), 30, fill=M["park"])
    ry = rnd.randint(top + 300, bottom - 300)
    pts = [(x, ry + rnd.randint(-120, 120)) for x in range(-100, W + 200, 240)]
    c.d.line(pts, fill=M["water"], width=90, joint="curve")
    majors = rnd.sample(range(len(hy)), 2)
    for i, y in enumerate(hy):
        maj = i in majors
        c.d.line((0, y, W, y), fill=M["mborder" if maj else "border"], width=36 if maj else 20)
    for x in vx:
        c.d.line((x, top, x, bottom), fill=M["border"], width=22)
    c.d.line((0, bottom - 200, W, top + 400), fill=M["border"], width=24)
    for i, y in enumerate(hy):
        maj = i in majors
        c.d.line((0, y, W, y), fill=M["major" if maj else "road"], width=30 if maj else 14)
    for x in vx:
        c.d.line((x, top, x, bottom), fill=M["road"], width=16)
    c.d.line((0, bottom - 200, W, top + 400), fill=M["road"], width=18)
    names = rnd.sample(STREETS, 6)
    for i, nm in enumerate(names):
        y = hy[(i * 2 + 1) % len(hy)]
        c.text(rnd.randint(40, 600), y, nm, 28, M["label"], stroke=4, sfill=M["halo"], vc=True)
    for nm in rnd.sample(POIS, 4):
        for _ in range(50):  # keep POI labels off street labels
            x, y = rnd.randint(60, W - 300), rnd.randint(top + 150, bottom - 150)
            if min(abs(y - yy) for yy in hy) > 45:
                break
        c.circle(x, y, 16, fill=rnd.choice([(66, 133, 244), (0, 150, 136), (233, 120, 30), (120, 110, 200)]))
        c.text(x + 26, y, nm, 28, M["label"], stroke=4, sfill=M["halo"], vc=True)
    return vx, hy


def pin(c, x, y, col=(234, 67, 53), r=30):
    c.d.polygon([(x - r * .8, y - r * 1.3), (x + r * .8, y - r * 1.3), (x, y)], fill=mix(col, BLACK, .15))
    c.circle(x, y - r * 1.75, r, fill=col)
    c.circle(x, y - r * 1.75, r * .38, fill=mix(col, BLACK, .45))


def map_search(c, y=130, text="Search here", chips=True):
    card = (48, 50, 54) if c.dark else WHITE
    fg, sub = ((232, 234, 237), (154, 160, 166)) if c.dark else ((32, 33, 36), (95, 99, 104))
    c.rr((36, y + 6, W - 36, y + 136), 65, fill=(0, 0, 0) if c.dark else (200, 200, 200))
    c.rr((36, y, W - 36, y + 130), 65, fill=card)
    pin(c, 96, y + 84, (234, 67, 53), 16)
    c.text(150, y + 65, text, 38, fg if text != "Search here" else sub, vc=True)
    ic_mic(c, W - 190, y + 65, sub)
    avatar(c, W - 100, y + 65, 36, "M")
    if chips:
        x = 36
        for lab, col in [("Restaurants", (233, 120, 30)), ("Hotels", (229, 57, 125)), ("Gas", (66, 133, 244)),
                         ("Coffee", (141, 110, 99)), ("Groceries", (15, 157, 88))]:
            w = c.tw(lab, 32) + 110
            c.rr((x, y + 160, x + w, y + 250), 45, fill=card, outline=(0, 0, 0) if c.dark else (218, 220, 224), width=2)
            c.circle(x + 44, y + 205, 16, fill=col)
            c.text(x + 72, y + 205, lab, 32, fg, vc=True)
            x += w + 18
    return fg, sub, card


def sheet(c, y, card):
    c.rr((0, y - 4, W, H + 40), 48, fill=(0, 0, 0) if c.dark else (200, 200, 200))
    c.rr((0, y, W, H + 40), 48, fill=card)
    c.rr((W / 2 - 50, y + 22, W / 2 + 50, y + 34), 6, fill=(120, 120, 120))


def stars_row(c, x, y, rating, count, fg, sub):
    w = c.text(x, y, f"{rating}", 32, sub)
    w += c.text(x + w + 8, y, "★★★★★"[: int(round(float(rating)))], 30, (251, 188, 4)) + 16
    c.text(x + w, y, f"({count})", 32, sub)


def map_screen(c, variant, place=None, dest=None, eta="12 min (3.4 km)", places=None):
    rnd = c.rnd
    if variant == "place":
        vx, hy = draw_map(c, 0, 1000)
    else:
        vx, hy = draw_map(c)
    fg, sub, card = (None, None, None)
    if variant == "chips":
        fg, sub, card = map_search(c)
        for _ in range(rnd.randint(3, 6)):
            pin(c, rnd.choice(vx), rnd.randint(600, 2000))
        c.circle(W - 110, H - 300, 60, fill=card)
        c.circle(W - 110, H - 300, 16, fill=(66, 133, 244))
    elif variant == "nearby":
        fg, sub, card = map_search(c, text="Restaurants")
        spots = places or ["Trattoria Roma", "Le Petit Bistro", "Sakura Sushi"]
        for i, nm in enumerate(spots):
            x, y = vx[i + 1], hy[2 + i]
            pin(c, x, y, (233, 120, 30))
            lx = x + 36 if x + 36 + c.tw(nm, 30, True) < W - 20 else x - 36 - c.tw(nm, 30, True)
            c.text(lx, y - 50, nm, 30, fg, bold=True, stroke=4, sfill=card)
        y = 1250
        sheet(c, y, card)
        c.text(48, y + 60, "Restaurants nearby", 46, fg, bold=True)
        info = [("4.5", "812", "Italian restaurant", "1.2 km", "23:00"), ("4.3", "264", "French restaurant", "800 m", "22:30"),
                ("4.7", "1,093", "Sushi restaurant", "2.1 km", "22:00")]
        for i, (nm, (r_, n, kind, km, close)) in enumerate(zip(spots, info)):
            yy = y + 160 + i * 300
            c.text(48, yy, nm, 40, fg, bold=True)
            stars_row(c, 48, yy + 60, r_, n, fg, sub)
            c.text(48, yy + 110, f"{kind} · {km}", 32, sub)
            w = c.text(48, yy + 160, "Open", 32, (24, 128, 56))
            c.text(48 + w, yy + 160, f" ⋅ Closes {close}", 32, sub)
            scene(c, (W - 300, yy, W - 48, yy + 220), "food", 20)
            c.d.line((48, yy + 260, W - 48, yy + 260), fill=(70, 70, 70) if c.dark else (230, 230, 230), width=2)
    elif variant == "dir":
        card = (48, 50, 54) if c.dark else WHITE
        fg, sub = ((232, 234, 237), (154, 160, 166)) if c.dark else ((32, 33, 36), (95, 99, 104))
        i1, i2 = rnd.sample(range(1, 4), 2)
        vis = [yy for yy in hy if 700 < yy < 1720] or hy[2:7]
        route = [(vx[i1], vis[-1]), (vx[i1], vis[len(vis) // 2]), (vx[i2], vis[len(vis) // 2]), (vx[i2], vis[0])]
        c.d.line(route, fill=(25, 103, 210), width=30, joint="curve")
        c.d.line(route, fill=(66, 133, 244), width=20, joint="curve")
        c.circle(*route[0], 22, fill=WHITE)
        c.circle(*route[0], 15, fill=(66, 133, 244))
        pin(c, *route[-1])
        lx = route[-1][0] + 40
        if lx + c.tw(dest, 30, True) > W - 20:
            lx = route[-1][0] - 40 - c.tw(dest, 30, True)
        c.text(lx, route[-1][1] - 70, dest, 30, fg, bold=True, stroke=4, sfill=card)
        c.d.rectangle((0, 0, W, 560), fill=card)
        c.sb_bg = card
        ic_back(c, 40, 170, fg)
        for k, (lab, col) in enumerate([("Your location", (66, 133, 244)), (dest, (234, 67, 53))]):
            y = 120 + k * 140
            c.circle(140, y + 50, 14, fill=col)
            c.rr((190, y, W - 120, y + 104), 20, outline=(90, 90, 90) if c.dark else (218, 220, 224), width=3)
            c.text(220, y + 52, lab, 36, fg, vc=True)
        c.text(W - 70, 260, "⇅", 50, fg, align="m", vc=True, record=False)
        for k, lab in enumerate(["12 min", "38 min", "15 min", "45 min"]):
            x = 60 + k * 250
            if k == 0:
                c.rr((x - 20, 430, x + 200, 510), 40, fill=(210, 227, 252) if not c.dark else (40, 70, 120))
            c.text(x + 90, 470, lab if k else eta.split(" (")[0], 32, fg, bold=k == 0, align="m", vc=True)
        y = 1820
        sheet(c, y, card)
        w = c.text(48, y + 70, eta.split(" (")[0], 48, (24, 128, 56), bold=True)
        c.text(64 + w, y + 74, "(" + eta.split(" (")[1], 44, sub)
        c.text(48, y + 150, "Fastest route now due to traffic conditions", 32, sub)
        c.rr((48, y + 240, 340, y + 350), 55, fill=(26, 115, 232))
        c.text(194, y + 295, "Start", 40, WHITE, bold=True, align="m", vc=True)
        c.rr((370, y + 240, 640, y + 350), 55, outline=(120, 120, 120), width=3)
        c.text(505, y + 295, "Steps", 38, (26, 115, 232) if not c.dark else (138, 180, 248), align="m", vc=True)
    elif variant == "place":
        fg, sub, card = map_search(c, text=place, chips=False)
        pin(c, vx[2], hy[4])
        y = 900
        sheet(c, y, card)
        c.text(48, y + 70, place, 54, fg, bold=True)
        stars_row(c, 48, y + 150, "4.5", "812", fg, sub)
        c.text(48, y + 205, "Italian restaurant · €€ · 1.2 km", 32, sub)
        w = c.text(48, y + 255, "Open", 32, (24, 128, 56))
        c.text(48 + w, y + 255, " ⋅ Closes 23:00", 32, sub)
        x = 48
        for k, tab in enumerate(["Overview", "Menu", "Reviews", "Photos", "About"]):
            tw = c.text(x, y + 345, tab, 36, (26, 115, 232) if k == 0 else sub, bold=k == 0)
            if k == 0:
                c.rr((x, y + 410, x + tw, y + 418), 4, fill=(26, 115, 232))
            x += tw + 64
        c.d.line((0, y + 420, W, y + 420), fill=(70, 70, 70) if c.dark else (230, 230, 230), width=2)
        for k, lab in enumerate(["Directions", "Start", "Call", "Save", "Share"]):
            cx = 120 + k * 210
            c.circle(cx, y + 530, 56, fill=(26, 115, 232) if k == 0 else (210, 227, 252) if not c.dark else (40, 70, 120))
            c.text(cx, y + 620, lab, 30, (26, 115, 232) if not c.dark else (138, 180, 248), align="m")
        for k, line in enumerate(["Via Roma 12, 69002 Lyon", "Open ⋅ Closes 23:00", re.sub(r"[^a-z]", "", place.lower()) + ".example", "+33 4 78 00 12 34"]):
            yy = y + 720 + k * 120
            c.circle(80, yy + 22, 18, outline=sub, width=4)
            c.text(140, yy, line, 36, fg)
        scene(c, (48, y + 1210, 520, y + 1420), "food", 20)
        scene(c, (548, y + 1210, W - 48, y + 1420), "food", 20)
    c.sb_bg = c.sb_bg if variant == "dir" else None
    c.nav_bg = card


# --------------------------------------------------------------------------- generic pages

LIGHT = dict(bg=WHITE, fg=(28, 28, 30), sub=(98, 102, 108), card=(242, 243, 245), div=(225, 227, 230),
             acc=(26, 115, 232), accfg=WHITE)
DARK = dict(bg=(18, 18, 20), fg=(232, 234, 237), sub=(158, 162, 168), card=(40, 42, 46), div=(58, 60, 64),
            acc=(138, 180, 248), accfg=(16, 16, 16))
X0, X1 = 48, W - 48
CW = X1 - X0


def header(c, T, h):
    kind = h[0]
    if kind == "browser":
        c.d.rectangle((0, 0, W, 240), fill=T["card"])
        c.sb_bg = T["card"]
        c.rr((36, 116, W - 200, 216), 50, fill=T["bg"])
        ic_lock(c, 84, 162, T["sub"])
        c.text(120, 166, c.ellipsize(h[1], 34, W - 360), 34, T["fg"], vc=True)
        c.rr((W - 168, 138, W - 116, 190), 8, outline=T["fg"], width=4)
        c.text(W - 142, 164, str(c.rnd.randint(2, 19)), 26, T["fg"], bold=True, align="m", vc=True, record=False)
        ic_dots(c, W - 56, 164, T["fg"])
        return 240
    if kind == "bar":
        title, opt = h[1], (h[2] if len(h) > 2 else {})
        bg = opt.get("bg", T["bg"])
        fg = opt.get("fg", T["fg"])
        c.d.rectangle((0, 0, W, 270), fill=bg)
        c.sb_bg = bg
        x = 48
        if opt.get("back", True):
            ic_back(c, 44, 185, fg)
            x = 140
        if title:
            c.text(x, 185, title, opt.get("size", 50), fg, bold=opt.get("bold", False), vc=True)
        ax = W - 60
        for a in opt.get("actions", ["dots"]):
            {"dots": lambda: ic_dots(c, ax, 185, fg), "search": lambda: ic_search(c, ax, 185, fg),
             "cart": lambda: c.rr((ax - 26, 165, ax + 26, 210), 8, outline=fg, width=5),
             "heart": lambda: ic_heart(c, ax, 185, fg, 56), "share": lambda: c.text(ax, 185, "↗", 50, fg, align="m", vc=True, record=False),
             "avatar": lambda: avatar(c, ax, 185, 40, "M")}[a]()
            ax -= 110
        return 270
    if kind == "searchbar":
        c.d.rectangle((0, 0, W, 280), fill=T["bg"])
        c.sb_bg = T["bg"]
        c.rr((36, 130, W - 36, 250), 60, fill=T["card"])
        c.text(80, 190, "☰", 44, T["fg"], vc=True, record=False)
        c.text(160, 190, h[1], 38, T["sub"], vc=True)
        avatar(c, W - 110, 190, 40, "M")
        return 280
    c.sb_bg = None
    return SB_H + 30


def draw_block(c, T, y, b):
    k, a = b[0], b[1:]
    fg, sub, acc = T["fg"], T["sub"], T["acc"]
    if k == "h1":
        return y + c.para(X0, y, a[0], a[1] if len(a) > 1 else 60, CW, fg, True) + 24
    if k == "h2":
        return y + c.para(X0, y, a[0], 46, CW, fg, True) + 18
    if k == "h3":
        return y + c.para(X0, y, a[0], 40, CW, fg, True) + 10
    if k == "p":
        return y + c.para(X0, y, a[0], 36, CW, fg) + 26
    if k == "sub":
        return y + c.para(X0, y, a[0], 32, CW, sub) + 18
    if k == "site":  # coloured site banner with masthead
        c.d.rectangle((0, y, W, y + 140), fill=a[1])
        c.text(X0, y + 70, a[0], 52, WHITE, bold=True, face="arial", vc=True)
        c.text(W - 70, y + 70, "☰", 50, WHITE, align="m", vc=True, record=False)
        return y + 170
    if k == "img":
        scene(c, (X0, y, X1, y + a[0]), a[1], 24)
        return y + a[0] + 30
    if k == "hero":
        scene(c, (0, y, W, y + a[0]), a[1], 0)
        return y + a[0] + 30
    if k == "nav":
        x = X0
        for it in a[0]:
            x += c.text(x, y, it, 34, acc) + 30
            if it != a[0][-1]:
                x += c.text(x, y, "·", 34, sub, record=False) + 30
        c.d.line((0, y + 70, W, y + 70), fill=T["div"], width=2)
        return y + 100
    if k == "btn":
        col = a[1] if len(a) > 1 else acc
        c.rr((X0, y, X1, y + 120), 60, fill=col)
        c.text(W / 2, y + 60, a[0], 40, WHITE if lum(col) < 160 else BLACK, bold=True, align="m", vc=True)
        return y + 150
    if k == "kv":
        bold = len(a) > 2 and a[2]
        c.text(X0, y, a[0], 36 if not bold else 40, sub if not bold else fg, bold=bold)
        c.text(X1, y, a[1], 36 if not bold else 40, fg, bold=bold, align="r")
        return y + 72
    if k == "div":
        c.d.line((X0, y + 10, X1, y + 10), fill=T["div"], width=2)
        return y + 34
    if k == "sp":
        return y + a[0]
    if k == "toggle":
        on = a[2]
        c.text(X0, y, a[0], 40, fg)
        if a[1]:
            c.text(X0, y + 58, a[1], 32, sub)
        tx = X1 - 110
        c.rr((tx, y + 10, tx + 110, y + 70), 30, fill=acc if on else T["div"])
        c.circle(tx + (80 if on else 30), y + 40, 22, fill=T["accfg"] if on else sub)
        return y + (140 if a[1] else 110)
    if k == "li":  # (title, sub, right, lead)
        title, s2, right, lead = (list(a) + [None] * 4)[:4]
        tx = X0
        if lead:
            if lead[0] == "av":
                avatar(c, X0 + 50, y + 50, 50, lead[1])
            elif lead[0] == "wifi":
                ic_wifi(c, X0 + 40, y + 62, fg, 40, lead[1])
                if len(lead) > 2:
                    ic_lock(c, X0 + 64, y + 66, fg)
            else:
                c.circle(X0 + 40, y + 50, 36, fill=lead[1])
            tx = X0 + 140
        c.text(tx, y, c.ellipsize(title, 40, X1 - tx - (200 if right else 0), bool(lead and lead[0] == "av")), 40, fg,
               bold=bool(lead and lead[0] == "av"))
        if right:
            c.text(X1, y + 4, right, 30, sub, align="r")
        if s2:
            c.para(tx, y + 58, c.ellipsize(s2, 32, X1 - tx) if "\n" not in s2 else s2, 32, X1 - tx, sub, max_lines=2)
        return y + (130 + (44 if s2 and "\n" in s2 else 0) if s2 else 116)
    if k == "mail":  # sender, subject, snippet, time, unread
        snd, subj, snip, tm, unread = a
        avatar(c, X0 + 50, y + 54, 50, snd)
        c.text(X0 + 140, y, snd, 40, fg, bold=unread)
        c.text(X1, y + 6, tm, 30, fg if unread else sub, bold=unread, align="r")
        c.text(X0 + 140, y + 56, c.ellipsize(subj, 36, CW - 160, unread), 36, fg, bold=unread)
        c.text(X0 + 140, y + 106, c.ellipsize(snip, 34, CW - 160), 34, sub)
        return y + 190
    if k == "result":
        c.text(X0, y, a[0], 30, sub)
        h1 = c.para(X0, y + 46, a[1], 42, CW, acc)
        return y + 46 + h1 + c.para(X0, y + 56 + h1, a[2], 34, CW, sub) + 50
    if k == "tabs":
        x, act = X0, a[1]
        for i, it in enumerate(a[0]):
            w = c.text(x, y, it, 38, fg if i == act else sub, bold=i == act)
            if i == act:
                c.rr((x, y + 64, x + w, y + 72), 4, fill=fg)
            x += w + 70
        c.d.line((0, y + 72, W, y + 72), fill=T["div"], width=2)
        return y + 110
    if k == "chips":
        x = X0
        for i, it in enumerate(a[0]):
            w = c.tw(it, 32) + 60
            c.rr((x, y, x + w, y + 80), 40, fill=acc if i == 0 else T["card"])
            c.text(x + 30, y + 40, it, 32, T["accfg"] if i == 0 else fg, vc=True)
            x += w + 18
        return y + 110
    if k == "grid":  # products: (name, price, kind, colour)
        cw = (CW - 30) // 2
        for i, (nm, price, kind, col) in enumerate(a[0]):
            x, yy = X0 + (i % 2) * (cw + 30), y + (i // 2) * 820
            product(c, (x, yy, x + cw, yy + 540), kind, col)
            ic_heart(c, x + cw - 50, yy + 50, fg, 50)
            c.para(x, yy + 560, nm, 34, cw, fg, max_lines=2)
            c.text(x, yy + 660, price, 38, fg, bold=True)
            if len(a) > 1 and a[1]:
                c.rr((x, yy + 720, x + cw, yy + 800), 40, outline=fg, width=3)
                c.text(x + cw / 2, yy + 760, "Add to bag", 32, fg, bold=True, align="m", vc=True)
        return y + ((len(a[0]) + 1) // 2) * 820
    if k == "dish":  # name, desc, price
        scene(c, (X1 - 230, y, X1, y + 230), "food", 24)
        c.text(X0, y + 6, a[0], 40, fg, bold=True)
        c.para(X0, y + 64, a[1], 32, CW - 280, sub, max_lines=2)
        c.text(X0, y + 176, a[2], 36, fg)
        c.d.line((X0, y + 262, X1, y + 262), fill=T["div"], width=2)
        return y + 292
    if k == "check":
        done = a[1]
        c.rr((X0, y + 4, X0 + 50, y + 54), 10, outline=sub if not done else acc, width=4, fill=acc if done else None)
        if done:
            c.d.line([(X0 + 12, y + 30), (X0 + 22, y + 42), (X0 + 40, y + 16)], fill=T["accfg"], width=5)
        w = c.text(X0 + 80, y, a[0], 38, sub if done else fg)
        if done:
            c.d.line((X0 + 80, y + 30, X0 + 80 + w, y + 30), fill=sub, width=3)
        return y + 84
    if k == "bullets":
        for it in a[0]:
            c.text(X0, y, "•", 36, fg, record=False)
            y += c.para(X0 + 44, y, it, 36, CW - 44, fg) + 12
        return y + 14
    if k == "banner":
        col = a[1]
        c.rr((X0, y, X1, y + 150), 28, fill=col)
        c.text(X0 + 40, y + 75, a[0], 42, WHITE if lum(col) < 160 else BLACK, bold=True, vc=True)
        return y + 180
    if k == "card":  # boxed key/value list
        rows = a[0]
        c.rr((X0, y, X1, y + 40 + 76 * len(rows)), 28, fill=T["card"])
        for i, (kk, vv) in enumerate(rows):
            c.text(X0 + 36, y + 30 + i * 76, kk, 34, sub)
            c.text(X1 - 36, y + 30 + i * 76, vv, 34, fg, bold=True, align="r")
        return y + 70 + 76 * len(rows)
    if k == "qr":
        s, n = a[0], 25
        x0, cell = (W - s) / 2, s / n
        c.d.rectangle((x0 - 30, y - 30, x0 + s + 30, y + s + 30), fill=WHITE)
        for i in range(n):
            for j in range(n):
                if c.rnd.random() < .5:
                    c.d.rectangle((x0 + i * cell, y + j * cell, x0 + (i + 1) * cell, y + (j + 1) * cell), fill=BLACK)
        for fx, fy in ((0, 0), (n - 7, 0), (0, n - 7)):
            bx, by = x0 + fx * cell, y + fy * cell
            c.d.rectangle((bx, by, bx + 7 * cell, by + 7 * cell), fill=WHITE)
            c.d.rectangle((bx, by, bx + 7 * cell, by + 7 * cell), outline=BLACK, width=int(cell))
            c.d.rectangle((bx + 2 * cell, by + 2 * cell, bx + 5 * cell, by + 5 * cell), fill=BLACK)
        return y + s + 70
    if k == "barcode":
        x = X0 + 60
        c.d.rectangle((X0, y, X1, y + 220), fill=WHITE)
        while x < X1 - 70:
            bw = c.rnd.choice([4, 4, 8, 12])
            c.d.rectangle((x, y + 20, x + bw, y + 200), fill=BLACK)
            x += bw + c.rnd.choice([4, 6, 10])
        return y + 250
    if k == "cal":  # (start_hour, [(start "HH:MM", minutes, title, colour)])
        h0, evs = a
        for i in range(10):
            yy = y + i * 160
            c.text(X0, yy - 16, f"{h0 + i:02d}:00", 30, sub)
            c.d.line((X0 + 120, yy, X1, yy), fill=T["div"], width=2)
        for st, mins, title, col in evs:
            hh, mm = map(int, st.split(":"))
            yy = y + (hh - h0 + mm / 60) * 160
            c.rr((X0 + 140, yy + 4, X1, yy + max(110, mins / 60 * 160) - 4), 18, fill=col)
            c.text(X0 + 170, yy + 18, title, 36, WHITE, bold=True)
            c.text(X0 + 170, yy + 66, st + f" – {(hh * 60 + mm + mins) // 60:02d}:{(mm + mins) % 60:02d}", 30, WHITE)
        return y + 1600
    if k == "post":  # (user, scene, likes_by, likes, caption, comments, ago)
        user, sc, lb, likes, cap, ncom, ago = a
        avatar(c, X0 + 40, y + 50, 38, user, ring=(225, 48, 108))
        c.text(X0 + 110, y + 50, user, 36, fg, bold=True, vc=True)
        c.text(X1, y + 50, "···", 40, fg, align="r", vc=True, record=False)
        scene(c, (0, y + 110, W, y + 110 + W), sc)
        yy = y + 130 + W
        for i, g in enumerate(["♡", "💬", "↗"]):
            c.text(X0 + 20 + i * 100, yy + 40, g, 52, fg, align="m", vc=True, record=False)
        c.text(X1 - 20, yy + 40, "⚐", 52, fg, align="r", vc=True, record=False)
        yy += 100
        c.text(X0, yy, f"Liked by {lb} and {likes} others", 34, fg)
        yy += 56
        w = c.text(X0, yy, user, 34, fg, bold=True, record=False)
        c.para(X0 + w + 14, yy, cap, 34, CW - w - 14, fg, max_lines=2)
        if c.texts and c.texts[-1] == (cap, c.role):
            c.texts[-1] = (f"{user} {cap}", c.role)
        yy += 104
        c.text(X0, yy, f"View all {ncom} comments", 32, sub)
        c.text(X0, yy + 52, ago, 28, sub)
        return yy + 130
    if k == "tweet":  # (name, handle, ago, text, counts)
        name, handle, ago, text, counts = a
        avatar(c, X0 + 46, y + 46, 46, name)
        w = c.text(X0 + 120, y, name, 36, fg, bold=True)
        c.text(X0 + 136 + w, y, f"@{handle} · {ago}", 34, sub)
        hh = c.para(X0 + 120, y + 56, text, 36, CW - 120, fg)
        yy = y + 76 + hh
        for i, n in enumerate(counts):
            c.text(X0 + 120 + i * 220, yy, ["💬", "⇄", "♡", "↗"][i] + " " + n if i != 1 else "⇄ " + n, 30, sub)
        c.d.line((0, yy + 70, W, yy + 70), fill=T["div"], width=2)
        return yy + 100
    if k == "clock":
        c.text(W / 2, y, c.when.strftime("%H:%M"), 210, WHITE, align="m", record=False)  # matches the status bar
        c.text(W / 2, y + 280, c.when.strftime("%A %d %B").replace(" 0", " "), 40, WHITE, align="m")
        return y + 380
    if k == "notif":  # (app, title, body, ago)
        app, title, body, ago = a
        c.rr((36, y, W - 36, y + 250), 40, fill=(250, 250, 252) if not c.dark else (44, 46, 50))
        c.circle(96, y + 60, 26, fill=(26, 115, 232))
        c.text(140, y + 60, f"{app} · {ago}", 30, sub, vc=True)
        c.text(96 - 26, y + 110, title, 38, fg, bold=True)
        c.text(96 - 26, y + 166, c.ellipsize(body, 34, W - 200), 34, fg)
        return y + 280
    raise ValueError(k)


def page(c, header_spec, blocks, theme=None, bottom=None, bg=None, wall=None):
    T = dict(DARK if c.dark else LIGHT)
    T.update(theme or {})
    c.img.paste(bg or T["bg"], (0, 0, W, H))
    if wall:
        scene(c, (0, 0, W, H), wall)
    y = header(c, T, header_spec) + 30
    if header_spec[0] == "none" and wall:
        c.sb_bg = None
    bottom_top = H - NAV_H - (170 if bottom else 0)
    c.vis = (0, bottom_top)
    for b in blocks:
        if y > bottom_top:
            break
        y = draw_block(c, T, y, b)
    c.vis = (0, H)
    if bottom:
        c.d.rectangle((0, bottom_top, W, H), fill=T["card"] if not c.dark else (30, 31, 34))
        n = len(bottom)
        for i, lab in enumerate(bottom):
            cx = W * (2 * i + 1) / (2 * n)
            active = i == 0
            if active:
                c.rr((cx - 60, bottom_top + 22, cx + 60, bottom_top + 82), 30, fill=mix(T["acc"], T["bg"], .7))
            c.circle(cx, bottom_top + 52, 16, outline=T["fg"], width=4)
            c.text(cx, bottom_top + 100, lab, 30, T["fg"], bold=active, align="m")
    c.nav_bg = (T["card"] if not c.dark else (30, 31, 34)) if bottom else None if wall else T["bg"]


# --------------------------------------------------------------------------- catalog

CATALOG: list = []
S = dict(wa="whatsapp_like", ms="messenger_like", ig="instagram_like", sms="sms_like")


def chat(id_, st, th, title, msgs, desc, sub=None, group=False, tags=()):
    CATALOG.append(dict(id=id_, screen_type="chat", style=S[st], theme="dark" if th == "d" else "light", desc=desc,
                        chat_title=title, chat_is_group=group, tags=list(tags),
                        fn=lambda c: chat_screen(c, S[st], title, msgs, sub, group)))


def scr(id_, typ, th, desc, fn, style="generic", tags=()):
    CATALOG.append(dict(id=id_, screen_type=typ, style=style, theme="dark" if th == "d" else "light",
                        desc=desc, tags=list(tags), fn=fn))


def pg(id_, typ, th, desc, hdr, blocks, tags=(), style="generic", **kw):
    scr(id_, typ, th, desc, lambda c: page(c, hdr, blocks, **kw), style, tags)


# ---- chats with Jamie (1:1)
chat("chat_wa_jamie_light", "wa", "l", "Jamie", """
= TODAY
> Are we still on for dinner tonight?
< Yes! I found two restaurants near the station
< The Thai place or the pizza one?
> Thai please 🙏 I had pizza yesterday
< Ok booking for 19:30
> Perfect. Is Alex coming too?
< He said maybe, he'll text you
""", "1:1 chat with Jamie about dinner plans")
chat("chat_ms_jamie_keys", "ms", "d", "Jamie", """
= {t}
< Did you take my keys by mistake? 🔑
> Oh no… they're in my bag 🙈
< Haha no worries
< Can you drop them off after work?
> Sure, around 6?
< Leave them with the neighbour if I'm not home
> Will do!
""", "1:1 chat with Jamie about returning keys")
chat("chat_ig_jamie_flight", "ig", "l", "Jamie", """
= Today {t}
< What time does your flight land?
> 14:25 at Terminal 2
< I'll pick you up at arrivals
> You're the best ❤️
> Update: gate changed, now landing 14:50
< No problem, I'll wait in the car park
""", "1:1 chat with Jamie about flight arrival time", sub="jamie.r")
chat("chat_sms_jamie_photos", "sms", "l", "Jamie", """
= Yesterday · {t}
< Can you send me the photos from Saturday?
> Sending now, there are like 80 of them
< Haha that's fine
> The one at the lake is my favourite
< Same! Going to print it for the fridge
""", "1:1 SMS with Jamie about weekend photos")
chat("chat_wa_jamie_money_dark", "wa", "d", "Jamie", """
= TODAY
> Hey, can you send me 20 for the concert tickets?
< Sure, sending now
< Done 👍
> Got it, thanks!
> See you Friday
""", "1:1 chat with Jamie asking to send 20 for tickets")
chat("chat_ms_jamie_long", "ms", "l", "Jamie", """
< Morning! Still ok to help me move the sofa?
> Yes, what time?
< 10ish?
> Make it 10:30, I need coffee first ☕
< Deal
> Do you have straps or should I bring mine?
< Bring yours, mine snapped last time
> Haha ok
> Is the van booked?
< Yes, picking it up at 9
> Great
< Also the wardrobe needs to come apart
> I'll bring the toolbox
< Legend
> How many floors again?
< Third floor, no lift 😅
> Oh no
< Pizza is on me after
> Now we're talking 🍕
< See you tomorrow!
> 👋
""", "long scrolled 1:1 chat with Jamie about moving furniture")
chat("chat_ig_jamie_dark", "ig", "d", "Jamie", """
= Today {t}
> Did you get the tickets?
< Two tickets, row F 🎶
> Amazing!! How much do I owe you?
< 45, no rush
> Sending tonight
""", "1:1 chat with Jamie about concert tickets", sub="jamie.r")
chat("chat_sms_jamie_late_dark", "sms", "d", "Jamie", """
= Today · {t}
> Running 10 min late, sorry!
< No worries, I'm at the corner table
> Order me a coffee?
< Already did
""", "1:1 SMS with Jamie running late")
chat("chat_wa_jamie_holiday", "wa", "l", "Jamie", """
< Found a nice place in Porto for July
< Hotel near the river, breakfast included
> Send me the link!
< Sent it by email
> Looks great. What dates?
< 12th to 16th?
> Works for me. I'll ask for the days off
< Shall I book it then?
> Yes go for it
< Booked ✅
> Yay!! 🎉
< Now we need flights
> I'll check tonight
""", "long 1:1 chat with Jamie planning a holiday in Porto", sub="last seen today at 09:12")
chat("chat_ms_jamie_recipe_dark", "ms", "d", "Jamie", """
= {t}
< What was that pasta we had last week?
> Cacio e pepe! I'll send you the recipe
< Please, I want to cook it on Sunday
> It's just pecorino, pepper and pasta water
< That's it?
> That's it 😄
""", "1:1 chat with Jamie about a pasta recipe")

# ---- Jamie full name / emoji titles
chat("chat_wa_jamiefox_light", "wa", "l", "Jamie Fox", """
= TODAY
< Hi Jamie, the slides for Monday are ready
> Thanks! I'll review them tonight
< Shared in the team folder
> Got them. Slide 7 needs the new numbers
< On it
""", "1:1 work chat with Jamie Fox about slides", sub="online")
chat("chat_sms_jamiefox_dark", "sms", "d", "Jamie Fox", """
= Yesterday · {t}
> Hi, it's Jamie Fox from the running club
> Are you joining the Sunday 10k?
< Yes, count me in!
> Great, we meet at the park gate at 8
""", "SMS with Jamie Fox about a Sunday run")
chat("chat_ig_jamie_sunflower", "ig", "l", "Jamie 🌻", """
= Today {t}
> Look at my balcony garden 🌻
< Wow they got so tall!
> Planted them in April
< Can I have some seeds next year?
> Of course
""", "1:1 chat with Jamie (sunflower emoji in title) about gardening", sub="jamie.sun")

# ---- other people mentioning Jamie
chat("chat_ms_alex_mentions_jamie", "ms", "l", "Alex", """
= {t}
> Jamie said she'd bring the cake
< Great, I'll get the candles
> And balloons?
< Sam is on balloons
""", "chat with Alex; Jamie mentioned in body")
chat("chat_wa_mom_mentions_jamie", "wa", "l", "Mom", """
= TODAY
> Are you coming for lunch on Sunday?
< Yes! What time?
> 12:30. Ask Jamie for the keys, I'll be at the market
< Ok will do
> Love you ❤️
""", "chat with Mom; Jamie mentioned in body")
chat("chat_sms_sam_mentions_jamie", "sms", "l", "Sam", """
= Today · {t}
> Is Jamie coming to the match?
< I think so, she bought a ticket
> Nice, we can share a taxi then
""", "SMS with Sam; Jamie mentioned in body")
chat("chat_ig_priya_mentions_jamie", "ig", "d", "Priya", """
= Today {t}
> Jamie recommended this restaurant for Friday
> The menu at that restaurant was great last time
< Book it! 8pm?
> Done ✅
""", "chat with Priya about a restaurant Jamie recommended", sub="priya.k")
chat("chat_wa_lena_mentions_jamie", "wa", "d", "Lena", """
= TODAY
> Jamie and I will be there at 8
< Perfect, I'll save you seats
> Thanks!! 😘
""", "chat with Lena; Jamie mentioned in body")
chat("chat_ms_marco_mentions_jamie", "ms", "d", "Marco", """
= {t}
> Tell Jamie I found her scarf in my car
< Haha she was looking everywhere
> I'll bring it on Saturday
""", "chat with Marco; Jamie mentioned in body")

# ---- groups
chat("chat_wa_group_jamie_birthday", "wa", "l", "Jamie's birthday 🎂", """
= TODAY
> Alex| Who's bringing the cake?
> Sam| I can pick it up at 5
< I'll get the decorations
> Alex| Remember it's a surprise, don't tell her 🤫
> Sam| My lips are sealed
""", "group chat named after Jamie's birthday", sub="You, Jamie, Alex, Sam", group=True)
chat("chat_wa_group_sunday_league", "wa", "d", "Sunday League ⚽", """
= TODAY
> Jamie| Pitch is booked for 10:00
> Tom| I'm in
> Marco| In 👍
> Jamie| We need one more player
< I'll ask my brother
> Jamie| Legend
""", "football group chat with messages from Jamie", sub="Jamie, Marco, Tom, You", group=True)
chat("chat_sms_group_sunday_league", "sms", "l", "Sunday League ⚽", """
= Yesterday · {t}
> Tom| Great game today lads
> Jamie| Same time next week?
< Yes!
> Jamie| I'll bring the new ball
""", "football group SMS thread with messages from Jamie", group=True)
chat("chat_ig_group_flat4b", "ig", "l", "Flat 4B", """
= Today {t}
> Priya| Heating is off again 🥶
> Lena| Jamie is fixing the boiler tomorrow
< Thank you Jamie!
> Priya| Who's buying bin bags?
< Me
""", "flat-share group chat mentioning Jamie", sub="Priya, Lena, Jamie, You", group=True)
chat("chat_ms_group_book_club", "ms", "l", "Book club 📚", """
= {t}
> Nina| Next book: The Old Man and the Sea
> Chloe| Short one, I like it
< Meeting at mine on the 14th?
> Nina| Perfect
""", "book club group chat (body mentions man)", group=True)

# ---- prefix / substring distractors
chat("chat_wa_jamieson_plumbing", "wa", "l", "Jamieson Plumbing", """
= TODAY
> Hello, this is Jamieson Plumbing. Your appointment is confirmed for Tuesday 9:00
< Great, thank you
> Our engineer will call 30 minutes before arrival
""", "business chat with Jamieson Plumbing (prefix distractor)", sub="Business account")
chat("chat_ms_benjamin", "ms", "l", "Benjamin", """
= {t}
> Still up for tennis tomorrow?
< Yes, court 3 at 7
> See you there 🎾
""", "chat with Benjamin (substring distractor)")
chat("chat_sms_jamal_dark", "sms", "d", "Jamal", """
= Today · {t}
> Bro did you watch the game?
< Last minute goal!! 😱
> Unreal
""", "SMS with Jamal (prefix distractor)")

# ---- other chats
chat("chat_wa_alex_iban", "wa", "l", "Alex", """
= TODAY
< Can you send me your bank details for the rent?
> IBAN DE89 3704 0044 0532 0130 00
> Name: Alex Morgan
< Thanks, transferring now
""", "chat with Alex sharing an IBAN", tags=["iban"])
chat("chat_sms_mom", "sms", "l", "Mom", """
= Today · {t}
> Did you get home safe?
< Yes, just arrived
> Good. Call me tomorrow 😘
""", "SMS with Mom")
chat("chat_ig_sam_germany", "ig", "l", "Sam", """
= Today {t}
> Berlin or Munich for the trip to Germany?
< Berlin! Then a day in Leipzig
> Train tickets are cheaper on Tuesday
< Let's book them tonight
""", "chat with Sam about a trip to Germany", sub="sam.k")
chat("chat_wa_priya_wifi_dark", "wa", "d", "Priya", """
= TODAY
< What's the wifi at the cabin?
> network CabinNet, password pinecone2026
< Thanks! Connected
""", "chat with Priya sharing a Wi-Fi password", tags=["wifi_password"])
chat("chat_ms_lena_address", "ms", "l", "Lena", """
= {t}
< What's your new address?
> 14 Linden Road, Flat 2, Bristol BS1 4DJ
< Thanks, the parcel is on its way
""", "chat with Lena sharing an address")
chat("chat_ig_marco_restaurants_dark", "ig", "d", "Marco", """
= Today {t}
> Any good restaurants in Lyon?
< So many! Try the bouchons near Rue Mercière
> Bookmarked
""", "chat with Marco about restaurants in Lyon", sub="marco.b")
chat("chat_sms_dad_dark", "sms", "d", "Dad", """
= Yesterday · {t}
> The man from the garage called
> Car is ready, 240 for the service
< Thanks Dad, I'll pick it up Monday
""", "SMS with Dad about the car (body mentions man)")
chat("chat_sms_dr_patel", "sms", "l", "Dr Patel Clinic", """
= Today · {t}
> Reminder: your appointment is on 12 March at 10:15
> Reply C to confirm or call 020 7946 0321
< C
> Thank you, your appointment is confirmed
""", "SMS reminder from Dr Patel Clinic")
chat("chat_wa_unknown_number", "wa", "l", "+33 6 12 34 56 78", """
= TODAY
> Bonjour, your parcel will be delivered tomorrow between 9 and 12
< Merci!
> Please leave a code for the building door
< 4721B
""", "chat with an unknown French number about a delivery", sub="")
chat("chat_ms_nina_men_dark", "ms", "d", "Nina", """
= {t}
> The men's final is on tonight!
< Watching at the pub?
> Yes, 8pm, the usual one
""", "chat with Nina about the men's final")
chat("chat_wa_tom_man", "wa", "l", "Tom", """
= TODAY
> That man at the market sold me 3 kilos of apples 🍎
< Apple pie then?
> Already in the oven
""", "chat with Tom about the market (body mentions man)")
chat("chat_ig_oliver_menu", "ig", "l", "Oliver", """
= Today {t}
> Check out the new menu at the café downstairs
< Is the brunch still good?
> Even better, they added pancakes
""", "chat with Oliver about a café menu", sub="oliver.w")
chat("chat_sms_sophie_restaurants", "sms", "l", "Sophie", """
= Yesterday · {t}
> Most restaurants are closed on Monday here
< Let's do Tuesday then
> Tuesday works 👍
""", "SMS with Sophie about restaurants closed on Monday")
chat("chat_ig_alex_gym_dark", "ig", "d", "Alex", """
= Today {t}
> Gym at 7 tomorrow?
< Make it 7:30
> Fine, lazy bones 😂
""", "chat with Alex about the gym", sub="alex.m")
chat("chat_wa_sam_dark", "wa", "d", "Sam", """
= TODAY
> Did you see the match?
< Missed it, was it good?
> 3-2, last minute winner
""", "chat with Sam about a match")
chat("chat_ms_mom_recipe", "ms", "l", "Mom", """
= {t}
> I'm making soup tonight, want some?
< Yes please!
> I'll leave a box at your door
""", "chat with Mom about soup")
chat("chat_wa_dad_garden", "wa", "l", "Dad", """
= TODAY
> Tomatoes are finally red 🍅
< Save me some!
> Come by on Saturday
""", "chat with Dad about the garden")
chat("chat_sms_chloe_dark", "sms", "d", "Chloe", """
= Today · {t}
> Can I borrow your tent this weekend?
< Sure, it's in the garage
> You're a star ⭐
""", "SMS with Chloe about borrowing a tent")
chat("chat_ms_group_work_team", "ms", "l", "Work team", """
= {t}
> Oliver| Standup moved to 10:30
> Nina| Thanks for the heads up
< 👍
""", "work group chat about a meeting", group=True)
chat("chat_wa_grandma", "wa", "l", "Grandma", """
= TODAY
> Happy Sunday darling
< Hi Grandma! Coming to see you next week
> I'll make your favourite cake
""", "chat with Grandma")
chat("chat_ig_lena_hike", "ig", "l", "Lena", """
= Today {t}
> Hike on Saturday? The weather looks good
< Yes! Which trail?
> The lakeside one, 12 km
""", "chat with Lena about a hike", sub="lena.travels")
chat("chat_sms_priya_hotel_dark", "sms", "d", "Priya", """
= Today · {t}
> Booked the hotel for the conference
> Two nights, breakfast included
< Great, send me the confirmation
""", "SMS with Priya about a hotel booking")
chat("chat_wa_marco_football_dark", "wa", "d", "Marco", """
= TODAY
> Training moved to Thursday
< Same pitch?
> Yes, 19:00
""", "chat with Marco about football training")
chat("chat_ms_tom_menu_dark", "ms", "d", "Tom", """
= {t}
> They changed the lunch menu at work
< Better or worse?
> Way more vegetarian options
""", "chat with Tom about a lunch menu")
chat("chat_sms_unknown_number_uk", "sms", "l", "+44 7700 900123", """
= Today · {t}
> Hi, is the bike still for sale?
< Yes it is
> Can I see it tomorrow at 6?
""", "SMS from an unknown UK number about a bike for sale")
chat("chat_ig_sam_men_jackets", "ig", "l", "Sam", """
= Today {t}
> Sale on men's jackets this week
< Send me the link!
> Sent ✅
""", "chat with Sam about a men's jackets sale", sub="sam.k")
chat("chat_wa_lena_restaurant_dark", "wa", "d", "Lena", """
= TODAY
< That restaurant by the river was lovely
> The dessert menu was the best part
< Let's go back for your birthday
""", "chat with Lena about a restaurant and its dessert menu")

# ---- maps
CITY_DIR = [("Hotel Lumière", "12 min (3.4 km)"), ("Grand Hotel Central", "18 min (6.1 km)"),
            ("Ibis Budget", "9 min (2.2 km)"), ("Hotel Lumière", "25 min (11 km)")]
for i, (dest, eta) in enumerate(CITY_DIR):
    scr(f"map_dir_hotel_{i}", "map", "d" if i == 3 else "l", f"map directions to {dest}",
        lambda c, d_=dest, e_=eta: map_screen(c, "dir", dest=d_, eta=e_), "maps_like", ["directions_to:hotel"])
for i, (dest, eta) in enumerate([("Central Station", "14 min (4.0 km)"), ("Airport Terminal 2", "32 min (24 km)")]):
    scr(f"map_dir_other_{i}", "map", "l" if i == 0 else "d", f"map directions to {dest}",
        lambda c, d_=dest, e_=eta: map_screen(c, "dir", dest=d_, eta=e_), "maps_like")
for i in range(4):
    scr(f"map_chips_{i}", "map", "d" if i % 2 else "l", "map with search bar and category chips",
        lambda c: map_screen(c, "chips"), "maps_like")
for i, sp in enumerate([None, ["Bella Napoli", "Chez Margot", "Golden Dragon"], ["Taverna Kostas", "Le Comptoir", "Ramen Ichi"]]):
    scr(f"map_restaurants_nearby_{i}", "map", "d" if i == 2 else "l", "map with a bottom sheet listing restaurants nearby",
        lambda c, s_=sp: map_screen(c, "nearby", places=s_), "maps_like")
for i, nm in enumerate(["Trattoria Roma", "Osteria del Ponte"]):
    scr(f"map_place_restaurant_{i}", "map", "l" if i == 0 else "d", f"map place page for restaurant {nm} (has Menu tab)",
        lambda c, n_=nm: map_screen(c, "place", place=n_), "maps_like")
scr("map_chips_extra_dark", "map", "d", "dark map with chips", lambda c: map_screen(c, "chips"), "maps_like")

# ---- web
WEB = [
    ("web_news_man_rescued", "l", "https://www.cityherald.com/news/local/man-rescued-river", ("CITY HERALD", (180, 30, 40)),
     [("sub", "Local news · 3 min read"), ("h1", "Man rescued from river after 3 hours"),
      ("sub", "By Clara Benton · Updated 08:14"), ("img", 520, "river"),
      ("p", "A 42-year-old man was pulled from the river on Tuesday evening after clinging to a fallen tree for more than three hours, firefighters said."),
      ("p", "Emergency crews were alerted by a dog walker who heard shouting near the old mill.")], "news article about a man rescued from a river"),
    ("web_sport_mens_world_cup", "d", "https://sport.example.com/football/mens-world-cup-qualifiers", ("SPORT DAILY", (20, 90, 60)),
     [("nav", ["Football", "Tennis", "F1"]), ("h1", "Men's World Cup qualifiers: five things we learned"),
      ("img", 500, "stadium"), ("p", "A late equaliser kept the group wide open, while two debutants impressed in midfield."),
      ("p", "The next round of fixtures takes place in March.")], "sports article about men's World Cup qualifiers"),
    ("web_best_restaurants_lyon", "l", "https://www.foodtraveller.example/lyon/best-restaurants", ("FOOD TRAVELLER", (230, 100, 30)),
     [("h1", "The 10 best restaurants in Lyon"), ("sub", "Our critics' picks for 2026"), ("img", 480, "food"),
      ("h2", "1. Le Bouchon des Filles"), ("p", "Classic Lyonnaise cooking in a cosy room with checked tablecloths."),
      ("h2", "2. Café Comptoir Abel"), ("p", "One of the oldest bouchons in town.")], "listicle of the best restaurants in Lyon"),
    ("web_recipe_risotto", "l", "https://www.homecook.example/recipes/mushroom-risotto", ("HOMECOOK", (60, 120, 60)),
     [("h1", "Creamy mushroom risotto"), ("sub", "Serves 4 · 40 minutes"), ("img", 460, "food"), ("h2", "Ingredients"),
      ("bullets", ["300 g arborio rice", "250 g chestnut mushrooms", "1 litre vegetable stock", "50 g parmesan", "1 onion, finely chopped"])],
     "recipe page for mushroom risotto"),
    ("web_restaurant_site_hours", "l", "https://www.trattoriaroma.example/opening-hours", ("Trattoria Roma", (120, 30, 30)),
     [("nav", ["Home", "Menu", "Book a table"]), ("h1", "Opening hours"),
      ("kv", "Monday", "Closed"), ("kv", "Tuesday – Friday", "12:00 – 23:00"), ("kv", "Saturday", "11:00 – 23:30"),
      ("kv", "Sunday", "11:00 – 16:00"), ("sp", 30), ("p", "Via Roma 12, Lyon. Call us on +33 4 78 00 12 34."),
      ("btn", "Book a table", (120, 30, 30))], "restaurant website opening hours page (nav has Menu)"),
    ("web_hotel_booking", "l", "https://www.hotel-lumiere.example/book", ("Hotel Lumière", (30, 50, 90)),
     [("img", 520, "city"), ("h1", "Hotel Lumière – Book now"), ("sub", "★★★★ · 12 Rue de la Paix, Paris"),
      ("card", [("Check-in", "Fri 14 Mar"), ("Check-out", "Sun 16 Mar"), ("Guests", "2 adults")]),
      ("kv", "2 nights", "€318", True), ("btn", "Book now", (30, 50, 90))], "hotel booking web page"),
    ("web_wiki_lyon", "l", "https://en.encyclopedia.example/wiki/Lyon", ("Encyclopedia", (90, 90, 90)),
     [("h1", "Lyon", 64), ("sub", "From the free encyclopedia"), ("div",),
      ("p", "Lyon is the third-largest city of France. It is located at the confluence of the rivers Rhône and Saône."),
      ("img", 420, "city"), ("p", "The city is known for its cuisine and gastronomy, as well as historical and architectural landmarks.")],
     "encyclopedia article about Lyon"),
    ("web_search_pizza", "l", "https://www.search.example/search?q=best+pizza+near+me", None,
     [("chips", ["All", "Maps", "Images", "News"]), ("result", "pizzeria-luigi.example", "Pizzeria Luigi – Wood-fired pizza", "Open until 23:00 · 4.6 ★ · Order online or book a table."),
      ("result", "foodguide.example › pizza", "15 best pizza places in town (2026)", "We tried 40 pizzerias so you don't have to."),
      ("result", "napoli-express.example", "Napoli Express – Delivery", "Free delivery on orders over 20.")], "search results for best pizza"),
    ("web_weather", "d", "https://weather.example.com/lyon", ("WEATHER NOW", (40, 90, 160)),
     [("h1", "Lyon, France"), ("h1", "18°  Partly cloudy", 72), ("sub", "Feels like 16° · Wind 12 km/h"),
      ("img", 380, "sky"), ("kv", "Tomorrow", "21° / 11°"), ("kv", "Saturday", "19° / 10°"), ("kv", "Sunday", "15° / 9°")], "weather forecast page"),
    ("web_news_tram", "l", "https://www.cityherald.com/news/council-approves-tram-line", ("CITY HERALD", (180, 30, 40)),
     [("h1", "City council approves new tram line"), ("sub", "By Omar Haddad · 2 hours ago"), ("img", 480, "city"),
      ("p", "The 9 km line will connect the university to the airport, with 14 new stops."),
      ("p", "Construction is expected to start next spring.")], "news article about a new tram line"),
    ("web_search_hotel_lumiere", "d", "https://www.search.example/search?q=hotel+lumiere+paris", None,
     [("chips", ["All", "Hotels", "Maps", "Images"]), ("result", "hotel-lumiere.example", "Hotel Lumière Paris – Official site", "Boutique hotel near the Opéra. Best price guaranteed."),
      ("result", "travelreviews.example › paris", "Hotel Lumière – 1,204 reviews", "Rated 4.4 of 5. Great location, small rooms.")], "search results for hotel Lumière"),
    ("web_blog_monstera", "l", "https://greenthumb.example/blog/repot-monstera", ("GREEN THUMB", (40, 110, 70)),
     [("h1", "How to repot a monstera"), ("sub", "Gardening · 6 min read"), ("img", 480, "abstract"),
      ("p", "Spring is the best time to repot. Choose a pot 5 cm wider than the current one."),
      ("bullets", ["Water the plant a day before", "Loosen the roots gently", "Use chunky, airy soil"])], "gardening blog post"),
    ("web_news_marathon_man_dark", "d", "https://www.cityherald.com/sport/man-84-marathon", ("CITY HERALD", (180, 30, 40)),
     [("h1", "Man, 84, completes his first marathon"), ("sub", "By Clara Benton · Yesterday"), ("img", 480, "sunset"),
      ("p", "Retired teacher Henri Dubois crossed the line in 5 hours and 41 minutes, cheered on by his grandchildren.")],
     "news article about an 84-year-old man running a marathon"),
    ("web_forum_phones", "l", "https://forum.techtalk.example/t/best-budget-phones-2026", ("TechTalk", (70, 70, 140)),
     [("h2", "Best budget phones 2026?"), ("sub", "Started by user4821 · 38 replies"),
      ("p", "Looking for something under 300 with a good camera and at least 5 years of updates."),
      ("div",), ("p", "Reply: battery life matters more than the camera for me, check the reviews first.")], "forum thread about budget phones"),
]
for id_, th, url, site, body, desc in WEB:
    blocks = ([("site",) + site] if site else []) + body + [
        ("div",), ("h3", "More stories"), ("li", "Weekend weather: sunshine returns", "2 min read", None, ("c", (120, 160, 200))),
        ("li", "New cycle lanes open on the quay", "4 min read", None, ("c", (150, 190, 120))),
        ("li", "Library extends its evening hours", "3 min read", None, ("c", (200, 160, 120)))]
    pg(id_, "web", th, desc, ("browser", url), blocks, style="browser_like")

# ---- shop
SHOP_BOTTOM = ["Home", "Search", "Bag", "Profile"]
JACKETS = [("Quilted puffer jacket", "€89.99", "jacket", (40, 60, 90)), ("Classic denim jacket", "€59.99", "jacket", (70, 110, 160)),
           ("Wool overshirt", "€69.99", "jacket", (120, 90, 60)), ("Rain jacket", "€49.99", "jacket", (200, 160, 40))]
SNEAKERS = [("Court sneakers", "€74.99", "shoe", (230, 230, 230)), ("Running shoes", "€99.99", "shoe", (230, 80, 80)),
            ("Canvas trainers", "€39.99", "shoe", (60, 120, 200)), ("Trail shoes", "€109.00", "shoe", (90, 120, 70))]
pg("shop_mens_jackets", "shop", "l", "shop product grid of men's jackets", ("bar", "Men's jackets", {"actions": ["cart", "search"], "bold": True}),
   [("tabs", ["Women", "Men", "Kids"], 1), ("chips", ["Filter", "Size", "Colour", "Price"]), ("grid", JACKETS, True)], bottom=SHOP_BOTTOM, style="shop_like")
pg("shop_womens_sneakers", "shop", "l", "shop grid of women's sneakers", ("bar", "Sneakers", {"actions": ["cart", "search"], "bold": True}),
   [("tabs", ["Women", "Men", "Kids"], 0), ("grid", SNEAKERS, True)], bottom=SHOP_BOTTOM, style="shop_like")
pg("shop_kids_dark", "shop", "d", "shop grid of kids' clothes", ("bar", "Kids", {"actions": ["cart", "search"], "bold": True}),
   [("tabs", ["Women", "Men", "Kids"], 2), ("grid", [("Striped T-shirt", "€12.99", "tshirt", (230, 120, 60)), ("Zip hoodie", "€24.99", "hoodie", (90, 150, 200)),
                                                   ("Light sneakers", "€29.99", "shoe", (240, 200, 60)), ("Summer dress", "€19.99", "dress", (230, 110, 160))], True)],
   bottom=SHOP_BOTTOM, style="shop_like")
pg("shop_mens_shoes_dark", "shop", "d", "shop grid of men's shoes", ("bar", "Men's shoes", {"actions": ["cart", "search"], "bold": True}),
   [("tabs", ["Women", "Men", "Kids"], 1), ("grid", SNEAKERS[::-1], True)], bottom=SHOP_BOTTOM, style="shop_like")
pg("shop_product_detail", "shop", "l", "shop product detail page for a denim jacket", ("bar", "", {"actions": ["share", "heart"]}),
   [("img", 900, "abstract"), ("h2", "Classic denim jacket"), ("h3", "€59.99"), ("sub", "Free delivery over €50 · Free returns"),
    ("chips", ["S", "M", "L", "XL"]), ("sp", 20), ("btn", "Add to bag", (20, 20, 20))], style="shop_like")
pg("shop_cart", "shop", "l", "shopping bag with two items", ("bar", "Your bag (2)", {"actions": []}),
   [("li", "Classic denim jacket", "Size M · Blue", "€59.99", ("c", (70, 110, 160))),
    ("li", "Court sneakers", "Size 42 · White", "€74.99", ("c", (200, 200, 200))), ("div",),
    ("kv", "Subtotal", "€134.98"), ("kv", "Delivery", "Free"), ("kv", "Total", "€134.98", True), ("sp", 30), ("btn", "Checkout", (20, 20, 20))], style="shop_like")
pg("shop_order_confirmation", "shop", "l", "shop order confirmation with order number", ("bar", "Order placed", {"actions": []}),
   [("banner", "✓ Thank you for your order!", (24, 128, 56)), ("p", "We've sent a confirmation email to you. Your order will arrive Thu 6 Nov – Mon 10 Nov."),
    ("card", [("Order number", "112-4839201-55"), ("Items", "2"), ("Total", "€134.98"), ("Payment", "Card •••• 4417")]),
    ("btn", "Track order"), ("sub", "Need help? Visit Customer service")], tags=["order_number"], style="shop_like")
pg("shop_order_shipped_dark", "shop", "d", "shop order tracking page with order number", ("bar", "Track order", {"actions": []}),
   [("h2", "Your order is on its way"), ("sub", "Order number 305-1192847-02"),
    ("card", [("Ordered", "Mon 3 Nov"), ("Shipped", "Tue 4 Nov"), ("Out for delivery", "Today"), ("Arriving", "by 18:00")]),
    ("li", "Rain jacket", "Size L · Yellow", "€49.99", ("c", (200, 160, 40)))], tags=["order_number"], style="shop_like")
pg("shop_search_running", "shop", "l", "shop search results for running shoes", ("searchbar", "running shoes"),
   [("chips", ["Running", "Trail", "Under €80"]), ("grid", SNEAKERS[1:] + SNEAKERS[:1], False)], bottom=SHOP_BOTTOM, style="shop_like")
pg("shop_wishlist", "shop", "l", "shop wishlist", ("bar", "Wishlist", {"actions": ["cart"], "bold": True}),
   [("sub", "4 items saved"), ("grid", [JACKETS[2], SNEAKERS[0], ("Linen shirt", "€34.99", "tshirt", (200, 190, 170)), ("Hoodie", "€44.99", "hoodie", (60, 60, 60))], True)],
   bottom=SHOP_BOTTOM, style="shop_like")

# ---- social
FEED_HDR = ("bar", "Moments", {"back": False, "actions": ["share", "heart"], "bold": True, "size": 56})
for id_, th, user, sc, lb, n, cap, ncom, ago, desc in [
    ("social_feed_jamie_dinner", "l", "jamie.r", "food", "alex", "120", "Great dinner with the team", "23", "2 hours ago", "feed post by jamie.r about dinner"),
    ("social_feed_alex_sunset", "l", "alex.m", "sunset", "sam_k", "348", "Golden hour from the rooftop", "41", "5 hours ago", "feed post of a sunset by alex.m"),
    ("social_feed_lena_mountains_dark", "d", "lena.travels", "sky", "priya.k", "1,021", "Day 3 in the Alps, legs are gone", "87", "1 day ago", "feed post of mountains by lena.travels"),
    ("social_feed_sam_restaurant", "l", "sam_k", "food", "marco.b", "64", "Best restaurant in town, no debate", "12", "3 days ago", "feed post about the best restaurant by sam_k"),
    ("social_feed_priya_city_dark", "d", "priya.k", "city", "jamie.r", "205", "City lights never get old", "19", "4 hours ago", "feed post of a city at night liked by jamie.r"),
]:
    pg(id_, "social", th, desc, FEED_HDR, [("post", user, sc, lb, n, cap, ncom, ago),
                                           ("post", "travel.daily", "sky", "nina_k", "5,310", "Where to next?", "204", "1 day ago")], bottom=["Home", "Search", "Reels", "Profile"], style="instagram_like_feed")
FILLER_POSTS = [("Daily Facts", "dailyfacts", "6h", "Octopuses have three hearts and blue blood.", ["52", "310", "4.1K", ""]),
                ("Chris P", "chrisp", "7h", "Finally finished the garden shed. Only took three summers.", ["9", "3", "77", ""]),
                ("Transit Updates", "transit_updates", "8h", "Line 2 trams are running every 6 minutes again after this morning's delay.", ["4", "21", "60", ""])]
for id_, th, posts, desc in [
    ("social_timeline_man", "l", [("City Herald", "cityherald", "2h", "Man rescued from river after 3 hours, firefighters say", ["24", "112", "1.2K", ""]),
                                  ("Chloe", "chloe_writes", "3h", "Nothing beats a Sunday walk by the lake", ["3", "1", "48", ""]),
                                  ("Oliver W", "oliverw", "5h", "Anyone know a good plumber in the east end?", ["11", "0", "2", ""])], "timeline with a post about a man rescued"),
    ("social_timeline_restaurant", "l", [("Food Critic", "foodcritic", "1h", "This new restaurant in the old station is worth the hype. Book early.", ["40", "88", "960", ""]),
                                         ("Marco", "marco_b", "4h", "Training cancelled tonight, pitch is flooded", ["2", "0", "9", ""])], "timeline with a post about a restaurant"),
    ("social_timeline_men_dark", "d", [("Sport Daily", "sportdaily", "30m", "Men's World Cup qualifiers: full results and table", ["210", "1.1K", "8K", ""]),
                                      ("Nina", "nina_k", "2h", "Pub quiz tonight, our team name is still a secret", ["5", "1", "33", ""])], "timeline with a men's football post"),
    ("social_timeline_misc", "l", [("Weather Now", "weathernow", "10m", "Heavy rain expected this afternoon across the region", ["15", "60", "210", ""]),
                                   ("Sophie", "sophie.l", "1h", "Finished my first pottery class today!", ["8", "2", "120", ""])], "timeline with weather and hobby posts"),
]:
    pg(id_, "social", th, desc, ("bar", "Home", {"back": False, "actions": ["search"], "bold": True}),
       [("tabs", ["For you", "Following"], 0)] + [("tweet",) + p for p in posts + FILLER_POSTS], bottom=["Home", "Search", "Alerts", "Inbox"], style="twitter_like")
pg("social_notifications", "social", "l", "social notifications list mentioning jamie.r", ("bar", "Notifications", {"back": True, "actions": []}),
   [("h3", "Today"), ("li", "jamie.r started following you", "2h", None, ("av", "jamie.r")),
    ("li", "alex.m liked your photo", "3h", None, ("av", "alex.m")), ("li", "sam_k commented: so good!", "5h", None, ("av", "sam_k")),
    ("h3", "This week"), ("li", "priya.k liked your reel", "2d", None, ("av", "priya.k"))], style="instagram_like_feed")

# ---- settings
NETS = [("HOME-5G-81F2", "Connected", 4), ("CabinNet", "Saved", 3), ("Cafe_Guest", None, 2), ("Office-2.4G", None, 1), ("Phone_7342", None, 2)]
for i, th in enumerate(["l", "d"]):
    pg(f"settings_wifi_list_{i}", "settings", th, "Wi-Fi settings with network list", ("bar", "Wi-Fi", {"actions": ["search"]}),
       [("toggle", "Use Wi-Fi", None, True), ("div",)] + [("li", n, s, None, ("wifi", lv, True)) for n, s, lv in NETS[:1] + NETS[1 + i:] + NETS[1:1 + i]] +
       [("li", "Add network", None, None, ("c", (120, 120, 120)))], style="android_settings")
pg("settings_share_wifi", "settings", "l", "Wi-Fi share screen with password", ("bar", "Share Wi-Fi", {"actions": []}),
   [("sp", 40), ("qr", 600), ("p", "Scan this QR code to join “HOME-5G”"), ("kv", "Network name:", "HOME-5G"), ("kv", "Password:", "7hX2-99kL-a0")],
   tags=["wifi_password"], style="android_settings")
pg("settings_share_wifi_dark", "settings", "d", "Wi-Fi share screen with password (dark)", ("bar", "Share Wi-Fi", {"actions": []}),
   [("sp", 40), ("qr", 600), ("p", "Scan this QR code to join “Flat4B-Fibre”"), ("kv", "Network name:", "Flat4B-Fibre"), ("kv", "Password:", "sunny-otter-482")],
   tags=["wifi_password"], style="android_settings")
pg("settings_bluetooth", "settings", "l", "Bluetooth settings", ("bar", "Connected devices", {"actions": ["search"]}),
   [("toggle", "Bluetooth", "Visible as “My phone”", True), ("h3", "Saved devices"),
    ("li", "Earbuds Pro", "Connected", None, ("c", (26, 115, 232))), ("li", "Car audio", None, None, ("c", (120, 120, 120))),
    ("li", "Kitchen speaker", None, None, ("c", (120, 120, 120))), ("li", "Pair new device", None, None, ("c", (26, 115, 232)))], style="android_settings")
pg("settings_display_dark", "settings", "d", "Display settings", ("bar", "Display", {"actions": ["search"]}),
   [("toggle", "Dark theme", "On", True), ("toggle", "Adaptive brightness", "Optimise for available light", True),
    ("li", "Screen timeout", "After 2 minutes of inactivity"), ("li", "Font size and text", "Default"), ("toggle", "Auto-rotate screen", None, False),
    ("li", "Screen saver", "Off")], style="android_settings")
pg("settings_about_phone", "settings", "l", "About phone settings", ("bar", "About phone", {"actions": ["search"]}),
   [("li", "Device name", "My phone"), ("li", "Phone number", "+44 7700 900456"), ("li", "Android version", "16"),
    ("li", "Model", "PX-2026"), ("li", "IP address", "192.168.1.24"), ("li", "Build number", "BP2A.250605.031")], style="android_settings")
pg("settings_battery", "settings", "l", "Battery settings", ("bar", "Battery", {"actions": []}),
   [("h1", "72%", 90), ("sub", "About 1 day, 4 hr left"), ("toggle", "Battery Saver", "Off", False),
    ("toggle", "Adaptive Battery", "Limit battery for apps you don't use often", True), ("li", "Battery usage", "Since last full charge")], style="android_settings")

# ---- receipts / documents
pg("receipt_eshop", "receipt", "l", "e-receipt order confirmation", ("bar", "Receipt", {"actions": ["share"]}),
   [("h2", "Order confirmation"), ("sub", "Order 7731-2290 · 2 Nov 2026"), ("div",), ("kv", "Wireless mouse", "€24.90"),
    ("kv", "USB-C cable 2 m", "€12.50"), ("kv", "Laptop stand", "€39.00"), ("div",), ("kv", "Subtotal", "€76.40"),
    ("kv", "Shipping", "€4.90"), ("kv", "VAT (20%)", "€16.26"), ("kv", "Total", "€81.30", True)], tags=["receipt"], style="document")
pg("receipt_cafe_dark", "receipt", "d", "coffee shop e-receipt", ("bar", "Payment receipt", {"actions": ["share"]}),
   [("h2", "Café Lune"), ("sub", "12 Rue Mercière, Lyon"), ("div",), ("kv", "Flat white", "€3.80"), ("kv", "Almond croissant", "€3.20"),
    ("kv", "Orange juice", "€4.00"), ("div",), ("kv", "Total", "€11.00", True), ("sub", "Paid by card •••• 4417 · 09:42")], tags=["receipt"], style="document")
pg("bank_account_iban", "receipt", "l", "bank app account details with IBAN", ("bar", "Account details", {"actions": ["share"]}),
   [("banner", "Main account  ·  €2,481.07", (20, 60, 120)), ("card", [("Account holder", "M. Laurent"), ("IBAN", "FR76 3000 6000 0112 3456 7890 189"), ("BIC", "AGRIFRPP"),
                                                                       ("Currency", "EUR")]), ("btn", "Copy details"), ("sub", "Share these details to receive money from other banks.")],
   tags=["iban"], style="bank_like")
pg("bank_transfer_dark", "receipt", "d", "bank transfer confirmation with IBAN", ("bar", "Transfer sent", {"actions": []}),
   [("banner", "✓ €450.00 sent", (24, 128, 56)), ("card", [("To", "Alex Morgan"), ("IBAN", "DE89 3704 0044 0532 0130 00"), ("Reference", "Rent November"), ("Date", "1 Nov 2026")])],
   tags=["iban"], style="bank_like")
pg("boarding_pass", "receipt", "l", "mobile boarding pass", ("bar", "Boarding pass", {"actions": ["share"]}),
   [("h1", "LYS  →  LIS", 80), ("sub", "Lyon to Lisbon · Flight XY 2481"), ("card", [("Passenger", "M. LAURENT"), ("Date", "14 Mar 2026"), ("Boarding", "06:45"),
                                                                                    ("Gate", "B12"), ("Seat", "17C")]), ("barcode",)], style="document")
pg("payslip", "receipt", "l", "payslip document screenshot", ("bar", "Payslip October 2026", {"actions": ["share"], "size": 42}),
   [("h3", "Northbridge Logistics Ltd"), ("sub", "Employee: M. Laurent · No. 04471"), ("div",), ("kv", "Gross salary", "€3,450.00"),
    ("kv", "Social security", "−€412.30"), ("kv", "Income tax", "−€298.15"), ("kv", "Meal vouchers", "−€54.00"), ("div",), ("kv", "Net pay", "€2,685.55", True)],
   tags=["receipt"], style="document")
pg("utility_bill", "receipt", "d", "electricity bill screenshot", ("bar", "Your bill", {"actions": []}),
   [("h2", "Electricity – October"), ("kv", "Account", "5531 0927"), ("kv", "Usage", "214 kWh"), ("kv", "Amount due", "€61.84", True),
    ("sub", "Direct debit on 15 Nov 2026"), ("btn", "Download PDF")], tags=["receipt"], style="document")
pg("receipt_taxi", "receipt", "l", "ride receipt", ("bar", "Trip receipt", {"actions": ["share"]}),
   [("h2", "Thanks for riding"), ("sub", "Tue 4 Nov · 23:12"), ("card", [("From", "Central Station"), ("To", "14 Linden Road"), ("Distance", "6.2 km")]),
    ("kv", "Fare", "€14.20"), ("kv", "Tip", "€2.00"), ("kv", "Total", "€16.20", True)], tags=["receipt"], style="document")

# ---- email
INBOX = [("Jamie Lee", "Dinner menu for Saturday", "Here's what I'm planning to cook…", "18:02", True),
         ("City Herald", "Your morning briefing", "Tram line approved, weather and more", "07:00", False),
         ("Hotel Lumière", "Your booking is confirmed", "Thank you for booking with us. Check-in…", "Yesterday", True),
         ("Northbridge HR", "Payslip available", "Your October payslip is ready to view", "31 Oct", False),
         ("Store", "Your order has shipped", "Order 305-1192847-02 is on its way", "30 Oct", False),
         ("Book club", "Next meeting", "Don't forget to finish the book!", "28 Oct", False)]
pg("email_inbox_light", "email", "l", "email inbox with a message from Jamie Lee", ("searchbar", "Search in mail"),
   [("sub", "Primary")] + [("mail",) + m for m in INBOX], bottom=["Mail", "Meet"], style="mail_like")
pg("email_inbox_dark", "email", "d", "email inbox (dark) with a message from Jamie Lee", ("searchbar", "Search in mail"),
   [("sub", "Primary")] + [("mail",) + m for m in INBOX[1:3] + INBOX[:1] + INBOX[3:]], bottom=["Mail", "Meet"], style="mail_like")
pg("email_open_jamie_menu", "email", "l", "opened email from Jamie Lee about a dinner menu", ("bar", "", {"actions": ["dots", "share"]}),
   [("h2", "Dinner menu for Saturday"), ("li", "Jamie Lee", "to me · 18:02", None, ("av", "Jamie Lee")),
    ("p", "Hi! Here's the menu I'm thinking of for Saturday:"), ("bullets", ["Burrata with peaches", "Lemon risotto", "Tiramisu"]),
    ("p", "Let me know if anyone has allergies. See you at 7!\nJamie")], style="mail_like")
pg("email_open_hotel_dark", "email", "d", "opened hotel booking confirmation email", ("bar", "", {"actions": ["dots"]}),
   [("h2", "Your booking is confirmed"), ("li", "Hotel Lumière", "to me · Yesterday", None, ("av", "Hotel Lumière")),
    ("p", "Dear guest, thank you for choosing Hotel Lumière."), ("card", [("Check-in", "14 Mar, from 15:00"), ("Check-out", "16 Mar, by 11:00"), ("Booking ref", "HL-77412")])],
   style="mail_like")
pg("email_open_order", "email", "l", "opened shipping email with order number", ("bar", "", {"actions": ["dots"]}),
   [("h2", "Your order has shipped"), ("li", "Store", "to me · 30 Oct", None, ("av", "Store")),
    ("p", "Good news! Your order 305-1192847-02 is on its way and should arrive by Thursday."), ("btn", "Track your parcel")],
   tags=["order_number"], style="mail_like")
pg("email_open_work", "email", "l", "opened work email about a report", ("bar", "", {"actions": ["dots"]}),
   [("h2", "Q3 report – final numbers"), ("li", "Oliver Wright", "to me, Nina · 09:15", None, ("av", "Oliver Wright")),
    ("p", "Hi both, attached are the final numbers for Q3. Revenue is up 8% on last quarter."), ("p", "Can we review on Thursday?\nOliver")],
   style="mail_like")

# ---- delivery-app restaurant menus
MENUS = [("menu_trattoria_roma", "l", "Trattoria Roma", "4.6 ★ (2k+) · Italian · 25–35 min",
          [("Margherita", "Tomato, mozzarella, basil", "€11.50"), ("Spaghetti carbonara", "Guanciale, egg yolk, pecorino", "€14.00"),
           ("Lasagne al forno", "Slow-cooked beef ragù, béchamel", "€15.50"), ("Tiramisu", "Mascarpone, espresso, cocoa", "€6.50")]),
         ("menu_sakura_sushi", "l", "Sakura Sushi", "4.8 ★ (900+) · Japanese · 30–40 min",
          [("Salmon nigiri (2)", "Fresh salmon on seasoned rice", "€5.90"), ("Dragon roll", "Prawn tempura, avocado, eel sauce", "€13.50"),
           ("Miso soup", "Tofu, wakame, spring onion", "€3.50"), ("Chicken katsu", "Panko chicken, curry sauce, rice", "€12.90")]),
         ("menu_burger_barn_dark", "d", "Burger Barn", "4.4 ★ (3k+) · Burgers · 20–30 min",
          [("Classic cheeseburger", "Beef patty, cheddar, pickles", "€10.90"), ("Crispy chicken burger", "Buttermilk chicken, slaw", "€11.50"),
           ("Sweet potato fries", "With chipotle mayo", "€4.50"), ("Chocolate shake", "Made with real ice cream", "€5.20")]),
         ("menu_spice_route", "l", "Spice Route", "4.7 ★ (1k+) · Indian · 35–45 min",
          [("Chicken tikka masala", "Creamy tomato sauce, basmati", "€13.90"), ("Saag paneer", "Spinach, paneer, garlic", "€11.90"),
           ("Garlic naan", "Baked in the tandoor", "€3.20"), ("Mango lassi", "Yoghurt, mango, cardamom", "€4.00")]),
         ("menu_green_bowl_dark", "d", "Green Bowl", "4.5 ★ (500+) · Salads · 15–25 min",
          [("Falafel bowl", "Hummus, tabbouleh, pickled onion", "€11.00"), ("Poke bowl", "Salmon, edamame, mango", "€13.50"),
           ("Caesar salad", "Romaine, croutons, parmesan", "€9.80"), ("Lemonade", "Fresh mint and lime", "€3.50")])]
for id_, th, name, meta, dishes in MENUS:
    pg(id_, "menu", th, f"food delivery app menu for {name}", ("none",),
       [("hero", 520, "food"), ("h1", name, 64), ("sub", meta), ("tabs", ["Popular", "Menu", "Reviews"], 1), ("h2", "Menu")] +
       [("dish",) + d for d in dishes], tags=["menu"], style="delivery_like", theme={"acc": (6, 150, 90)})

# ---- notes / calendar / other
pg("notes_packing_list", "notes", "l", "notes app packing list", ("bar", "", {"actions": ["dots", "share"]}),
   [("h1", "Packing list"), ("sub", "Edited 2 Nov"), ("check", "Passport", True), ("check", "Phone charger", True), ("check", "Swimsuit", False),
    ("check", "Sunglasses", False), ("check", "Hiking boots", False), ("check", "Rain jacket", False), ("check", "Adapter plug", True)], style="notes_like")
pg("notes_groceries_dark", "notes", "d", "notes app grocery list", ("bar", "", {"actions": ["dots"]}),
   [("h1", "Groceries"), ("check", "Milk", False), ("check", "Eggs", True), ("check", "Spinach", False), ("check", "Pecorino", False),
    ("check", "Coffee beans", True), ("check", "Lemons", False)], style="notes_like")
pg("notes_gift_ideas", "notes", "l", "note with gift ideas for Jamie", ("bar", "", {"actions": ["dots"]}),
   [("h1", "Gift ideas"), ("p", "Jamie: sunflower seeds, gardening gloves, concert tickets"), ("p", "Mom: cookbook, scarf"),
    ("p", "Dad: tomato plant stakes, new mug")], style="notes_like")
pg("notes_ideas_dark", "notes", "d", "note with weekend ideas", ("bar", "", {"actions": ["dots"]}),
   [("h1", "Weekend ideas"), ("bullets", ["Lakeside hike (12 km)", "Flea market on Sunday", "Try the new bakery", "Fix the bike brakes"])], style="notes_like")
pg("calendar_dinner_jamie", "other", "l", "calendar day view with Dinner with Jamie", ("bar", "Saturday 14", {"back": False, "actions": ["avatar", "search"], "bold": True}),
   [("cal", 12, [("13:00", 60, "Lunch with Mom", (3, 155, 229)), ("16:00", 90, "Haircut", (124, 179, 66)),
                 ("19:30", 120, "Dinner with Jamie 19:30", (233, 30, 99))])], tags=["calendar"], style="calendar_like")
pg("calendar_workday_dark", "other", "d", "calendar day view of a workday", ("bar", "Tuesday 4", {"back": False, "actions": ["avatar", "search"], "bold": True}),
   [("cal", 8, [("09:00", 30, "Standup", (57, 73, 171)), ("10:30", 60, "Q3 report review", (0, 137, 123)), ("14:00", 120, "Dentist", (251, 140, 0))])],
   tags=["calendar"], style="calendar_like")
pg("lockscreen_notifications", "other", "d", "lock screen with message notifications from Jamie", ("none",),
   [("clock",), ("sp", 200), ("notif", "Messages", "Jamie", "See you at 7! Don't forget the wine 🍷", "now"),
    ("notif", "Mail", "Hotel Lumière", "Your booking is confirmed", "12m")], wall="sunset", style="lockscreen", tags=["notification"])
pg("notification_shade", "other", "l", "notification shade with a message from Jamie Fox", ("none",),
   [("h2", "Notifications"), ("notif", "Messages", "Jamie Fox", "Slides look great, thanks!", "2m"),
    ("notif", "Calendar", "Dinner with Jamie", "19:30 – 21:30", "1h"), ("notif", "Weather", "Rain expected", "Heavy rain from 15:00", "3h")],
   bg=(232, 234, 240), style="android_system", tags=["notification"])
pg("contacts_list", "other", "l", "contacts list containing Jamie, Jamal and Jamieson Plumbing", ("searchbar", "Search contacts"),
   [("h3", "J")] + [("li", n, s, None, ("av", n)) for n, s in [("Jamal", "Mobile"), ("Jamie", "Mobile"), ("Jamie Fox", "Work"),
                                                                ("Jamieson Plumbing", "Business"), ("Janet Hughes", "Mobile")]] +
   [("h3", "L"), ("li", "Lena", "Mobile", None, ("av", "Lena"))], style="contacts_like", tags=["contacts"])
pg("gallery_album", "other", "l", "photo gallery album view", ("bar", "Holiday 2026", {"actions": ["dots", "share"], "bold": True}),
   [("sub", "48 items · Porto"), ("img", 700, "sunset"), ("img", 700, "river")], style="gallery_like")

# --------------------------------------------------------------------------- tags & output

PEOPLE = ["jamie", "alex", "sam", "priya", "lena", "marco", "benjamin", "jamal", "tom", "nina", "oliver", "chloe", "sophie",
          "mom", "dad", "grandma", "fox", "patel", "lee"]
WORDS = ["restaurants", "restaurant", "menu", "man", "men", "hotel", "password", "iban", "order", "map"]
SUFFIX = {"web": "Chrome", "map": "Maps", "settings": "Settings"}
IBAN_RE = re.compile(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}")


def words_in(text):
    return set(re.findall(r"[a-z]+", text.lower()))


def build_tags(spec, texts):
    tags = set(spec["tags"])
    st = spec["screen_type"]
    tags.add(st if st != "other" else "other")
    body = " ".join(t for t, r in texts if r == "body" or (st != "chat" and r != "chrome"))
    every = " ".join(t for t, r in texts if r != "chrome")
    if st == "chat":
        tw = words_in(spec["chat_title"])
        key = "group_title_mentions" if spec["chat_is_group"] else "chat_with"
        tags |= {f"{key}:{p}" for p in PEOPLE if p in tw}
        hdr = " ".join(t for t, r in texts if r == "header" and t != spec["chat_title"])
        if spec["chat_is_group"]:
            tags |= {f"group_members:{p}" for p in PEOPLE if p in words_in(hdr)}
    tags |= {f"mentions:{p}" for p in PEOPLE if p in words_in(body)}
    tags |= {f"word:{w}" for w in WORDS if w in words_in(every)}
    if IBAN_RE.search(every):
        tags.add("iban")
    return sorted(tags)


def render(spec):
    rnd = random.Random("gallery-eval:" + spec["id"])
    start = dt.datetime(2025, 1, 5)
    when = start + dt.timedelta(days=rnd.randint(0, 680), hours=rnd.randint(7, 22), minutes=rnd.randint(0, 59),
                                seconds=rnd.randint(0, 59))
    c = Canvas(spec["theme"], rnd, when)
    spec["fn"](c)
    status_bar(c)
    nav_bar(c)
    if rnd.random() < 0.3:
        sfx = SUFFIX.get(spec["screen_type"]) or ("Messages" if spec["style"] == "sms_like" else None)
        fname = when.strftime("Screenshot_%Y%m%d_%H%M%S") + (f"_{sfx}" if sfx else "") + ".jpg"
    else:
        fname = when.strftime("Screenshot_%Y%m%d-%H%M%S") + ".png"
    out = OUT_DIR / f"{spec['id']}.png"
    c.img.save(out, optimize=True)
    entry = dict(id=spec["id"], file=f"screens/{spec['id']}.png", kind="screenshot", filename=fname,
                 date=when.strftime("%Y-%m-%dT%H:%M:%S"), screen_type=spec["screen_type"], style=spec["style"],
                 theme=spec["theme"])
    if spec["screen_type"] == "chat":
        entry.update(chat_title=spec["chat_title"], chat_is_group=spec["chat_is_group"])
    entry.update(tags=build_tags(spec, c.texts), description=spec["desc"],
                 texts=list(dict.fromkeys(t for t, r in c.texts if r != "chrome")))
    return entry, out.stat().st_size


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ids = [s["id"] for s in CATALOG]
    assert len(ids) == len(set(ids)), "duplicate ids"
    entries, total, counts = [], 0, {}
    for spec in CATALOG:
        e, size = render(spec)
        entries.append(e)
        total += size
        counts[e["screen_type"]] = counts.get(e["screen_type"], 0) + 1
    MANIFEST.write_text(json.dumps(entries, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"{len(entries)} screenshots, {total / 1e6:.1f} MB -> {OUT_DIR}")
    print(", ".join(f"{k}: {v}" for k, v in sorted(counts.items())))


if __name__ == "__main__":
    main()
