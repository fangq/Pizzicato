#!/usr/bin/env python3
"""CLIP through MNN (core/pzai_cli) against onnxruntime, and a ranking check.

    python3 tests/clip_parity.py <clip src dir> <mnn dir> photo1.jpg ...

Prints the cosine between MNN's and onnxruntime's embeddings of each photo
(want > 0.98: the resampling to 224 px differs a little) and of a few
queries (want > 0.99), then which photo each query ranks first.
"""
import os, subprocess, sys, tempfile
import numpy as np
import onnxruntime as ort
from PIL import Image
from tokenizers import Tokenizer

src, mnn, photos = sys.argv[1], sys.argv[2], sys.argv[3:]
cli = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "core", "pzai_cli")
queries = ["fireworks at night", "a sunset over the ocean", "a green rice field",
           "a stone statue of children", "people on a beach", "a city street with buildings"]
vis = ort.InferenceSession(f"{src}/vision_model.onnx", providers=["CPUExecutionProvider"])
txt = ort.InferenceSession(f"{src}/text_model.onnx", providers=["CPUExecutionProvider"])
tok = Tokenizer.from_file(f"{src}/tokenizer.json")
mean = np.array([0.48145466, 0.4578275, 0.40821073], np.float32)
std = np.array([0.26862954, 0.26130258, 0.27577711], np.float32)

def norm(v):
    return v / np.linalg.norm(v)

def run(args, dev="opencl"):
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "e.f32")
        r = subprocess.run([cli, "-d", dev] + args + [out], capture_output=True, text=True)
        if r.returncode:
            sys.exit(r.stderr)
        return np.fromfile(out, np.float32)

worst = 1.0
I_m, I_o = [], []
for p in photos:
    im = Image.open(p).convert("RGB")
    s = 224 / min(im.size)
    im = im.resize((max(224, round(im.width * s)), max(224, round(im.height * s))), Image.BICUBIC)
    x0, y0 = (im.width - 224) // 2, (im.height - 224) // 2
    a = (np.asarray(im.crop((x0, y0, x0 + 224, y0 + 224)), np.float32) / 255 - mean) / std
    o = norm(vis.run(None, {"pixel_values": a.transpose(2, 0, 1)[None]})[0][0])
    m = run(["--clip-image", f"{mnn}/clip_vision.mnn", p])
    c = float(o @ m)
    worst = min(worst, c + 0.01)
    print(f"image {os.path.basename(p):28s} cos(MNN, ORT) = {c:.4f}")
    I_m.append(m); I_o.append(o)
T = []
for q in queries:
    ids = np.array([tok.encode(q).ids], np.int64)
    o = norm(txt.run(None, {"input_ids": ids})[0][0])
    m = run(["--clip-text", f"{mnn}/clip_text.mnn", f"{mnn}/clip_vocab.json", f"{mnn}/clip_merges.txt", q], "cpu")  # the text tower runs on the CPU
    c = float(o @ m)
    worst = min(worst, c)
    T.append(m)
    print(f"text  {q!r:30s} cos(MNN, ORT) = {c:.4f}")
S = np.array(T) @ np.array(I_m).T
for q, row in zip(queries, S):
    k = int(np.argmax(row))
    print(f"  {q!r:30s} -> {os.path.basename(photos[k]):28s} ({row[k]:.3f}; next {np.sort(row)[-2]:.3f})")
print("PASS" if worst > 0.99 else "FAIL", f"(worst cosine {worst:.4f})")
sys.exit(0 if worst > 0.99 else 1)
