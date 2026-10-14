object PFSMainForm: TPFSMainForm
  Left = 0
  Top = 0
  Caption = 'Pi False Start Search'
  ClientHeight = 727
  ClientWidth = 999
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object PanelButtons: TPanel
    Left = 893
    Top = 0
    Width = 106
    Height = 727
    Align = alRight
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 1
    object ButtonRun: TButton
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 100
      Height = 25
      Action = ActionRun
      Align = alTop
      Default = True
      TabOrder = 0
    end
    object ButtonStopRun: TButton
      AlignWithMargins = True
      Left = 3
      Top = 34
      Width = 100
      Height = 25
      Action = ActionStopRun
      Align = alTop
      TabOrder = 1
    end
  end
  object PanelLog: TPanel
    Left = 0
    Top = 0
    Width = 893
    Height = 727
    Align = alClient
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 0
    object LabelProgress: TLabel
      AlignWithMargins = True
      Left = 3
      Top = 108
      Width = 887
      Height = 15
      Align = alTop
      Caption = 'LabelProgress'
    end
    object PanelFile: TPanel
      Left = 0
      Top = 0
      Width = 893
      Height = 29
      Align = alTop
      BevelOuter = bvNone
      ShowCaption = False
      TabOrder = 0
      object EditFileName: TEdit
        AlignWithMargins = True
        Left = 3
        Top = 3
        Width = 851
        Height = 23
        Align = alClient
        TabOrder = 0
        Text = 'D:\pi_dec_1t_01.txt'
      end
      object ButtonBrowse: TButton
        AlignWithMargins = True
        Left = 860
        Top = 3
        Width = 30
        Height = 23
        Action = ActionBrowse
        Align = alRight
        TabOrder = 1
      end
    end
    object PanelOptions: TPanel
      Left = 0
      Top = 29
      Width = 893
      Height = 76
      Align = alTop
      BevelOuter = bvNone
      ShowCaption = False
      TabOrder = 1
      object CheckBoxContinuationFiles: TCheckBox
        Left = 6
        Top = 4
        Width = 410
        Height = 17
        Caption = 'Continue with the numbered follow-up files (_02, _03, ...)'
        Checked = True
        State = cbChecked
        TabOrder = 0
      end
      object CheckBoxSelfLocating: TCheckBox
        Left = 6
        Top = 28
        Width = 410
        Height = 17
        Caption = 'Also search self-locating strings (digits at position P spell P)'
        TabOrder = 1
      end
      object CheckBoxListFalseStarts: TCheckBox
        Left = 430
        Top = 6
        Width = 170
        Height = 17
        Hint = 
          'Lists the false starts of at least this length in the summary at' +
          ' the end of the run, the first 1 000 of them. Without "Log only ' +
          'a new longest false start" they are also logged as found.'
        Caption = 'List false starts of length >='
        ParentShowHint = False
        ShowHint = True
        TabOrder = 2
      end
      object SpinEditListMatchLength: TSpinEdit
        Left = 604
        Top = 2
        Width = 60
        Height = 24
        MaxValue = 64
        MinValue = 4
        TabOrder = 3
        Value = 5
      end
      object CheckBoxOnlyNewLongest: TCheckBox
        Left = 430
        Top = 28
        Width = 240
        Height = 17
        Hint = 
          'Logs only a false start longer than any found before it. Without' +
          ' this, every false start of the length above is logged as found.'
        Caption = 'Log only a new longest false start'
        Checked = True
        ParentShowHint = False
        ShowHint = True
        State = cbChecked
        TabOrder = 4
      end
      object CheckBoxSummaryNewLongest: TCheckBox
        Left = 430
        Top = 52
        Width = 240
        Height = 17
        Hint = 
          'Lists the new longest false starts again in the summary at the e' +
          'nd of the run.'
        Caption = 'List new longest ones in the summary'
        ParentShowHint = False
        ShowHint = True
        TabOrder = 5
      end
    end
    object MemoLog: TMemo
      AlignWithMargins = True
      Left = 3
      Top = 129
      Width = 887
      Height = 595
      Align = alClient
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -13
      Font.Name = 'Courier New'
      Font.Style = []
      ParentFont = False
      ReadOnly = True
      ScrollBars = ssBoth
      TabOrder = 2
      WordWrap = False
    end
  end
  object ActionListMain: TActionList
    Left = 560
    Top = 130
    object ActionBrowse: TAction
      Caption = '...'
      Hint = 'Select the first digit file'
      OnExecute = ActionBrowseExecute
      OnUpdate = ActionBrowseUpdate
    end
    object ActionRun: TAction
      Caption = 'Run'
      OnExecute = ActionRunExecute
      OnUpdate = ActionRunUpdate
    end
    object ActionStopRun: TAction
      Caption = 'Stop run'
      OnExecute = ActionStopRunExecute
      OnUpdate = ActionStopRunUpdate
    end
  end
  object OpenDialogPiFile: TOpenDialog
    Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    Options = [ofHideReadOnly, ofFileMustExist, ofEnableSizing]
    Title = 'Select the first digit file'
    Left = 560
    Top = 200
  end
  object TimerProgress: TTimer
    Enabled = False
    Interval = 500
    OnTimer = TimerProgressTimer
    Left = 560
    Top = 270
  end
end
