#!/usr/bin/env python3
"""Parity of a converted .mnn model against its ONNX original.

    python3 tests/ai_parity.py model.onnx model.mnn image.jpg [tile] [devices]

One tile from the middle of the image goes through onnxruntime (CPU, the
reference) and through MNN via core/pzai_cli --raw on each device (default
"cpu opencl"); prints the PSNR of each against the reference and fails
when it is under 40 dB.
"""
import os, subprocess, sys, tempfile
import numpy as np
import onnxruntime as ort
from PIL import Image

onnx_path, mnn_path, img_path = sys.argv[1:4]
tile = int(sys.argv[4]) if len(sys.argv) > 4 else 0
devices = sys.argv[5].split() if len(sys.argv) > 5 else ["cpu", "opencl"]
cli = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "core", "pzai_cli")

sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
shape = sess.get_inputs()[0].shape
if isinstance(shape[2], int) and shape[2] > 0:
    tile = shape[2]
tile = tile or 256
img = Image.open(img_path).convert("RGB")
img.draft("RGB", (img.width // 2, img.height // 2))
a = np.asarray(img, dtype=np.float32) / 255.0
y0, x0 = (a.shape[0] - tile) // 2, (a.shape[1] - tile) // 2
x = np.ascontiguousarray(a[y0:y0 + tile, x0:x0 + tile].transpose(2, 0, 1)[None])
ref = sess.run(None, {sess.get_inputs()[0].name: x})[0].astype(np.float32)

worst = 1e9
with tempfile.TemporaryDirectory() as d:
    fin, fout = os.path.join(d, "in.f32"), os.path.join(d, "out.f32")
    x.tofile(fin)
    for dev in devices:
        r = subprocess.run([cli, "-d", dev, "-t", str(tile), "--raw", mnn_path, fin, fout],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"{dev}: FAILED\n{r.stderr}")
            sys.exit(1)
        out = np.fromfile(fout, dtype=np.float32).reshape(ref.shape)
        mse = float(np.mean((np.clip(out, 0, 1) - np.clip(ref, 0, 1)) ** 2))
        psnr = 99.0 if mse == 0 else 10 * np.log10(1.0 / mse)
        worst = min(worst, psnr)
        info = [l.strip() for l in r.stderr.splitlines() if "backend" in l or "forward" in l]
        print(f"{dev:7s} PSNR {psnr:6.2f} dB  max|d| {np.abs(out - ref).max():.4f}  | " + "; ".join(info))
print("PASS" if worst >= 40 else "FAIL", f"(worst {worst:.2f} dB, tile {tile})")
sys.exit(0 if worst >= 40 else 1)
