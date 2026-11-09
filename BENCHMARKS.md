# Pizzicato benchmarks — 2026-11-08

**Machine:** bixi1, 16 cores, 30 GB RAM, shared and busy (load average 8–13 during the runs).
**Library:** `lunar/Life/Pictures` on a local **HDD**: 1.6 TB, 492 folders, 107,592 photos
(about 73k Pentax K-5 DNG, 35k Pixel JPEG, plus Pixel 2 DNG). Thumbnail DB on local NVMe.
**Display:** Xvfb 1920×1080, viewer about 1570×1015, thumbnails 160 px.
**Logs:** `bench/*.txt`, kept locally and not in git (they list private album names).
Reproduce with `./pizzicato --bench --log=… --db=… <root>`.

"Cold" means the files are not in the OS page cache, so the times include HDD seeks.

## Loading a large library

| | time |
|---|---|
| Startup, warm DB (107,592 photos): DB load | **97 ms** |
| Startup → first screen of thumbnails fully drawn | **135 ms** after process start |
| Folder rescan, nothing changed (dir mtime check) | 0.2–0.7 s |
| First-ever folder scan (empty DB, cold disk) | 8.9 s |
| First-ever thumbnail build, whole library | 37.5 min, **46.6 thumbs/s** (HDD-bound), DB 1.8 GB |
| Jump-scroll to 16 random spots, thumbnails from DB | mean **26 ms**, max 44 ms per screen |
| Same, empty DB (generate on the fly, cold HDD) | mean 1.9 s per screen |
| Wheel scroll at 60 Hz (3,100 px/s) | screen complete on **240/240** frames, paint 0.02 ms |
| Thumbnail size change 160→256 | 12 ms |

Per-file thumbnail cost (C core, page cache warm): K-5 DNG **0.6 ms**
(MakerNote preview), Pixel 7 JPEG **1.5 ms** (510 px EXIF thumbnail), and
3,250 thumbnails/s across 16 threads. On a cold HDD it drops to about
60 files/s, which is the disk's seek limit.

## Opening and browsing photos (viewer, 1570×1015)

"Next" is the time from the key press to the full-quality frame.
"Dwell" is how long the user looks at each photo before pressing next;
neighbours are prefetched in the background meanwhile.

| | first open (cold disk) | next, no dwell (mean / median) | next, 400 ms dwell |
|---|---|---|---|
| K-5 DNG (full-size camera preview) | 94 ms | 40 / 36 ms | **3.3 ms** |
| Pixel 7 JPEG 4080×3072 | 25–500 ms | 64 / 55 ms | **2.8 ms** |
| Pixel 2 DNG (LibRaw half-size) | 210–1100 ms | 201 / 62 ms | **3.3 ms** |
| K-5 DNG, LibRaw rendering mode | 350–2170 ms | 421 / 339 ms | **3.8 ms** |

For raw files without a large preview (Pixel 2, or LibRaw mode), the embedded
preview is shown at once and the LibRaw frame replaces it when it's ready.
The table measures the LibRaw frame.

## Editing (each step re-renders the whole filter chain)

| | K-5 DNG (672×1015 screen image) | Pixel JPEG (1348×1015) |
|---|---|---|
| Any slider step (fill, highlights, shadows, temperature, brightness, contrast, saturation, boost, vignette) | 1.5–2.4 ms | 3.1–4.4 ms |
| Sharpen / soft focus / straighten | 2.6–3.1 ms | 5.2–6.0 ms |
| One-click: I'm Feeling Lucky / auto contrast / auto colour / B&W / sepia / warm | 1.4–3.3 ms | 2.8–6.6 ms |
| Crop | 0.2 ms | 0.4 ms |
| Stack of 6 filters (auto, finetune, boost, sharpen, tilt, crop), with rotate | 6.3 ms | 13.1 ms |
| 100% zoom: full-resolution decode | 262 ms (16 MP) | 174 ms (12.5 MP) |
| 100% zoom: 6-filter stack at full resolution | 166 ms | 108 ms |
| Export at full resolution (decode + 3 filters + JPEG q92) | 179 ms | 124 ms |

### 1:1 view on a remote display

At 1:1 the viewer no longer sends the whole photo to the X server. It cuts
the rendered image into 256 px tiles and sends only the ones on screen, and
uploads the tiles around the view while idle. Measured on the x2go (nxagent)
display this machine is used from, against a local Xvfb:

| X upload | x2go display | local Xvfb |
|---|---|---|
| Whole 4928×3264 image (64 MB): what entering 1:1 used to cost | 725–7,300 ms | 13 ms |
| A screenful of tiles (35 × 256²) | 108–118 ms | ~2 ms |
| Panning one frame (copying tiles already on the server) | 0.1 ms | 0.1–0.2 ms |

Edits made at 1:1 re-render without the whole-image upload too. A 1:1 render
with no edits fell from 29–31 ms to 13–17 ms on Xvfb, because the 16 MP bitmap
conversion is gone. 1:1 opens at once: until the full-resolution decode
(150–220 ms) is in, the screen-size image is shown enlarged in place. After
half a second on a photo the editor decodes its full resolution in the
background, as Picasa does. At most two full-resolution images are cached.

## AI tools (`make AI=1`, MNN 3.5 OpenCL on the TITAN V)

| Model | Work | Time |
|---|---|---|
| NAFNet-SIDD denoise | one 256 px tile | 73 ms (CPU, 16 threads: 195 ms) |
| NAFNet-SIDD denoise | screen-size image (1893×1254) | 5.1 s |
| NAFNet-SIDD denoise | full 16 MP K-5 DNG | 24.3 s; later from the disk cache 0.1 s |
| SCUNet ("High quality") | one 256 px tile | 204 ms (OpenCL images instead of buffers: 850 ms) |
| Real-ESRGAN general-x4v3 | one 128 px tile | 12 ms |
| Real-ESRGAN | export a 25 % crop at 4× (to 4928×3264) | 1.4 s |
| Real-ESRGAN | export a 16 MP photo at 2× (9856×6528) | 15.3 s |
| MobileSAM | encode a photo / one mask | 0.10 s / 0.05 s |
| LaMa | one removal | 0.57 s |
| CLIP ViT-B/32 | index the whole library from the thumbnails | 107,582 photos in 41 min (43.9 photos/s) |
| CLIP | one smart-search query over 107,582 photos | 26–28 ms (the first 0.4 s: loading the text tower) |
| YuNet + SFace | face detection on a 1600 px photo | 15–22 ms |
| YuNet + SFace | People indexing of the real library (HDD, newest first) | 11.2 photos/s (the whole library: about 2.7 h in the background) |

Parity of the converted models with onnxruntime (`tests/ai_parity.py`,
`tests/clip_parity.py`):
- NAFNet 101 dB, Real-ESRGAN 75 dB, SCUNet 64 dB PSNR;
- CLIP image cosine ≥ 0.985, CLIP text 1.0000 (on the CPU); the tokenizer
  gives the same ids as Hugging Face's, accents and CJK included;
- MobileSAM masks IoU 0.997.

MNN pitfalls found on the way:
- MobileSAM's and Florence-2's dynamic shapes convert wrongly. The encoder's
  output came out almost independent of the image, and the decoder's logits
  were 100× too small. Fixed shapes, set with `onnx` before converting,
  avoid it (`tools/fetch_models.sh`).
- MNN's OpenCL returns one embedding for every query on CLIP's text tower,
  so that runs on the CPU (2 ms a query).

On the real library, smart search gets 12 of 12 for "fireworks" and 12 of 12
for "temple" in its top 12. "a dog" finds dog statues and figurines first, and
real dogs after them.

People, on a sandbox of 111 copied photos:
- 38 faces found, 34 big enough to recognise;
- the biggest group's 19 faces are all one boy (masked, in profile, years
  apart);
- a second group is the same boy younger;
- a 2-photo group of monkey-statue faces is below the 3-photo listing
  threshold.

On the real library, the first 2,000 photos scanned gave:
- 1,295 faces, 739 of them big enough to recognise;
- 22 groups of 3 or more photos;
- the three biggest groups (234, 192 and 82 photos) are each one person, even
  at small, low-resolution face sizes;
- profile views group less cleanly: one mixed two people.

Florence-2 scene captions are not in yet: its decoder does not survive MNN's
conversion (see the `wip-florence` branch).

## Correctness checks

* All 260 `.picasa.ini` files in the library round-trip **byte-for-byte**
  (`tests/test_ini.pas`, run on copies). All 1,530 stored filter chains
  re-serialise identically.
* Benchmark and `--gen-all` modes force `.picasa.ini` to read-only. No photo
  or ini file was modified.
* 11 photos have no thumbnail: they are 0-byte files on disk.

## Not measured

Picasa itself was not run. Its database lives inside the photo tree
(`Pictures/picasa2`) and running it could rewrite user data. A side-by-side
comparison needs a sandboxed wine prefix and a copy of a few albums.
