{ Apply a Picasa filter chain to an image. The mapping from Picasa's stored
  parameters to pixel operations is an approximation of Picasa's look. }
unit pzrender;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, pzcorebind, pzini;

const
  { Picasa stores straighten as -1..1; this is the angle at |1| }
  PZ_TILT_MAX_DEG = 10.0;

{ Render chain + rotation in place. Img is replaced by the result. }
procedure RenderChain(var Img: Tpz_image; const Chain: TPzChain; Rotate: Integer);
{ Fraction of the source width/height that survives the crops in a chain,
  so a viewer can request a larger decode for heavily cropped photos. }
function ChainZoomFactor(const Chain: TPzChain): Double;
{ Does the chain change the image geometry (crop/tilt)? }
function ChainHasGeometry(const Chain: TPzChain): Boolean;
function IsKnownFilter(const Name: string): Boolean;

implementation

uses
  Math;

function ParseHex32(const S: string): LongWord;
begin
  Result := StrToIntDef('$' + S, 0);
end;

procedure RenderChain(var Img: Tpz_image; const Chain: TPzChain; Rotate: Integer);
var
  i: Integer;
  F: TPzFilter;
  N: string;
  L, T, R, B: Double;
  Rad: Single;
begin
  if Img.px = nil then
    Exit;
  for i := 0 to High(Chain) do
  begin
    F := Chain[i];
    N := F.Name;
    { sharpening radius tracks image size so previews look like the export }
    Rad := Max(1.0, Max(Img.w, Img.h) / 1600.0);
    if N = 'fill' then
      pz_tone(@Img, FArg(F, 0), 0, 0, 0, 0)
    else if N = 'finetune2' then
    begin
      pz_tone(@Img, FArg(F, 0), FArg(F, 1), FArg(F, 2), 0, 0);
      if (Length(F.Args) > 4) then
        pz_color(@Img, FArg(F, 4), ParseHex32(F.Args[3]))
      else if Length(F.Args) > 3 then
        pz_color(@Img, 0, ParseHex32(F.Args[3]));
    end
    else if N = 'autolight' then
      pz_autolight(@Img)
    else if N = 'autocolor' then
      pz_autocolor(@Img)
    else if N = 'enhance' then
    begin
      pz_autolight(@Img);
      pz_autocolor(@Img);
    end
    else if N = 'sat' then
      pz_saturation(@Img, 1.0 + FArg(F, 0, 0.5) * 1.5)
    else if N = 'Boost' then
      pz_boost(@Img, Min(1.0, FArg(F, 0, 6) / 12.0))
    else if N = 'bw' then
      pz_bw(@Img)
    else if N = 'sepia' then
      pz_sepia(@Img)
    else if N = 'warm' then
      pz_warm(@Img)
    else if N = 'unsharp2' then
      pz_sharpen(@Img, FArg(F, 0, 0.5) * 1.6, Rad)
    else if N = 'tilt' then
      pz_tilt(@Img, FArg(F, 0) * PZ_TILT_MAX_DEG)
    else if N = 'crop64' then
    begin
      if (Length(F.Args) > 0) and Crop64Decode(F.Args[0], L, T, R, B) then
        pz_crop(@Img, L, T, R, B);
    end
    { Pizzicato extensions (Picasa ignores unknown filters) }
    else if N = 'pzbc' then
      pz_tone(@Img, 0, 0, 0, FArg(F, 0), FArg(F, 1))
    else if N = 'pzvignette' then
      pz_vignette(@Img, FArg(F, 0, 0.5))
    else if N = 'pzsoft' then
      pz_softfocus(@Img, FArg(F, 0, 0.5));
    { retouch and unknown filters are kept in the chain but not rendered }
  end;
  if Rotate <> 0 then
    pz_rotate90(@Img, Rotate);
end;

function ChainZoomFactor(const Chain: TPzChain): Double;
var
  i: Integer;
  L, T, R, B: Double;
begin
  Result := 1.0;
  for i := 0 to High(Chain) do
    if (Chain[i].Name = 'crop64') and (Length(Chain[i].Args) > 0) and
      Crop64Decode(Chain[i].Args[0], L, T, R, B) then
      Result := Result * Max(R - L, B - T);
  if Result < 0.05 then
    Result := 0.05;
end;

function ChainHasGeometry(const Chain: TPzChain): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Chain) do
    if (Chain[i].Name = 'crop64') or (Chain[i].Name = 'tilt') then
      Exit(True);
  Result := False;
end;

function IsKnownFilter(const Name: string): Boolean;
begin
  case Name of
    'fill', 'finetune2', 'autolight', 'autocolor', 'enhance', 'sat', 'Boost', 'bw',
    'sepia', 'warm', 'unsharp2', 'tilt', 'crop64', 'pzbc', 'pzvignette', 'pzsoft':
      Result := True;
    else
      Result := False;
  end;
end;

end.
