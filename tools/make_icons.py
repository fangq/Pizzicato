#!/usr/bin/env python3
"""Pizzicato's toolbar icons. Where LED's painted artwork has a matching
action (data/icons/painted, from LED's data/icons) the PNG is scaled in;
the photo-specific icons are drawn here in the same style (LED's
tools/visual_icons.py): thick rounded strokes in a cyan-to-violet gradient
over a pale translucent fill, accents in green/red/orange/yellow.

    python3 tools/make_icons.py            # data/icons/*.png + src/pzicons.inc
    python3 tools/make_icons.py --sheet sheet.png

Every icon is drawn as vectors at each embedded size (so small sizes stay
crisp instead of being resampled from the 128 px master), and the PNGs are
embedded in src/pzicons.inc so the program needs no data files at runtime.
"""

import io
import math
import os
import sys

import cairo

S = 128.0
W = 11.0  # the main stroke at 128 px
SIZES = (16, 20, 24, 32, 40, 48)

# ---------- palette and primitives (as in LED) ----------

BLUE = [(0.0, (0.02, 0.74, 1.0)), (0.55, (0.30, 0.40, 1.0)), (1.0, (0.70, 0.22, 0.96))]
GREEN = [(0.0, (0.10, 0.86, 0.45)), (1.0, (0.0, 0.62, 0.86))]
RED = [(0.0, (1.0, 0.36, 0.42)), (1.0, (0.88, 0.12, 0.42))]
ORANGE = [(0.0, (1.0, 0.72, 0.10)), (1.0, (1.0, 0.40, 0.25))]
GOLD = [(0.0, (1.0, 0.90, 0.25)), (1.0, (1.0, 0.62, 0.08))]
GREY = [(0.0, (0.85, 0.85, 0.85)), (1.0, (0.25, 0.25, 0.28))]
BROWN = [(0.0, (0.93, 0.74, 0.48)), (1.0, (0.55, 0.33, 0.16))]
YELLOW = (1.0, 0.86, 0.12)


def grad(stops=BLUE, x0=8, y0=8, x1=120, y1=120, alpha=1.0):
    g = cairo.LinearGradient(x0, y0, x1, y1)
    for o, (r, gg, b) in stops:
        g.add_color_stop_rgba(o, r, gg, b, alpha)
    return g


def rrect(c, x, y, w, h, r):
    c.new_sub_path()
    c.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    c.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    c.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    c.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
    c.close_path()


def pale(c, stops=BLUE):
    c.set_source_rgba(1, 1, 1, 0.82)
    c.fill_preserve()
    c.set_source(grad(stops, alpha=0.22))
    c.fill_preserve()


def stroke(c, stops=BLUE, width=W):
    c.set_source(grad(stops))
    c.set_line_width(width)
    c.set_line_cap(cairo.LINE_CAP_ROUND)
    c.set_line_join(cairo.LINE_JOIN_ROUND)
    c.stroke()


def bar(c, x0, y0, x1, y1, stops=BLUE, width=W):
    c.move_to(x0, y0)
    c.line_to(x1, y1)
    stroke(c, stops, width)


def body(c, x, y, w, h, r=16, stops=BLUE):
    rrect(c, x, y, w, h, r)
    pale(c, stops)
    stroke(c, stops)


def dot(c, x, y, r, stops=BLUE):
    c.arc(x, y, r, 0, 2 * math.pi)
    c.set_source(grad(stops, x - r, y - r, x + r, y + r))
    c.fill()


def text(c, s, x, y, size, stops=BLUE):
    c.select_font_face("DejaVu Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
    c.set_font_size(size)
    e = c.text_extents(s)
    c.move_to(x - e.x_bearing - e.width / 2, y - e.y_bearing - e.height / 2)
    c.text_path(s)
    c.set_source(grad(stops))
    c.fill()


def head(c, x, y, ang, stops=BLUE, width=W, size=18):
    """an open arrow head at (x, y) pointing along ang"""
    for s in (-1, 1):
        c.move_to(x, y)
        c.line_to(x - size * math.cos(ang + s * 0.62), y - size * math.sin(ang + s * 0.62))
        stroke(c, stops, width)


def badge(c, kind, x=96, y=96, r=24):
    stops = {"plus": GREEN, "check": GREEN, "minus": RED, "cross": RED}[kind]
    c.arc(x, y, r, 0, 2 * math.pi)
    c.set_source_rgb(1, 1, 1)
    c.fill_preserve()
    c.set_source(grad(stops, x - r, y - r, x + r, y + r))
    c.fill()
    c.set_source_rgb(1, 1, 1)
    c.set_line_width(8)
    c.set_line_cap(cairo.LINE_CAP_ROUND)
    c.set_line_join(cairo.LINE_JOIN_ROUND)
    k = r * 0.5
    if kind in ("plus", "minus"):
        c.move_to(x - k, y)
        c.line_to(x + k, y)
        if kind == "plus":
            c.move_to(x, y - k)
            c.line_to(x, y + k)
    elif kind == "cross":
        c.move_to(x - k, y - k)
        c.line_to(x + k, y + k)
        c.move_to(x + k, y - k)
        c.line_to(x - k, y + k)
    else:
        c.move_to(x - k, y)
        c.line_to(x - k * 0.2, y + k * 0.7)
        c.line_to(x + k, y - k * 0.6)
    c.stroke()


def photo(c, x=14, y=24, w=100, h=80, stops=BLUE, sun=ORANGE, hills=None):
    """a framed landscape: the app's basic 'picture' glyph"""
    rrect(c, x, y, w, h, 14)
    pale(c, stops)
    c.save()
    rrect(c, x, y, w, h, 14)
    c.clip()
    c.move_to(x - 4, y + h * 0.86)
    c.line_to(x + w * 0.34, y + h * 0.40)
    c.line_to(x + w * 0.56, y + h * 0.66)
    c.line_to(x + w * 0.72, y + h * 0.50)
    c.line_to(x + w + 4, y + h * 0.88)
    c.line_to(x + w + 4, y + h + 4)
    c.line_to(x - 4, y + h + 4)
    c.close_path()
    c.set_source(grad(hills or stops, alpha=0.75))
    c.fill()
    c.restore()
    if sun:
        dot(c, x + w * 0.74, y + h * 0.27, h * 0.12, sun)
    rrect(c, x, y, w, h, 14)
    stroke(c, stops)


def star_path(c, cx, cy, r, inner=0.45):
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        rr = r if i % 2 == 0 else r * inner
        (c.move_to if i == 0 else c.line_to)(cx + rr * math.cos(a), cy + rr * math.sin(a))
    c.close_path()


def curved_arrow(c, cx, cy, r, a0, a1, stops=BLUE, width=W):
    """an arc from a0 to a1 (radians, cairo's clockwise sense) with a head at a1"""
    if a1 > a0:
        c.arc(cx, cy, r, a0, a1)
    else:
        c.arc_negative(cx, cy, r, a0, a1)
    stroke(c, stops, width)
    x, y = cx + r * math.cos(a1), cy + r * math.sin(a1)
    tang = a1 + (math.pi / 2 if a1 > a0 else -math.pi / 2)
    head(c, x, y, tang, stops, width, 20)


# ---------- the icons ----------

ICONS = {}


def icon(name):
    def reg(f):
        ICONS[name] = f
        return f
    return reg






@icon("star")
def _(c):
    star_path(c, 64, 68, 56)
    c.set_source(grad(GOLD))
    c.fill_preserve()
    stroke(c, ORANGE, W * 0.8)


@icon("rotleft")
def _(c):
    photo(c, 34, 50, 70, 56, sun=None)
    curved_arrow(c, 52, 50, 34, -0.15 * math.pi, -0.95 * math.pi, GREEN)


@icon("rotright")
def _(c):
    photo(c, 24, 50, 70, 56, sun=None)
    curved_arrow(c, 76, 50, 34, -0.85 * math.pi, -0.05 * math.pi, GREEN)







@icon("crop")
def _(c):
    c.move_to(36, 10)
    c.line_to(36, 92)
    c.line_to(118, 92)
    stroke(c, BLUE, W * 1.2)
    c.move_to(10, 36)
    c.line_to(92, 36)
    c.line_to(92, 118)
    stroke(c, ORANGE, W * 1.2)


@icon("apply")
def _(c):
    c.move_to(18, 66)
    c.line_to(50, 98)
    c.line_to(112, 30)
    stroke(c, GREEN, W * 1.7)


@icon("cancel")
def _(c):
    bar(c, 26, 26, 102, 102, RED, W * 1.7)
    bar(c, 102, 26, 26, 102, RED, W * 1.7)


@icon("enhance")  # I'm Feeling Lucky: a magic wand
def _(c):
    bar(c, 22, 108, 82, 48, BLUE, W * 1.4)
    star_path(c, 92, 36, 26)
    c.set_source(grad(GOLD, 66, 10, 118, 62))
    c.fill_preserve()
    stroke(c, ORANGE, W * 0.6)
    dot(c, 40, 30, 7, GOLD)
    dot(c, 110, 86, 6, GOLD)
    dot(c, 62, 16, 5, GOLD)


@icon("autolight")  # auto contrast: a half-filled disc
def _(c):
    c.arc(64, 64, 50, 0, 2 * math.pi)
    c.set_source_rgba(1, 1, 1, 0.9)
    c.fill()
    c.move_to(64, 14)
    c.arc(64, 64, 50, -math.pi / 2, math.pi / 2)
    c.close_path()
    c.set_source(grad(BLUE))
    c.fill()
    c.arc(64, 64, 50, 0, 2 * math.pi)
    stroke(c)



@icon("picker")  # neutral colour picker: an eyedropper
def _(c):
    c.save()
    c.translate(64, 64)
    c.rotate(math.pi / 4)
    rrect(c, -10, -14, 20, 66, 8)
    pale(c)
    stroke(c)
    rrect(c, -20, -38, 40, 26, 10)
    c.set_source(grad(BLUE, -20, -38, 20, -12))
    c.fill()
    c.restore()
    dot(c, 24, 104, 9, GREY)


@icon("bw")
def _(c):
    photo(c, stops=GREY, sun=[(0, (0.95, 0.95, 0.95)), (1, (0.7, 0.7, 0.7))], hills=GREY)


@icon("sepia")
def _(c):
    photo(c, stops=BROWN, sun=[(0, (1.0, 0.92, 0.75)), (1, (0.85, 0.65, 0.40))], hills=BROWN)


@icon("warm")  # warmify: a sun
def _(c):
    for i in range(8):
        a = i * math.pi / 4
        bar(c, 64 + 38 * math.cos(a), 64 + 38 * math.sin(a), 64 + 54 * math.cos(a), 64 + 54 * math.sin(a), ORANGE, W)
    dot(c, 64, 64, 28, ORANGE)


@icon("tab_basic")  # a wrench
def _(c):
    c.save()
    c.translate(64, 64)
    c.rotate(-math.pi / 4)
    rrect(c, -9, -10, 18, 66, 9)
    pale(c)
    stroke(c)
    c.arc(0, -30, 26, 0, 2 * math.pi)
    pale(c)
    stroke(c)
    rrect(c, -9, -60, 18, 30, 4)
    c.set_operator(cairo.OPERATOR_CLEAR)
    c.fill()
    c.set_operator(cairo.OPERATOR_OVER)
    c.restore()


@icon("tab_tuning")  # sliders
def _(c):
    for y, k in ((28, 84), (64, 44), (100, 72)):
        bar(c, 16, y, 112, y, BLUE, W * 0.8)
        c.arc(k, y, 13, 0, 2 * math.pi)
        c.set_source_rgb(1, 1, 1)
        c.fill_preserve()
        stroke(c, ORANGE, W * 0.8)


@icon("tab_effects")  # sparkles
def _(c):
    star_path(c, 54, 66, 44, 0.32)
    c.set_source(grad(BLUE))
    c.fill()
    star_path(c, 100, 28, 20, 0.32)
    c.set_source(grad(GOLD, 80, 8, 120, 48))
    c.fill()
    star_path(c, 104, 100, 14, 0.32)
    c.set_source(grad(GOLD, 90, 86, 118, 114))
    c.fill()


# painted artwork: icon name -> data/icons/painted/<file>.png
PAINTED = {
    "addfolder": "newfolder",
    "search": "find",
    "undo": "undo",
    "redo": "redo",
    "export": "saveas",
    "library": "shading",
    "zoom100": "zoomin",
    "autocolor": "theme",
    "thumbsize": "insertpicture",
    "folder": "open",
}
PAINTED_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           "data", "icons", "painted")


def painted(c, fname):
    img = cairo.ImageSurface.create_from_png(os.path.join(PAINTED_DIR, fname + ".png"))
    c.save()
    c.scale(S / img.get_width(), S / img.get_height())
    c.set_source_surface(img, 0, 0)
    c.get_source().set_filter(cairo.FILTER_BEST)
    c.paint()
    c.restore()


for _n, _f in PAINTED.items():
    ICONS[_n] = (lambda f: lambda c: painted(c, f))(_f)


@icon("pin")  # hold the selection in the tray: a green push pin
def _(c):
    c.save()
    c.translate(64, 64)
    c.rotate(math.pi / 5)
    rrect(c, -22, -54, 44, 18, 8)
    c.set_source(grad(GREEN, -22, -54, 22, -36))
    c.fill()
    c.move_to(-14, -36)
    c.line_to(14, -36)
    c.line_to(20, 4)
    c.line_to(-20, 4)
    c.close_path()
    pale(c, GREEN)
    stroke(c, GREEN)
    rrect(c, -34, 0, 68, 14, 7)
    c.set_source(grad(GREEN, -34, 0, 34, 14))
    c.fill()
    bar(c, 0, 16, 0, 58, GREY, W * 0.8)
    c.restore()


@icon("clearsel")  # clear the selection: Picasa's red ring
def _(c):
    c.arc(64, 64, 42, 0, 2 * math.pi)
    stroke(c, RED, W * 1.5)


@icon("tag")  # a luggage tag
def _(c):
    c.move_to(18, 24)
    c.line_to(64, 24)
    c.line_to(110, 70)
    c.line_to(70, 110)
    c.line_to(24, 64)
    c.close_path()
    pale(c, ORANGE)
    stroke(c, ORANGE)
    c.arc(44, 46, 9, 0, 2 * math.pi)
    stroke(c, ORANGE, W * 0.8)
    bar(c, 60, 64, 82, 86, ORANGE, W * 0.8)


@icon("info")  # properties
def _(c):
    c.arc(64, 64, 52, 0, 2 * math.pi)
    c.set_source(grad(BLUE))
    c.fill()
    dot(c, 64, 36, 9, [(0, (1, 1, 1)), (1, (1, 1, 1))])
    c.set_source_rgb(1, 1, 1)
    c.set_line_width(W * 1.4)
    c.set_line_cap(cairo.LINE_CAP_ROUND)
    c.move_to(64, 58)
    c.line_to(64, 94)
    c.stroke()


@icon("calendar")  # a year in the album list
def _(c):
    rrect(c, 14, 22, 100, 92, 14)
    pale(c)
    stroke(c)
    rrect(c, 14, 22, 100, 28, 14)
    c.set_source(grad(RED, 14, 22, 114, 50))
    c.fill()
    bar(c, 40, 12, 40, 32, BLUE, W * 0.9)
    bar(c, 88, 12, 88, 32, BLUE, W * 0.9)
    for r in range(2):
        for k in range(3):
            dot(c, 36 + k * 28, 70 + r * 24, 7)


@icon("straighten")  # a tilted photo over a level line
def _(c):
    c.save()
    c.translate(64, 58)
    c.rotate(-0.22)
    photo(c, -46, -34, 92, 68, sun=ORANGE)
    c.restore()
    bar(c, 8, 108, 120, 108, ORANGE, W)
    dot(c, 64, 108, 9, GOLD)


@icon("plus")  # add: a round green plus
def _(c):
    badge(c, "plus", 64, 64, 54)


@icon("gear")  # settings
def _(c):
    c.save()
    c.translate(64, 64)
    for i in range(8):
        c.save()
        c.rotate(i * math.pi / 4)
        rrect(c, -11, -58, 22, 26, 6)
        c.set_source(grad(ORANGE, -40, -60, 40, 60))
        c.fill()
        c.restore()
    c.arc(0, 0, 40, 0, 2 * math.pi)
    c.set_source(grad(ORANGE, -40, -40, 40, 40))
    c.fill()
    c.arc(0, 0, 16, 0, 2 * math.pi)
    c.set_source_rgb(1, 1, 1)
    c.fill()
    c.restore()


@icon("undoall")  # the painted undo with a red cross badge
def _(c):
    painted(c, "undo")
    badge(c, "cross", 98, 98, 26)


# ---------- output ----------

def render(name, size):
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    c = cairo.Context(surf)
    c.scale(size / S, size / S)
    ICONS[name](c)
    buf = io.BytesIO()
    surf.write_to_png(buf)
    return buf.getvalue()


def write_inc(path, blobs):
    out = ["{ generated by tools/make_icons.py -- do not edit }", ""]
    names = sorted(ICONS)
    allb = bytearray()
    recs = []
    for n in names:
        for s in SIZES:
            b = blobs[(n, s)]
            recs.append((n, s, len(allb), len(b)))
            allb += b
    out.append("const")
    out.append("  PZ_ICON_COUNT = %d;" % len(recs))
    out.append("  PZ_ICON_INDEX: array[0..PZ_ICON_COUNT - 1] of TPzIconRec = (")
    out.append(",\n".join("    (Name: '%s'; Size: %d; Offset: %d; Len: %d)" % r for r in recs))
    out.append("  );")
    out.append("  PZ_ICON_BYTES: array[0..%d] of Byte = (" % (len(allb) - 1))
    lines = []
    for i in range(0, len(allb), 24):
        lines.append("    " + ", ".join("$%02x" % v for v in allb[i:i + 24]))
    out.append(",\n".join(lines))
    out.append("  );")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    if len(sys.argv) > 2 and sys.argv[1] == "--sheet":
        names = sorted(ICONS)
        cols = 8
        rows = (len(names) + cols - 1) // cols
        cell = 150
        surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, cols * cell, rows * cell)
        c = cairo.Context(surf)
        c.set_source_rgb(0.19, 0.19, 0.19)
        c.paint()
        for i, n in enumerate(names):
            img = cairo.ImageSurface.create_from_png(io.BytesIO(render(n, 128)))
            x, y = (i % cols) * cell + 11, (i // cols) * cell + 6
            c.set_source_surface(img, x, y)
            c.paint()
            # small sizes too, as the toolbar shows them
            for k, s in enumerate((20, 24)):
                im2 = cairo.ImageSurface.create_from_png(io.BytesIO(render(n, s)))
                c.set_source_surface(im2, x + 128 - (k + 1) * 26, y + 116)
                c.paint()
            c.set_source_rgb(0.85, 0.85, 0.85)
            c.select_font_face("DejaVu Sans")
            c.set_font_size(11)
            c.move_to(x, y + 140)
            c.show_text(n)
        surf.write_to_png(sys.argv[2])
        return
    outdir = os.path.join(root, "data", "icons")
    os.makedirs(outdir, exist_ok=True)
    blobs = {}
    for n in sorted(ICONS):
        with open(os.path.join(outdir, n + ".png"), "wb") as f:
            f.write(render(n, 128))
        for s in SIZES:
            blobs[(n, s)] = render(n, s)
    write_inc(os.path.join(root, "src", "pzicons.inc"), blobs)
    print("%d icons x %d sizes -> data/icons, src/pzicons.inc" % (len(ICONS), len(SIZES)))


if __name__ == "__main__":
    main()
