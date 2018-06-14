unit LldbInstructions;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, math, LazLoggerBase, DbgIntfDebuggerBase, DebugInstructions,
  LldbHelper;

type

  (*
   *  Instructions
   *)

  TLldbInstruction = class;

  { TLldbInstructionQueue }

  TLldbInstructionQueue = class(TDBGInstructionQueue)
  private
  protected
    procedure DoBeforeHandleLineReceived(var ALine: String); override;

    function GetSelectFrameInstruction(AFrame: Integer): TDBGInstruction; override;
    //function GetSelectThreadInstruction(AThreadId: Integer): TDBGInstruction; override;
  public
    procedure CancelAllForCommand(ACommand: TObject); // Does NOT include the current or running instruction
  end;

  { TLldbInstruction }

  TLldbInstruction = class(TDBGInstruction)
  private
    FOwningCommand: TObject;
    function GetQueue: TLldbInstructionQueue;
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
    function CheckForIgnoredError(const AData: String): Boolean;
    procedure SetContentReceieved; reintroduce;

    property Queue: TLldbInstructionQueue read GetQueue;
    property NextInstruction;
  public
    property OwningCommand: TObject read FOwningCommand write FOwningCommand;
  end;

  { TLldbInstructionSettingSet }

  TLldbInstructionSettingSet = class(TLldbInstruction)
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create(AName, AValue: String; AGlobal: Boolean = False);
  end;

  { TLldbInstructionTargetCreate }

  TLldbInstructionTargetCreate = class(TLldbInstruction)
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create(AFile: String);
  end;

  { TLldbInstructionTargetDelete }

  TLldbInstructionTargetDelete = class(TLldbInstruction)
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create;
  end;

  { TLldbInstructionProcessLaunch }

  TLldbInstructionProcessLaunch = class(TLldbInstruction)
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create();
  end;

  { TLldbInstructionProcessStep }

  TLldbInstructionProcessStepAction = (saContinue, saOver, saInto, saOut);

  TLldbInstructionProcessStep = class(TLldbInstruction)
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create(AStepAction: TLldbInstructionProcessStepAction);
  end;

  { TLldbInstructionProcessKill }

  TLldbInstructionProcessKill = class(TLldbInstruction)
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create();
  end;

  { TLldbInstructionBreakSet }

  TLldbInstructionBreakSet = class(TLldbInstruction)
  private
    FBreakId: Integer;
    FState: TValidState;
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create(AFileName: String; ALine: Integer);
    property BreakId: Integer read FBreakId;
    property State: TValidState read FState;
  end;

  { TLldbInstructionBreakDelete }

  TLldbInstructionBreakDelete = class(TLldbInstruction)
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create(AnId: Integer);
  end;

  { TLldbInstructionFrameSelect }

  TLldbInstructionFrameSelect = class(TLldbInstruction)
  private
    FIndex: Integer;
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create(AnIndex: Integer);
  end;

  { TLldbInstructionExpression }

  TLldbInstructionExpression = class(TLldbInstruction)
  private
    FRes: String;
    FCurly: Integer;
  protected
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create(AnExpression: String; AThread, AFrame: Integer);
    property Res: String read FRes;
  end;

  { TLldbInstructionStackTrace }

  TLldbInstructionStackTrace = class(TLldbInstruction)
  private
    FCallstack: TCallStackBase;
    FRes: TStringArray;
    FReading: Boolean;
  protected
    procedure SendCommandDataToDbg(); override;
    function ProcessInputFromDbg(const AData: String): Boolean; override;
  public
    constructor Create(FrameCount: Integer; ACallstack: TCallStackBase);
    property Res: TStringArray read FRes;
    property Callstack: TCallStackBase read FCallstack;
  end;

implementation

{ TLldbInstructionQueue }

procedure TLldbInstructionQueue.DoBeforeHandleLineReceived(var ALine: String);
begin
  while LeftStr(ALine, 7) = '(lldb) ' do begin
    Delete(ALine, 1, 7);
  end;

  inherited DoBeforeHandleLineReceived(ALine);

  // TODO: detect the echo, and flag if data is for RunningInstruction;

//  if LeftStr(ALine, 7) = 'error: ' then begin
//    // TODO: late error for previous instruction
//    ALine := '';
//  end;
//
//  ALine := '';
end;

function TLldbInstructionQueue.GetSelectFrameInstruction(AFrame: Integer
  ): TDBGInstruction;
begin
  Result := TLldbInstructionFrameSelect.Create(AFrame);
end;

procedure TLldbInstructionQueue.CancelAllForCommand(ACommand: TObject);
var
  Instr, NextInstr: TLldbInstruction;
begin
  NextInstr := TLldbInstruction(FirstInstruction);
  while NextInstr <> nil do begin
    Instr := NextInstr;
    NextInstr := TLldbInstruction(Instr.NextInstruction);
    if Instr.OwningCommand = ACommand then begin
      Instr.Cancel;
    end;
  end;
end;

{ TLldbInstruction }

function TLldbInstruction.GetQueue: TLldbInstructionQueue;
begin
  Result := TLldbInstructionQueue(inherited Queue);
end;

function TLldbInstruction.ProcessInputFromDbg(const AData: String): Boolean;
begin
  Result := False;
  if LeftStr(AData, 7) = 'error: ' then begin
    Result := True;
    if CheckForIgnoredError(AData) then
      exit;

    HandleError(ifeContentError);
    exit;
  end;
end;

function TLldbInstruction.CheckForIgnoredError(const AData: String): Boolean;
begin
  Result := True;
  if StrStartsWith(AData, 'error: ') then begin // ignore dwarf warnings
    if StrMatches(AData, ['error', 'unhandled type tag', 'DW_TAG_', '']) then // ignore dwarf warnings
      exit;
    if StrStartsWith(AData, 'error: need to add support for DW_TAG_') then // ignore dwarf warnings
      exit;
  end;
  Result := False;
end;

procedure TLldbInstruction.SetContentReceieved;
begin
  inherited;
  MarkAsSuccess;
end;

{ TLldbInstructionSettingSet }

function TLldbInstructionSettingSet.ProcessInputFromDbg(const AData: String
  ): Boolean;
begin
  Result := inherited ProcessInputFromDbg(AData);

  if not Result then // if Result=true then self is destroyed;
    MarkAsSuccess;
  Result := true;
end;

constructor TLldbInstructionSettingSet.Create(AName, AValue: String;
  AGlobal: Boolean);
begin
  if AGlobal then
    inherited Create(Format('settings set -g -- %s %s', [AName, AValue]))
  else
    inherited Create(Format('settings set -- %s %s', [AName, AValue]));
end;

{ TLldbInstructionTargetCreate }

function TLldbInstructionTargetCreate.ProcessInputFromDbg(const AData: String
  ): Boolean;
begin
  Result := True;
  if LeftStr(AData, 25) = 'Current executable set to' then begin
    SetContentReceieved;
  end
  else
    Result := inherited;
end;

constructor TLldbInstructionTargetCreate.Create(AFile: String);
begin
  if pos(' ', AFile) > 0 then
    AFile := ''''+AFile+'''';
  inherited Create('target create '+AFile);
end;

{ TLldbInstructionTargetDelete }

function TLldbInstructionTargetDelete.ProcessInputFromDbg(const AData: String
  ): Boolean;
begin
  Result := True;
  if (LeftStr(AData, 27) = 'error: no targets to delete') or
     (LeftStr(AData, 17) = '1 targets deleted')
  then begin
    SetContentReceieved;
  end
  else
    Result := inherited;
end;

constructor TLldbInstructionTargetDelete.Create;
begin
  inherited Create('target delete 0');
end;

{ TLldbInstructionProcessLaunch }

function TLldbInstructionProcessLaunch.ProcessInputFromDbg(const AData: String
  ): Boolean;
begin
  Result := True;
  if (LeftStr(AData, 8) = 'Process ') and (pos(' launched:', AData) > 8) then begin
    SetContentReceieved;
  end
  else
    Result := inherited;
end;

constructor TLldbInstructionProcessLaunch.Create();
begin
  inherited Create('process launch -n');
end;

{ TLldbInstructionProcessStep }

function TLldbInstructionProcessStep.ProcessInputFromDbg(const AData: String
  ): Boolean;
begin
  Result := inherited ProcessInputFromDbg(AData);
  SetContentReceieved;
end;

constructor TLldbInstructionProcessStep.Create(
  AStepAction: TLldbInstructionProcessStepAction);
begin
  case AStepAction of
  	saContinue: inherited Create('thread continue');
    saOver: inherited Create('thread step-over');
  	saInto: inherited Create('thread step-in');
    saOut: inherited Create('thread step-out');
  end;
end;

{ TLldbInstructionProcessKill }

function TLldbInstructionProcessKill.ProcessInputFromDbg(const AData: String
  ): Boolean;
begin
  Result := True;
  if (LeftStr(AData, 8) = 'Process ') and (pos(' exited with status = ', AData) > 7) then begin
    SetContentReceieved;
  end
  else
      Result := inherited;
end;

constructor TLldbInstructionProcessKill.Create();
begin
  inherited Create('process kill');
end;

{ TLldbInstructionBreakSet }

function TLldbInstructionBreakSet.ProcessInputFromDbg(const AData: String
  ): Boolean;
var
  i: Integer;
  found, found2: TStringArray;
begin
  Result := True;
  if StrMatches(AData, ['Breakpoint ',': ', ''], found) then begin
    i := StrToIntDef(found[0], -1);
    if i = -1 then begin
      MarkAsFailed;
      exit;
    end;
    FBreakId:= i;

    if StrContains(found[1], 'pending') then
      FState := vsPending
    else
    if StrMatches(found[1], ['', ' locations'], found2) then begin
      if StrToIntDef(found2[0], 0) > 0 then
        FState := vsValid;
    end
    else
    if StrStartsWith(found[1], 'where = ') then
      FState := vsValid;

    MarkAsSuccess;
  end
//Breakpoint 41: where = lazarus.exe`CREATE + 2029 at synedit.pp:2123, address = 0x00764d2d
//Breakpoint 38: no locations (pending).
//Breakpoint 34: 3 locations.
  else
      Result := inherited;
end;

constructor TLldbInstructionBreakSet.Create(AFileName: String; ALine: Integer);
begin
  FState := vsInvalid;
  if pos(' ', AFileName) > 0 then
    AFileName := ''''+AFileName+'''';
  inherited Create(Format('breakpoint set --file %s --line %d', [AFileName, ALine]));
end;

{ TLldbInstructionBreakDelete }

function TLldbInstructionBreakDelete.ProcessInputFromDbg(const AData: String
  ): Boolean;
begin
  Result := inherited ProcessInputFromDbg(AData);

  if not Result then // if Result=true then self is destroyed;
    MarkAsSuccess;
  Result := true;
end;

constructor TLldbInstructionBreakDelete.Create(AnId: Integer);
begin
  inherited Create(Format('breakpoint delete %d', [AnId]));
end;

{ TLldbInstructionFrameSelect }

function TLldbInstructionFrameSelect.ProcessInputFromDbg(const AData: String
  ): Boolean;
begin
  Result := inherited ProcessInputFromDbg(AData);

  if not Result then begin // if Result=true then self is destroyed;
    Queue.SetKnownThreadAndFrame(Queue.CurrentThreadId, FIndex);
    MarkAsSuccess;
  end;
  Result := true;
end;

constructor TLldbInstructionFrameSelect.Create(AnIndex: Integer);
begin
  FIndex := AnIndex;
  inherited Create(Format('frame select %d', [AnIndex]));
end;

{ TLldbInstructionExpression }

function TLldbInstructionExpression.ProcessInputFromDbg(const AData: String
  ): Boolean;
  function ParseStruct(ALine: string): Boolean;
  var
    i: Integer;
  begin
    i := 1;
    while i <= Length(ALine) do begin
      case ALine[i] of
        '"': break; // string always goes to end of line
        '{': inc(FCurly);
        '}': dec(FCurly);
      end;
      inc(i);
if FCurly<0 then debugln(['ParseStruct curly too low ', FCurly]);
    end;
    Result := FCurly = 0;
  end;
var
  found: TStringArray;
begin
  Result := True;

  if CheckForIgnoredError(AData) then
    exit;

  if FRes <> '' then begin
    FRes := FRes + AData;
    if ParseStruct(AData) then
      SetContentReceieved;
    exit;
  end;

  if StrMatches(AData, ['(', ')', ' = ', ''], found) then begin
    FRes := AData;
    FCurly := 0;
    if ParseStruct(found[2]) then
      SetContentReceieved;
    exit;
  end;
// error: use of undeclared identifier 'i'
// (int) $0 = 133
// (LONGINT) I = 99
// (ANSISTRING) $1 = 0x005aac80
  Result := inherited ProcessInputFromDbg(AData);
end;

constructor TLldbInstructionExpression.Create(AnExpression: String; AThread,
  AFrame: Integer);
begin
//  inherited Create(Format('expression -R -- %s', [UpperCase(AnExpression)]));
  inherited Create(Format('expression -T -- %s', [UpperCase(AnExpression)]), AThread, AFrame);
end;

{ TLldbInstructionStackTrace }

procedure TLldbInstructionStackTrace.SendCommandDataToDbg();
begin
  inherited SendCommandDataToDbg();
  Queue.SendDataToDBG(Self, 'p 112233'); // end marker // do not sent before new prompt
end;

function TLldbInstructionStackTrace.ProcessInputFromDbg(const AData: String
  ): Boolean;
var
  l: Integer;
begin
  Result := False;
  if StrStartsWith(AData, Command) then begin
    FReading := True;
  end;

  if not FReading then
    exit;

  Result := True;
  if CheckForIgnoredError(AData) then
    exit;

  if StrStartsWith(AData, '* thread ') then
    exit;


  if StrStartsWith(AData, '  * frame ') or StrStartsWith(AData, '    frame ') then begin
    l := Length(FRes);
    SetLength(FRes, l+1);
    FRes[l] := AData;
    exit;
  end;

  if StrMatches(AData, ['(', ')', ' = ', '112233', '']) then begin
    MarkAsSuccess;
    Exit;
  end;

  Result := inherited ProcessInputFromDbg(AData);
end;

constructor TLldbInstructionStackTrace.Create(FrameCount: Integer;
  ACallstack: TCallStackBase);
begin
  FCallstack := ACallstack;
  inherited Create(Format('bt %d', [FrameCount]));
end;

end.
