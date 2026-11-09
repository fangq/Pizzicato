# Pizzicato

A fast, non-destructive photo manager and editor for Linux, in the spirit of
Picasa 3. Written in Free Pascal/Lazarus (UI) with a small C core (decoding and
pixel kernels).

* **Never touches your photos.** Edits are stored in the per-folder
  `.picasa.ini` files, in Picasa's own format, so edits made in Picasa
  show up in Pizzicato and the other way round.
* **Picasa-style library**: every folder in one continuous scroll with folder
  headers, a year/folder tree, a thumbnail size slider, stars, and a
  "Starred only" filter. Hide/Unhide (Picasa's `hidden=yes`) takes photos out
  of the library, and the "Hidden" toggle shows them again with a crossed-eye
  mark.
* **Photo tray, as in Picasa**: the selection (click, Ctrl+click, Shift+click
  across folders, Ctrl+A for a folder) plus photos *held* with the pin. Star,
  rotate, tag and export act on everything in the tray. A blue strip sums it up
  (count, dates, size on disk).
* **Properties and tags** in a right-hand panel. The properties of the tray
  are shown Picasa-style, with "(n)" counts and date ranges; EXIF is read in the
  background. Tags are Picasa's `keywords=` in `.picasa.ini`, and the search box
  matches folders, tags and file names.
* **Picasa's edit view**:
  * Basic Fixes as icon tiles (Crop, Straighten with a levelling grid, I'm
    Feeling Lucky, Auto Contrast, Auto Color), with Fill Light below.
  * A live Histogram & Camera Information box.
  * A "Make a caption!" line under the photo, stored as Picasa's `caption=`.
  * A Tags panel: type a tag and press +, see the photo's tags, and use ten
    Quick Tags (the gear configures them). A Quick Tag is bold when every photo
    in the tray has it, and clicking it adds or removes the tag.
* **Context menus**:
  * On a photo (library or full view): open, open with the default
    application, star, rotate, tag, hold, copy/paste/undo edits (Picasa's
    "copy all effects"), hide/unhide, export, copy the path, show in the file
    manager, delete from disk, properties.
  * **Delete from Disk** (also the Delete key) asks first, then moves the
    files to the desktop trash with `gio trash`, so they can be restored; their
    `.picasa.ini` entries are kept for that. Only when the trash cannot take a
    file does it offer to delete it permanently, with No as the default.
    `--readonly` refuses to delete.
  * On an album (folder list or folder header): select or hold all, export
    the album, edit its description (Picasa's `[Picasa] description=`), show it
    in the file manager, copy its path, rescan it.
* **Fast thumbnail cache** in SQLite (WAL mode), with JPEG blobs of 320 px on
  the long edge. Writes are batched, and each worker thread has its own read
  connection.
* **Formats**: JPEG, PNG, GIF, WebP, HEIC/HEIF/AVIF, and camera RAW (DNG, PEF,
  CR2/CR3, NEF, ARW, ORF, RW2, RAF and others) via LibRaw.
* **RAW speed**: thumbnails come from the JPEG previews embedded in the raw
  file, found by its own TIFF/MakerNote walker. That costs one 256 KB read and
  no demosaic. The viewer uses the full-size camera preview when the file has
  one (Pentax). Otherwise it does a LibRaw half-size decode. A toggle switches
  to LibRaw rendering for all raws.

* **AI tools** (local, offline, on the GPU with MNN's OpenCL backend; build
  with `make AI=1`):
  * **AI Denoise** (Basic Fixes): NAFNet, or SCUNet with "High quality",
    with a strength slider. Results are cached on disk.
  * **Remove**: click a person or a thing (MobileSAM selects it, shown in
    red), then Remove fills it in (LaMa).
  * **Upscale on export**: 2× or 4× with Real-ESRGAN, after the crop, so a
    tight crop can come back at full size.
  * **Smart search**: the toggle next to the search box finds photos by what
    is in them ("fireworks", "rice field") using CLIP embeddings of the
    thumbnails. The Properties panel shows what a photo "looks like".
  * **People**: faces are found (YuNet) and grouped by who they are (SFace)
    in the background. People and unnamed groups are listed at the top of the
    folder tree. Naming a group writes Picasa's own `faces=` and
    `[Contacts2]` entries, and the search box finds people by name.

## Build

Requirements: FPC 3.2, a built Lazarus tree (gtk2 LCL), gcc, and the -dev
packages for libjpeg-turbo, libpng, giflib, libwebp, libheif and sqlite3.
LibRaw 0.20 runtime (`libraw_r.so.20`) plus the matching headers are in
`third_party/libraw-0.20.2-include`.

    make                               # system Lazarus in /usr/lib/lazarus/default/
    make LAZDIR=/path/to/lazarus/      # or a built Lazarus tree; trailing slash required

Tested with Lazarus 2.2 (Ubuntu 22.04 package) and 4.2.

Run `make pretty` before committing. It formats the C core with astyle,
using mcx/mcxcl's options, and the Pascal sources with JCF
(`tools/jcfsettings.cfg`).

The build produces `./pizzicato`. The C core and its benchmark tool are in
`core/` (`core/pzbench`).

### AI tools

    tools/fetch_mnn.sh       # builds MNN with OpenCL into third_party/mnn
                             # (or: ln -s <an MNN already staged> third_party/mnn)
    tools/fetch_models.sh    # downloads + converts the models (needs `pip install MNN onnx`)
    make AI=1

The models go to `~/.local/share/pizzicato/models` (`PZ_MODELS` overrides).
GPU auto-tuning caches go next to the thumbnail DB. `PZ_AI_GPU=1` or
`PZ_AI_GPU=1:0` (platform:device) picks a GPU, and `PZ_AI_DEVICE=cpu` forces
the CPU. Plain `make` builds without MNN, and the AI tools then say so.

All the models have GPL-compatible licences: NAFNet (MIT), SCUNet
(Apache-2.0), Real-ESRGAN (BSD-3), MobileSAM (Apache-2.0), LaMa (Apache-2.0),
CLIP ViT-B/32 (MIT), YuNet (MIT) and SFace (Apache-2.0).
`tests/ai_parity.py` and `tests/clip_parity.py` check the converted models
against onnxruntime.

## Run

    ./pizzicato ~/Pictures            # add folders as library roots (not saved)
    ./pizzicato photo.dng             # open a single photo in the editor
    PZ_DB=/local/disk/pz.db ./pizzicato   # put the thumbnail cache somewhere local

Without arguments it uses the roots saved via *Add Folder…*, or `~/Pictures`.
The cache defaults to `$XDG_CACHE_HOME/pizzicato/library.db`. Keep it on a
local disk, because SQLite WAL on NFS is slow and unsafe.

### Keys

| Where   | Key                         | Action                         |
|---------|-----------------------------|--------------------------------|
| Library | arrows, PgUp/PgDn, Home/End | move / scroll                  |
| Library | Enter, double-click         | open in editor                 |
| Library | Ctrl+wheel                  | thumbnail size                 |
| Library | Ctrl+click, Shift+click     | add to / extend the selection  |
| Library | Ctrl+A                      | select the folder              |
| Both    | Ctrl+T                      | tag the photos in the tray     |
| Both    | Ctrl+8                      | star / unstar the tray         |
| Both    | Ctrl+] / Ctrl+[             | rotate clockwise / counter-clockwise |
| Editor  | ←/→, PgUp/PgDn, Space       | previous / next photo          |
| Editor  | Ctrl+Z / Ctrl+Y             | undo / redo                    |
| Editor  | mouse wheel                 | previous / next photo          |
| Editor  | double-click the photo      | 1:1 at that point              |
| Editor  | in 1:1: drag / click        | move the photo / back to fit   |
| Editor  | 1                           | toggle 1:1 at the centre       |
| Editor  | Esc                         | leave 1:1 or crop, else back to library |

## Picasa compatibility

| `.picasa.ini` key / filter | Status |
|---|---|
| `star=yes`, `rotate=rotate(n)`, `keywords=` (tags), `caption=`, `[Picasa] description=` | read + write |
| `filters=` chain, `redo=` (undo stack) | read + write, unknown entries kept verbatim |
| `fill`, `finetune2` (fill, highlights, shadows, neutral colour, temperature) | rendered |
| `autolight`, `autocolor`, `enhance` | rendered |
| `crop64`, `tilt` | rendered |
| `sat`, `Boost`, `bw`, `sepia`, `warm`, `unsharp2` | rendered |
| `retouch` | kept, **not rendered** (Picasa stores the retouch data elsewhere) |
| `pzbc` (brightness/contrast), `pzvignette`, `pzsoft` | Pizzicato extensions |
| `pzdenoise`, `pzremove` (masks in the album's `.pizzicato/`) | Pizzicato AI extensions |
| `faces=rect64(…),<hash>`, `[Contacts2] <hash>=Name;;` | written when a person is named |

The filter maths approximates Picasa's look and is not a bit-exact clone.
Picasa's implementation is closed, and there were too few original/edited
pairs on disk to calibrate against. The straighten scale (`tilt` ±1 = ±10°)
and the `Boost` and `sat` scales are educated guesses. Their constants are at
the top of `src/pzrender.pas` and in `core/pzcore.c`.

## Layout

    core/pzcore.c      decoders, TIFF/EXIF/MakerNote walker, resampler, filters (OpenMP)
    core/pzbench.c     command-line timing tool for the core
    core/pzai.cpp      AI models on MNN (tiling, CLIP, faces, SAM, LaMa); C ABI in pzai.h
    core/pzai_stub.c   the same API without MNN (plain `make`); core/pzai_cli = test tool
    src/pzai.pas       AI bindings, the GPU worker thread, denoise/remove/upscale
    src/pzsearch.pas   smart search: CLIP indexer + in-memory int8 index
    src/pzfaces.pas    People: face indexer, groups, persons
    src/pzcorebind.pas Pascal bindings
    src/pzini.pas      .picasa.ini + filter chain model
    src/pzrender.pas   filter chain -> pixel ops
    src/pzlibrary.pas  folders/photos model, SQLite cache, scanner, worker pool
    src/pzviews.pas    library grid, viewer, filmstrip (custom drawn)
    src/mainform.pas   window, edit panel; src/pzbench.inc = --bench driver
    src/pzicons.pas    toolbar icons, embedded from the generated src/pzicons.inc
    tools/make_icons.py  draws the icons (LED's painted style, pycairo): `make icons`
    data/icons/        the icons' 128 px masters

## Benchmarking

    ./pizzicato --bench --log=bench.txt --db=/local/pz.db <root>   # never writes .picasa.ini
    ./pizzicato --gen-all --log=gen.txt --db=/local/pz.db <root>   # build every thumbnail

Under Xvfb, run a window manager as well (for example `xfwm4 --compositor=off &`).
Without one, GTK keeps polling X for frame extents that never arrive, and the
window takes about 0.8 s longer to appear. On a real desktop this doesn't happen.
    core/pzbench thumb|view|raw|full|filters [-j N] files...
