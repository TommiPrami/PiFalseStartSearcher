unit PFSForm.Main;

interface

uses
  Winapi.Messages, Winapi.Windows, System.Actions, System.Classes, System.SysUtils, System.UITypes, System.Variants, Vcl.ActnList,
  Vcl.Controls, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Forms, Vcl.Graphics, Vcl.Samples.Spin, Vcl.StdCtrls, PFSUnit.FalseStartSearch,
  PFSUnit.Report, PFSUnit.RunLog;

type
  TPFSMainForm = class(TForm)
    ActionBrowse: TAction;
    ActionFlushFileCache: TAction;
    ActionListMain: TActionList;
    ActionRun: TAction;
    ActionStopRun: TAction;
    ButtonBrowse: TButton;
    ButtonFlushFileCache: TButton;
    ButtonRun: TButton;
    ButtonStopRun: TButton;
    CheckBoxContinuationFiles: TCheckBox;
    CheckBoxFlushAfterRun: TCheckBox;
    CheckBoxListFalseStarts: TCheckBox;
    CheckBoxOnlyNewLongest: TCheckBox;
    CheckBoxSelfLocating: TCheckBox;
    CheckBoxSummaryNewLongest: TCheckBox;
    ComboBoxReadMethod: TComboBox;
    EditFileName: TEdit;
    LabelProgress: TLabel;
    LabelReadMethod: TLabel;
    MemoLog: TMemo;
    OpenDialogPiFile: TOpenDialog;
    PanelButtons: TPanel;
    PanelFile: TPanel;
    PanelLog: TPanel;
    PanelOptions: TPanel;
    SpinEditListMatchLength: TSpinEdit;
    TimerProgress: TTimer;
    procedure ActionBrowseExecute(Sender: TObject);
    procedure ActionBrowseUpdate(Sender: TObject);
    procedure ActionFlushFileCacheExecute(Sender: TObject);
    procedure ActionFlushFileCacheUpdate(Sender: TObject);
    procedure ActionRunExecute(Sender: TObject);
    procedure ActionRunUpdate(Sender: TObject);
    procedure ActionStopRunExecute(Sender: TObject);
    procedure ActionStopRunUpdate(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure TimerProgressTimer(Sender: TObject);
  strict private
    FPiSearcher: TPiFalseStartSearcher;
    FRunLog: TPFSRunLog;
    // True from the start of a run until its end event has run, not only while the search thread runs
    FRunning: Boolean;
    function GetFileNames: TArray<string>;
    function GetListedKinds: TPFSMatchKinds;
    procedure FalseStartFound(const APiSearcher: TPiFalseStartSearcher; const AMatch: TPFSMatch);
    procedure FlushFileCache(const AFileNames: TArray<string>);
    procedure SearchEnded(const APiSearcher: TPiFalseStartSearcher);
    procedure SetRunning(const ARunning: Boolean);
  end;

var
  PFSMainForm: TPFSMainForm;

implementation

uses
  PFSUnit.FileCache, PFSUnit.RunLog.Memo;

{$R *.dfm}

{ TPFSMainForm }

procedure TPFSMainForm.ActionBrowseExecute(Sender: TObject);
begin
  OpenDialogPiFile.FileName := EditFileName.Text;

  if OpenDialogPiFile.Execute then
    EditFileName.Text := OpenDialogPiFile.FileName;
end;

procedure TPFSMainForm.ActionBrowseUpdate(Sender: TObject);
begin
  ActionBrowse.Enabled := not FRunning;
end;

procedure TPFSMainForm.ActionFlushFileCacheExecute(Sender: TObject);
begin
  FlushFileCache(GetFileNames);
end;

procedure TPFSMainForm.ActionFlushFileCacheUpdate(Sender: TObject);
begin
  ActionFlushFileCache.Enabled := not FRunning;
end;

procedure TPFSMainForm.ActionRunExecute(Sender: TObject);
begin
  if FRunning then
    Exit;

  FreeAndNil(FPiSearcher);
  FRunLog.Clear;

  FPiSearcher := TPiFalseStartSearcher.Create(FalseStartFound, SearchEnded);
  try
    FPiSearcher.ListMatchLength := SpinEditListMatchLength.Value;
    FPiSearcher.OnlyNewLongestMatches := CheckBoxOnlyNewLongest.Checked;
    FPiSearcher.ReadMethod := TPFSReadMethod(ComboBoxReadMethod.ItemIndex);
    FPiSearcher.SearchSelfLocating := CheckBoxSelfLocating.Checked;
    FPiSearcher.Execute(GetFileNames);
  except
    FreeAndNil(FPiSearcher);
    raise;
  end;

  FRunLog.LogRunStarted(FPiSearcher);
  SetRunning(True);
end;

procedure TPFSMainForm.ActionRunUpdate(Sender: TObject);
begin
  ActionRun.Enabled := not FRunning;
end;

procedure TPFSMainForm.ActionStopRunExecute(Sender: TObject);
begin
  if Assigned(FPiSearcher) then
    FPiSearcher.Cancel;
end;

procedure TPFSMainForm.ActionStopRunUpdate(Sender: TObject);
begin
  ActionStopRun.Enabled := FRunning;
end;

procedure TPFSMainForm.FalseStartFound(const APiSearcher: TPiFalseStartSearcher; const AMatch: TPFSMatch);
begin
  FRunLog.LogMatch(APiSearcher, AMatch);
end;

procedure TPFSMainForm.FormCreate(Sender: TObject);
begin
  FPiSearcher := nil;
  FRunning := False;
  FRunLog := TPFSMemoRunLog.Create(MemoLog, LabelProgress);
  FRunLog.Clear;

  // In the order of TPFSReadMethod, the item index is the method
  for var LReadMethod := Low(TPFSReadMethod) to High(TPFSReadMethod) do
    ComboBoxReadMethod.Items.Add(READ_METHOD_NAMES[LReadMethod]);

  ComboBoxReadMethod.ItemIndex := Ord(rmReadFile);
end;

procedure TPFSMainForm.FormDestroy(Sender: TObject);
begin
  // Cancels a running search and waits for it, before the log its events write to goes
  FreeAndNil(FPiSearcher);
  FreeAndNil(FRunLog);
end;

procedure TPFSMainForm.FlushFileCache(const AFileNames: TArray<string>);
begin
  PurgeFileCache(AFileNames);
  FRunLog.LogFileCachePurged(AFileNames);
end;

function TPFSMainForm.GetFileNames: TArray<string>;
begin
  if CheckBoxContinuationFiles.Checked then
    Result := TPiFalseStartSearcher.FindContinuationFiles(EditFileName.Text)
  else
    Result := [EditFileName.Text];
end;

function TPFSMainForm.GetListedKinds: TPFSMatchKinds;
begin
  Result := [];

  if CheckBoxListFalseStarts.Checked then
    Include(Result, mkFalseStart);

  if CheckBoxSummaryNewLongest.Checked then
    Include(Result, mkNewLongest);
end;

procedure TPFSMainForm.SearchEnded(const APiSearcher: TPiFalseStartSearcher);
begin
  SetRunning(False);
  FRunLog.LogRunEnded(APiSearcher, GetListedKinds);

  // The files of this run, the file name may have been edited meanwhile
  if CheckBoxFlushAfterRun.Checked then
    FlushFileCache(APiSearcher.FileNames);
end;

procedure TPFSMainForm.SetRunning(const ARunning: Boolean);
begin
  FRunning := ARunning;

  // The buttons follow FRunning through their actions
  EditFileName.Enabled := not ARunning;

  for var LIndex := 0 to PanelOptions.ControlCount - 1 do
    PanelOptions.Controls[LIndex].Enabled := not ARunning;

  TimerProgress.Enabled := ARunning;
end;

procedure TPFSMainForm.TimerProgressTimer(Sender: TObject);
begin
  if Assigned(FPiSearcher) then
    FRunLog.ShowProgress(FPiSearcher.Progress);
end;

end.
