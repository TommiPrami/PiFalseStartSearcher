program PiFalseStartSearch;

uses
  Vcl.Forms,
  PFSForm.Main in 'Source\Forms\PFSForm.Main.pas' {PFSMainForm},
  PFSUnit.FalseStartSearch in 'Source\Units\PFSUnit.FalseStartSearch.pas',
  PFSUnit.FileCache in 'Source\Units\PFSUnit.FileCache.pas',
  PFSUnit.Report in 'Source\Units\PFSUnit.Report.pas',
  PFSUnit.RunLog in 'Source\Units\PFSUnit.RunLog.pas',
  PFSUnit.RunLog.Memo in 'Source\Units\PFSUnit.RunLog.Memo.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TPFSMainForm, PFSMainForm);
  Application.Run;
end.
