{ render_chain <photo> <out.jpg> [rotate]: render a photo at 1000px with the
  chain stored for it in its folder's .picasa.ini, side by side with the original }
program render_chain;

{$mode objfpc}{$H+}
uses
  cthreads,
  SysUtils,
  pzcorebind,
  pzini,
  pzrender;

var
  Img, Ed, Both: Tpz_image;
  M: Tpz_meta;
  Ini: TPzIni;
  F: string;
  y: Integer;
begin
  if pz_load(PAnsiChar(ParamStr(1)), 1000, 1000, 0, @Img, @M) < 0 then Halt(1);
  Ini := TPzIni.Create(ExtractFileDir(ParamStr(1)) + '/.picasa.ini');
  Ini.Load;
  F := Ini.ReadValue(ExtractFileName(ParamStr(1)), 'filters');
  WriteLn(ExtractFileName(ParamStr(1)), ': ', F);
  pz_copy(@Img, @Ed);
  RenderChain(Ed, ParseChain(F),
    ParseRotate(Ini.ReadValue(ExtractFileName(ParamStr(1)), 'rotate')));
  { side by side, edited scaled to the original's height }
  if Ed.h <> Img.h then
  begin
    pz_resize(@Ed, Round(Ed.w * Img.h / Ed.h), Img.h, @Both);
    pz_free(@Ed);
    Ed := Both;
  end;
  pz_alloc(@Both, Img.w + Ed.w + 8, Img.h);
  FillChar(Both.px^, Both.w * Both.h * 4, 0);
  for y := 0 to Img.h - 1 do
  begin
    Move(Img.px[y * Img.w], Both.px[y * Both.w], Img.w * 4);
    Move(Ed.px[y * Ed.w], Both.px[y * Both.w + Img.w + 8], Ed.w * 4);
  end;
  pz_save_jpeg(PAnsiChar(ParamStr(2)), @Both, 88);
end.
