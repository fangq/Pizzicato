{ Pascal bindings for the pzcore C library (core/pzcore.h). }
unit pzcorebind;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

interface

uses
  ctypes;

type
  Tpz_image = record
    w, h: cint32;
    px: PLongWord;
  end;
  Ppz_image = ^Tpz_image;

  Tpz_meta = record
    width, height: cint32;
    orientation: cint32;
    is_raw: cint32;
    format: cint32;
    taken: cint64;
    exposure, fnumber, iso, focal: cfloat;
    make: array[0..31] of AnsiChar;
    model: array[0..63] of AnsiChar;
    lens: array[0..63] of AnsiChar;
  end;
  Ppz_meta = ^Tpz_meta;

  Tpz_hist = array[0..3, 0..255] of cuint32;

const
  PZ_FMT_UNKNOWN = 0;
  PZ_FMT_JPEG = 1;
  PZ_FMT_PNG = 2;
  PZ_FMT_GIF = 3;
  PZ_FMT_RAW = 4;
  PZ_FMT_TIFF = 5;
  PZ_FMT_WEBP = 6;

  PZ_THUMB = 1;
  PZ_RAW_FULL = 2;
  PZ_NO_PREVIEW = 4;
  PZ_PREVIEW_ONLY = 8;

function pz_load(path: PAnsiChar; maxw, maxh, flags: cint; img: Ppz_image;
  meta: Ppz_meta): cint; cdecl; external;
function pz_probe(path: PAnsiChar; meta: Ppz_meta): cint; cdecl; external;
function pz_format_of(path: PAnsiChar): cint; cdecl; external;
function pz_alloc(img: Ppz_image; w, h: cint): cint; cdecl; external;
procedure pz_free(img: Ppz_image); cdecl; external;
function pz_copy(src, dst: Ppz_image): cint; cdecl; external;
function pz_resize(src: Ppz_image; w, h: cint; dst: Ppz_image): cint; cdecl; external;
function pz_orient(img: Ppz_image; orientation: cint): cint; cdecl; external;
function pz_rotate90(img: Ppz_image; quarter_turns_cw: cint): cint; cdecl; external;
function pz_decode_jpeg_mem(buf: PByte; len: culong; maxw, maxh, fast: cint;
  img: Ppz_image): cint; cdecl; external;
function pz_encode_jpeg_mem(img: Ppz_image; quality: cint; out_: PPByte;
  outlen: pculong): cint; cdecl; external;
procedure pz_free_mem(p: Pointer); cdecl; external;
function pz_save_jpeg(path: PAnsiChar; img: Ppz_image; quality: cint): cint;
  cdecl; external;

procedure pz_histogram(img: Ppz_image; var hist: Tpz_hist); cdecl; external;
procedure pz_tone(img: Ppz_image;
  fill, highlights, shadows, brightness, contrast: cfloat); cdecl; external;
procedure pz_color(img: Ppz_image; temperature: cfloat; neutral_argb: cuint32);
  cdecl; external;
procedure pz_autolight(img: Ppz_image); cdecl; external;
procedure pz_autocolor(img: Ppz_image); cdecl; external;
procedure pz_saturation(img: Ppz_image; factor: cfloat); cdecl; external;
procedure pz_boost(img: Ppz_image; amount: cfloat); cdecl; external;
procedure pz_bw(img: Ppz_image); cdecl; external;
procedure pz_sepia(img: Ppz_image); cdecl; external;
procedure pz_warm(img: Ppz_image); cdecl; external;
procedure pz_sharpen(img: Ppz_image; amount, radius: cfloat); cdecl; external;
procedure pz_softfocus(img: Ppz_image; amount: cfloat); cdecl; external;
procedure pz_vignette(img: Ppz_image; amount: cfloat); cdecl; external;
function pz_crop(img: Ppz_image; l, t, r, b: cfloat): cint; cdecl; external;
function pz_tilt(img: Ppz_image; degrees: cfloat): cint; cdecl; external;
procedure pz_set_threads(n: cint); cdecl; external;
function pz_version: PAnsiChar; cdecl; external;

{ Helpers }
procedure pz_dot_i8(m: PShortInt; scale: PSingle; n, d: cint; q: PSingle; out_: PSingle);
  cdecl; external;
procedure PzInit(out img: Tpz_image);
function PzMake(const m: Tpz_meta): string;

implementation

uses
  SysUtils;

{$linklib pzai}// before pzcore: it uses pzcore's functions
{$linklib pzcore}
{$linklib jpeg}
{$linklib png16}
{$linklib gif}
{$linklib webp}
{$linklib heif}
{$linklib raw_r}
{$linklib z}
{$linklib gomp}
{$linklib stdc++}
{$linklib gcc_s}
{$linklib m}

procedure PzInit(out img: Tpz_image);
begin
  img.w := 0;
  img.h := 0;
  img.px := nil;
end;

function PzMake(const m: Tpz_meta): string;
var
  mk, md: string;
begin
  mk := Trim(StrPas(PAnsiChar(@m.make[0])));
  md := Trim(StrPas(PAnsiChar(@m.model[0])));
  if (mk <> '') and (Pos(LowerCase(mk), LowerCase(md)) = 1) then
    Result := md
  else if mk <> '' then
    Result := mk + ' ' + md
  else
    Result := md;
end;

end.
