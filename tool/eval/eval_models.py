"""Offline comparison of image-text models for visual search.

Embeds every corpus image (tool/eval/photos_manifest.json + screens_manifest.json)
the way the app does (a ~256 px gallery thumbnail, then the model's own
preprocessing) and every visual query with a prompt ensemble, then reports
per model:
  * mean average precision and judged P@5 / P@10 over the visual queries
    (results matching a query's 'unjudged' clauses are skipped, labels being
    incomplete);
  * screenshots that intrude into the top 10 of photo queries (the
    "text in the image" effect: a screenshot that says MEN for "a man");
  * the best (floor, margin) operating point: keep a hit when
    cos >= floor and cos >= best - margin, with every negative query empty.

Subcommands:
  compare  [models...]        metrics table (default: all cached models)
  export   <model> <out_dir> [prompts.json]
                              image embeddings (+ embeddings of the prompts the
                              Dart evaluation asked for) for
                              test/eval/real_corpus_eval_test.dart; a model
                              named <id>_int8 is exported as <id>

Usage: tool/.venv/Scripts/python -I tool/eval/eval_models.py compare
Models must first be downloaded with tool/fetch_models.py.
"""
from __future__ import annotations

import base64
import io
import json
import re
import sys
from datetime import datetime
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image
from tokenizers import Tokenizer

ROOT = Path(__file__).resolve().parents[2]
EVAL = ROOT / "tool" / "eval"
DATA = EVAL / ".data"
CACHE = ROOT / "tool" / ".cache"
THUMB = 256

CLIP_MEAN = np.array([0.48145466, 0.4578275, 0.40821073], np.float32)
CLIP_STD = np.array([0.26862954, 0.26130258, 0.27577711], np.float32)

# Prompt ensembles. {} is the visual phrase, with an article when the query
# had none ("dog" -> "a dog").
PHOTO_PROMPTS = [
    "a photo of {}.",
    "a picture of {}.",
    "a close-up photo of {}.",
    "a phone photo of {}.",
    "an image showing {}.",
]
SCREEN_PROMPTS = [
    "a screenshot of {}.",
    "a phone screenshot showing {}.",
    "a screen capture of {}.",
]


# ------------------------------------------------------------------ corpus

def load_corpus() -> list[dict]:
    items = []
    for name in ("photos_manifest.json", "screens_manifest.json"):
        p = EVAL / name
        if not p.exists():
            continue
        for e in json.loads(p.read_text(encoding="utf-8")):
            f = DATA / e["file"]
            if not f.exists():
                continue
            items.append({
                "id": e["id"], "path": f, "kind": e["kind"],
                "pos": set(e.get("positive", [])), "neg": set(e.get("negative", [])),
                "tags": set(e.get("tags", [])), "date": e.get("date", "2026-01-01T12:00:00"),
            })
    return items


def clause_matches(item: dict, clause: str) -> bool:
    for part in clause.split("&"):
        kind, _, value = part.partition(":")
        if kind == "label":
            ok = value in item["pos"]
        elif kind == "tag":
            ok = value in item["tags"]
        elif kind == "kind":
            ok = item["kind"] == value
        elif kind == "date":
            lo, hi = value.split("..")
            ok = lo <= item["date"][:10] < hi
        else:
            raise ValueError(clause)
        if not ok:
            return False
    return True


def judge(item: dict, q: dict) -> int | None:
    """1 relevant, 0 not relevant, None unjudged."""
    if any(clause_matches(item, c) for c in q.get("relevant", [])):
        return 1
    if any(clause_matches(item, c) for c in q.get("unjudged", [])):
        return None
    return 0


_FILLER = re.compile(
    r"^(?:show me |find |the )?(?:(?:a |the )?(?:picture|photo|image|pic|screenshot)s? of |photos? of |pictures? of |"
    r"my |someone |the )+")


def visual_phrase(query: str) -> str:
    q = query.lower().strip()
    q = re.sub(r"\b(last summer|i photographed|i took|nearby)\b", "", q)
    q = _FILLER.sub("", q).strip()
    q = re.sub(r"\s+screenshot$", "", q)
    q = re.sub(r"\s+", " ", q).strip()
    if not re.match(r"^(a|an|the|some|my)\b", q) and not q.endswith("s"):
        q = ("an " if q[:1] in "aeiou" else "a ") + q
    return q


# ------------------------------------------------------------------ models

def thumbnail(path: Path) -> Image.Image:
    """Approximates the gallery thumbnail the app embeds (longest side 256, JPEG)."""
    img = Image.open(path).convert("RGB")
    img.thumbnail((THUMB, THUMB), Image.BILINEAR)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=95)
    return Image.open(io.BytesIO(buf.getvalue())).convert("RGB")


class Model:
    def __init__(self, name: str):
        self.name = name
        d = CACHE / name
        vision, text, tok, pre = (d / "onnx" / "vision_model.onnx", d / "onnx" / "text_model.onnx",
                                  d / "tokenizer.json", d / "preprocessor_config.json")
        bundled = ROOT / "assets" / "models" / "siglip_b16"
        if name == "siglip_b16_int8" and not d.exists():
            # The bundled int8 files (tool/install_assets.py) with the export's tokenizer.
            vision, text = bundled / "siglip_b16_vision_int8.onnx", bundled / "siglip_b16_text_int8.onnx"
            tok, pre = CACHE / "siglip_b16" / "tokenizer.json", bundled / "preprocessor_config.json"
        so = ort.SessionOptions()
        so.intra_op_num_threads = 4
        self.vision = ort.InferenceSession(str(vision), so, providers=["CPUExecutionProvider"])
        self.text = ort.InferenceSession(str(text), so, providers=["CPUExecutionProvider"])
        self.tok = Tokenizer.from_file(str(tok))
        self.pre = json.loads(pre.read_text(encoding="utf-8"))
        self.siglip = "siglip" in name
        if self.siglip:
            self.max_len = 64
            pad = self.tok.token_to_id("</s>")
            self.tok.enable_padding(length=self.max_len, pad_id=pad, pad_token="</s>")
            self.tok.enable_truncation(self.max_len)
        else:
            self.max_len = 77
            self.tok.enable_truncation(self.max_len)
        self.text_inputs = [i.name for i in self.text.get_inputs()]

    def _pixels(self, img: Image.Image) -> np.ndarray:
        p = self.pre
        if self.siglip:
            s = p["size"]
            img = img.resize((s["width"], s["height"]), Image.BICUBIC)
            x = np.asarray(img, np.float32) / 255.0
            x = (x - np.array(p["image_mean"], np.float32)) / np.array(p["image_std"], np.float32)
        else:
            short = p["size"]["shortest_edge"]
            w, h = img.size
            scale = short / min(w, h)
            img = img.resize((max(short, round(w * scale)), max(short, round(h * scale))),
                             Image.BICUBIC if p.get("resample") == 3 else Image.BILINEAR)
            c = p["crop_size"]["height"] if isinstance(p["crop_size"], dict) else p["crop_size"]
            w, h = img.size
            left, top = (w - c) // 2, (h - c) // 2
            img = img.crop((left, top, left + c, top + c))
            x = np.asarray(img, np.float32) / 255.0
            if p.get("do_normalize", True):
                x = (x - CLIP_MEAN) / CLIP_STD
        return x.transpose(2, 0, 1)[None]

    def embed_images(self, paths: list[Path]) -> np.ndarray:
        out = []
        out_name = self.vision.get_outputs()[-1].name if self.siglip else self.vision.get_outputs()[0].name
        for i, p in enumerate(paths):
            v = self.vision.run([out_name], {"pixel_values": self._pixels(thumbnail(p))})[0][0]
            out.append(v / np.linalg.norm(v))
            if i % 100 == 0:
                print(f"  {self.name}: {i}/{len(paths)}", file=sys.stderr)
        return np.stack(out).astype(np.float32)

    def embed_texts(self, texts: list[str]) -> np.ndarray:
        out = []
        out_name = self.text.get_outputs()[-1].name if self.siglip else self.text.get_outputs()[0].name
        for t in texts:
            enc = self.tok.encode(t)
            ids = enc.ids
            if not self.siglip:
                ids = ids + [0] * (self.max_len - len(ids))
            feed = {"input_ids": np.array([ids], np.int64)}
            if "attention_mask" in self.text_inputs:
                feed["attention_mask"] = np.array([[1 if k < len(enc.ids) else 0 for k in range(len(ids))]], np.int64)
            v = self.text.run([out_name], feed)[0][0]
            out.append(v / np.linalg.norm(v))
        return np.stack(out).astype(np.float32)


def image_embeddings(model: Model, items: list[dict]) -> np.ndarray:
    cache = DATA / "emb" / f"{model.name}_t{THUMB}.npz"
    cached = {}
    if cache.exists():
        z = np.load(cache, allow_pickle=False)
        cached = dict(zip(z["ids"].tolist(), z["vecs"]))
    missing = [it for it in items if it["id"] not in cached]
    if missing:
        vecs = model.embed_images([it["path"] for it in missing])
        cached.update({it["id"]: v for it, v in zip(missing, vecs)})
        cache.parent.mkdir(parents=True, exist_ok=True)
        ids = sorted(cached)
        np.savez(cache, ids=np.array(ids), vecs=np.stack([cached[i] for i in ids]))
    return np.stack([cached[it["id"]] for it in items])


def query_vector(model: Model, phrase: str, screenshot: bool, ensemble: bool = True) -> np.ndarray:
    templates = (SCREEN_PROMPTS if screenshot else PHOTO_PROMPTS) if ensemble else (
        ["a screenshot of {}."] if screenshot else ["a photo of {}."])
    v = model.embed_texts([t.format(phrase) for t in templates]).mean(0)
    return v / np.linalg.norm(v)


# ----------------------------------------------------------------- metrics

def ranked_metrics(sims: np.ndarray, items: list[dict], q: dict) -> dict:
    order = np.argsort(-sims)
    judged = [(i, judge(items[i], q)) for i in order]
    rels = [(i, j) for i, j in judged if j is not None]
    n_rel = sum(j for _, j in rels)
    hits, ap = 0, 0.0
    for rank, (_, j) in enumerate(rels, 1):
        if j:
            hits += 1
            ap += hits / rank
    ap = ap / n_rel if n_rel else 0.0
    p5 = sum(j for _, j in rels[:5]) / 5
    p10 = sum(j for _, j in rels[:10]) / 10
    top10 = [items[i] for i, _ in judged[:10]]
    intrude = sum(1 for it in top10 if it["kind"] == "screenshot" and judge(it, q) == 0)
    return {"ap": ap, "p5": p5, "p10": p10, "n_rel": n_rel, "screens_top10": intrude}


def threshold_eval(per_query: list[tuple[dict, np.ndarray]], items, floor: float, margin: float):
    precisions, recalls, neg_empty, neg_total = [], [], 0, 0
    for q, sims in per_query:
        best = sims.max()
        keep = [i for i in np.argsort(-sims) if sims[i] >= floor and sims[i] >= best - margin]
        if q.get("empty"):
            neg_total += 1
            neg_empty += not keep
            continue
        judged = [judge(items[i], q) for i in keep]
        judged = [j for j in judged if j is not None]
        n_rel = sum(judge(it, q) == 1 for it in items)
        precisions.append(sum(judged) / len(judged) if judged else (1.0 if n_rel == 0 else 0.0))
        recalls.append(sum(judged) / n_rel if n_rel else 1.0)
    return float(np.mean(precisions)), float(np.mean(recalls)), neg_empty, neg_total


def compare(names: list[str]) -> None:
    items = load_corpus()
    queries = json.loads((EVAL / "queries.json").read_text(encoding="utf-8"))["queries"]
    vis = [q for q in queries if q["class"] == "visual" or q["class"] == "negative" and not
           re.search(r"conversation|chat", q["query"])]
    print(f"corpus: {len(items)} images ({sum(i['kind'] == 'photo' for i in items)} photos), "
          f"{len(vis)} visual queries")
    for name in names:
        model = Model(name)
        img = image_embeddings(model, items)
        for ensemble in (False, True):
            per_query, rows = [], []
            for q in vis:
                phrase = visual_phrase(q["query"])
                sims = img @ query_vector(model, phrase, screenshot=False, ensemble=ensemble)
                per_query.append((q, sims))
                if not q.get("empty"):
                    rows.append((q, ranked_metrics(sims, items, q)))
            m = {k: np.mean([r[k] for _, r in rows]) for k in ("ap", "p5", "p10", "screens_top10")}
            print(f"\n== {name} ({'ensemble' if ensemble else 'single prompt'}): mAP {m['ap']:.3f}  "
                  f"P@5 {m['p5']:.3f}  P@10 {m['p10']:.3f}  screenshots in top10 {m['screens_top10']:.2f}")
            if ensemble:
                for q, r in rows:
                    print(f"   {q['query']:32s} AP {r['ap']:.2f} P@5 {r['p5']:.2f} P@10 {r['p10']:.2f} "
                          f"rel {r['n_rel']:3d} scr@10 {r['screens_top10']}")
            pos = np.concatenate([s[[judge(items[i], q) == 1 for i in range(len(items))]] for q, s in per_query
                                  if not q.get("empty")])
            neg = np.concatenate([s[[judge(items[i], q) == 0 for i in range(len(items))]] for q, s in per_query])
            print(f"   cos: relevant median {np.median(pos):.3f} p10 {np.percentile(pos, 10):.3f} | "
                  f"non-relevant p99 {np.percentile(neg, 99):.3f} max {neg.max():.3f}")
            best = None
            lo, hi = np.percentile(neg, 95), np.percentile(pos, 90)
            for floor in np.linspace(lo, hi, 40):
                for margin in (0.02, 0.03, 0.04, 0.05, 0.06, 0.08, 0.10, 0.15, 1.0):
                    p, r, ne, nt = threshold_eval(per_query, items, floor, margin)
                    f = 1.25 * p * r / (0.25 * p + r) if p + r else 0
                    if ne == nt and (best is None or f > best[0]):
                        best = (f, floor, margin, p, r)
            if best:
                print(f"   operating point (negatives empty): floor {best[1]:.3f} margin {best[2]:.2f} -> "
                      f"precision {best[3]:.3f} recall {best[4]:.3f} F0.5 {best[0]:.3f}")


def export(name: str, out_dir: str, prompts_file: str | None) -> None:
    """Writes <out>/<model>_images.json (id -> base64 float16) and, when a
    prompt list is given (written by the Dart eval), <model>_prompts.json."""
    items = load_corpus()
    model = Model(name)
    img = image_embeddings(model, items)
    # Files are named after the app's model id: the bundled int8 SigLIP is
    # "siglip_b16" in the app.
    name = name.removesuffix("_int8")
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    enc = lambda v: base64.b64encode(v.astype("<f2").tobytes()).decode()
    (out / f"{name}_images.json").write_text(json.dumps(
        {"model": name, "dim": int(img.shape[1]), "vectors": {it["id"]: enc(v) for it, v in zip(items, img)}}),
        encoding="utf-8")
    if prompts_file:
        prompts = json.loads(Path(prompts_file).read_text(encoding="utf-8"))
        vecs = model.embed_texts(prompts) if prompts else np.zeros((0, img.shape[1]), np.float32)
        (out / f"{name}_prompts.json").write_text(json.dumps(
            {"model": name, "vectors": {p: enc(v) for p, v in zip(prompts, vecs)}}, ensure_ascii=False),
            encoding="utf-8")
    print("exported", len(items), "images", "to", out)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    args = sys.argv[1:]
    if not args or args[0] == "compare":
        names = args[1:] or [n for n in ("mobileclip_s0", "clip_b16", "siglip_b16") if (CACHE / n / "onnx").exists()]
        compare(names)
    elif args[0] == "export":
        export(args[1], args[2], args[3] if len(args) > 3 else None)
    else:
        raise SystemExit(__doc__)
