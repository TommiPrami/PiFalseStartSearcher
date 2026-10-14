program PiFalseStartSearch;

uses
  Vcl.Forms,
  PFSForm.Main in 'PFSForm.Main.pas' {PFSMainForm},
  PFSUnit.FalseStartSearch in 'PFSUnit.FalseStartSearch.pas',
  PFSUnit.Report in 'PFSUnit.Report.pas',
  PFSUnit.RunLog in 'PFSUnit.RunLog.pas',
  PFSUnit.RunLog.Memo in 'PFSUnit.RunLog.Memo.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TPFSMainForm, PFSMainForm);
  Application.Run;
end.
