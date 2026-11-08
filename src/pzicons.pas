{ Toolbar icons: PNGs drawn by tools/make_icons.py at several sizes and
  embedded in pzicons.inc, so the program needs no data files. }
unit pzicons;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Buttons, Controls, Forms, ImgList;

{ the icon at the embedded size closest to ASize (nil if unknown) }
function PzIconBitmap(const AName: string; ASize: Integer): TBitmap;
{ toolbar icon size for this screen: 20 px at 96 dpi, scaled }
function PzIconSize: Integer;
procedure PzSetGlyph(B: TCustomBitBtn; const AName: string);
procedure PzSetGlyph(B: TCustomSpeedButton; const AName: string);
function PzAddToImageList(IL: TCustomImageList; const AName: string): Integer;

implementation

type
  TPzIconRec = record
    Name: string;
    Size: Integer;
    Offset: Integer;
    Len: Integer;
  end;

{$I pzicons.inc}

function PzIconSize: Integer;
begin
  Result := Round(20 * Screen.PixelsPerInch / 96);
  if Result < 16 then
    Result := 16;
end;

function PzIconBitmap(const AName: string; ASize: Integer): TBitmap;
var
  i, Best: Integer;
  MS: TMemoryStream;
  Png: TPortableNetworkGraphic;
begin
  Result := nil;
  Best := -1;
  { the smallest embedded size not below ASize, else the largest }
  for i := 0 to PZ_ICON_COUNT - 1 do
    if PZ_ICON_INDEX[i].Name = AName then
    begin
      if (Best < 0) or ((PZ_ICON_INDEX[i].Size >= ASize) and
        ((PZ_ICON_INDEX[Best].Size < ASize) or
        (PZ_ICON_INDEX[i].Size < PZ_ICON_INDEX[Best].Size))) or
        ((PZ_ICON_INDEX[Best].Size < ASize) and (PZ_ICON_INDEX[i].Size >
        PZ_ICON_INDEX[Best].Size)) then
        Best := i;
    end;
  if Best < 0 then
    Exit;
  MS := TMemoryStream.Create;
  Png := TPortableNetworkGraphic.Create;
  try
    MS.WriteBuffer(PZ_ICON_BYTES[PZ_ICON_INDEX[Best].Offset], PZ_ICON_INDEX[Best].Len);
    MS.Position := 0;
    Png.LoadFromStream(MS);
    Result := TBitmap.Create;
    Result.Assign(Png); // keeps the alpha channel
  finally
    Png.Free;
    MS.Free;
  end;
end;

procedure PzSetGlyph(B: TCustomBitBtn; const AName: string);
var
  Bmp: TBitmap;
begin
  Bmp := PzIconBitmap(AName, PzIconSize);
  if Bmp = nil then
    Exit;
  try
    B.Glyph.Assign(Bmp);
    B.NumGlyphs := 1;
  finally
    Bmp.Free;
  end;
end;

procedure PzSetGlyph(B: TCustomSpeedButton; const AName: string);
var
  Bmp: TBitmap;
begin
  Bmp := PzIconBitmap(AName, PzIconSize);
  if Bmp = nil then
    Exit;
  try
    B.Glyph.Assign(Bmp);
    B.NumGlyphs := 1;
  finally
    Bmp.Free;
  end;
end;

function PzAddToImageList(IL: TCustomImageList; const AName: string): Integer;
var
  Bmp: TBitmap;
begin
  Result := -1;
  Bmp := PzIconBitmap(AName, IL.Width);
  if Bmp = nil then
    Exit;
  try
    Result := IL.Add(Bmp, nil);
  finally
    Bmp.Free;
  end;
end;

end.
