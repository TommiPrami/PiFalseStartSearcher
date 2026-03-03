unit PFSUnit.FalseRestartSearch;

interface

uses
  System.Classes, System.Diagnostics, System.Generics.Collections, System.SyncObjs, System.SysUtils, System.Threading;

type
  TPiFalseRestartSearcher = class;


  /// Fired when a Pi-prefix restart of length >= MinMatchLen is found.
  TPiMatchEvent = procedure(const ASender: TObject; const APosition: Int64; const AMatchedValue: AnsiString) of object;
  TPiTaskEndedEvent = procedure(const APiSearcher: TPiFalseRestartSearcher) of object;

  TRunStatus = (rsNone, rsRunning, rsCanceled, rsError, rsFinished);

  TPiFalseRestartSearcher = class(TObject)
  strict private
    FTask: ITask;
    FBufferSize: Integer;
    FFileStream: TFileStream;
    FFoundDictionary: TDictionary<AnsiString, Int64>;
    FMinMatchLength: Integer;
    FOnlyUniqueMatches: Boolean;
    FOnMatch: TPiMatchEvent;
    FPartialMatchTable: array of Integer; // KMP partial-match table
    FPiPrefix: AnsiString;
    FPrefixRemplateFileName: string;
    FStatus: TRunStatus;
    FLock: TCriticalSection;
    FStopWatch: TStopwatch;
    FOnTaksEndedEvent: TPiTaskEndedEvent;
    function LoadPiPrefix: AnsiString;
    procedure BuildKmpTable;
    procedure FireMatch(const APosition: Int64; const ALen: Integer); {$IF NOT Defined(DEBUG)}inline;{$ENDIF}
    procedure SetMinMatchLen(const AValue: Integer);
    procedure DoBeforeRunValidation;
    procedure StartSeachTask(const AFileStream: TFileStream);
    procedure ThreadedSearchFileStreamProc(const AFileStream: TFileStream);
    procedure SetStatus(const AStatus: TRunStatus); {$IF NOT Defined(DEBUG)}inline;{$ENDIF}
    function GetStatus: TRunStatus;
    function Lock: Boolean; {$IF NOT Defined(DEBUG)}inline;{$ENDIF}
    procedure UnLock;
  private
    function GetElapsedSeconds: Double; {$IF NOT Defined(DEBUG)}inline;{$ENDIF}
  public
    constructor Create(const AOnMatchEvent: TPiMatchEvent; const AOnTaksEndedEvent: TPiTaskEndedEvent; const AOnlyUniqueMatches: Boolean = True);
    destructor Destroy; override;

    function HasRunEndedStatus: Boolean; {$IF NOT Defined(DEBUG)}inline;{$ENDIF}
    procedure Cancel;
    // Perform the search.  Raises EFileStreamError on I/O problems.
    procedure Execute(const AFileName: string);
    property Status: TRunStatus read GetStatus;
    // Minimum run length to fire OnMatch.  Default = 4, must be >= 1.
    property MinMatchLength: Integer read FMinMatchLength write FMinMatchLength;
    // Read-buffer size in bytes.  Default = 16 MB.
    // Good values: 4-64 MB.  Does NOT affect which matches are found.
    property ElapsedSeconds: Double read GetElapsedSeconds;
    property BufferSize: Integer read FBufferSize write FBufferSize;
    // Fired for every Pi-prefix run of length >= MinMatchLen.
    property OnMatch: TPiMatchEvent read FOnMatch write FOnMatch;
  end;

implementation

// ---------------------------------------------------------------------------
//  Embedded Pi digits – first 1 000 decimal digits (no dot, no whitespace).
// ---------------------------------------------------------------------------
const
  MIN_MATCH_LENGTH = 4;
  PI_1000: AnsiString =
    '3141592653589793238462643383279502884197169399375105820974944592307816406286' +
    '2089986280348253421170679821480865132823066470938446095505822317253594081284' +
    '8111745028410270193852110555964462294895493038196442881097566593344612847564' +
    '8233786783165271201909145648566923460348610454326648213393607260249141273724' +
    '5870066063155881748815209209628292540917153643678925903600113305305488204665' +
    '2138414695194151160943305727036575959195309218611738193261179310511854807446' +
    '2379962749567351885752724891227938183011949129833673362440656643086021394946' +
    '3952247371907021798609437027705392171762931767523846748184676694051320005681' +
    '2714526356082778577134275778960917363717872146844090122495343014654958537105' +
    '0792279689258923542019956112129021960864034418159813629774771309960518707211' +
    '3499999837297804995105973173281609631859502445945534690830264252230825334468' +
    '5035261931188171010003137838752886587533208381420617177669147303598253490428' +
    '7554687311595628638823537875937519577818577805321712268066130019278766111959' +
    '09216420199';  // 1 000 digits total

// ---------------------------------------------------------------------------

procedure TPiFalseRestartSearcher.Cancel;
begin
  if GetStatus in [rsNone, rsRunning] then
    SetStatus(rsCanceled);
end;

constructor TPiFalseRestartSearcher.Create(const AOnMatchEvent: TPiMatchEvent; const AOnTaksEndedEvent: TPiTaskEndedEvent;
  const AOnlyUniqueMatches: Boolean = True);
begin
  inherited Create;

  FLock := TCriticalSection.Create;
  FFoundDictionary := TDictionary<AnsiString, Int64>.Create;
  FTask := nil;
  FOnMatch := AOnMatchEvent;
  SetStatus(rsNone);
  FPrefixRemplateFileName := '';
  FMinMatchLength := MIN_MATCH_LENGTH;
  FBufferSize  := 16 * 1024 * 1024;
  FOnlyUniqueMatches := AOnlyUniqueMatches;
  FOnTaksEndedEvent := AOnTaksEndedEvent;
end;

destructor TPiFalseRestartSearcher.Destroy;
begin
  FFoundDictionary.Free;

  inherited Destroy;
end;

procedure TPiFalseRestartSearcher.DoBeforeRunValidation;
begin
  try
    // ---- validate ----
    if FMinMatchLength < 1 then
      raise EArgumentException.Create('MinMatchLen must be >= 1');

    if FBufferSize < 1 then
      raise EArgumentException.Create('BufferSize must be >= 1');

    FPiPrefix := LoadPiPrefix;
    var LPiPrefixLength := Length(FPiPrefix);

    if LPiPrefixLength = 0 then
      raise EArgumentException.Create('Pi reference string is empty');

    if FMinMatchLength > LPiPrefixLength then
      raise EArgumentException.CreateFmt('MinMatchLen (%d) > Pi reference length (%d). ' +
        'Set PiSourceFile to a longer digit file.', [FMinMatchLength, LPiPrefixLength]);
  except
    SetStatus(rsError);
    raise;
  end;
end;

// ---------------------------------------------------------------------------
function TPiFalseRestartSearcher.LoadPiPrefix: AnsiString;
begin
  if not FPrefixRemplateFileName.IsEmpty and FileExists(FPrefixRemplateFileName) then
  begin
    var LFS := TBufferedFileStream.Create(FPrefixRemplateFileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Result, LFS.Size);

      LFS.ReadBuffer(Result[1], LFS.Size);
    finally
      LFS.Free;
    end;
  end
  else
    Result := PI_1000;
end;

function TPiFalseRestartSearcher.Lock: Boolean;
begin
  Result := False;

  if Assigned(FLock) then
  begin
    FLock.Acquire;
    Result := True;
  end;
end;

// ---------------------------------------------------------------------------
//  KMP partial-match (failure) table, 0-based.
//  Table[i] = length of the longest proper prefix of Pattern[1..i+1]
//             that is also a suffix.
// ---------------------------------------------------------------------------
procedure TPiFalseRestartSearcher.BuildKmpTable;
var
  LLength: Integer;
  LIndex: Integer;
  k: Integer;
begin
  LLength := Length(FPiPrefix);

  SetLength(FPartialMatchTable, LLength);

  FPartialMatchTable[0] := 0;
  k := 0;

  for LIndex := 1 to LLength - 1 do
  begin
    while (k > 0) and (FPiPrefix[k + 1] <> FPiPrefix[LIndex + 1]) do
      k := FPartialMatchTable[k - 1];

    if FPiPrefix[k + 1] = FPiPrefix[LIndex + 1] then
      Inc(k);

    FPartialMatchTable[LIndex] := k;
  end;
end;

// ---------------------------------------------------------------------------
procedure TPiFalseRestartSearcher.FireMatch(const APosition: Int64; const ALen: Integer);
begin
  if HasRunEndedStatus then
    Exit;

  if Assigned(FOnMatch) then
  begin
    var LPosition := APosition + 1;
    var LMatchString: AnsiString := Copy(FPiPrefix, 1, ALen);

    if FOnlyUniqueMatches then
    begin
      if FFoundDictionary.ContainsKey(LMatchString) then
        Exit
      else
        FFoundDictionary.Add(LMatchString, LPosition);
    end;


    TThread.Queue(nil,
      procedure
      begin
        FOnMatch(Self, LPosition, LMatchString);
      end
    );
  end;
end;

function TPiFalseRestartSearcher.GetElapsedSeconds: Double;
begin
  if GetStatus >= rsRunning then
    Result := FStopWatch.Elapsed.TotalSeconds
  else
    Result := 0.00;
end;

function TPiFalseRestartSearcher.GetStatus: TRunStatus;
begin
  if Lock then
  try
    Result := FStatus;
  finally
    UnLock;
  end;
end;

function TPiFalseRestartSearcher.HasRunEndedStatus: Boolean;
begin
  Result := GetStatus in [rsCanceled, rsError, rsFinished];
end;

// ---------------------------------------------------------------------------
(*
  SearchFile – streaming KMP loop
  ================================

  Key insight
  -----------
  We treat the file as the "text" and FPiPrefix (the Pi digits) as the
  "pattern".  KMP keeps a state variable j = number of Pi digits currently
  matched.  A "restart" of length L at file offset P means:
    the sub-string file[P..P+L-1] equals Pi[1..L].

  We report a run when j falls back to a smaller value (or 0), meaning the
  run just ended.  We always report the MAXIMUM depth reached before the
  fall-back.

  Algorithm (per byte ch at global file offset gOff)
  ---------------------------------------------------
  1.  While (j > 0) AND (ch != Pi[j+1]):
        The run at depth j just ended at gOff-1.
        Report if j >= MinMatchLen.
        j <- Failure[j-1]                  -- KMP fall-back
  2.  If ch == Pi[j+1]:
        If j == 0: record RunStart = gOff  -- new run starts here
        j <- j + 1
        If j == m: report + fall-back      -- full pattern hit (very rare)
  3.  Else (j==0 and ch != Pi[1]):
        No match; RunStart is irrelevant.

  The while-loop in step 1 can report multiple times per character only when
  overlapping prefixes of different lengths all end at gOff-1.  That is
  correct: e.g. if Pi starts "ABCABD..." and we matched 6, fail to 3, the
  run of 6 and independently the run of 3 are both legitimate restarts at
  (possibly different) start positions.

  Buffer overlap
  --------------
  We carry the last (m-1) bytes of each buffer into the start of the next
  read so that a run spanning a read boundary is never interrupted.
*)
procedure TPiFalseRestartSearcher.Execute(const AFileName: string);
begin
  FStatus := rsNone;

  DoBeforeRunValidation;
  BuildKmpTable;

  FFileStream := TBufferedFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite, BufferSize * 8);

  StartSeachTask(FFileStream);
end;

procedure TPiFalseRestartSearcher.SetMinMatchLen(const AValue: Integer);
begin
  if AValue >= MIN_MATCH_LENGTH then
    FMinMatchLength := AValue
  else
    FMinMatchLength := MIN_MATCH_LENGTH;
end;

procedure TPiFalseRestartSearcher.SetStatus(const AStatus: TRunStatus);
begin
  if Lock then
  try
    FStatus := AStatus;

    // TODO: test this, should not need this, loop shpould exit fast...
    // if (FStatus = rsCanceled) and Assigned(FTask) then
    //   FTask.Cancel;
  finally
    UnLock;
  end;
end;

procedure TPiFalseRestartSearcher.StartSeachTask(const AFileStream: TFileStream);
begin
  FTask := TTask.Create(
    procedure
    begin
      FStopWatch := FStopWatch.StartNew;
      try
        ThreadedSearchFileStreamProc(AFileStream);

        if Assigned(FTask) then
        begin
          case FTask.Status of
            TTaskStatus.Completed: SetStatus(rsFinished);
            TTaskStatus.Canceled: SetStatus(rsCanceled);
            TTaskStatus.Exception: SetStatus(rsError);
            else
              SetStatus(rsFinished);
          end;
        end
        else
          SetStatus(rsFinished);
      except
        SetStatus(rsError);
      end;

      FStopWatch.Stop;

      if Assigned(FOnTaksEndedEvent) then
        TThread.Synchronize(nil,
          procedure
          begin
            FOnTaksEndedEvent(Self);
          end
        );
    end
  );

  SetStatus(rsRunning);
  FTask.Start;
end;

procedure TPiFalseRestartSearcher.ThreadedSearchFileStreamProc(const AFileStream: TFileStream);
var
  LChunkBytes: Integer;
  LOverlapBytes: Integer;
  BufUsed: Integer;
  LGlobalBase: Int64; // file offset of Buf[0] in current iteration
  i: Integer;
  ch: Byte;
  j: Integer; // KMP state: digits matched so far
begin
  var LPiPrefixLength: Integer := Length(FPiPrefix);;
  var LBuffer: TBytes;

  // Allocate once: room for (m-1) overlap + up to FBufferSize new bytes
  SetLength(LBuffer, LPiPrefixLength + FBufferSize);

  var LRunStart: Int64 := 0; // file offset of the start of the current run
  j := 0;
  LOverlapBytes := 0;
  LGlobalBase := 0;

  repeat
    // -- read next chunk (overlap bytes are already at LBuffer[0..OverlapBytes-1]) --
    LChunkBytes := AFileStream.Read(LBuffer[LOverlapBytes], FBufferSize);
    BufUsed := LOverlapBytes + LChunkBytes;

    if BufUsed = 0 then
      Break;

    // -- KMP walk --
    for i := 0 to BufUsed - 1 do
    begin
      ch := LBuffer[i];

      // Step 1: fall-back while mismatch
      while (j > 0) and (ch <> Ord(FPiPrefix[j + 1])) do
      begin
        if j >= FMinMatchLength then
          FireMatch(LRunStart, j);

        j := FPartialMatchTable[j - 1];
        // Recompute RunStart for the shorter run now potentially active:
        // the run of length j ends at (global offset i - 1), so it starts at
        // (GlobalBase + i - 1) - (j - 1) = GlobalBase + i - j.
        // We update unconditionally; if j=0 it will be reset on first match.
        LRunStart := LGlobalBase + i - j;
      end;

      // Step 2: try to extend
      if ch = Ord(FPiPrefix[j + 1]) then
      begin
        if j = 0 then
          LRunStart := LGlobalBase + i;  // fresh start

        Inc(j);

        // Full pattern matched (extremely rare in a real Pi file)
        if j = LPiPrefixLength then
        begin
          if j >= FMinMatchLength then
            FireMatch(LRunStart, j);

          j := FPartialMatchTable[j - 1];
          LRunStart := LGlobalBase + i + 1 - j;
        end;
      end;
      // (if j = 0 and ch <> Pi[1]: nothing to do, RunStart is overwritten on next match)
    end;

    // -- prepare next iteration --
    // Carry last (m - 1) bytes forward so no boundary-spanning match is lost
    LOverlapBytes := LPiPrefixLength - 1;

    if LOverlapBytes > BufUsed then
      LOverlapBytes := BufUsed;

    // Advance the global base by the bytes we WON'T re-read
    LGlobalBase := LGlobalBase + (BufUsed - LOverlapBytes);

    if LOverlapBytes > 0 then
      Move(LBuffer[BufUsed - LOverlapBytes], LBuffer[0], LOverlapBytes);

    if HasRunEndedStatus then
      Exit;
  until LChunkBytes = 0;

  // Report any run still in progress at EOF
  if j >= FMinMatchLength then
    FireMatch(LRunStart, j);
end;

procedure TPiFalseRestartSearcher.UnLock;
begin
  FLock.Release;
end;

end.
