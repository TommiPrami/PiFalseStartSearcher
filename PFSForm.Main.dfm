object PFSMainForm: TPFSMainForm
  Left = 0
  Top = 0
  Caption = 'Pi False Start Search'
  ClientHeight = 387
  ClientWidth = 531
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  TextHeight = 15
  object Panel1: TPanel
    Left = 425
    Top = 0
    Width = 106
    Height = 387
    Align = alRight
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 0
    object ButtonRun: TButton
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 100
      Height = 25
      Align = alTop
      Caption = 'Run'
      Default = True
      TabOrder = 0
      OnClick = ButtonRunClick
    end
    object ButtonStopRun: TButton
      AlignWithMargins = True
      Left = 3
      Top = 34
      Width = 100
      Height = 25
      Align = alTop
      Caption = 'Stop run'
      Enabled = False
      TabOrder = 1
      OnClick = ButtonStopRunClick
    end
    object ButtonValidateFIle: TButton
      Left = 0
      Top = 337
      Width = 106
      Height = 25
      Align = alBottom
      Caption = 'Validate file'
      TabOrder = 2
      OnClick = ButtonValidateFIleClick
    end
    object ButtonMakeValidFile: TButton
      Left = 0
      Top = 362
      Width = 106
      Height = 25
      Align = alBottom
      Caption = 'Make valid file'
      TabOrder = 3
      OnClick = ButtonMakeValidFileClick
    end
  end
  object Panel2: TPanel
    Left = 0
    Top = 0
    Width = 425
    Height = 387
    Align = alClient
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 1
    object EditFileName: TEdit
      AlignWithMargins = True
      Left = 3
      Top = 3
      Width = 419
      Height = 23
      Align = alTop
      TabOrder = 0
      Text = 'D:\pi_dec_1t_01.txt'
    end
    object MemoLog: TMemo
      AlignWithMargins = True
      Left = 3
      Top = 32
      Width = 419
      Height = 352
      Align = alClient
      Font.Charset = DEFAULT_CHARSET
      Font.Color = clWindowText
      Font.Height = -15
      Font.Name = 'Courier New'
      Font.Style = []
      ParentFont = False
      TabOrder = 1
    end
  end
  object TimerProgress: TTimer
    Enabled = False
    Interval = 150
    OnTimer = TimerProgressTimer
    Left = 563
    Top = 86
  end
end
