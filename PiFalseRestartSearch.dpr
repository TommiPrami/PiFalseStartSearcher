program PiFalseRestartSearch;

uses
  Vcl.Forms,
  PFSForm.Main in 'PFSForm.Main.pas' {PFSMainForm};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TPFSMainForm, PFSMainForm);
  Application.Run;
end.
