# Painted icons

PNG artwork (128x128 RGBA) from LED (https://github.com/fangq/led, GPL-3.0),
`data/icons`, added there in commit 010ea34 "[icons] PNG artwork for the
actions"; the same set ships with mima-ide. `tools/make_icons.py` scales these
into `src/pzicons.inc` for the buttons that have a matching action; the
photo-specific icons are drawn by the script in the same palette.
