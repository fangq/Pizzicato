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
