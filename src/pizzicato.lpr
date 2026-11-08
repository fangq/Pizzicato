program pizzicato;

{$mode objfpc}{$H+}

uses
  cthreads,
  cmem,
  Interfaces,
  Forms,
  pzlibrary,
  mainform;

begin
  PzStartTime := NowSeconds;
  RequireDerivedFormResource := False;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainFrm);
  Application.Run;
end.
