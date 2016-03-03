(*
 * 内存池单元
 *   内存块通过引用计数，归还到池
 *
*)

unit utils_BufferPool;

interface

{$DEFINE USE_SPINLOCK}

uses
  SyncObjs, SysUtils
  {$IFDEF MSWINDOWS}
  , Windows
  {$ELSE}

  {$ENDIF};

{$IF defined(FPC) or (RTLVersion>=18))}
  {$DEFINE HAVE_INLINE}
{$IFEND HAVE_INLINE}

const
  block_flag :Word = $1DFB;

{$IFDEF DEBUG}
  protect_size = 8;
{$ELSE}
  protect_size = 0;
{$ENDIF}

type
 
  PBufferPool = ^ TBufferPool;
  PBufferBlock = ^TBufferBlock;
  
  TBufferPool = record
    FBlockSize: Integer;
    FHead:PBufferBlock;
    FGet:Integer;
    FPut:Integer;
    FSize:Integer;
    FAddRef:Integer;
    FReleaseRef:Integer;

    {$IFDEF USE_SPINLOCK}
    FSpinLock:Integer;
    FLockWaitCounter: Integer;
    {$ELSE}
    FLocker:TCriticalSection;
    {$ENDIF}

  end;



  TBufferBlock = record
    flag: Word;
    refcounter :Integer;
    next: PBufferBlock;
    owner: PBufferPool;
  end;

const
  BLOCK_SIZE = SizeOf(TBufferBlock);

function NewBufferPool(pvBlockSize: Integer = 1024): PBufferPool;
procedure FreeBufferPool(buffPool:PBufferPool);

function GetBuffer(ABuffPool:PBufferPool): PByte;

function AddRef(pvBuffer:PByte): Integer;
function ReleaseRef(pvBuffer:PByte): Integer;

/// <summary>
///  检测池中内存块越界情况
/// </summary>
function CheckBufferBounds(ABuffPool:PBufferPool): Integer;

{$IF RTLVersion<24}
function AtomicCmpExchange(var Target: Integer; Value: Integer;
  Comparand: Integer): Integer; {$IFDEF HAVE_INLINE} inline;{$ENDIF}
function AtomicIncrement(var Target: Integer): Integer;{$IFDEF HAVE_INLINE} inline;{$ENDIF}
function AtomicDecrement(var Target: Integer): Integer;{$IFDEF HAVE_INLINE} inline;{$ENDIF}
{$IFEND <XE5}

procedure SpinLock(var Target:Integer; var WaitCounter:Integer); {$IFDEF HAVE_INLINE} inline;{$ENDIF} overload;
procedure SpinLock(var Target:Integer); {$IFDEF HAVE_INLINE} inline;{$ENDIF} overload;
procedure SpinUnLock(var Target:Integer; var WaitCounter:Integer); {$IFDEF HAVE_INLINE} inline;{$ENDIF}overload;
procedure SpinUnLock(var Target:Integer); {$IFDEF HAVE_INLINE} inline;{$ENDIF}overload;

implementation

procedure SpinLock(var Target:Integer; var WaitCounter:Integer);
begin
  while AtomicCmpExchange(Target, 1, 0) <> 0 do
  begin
    AtomicIncrement(WaitCounter);
//    {$IFDEF MSWINDOWS}
//      SwitchToThread;
//    {$ELSE}
//      TThread.Yield;
//    {$ENDIF}
    Sleep(1);    // 1 对比0 (线程越多，速度越平均)
  end;
end;

procedure SpinLock(var Target:Integer);
begin
  while AtomicCmpExchange(Target, 1, 0) <> 0 do
  begin
    Sleep(1);    // 1 对比0 (线程越多，速度越平均)
  end;
end;

procedure SpinUnLock(var Target:Integer; var WaitCounter:Integer);
begin
  while AtomicCmpExchange(Target, 0, 1) <> 1 do
  begin
    AtomicIncrement(WaitCounter);
    Sleep(1);    // 1 对比0 (线程越多，速度越平均)
  end;
end;

procedure SpinUnLock(var Target:Integer); 
begin
  while AtomicCmpExchange(Target, 0, 1) <> 1 do
  begin
    Sleep(1);
  end;
end;



{$IF RTLVersion<24}
function AtomicCmpExchange(var Target: Integer; Value: Integer;
  Comparand: Integer): Integer; {$IFDEF HAVE_INLINE} inline;{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Result := InterlockedCompareExchange(Target, Value, Comparand);
{$ELSE}
  Result := TInterlocked.CompareExchange(Target, Value, Comparand);
{$ENDIF}
end;

function AtomicIncrement(var Target: Integer): Integer;{$IFDEF HAVE_INLINE} inline;{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Result := InterlockedIncrement(Target);
{$ELSE}
  Result := TInterlocked.Increment(Target);
{$ENDIF}
end;

function AtomicDecrement(var Target: Integer): Integer; {$IFDEF HAVE_INLINE} inline;{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Result := InterlockedDecrement(Target);
{$ELSE}
  Result := TInterlocked.Decrement(Target);
{$ENDIF}
end;

{$IFEND <XE5}

/// <summary>
///   检测一块内存是否有越界情况
/// </summary>
function CheckBufferBlockBounds(ABlock: PBufferBlock): Boolean;
var
  lvBuffer:PByte;
  i:Integer;
begin
  Result := True;
  lvBuffer:= PByte(ABlock);
  Inc(lvBuffer, BLOCK_SIZE + ABlock.owner.FBlockSize);
  for I := 0 to protect_size - 1 do
  begin
    if lvBuffer^ <> 0 then
    begin
      Result := False;
      Break;
    end;
    Inc(lvBuffer);
  end;      
end;

function GetBuffer(ABuffPool:PBufferPool): PByte;
var
  lvBuffer:PBufferBlock;
begin
  {$IFDEF USE_SPINLOCK}
  SpinLock(ABuffPool.FSpinLock, ABuffPool.FLockWaitCounter);
  {$ELSE}
  ABuffPool.FLocker.Enter;
  {$ENDIF}
  lvBuffer := PBufferBlock(ABuffPool.FHead);
  if lvBuffer <> nil then ABuffPool.FHead := lvBuffer.next;
  {$IFDEF USE_SPINLOCK}
  SpinUnLock(ABuffPool.FSpinLock);
  {$ELSE}
  ABuffPool.FLocker.Leave;
  {$ENDIF}


  if lvBuffer = nil then
  begin
    // + 2保护边界(可以检测内存越界写入)
    GetMem(Result, BLOCK_SIZE + ABuffPool.FBlockSize + protect_size);
    {$IFDEF DEBUG}
    FillChar(Result^, BLOCK_SIZE + ABuffPool.FBlockSize + protect_size, 0);
    {$ELSE}
    FillChar(Result^, BLOCK_SIZE, 0);
    {$ENDIF}
    lvBuffer := PBufferBlock(Result);
    lvBuffer.owner := ABuffPool;
    lvBuffer.flag := block_flag;


    AtomicIncrement(ABuffPool.FSize);
  end else
  begin
    Result := PByte(lvBuffer);
  end;     

  Inc(Result, BLOCK_SIZE);
  AtomicIncrement(ABuffPool.FGet);
end;

procedure FreeBuffer(pvBufBlock:PBufferBlock);
var
  lvBuffer:PBufferBlock;
  lvOwner:PBufferPool;
begin
  lvOwner := pvBufBlock.owner;
  {$IFDEF USE_SPINLOCK}
  SpinLock(lvOwner.FSpinLock, lvOwner.FLockWaitCounter);
  {$ELSE}
  lvOwner.FLocker.Enter;
  {$ENDIF}
  lvBuffer := lvOwner.FHead;
  pvBufBlock.next := lvBuffer;
  lvOwner.FHead := pvBufBlock;
  {$IFDEF USE_SPINLOCK}
  SpinUnLock(lvOwner.FSpinLock);
  {$ELSE}
  lvOwner.FLocker.Leave;
  {$ENDIF}
  AtomicIncrement(lvOwner.FPut);
end;



function AddRef(pvBuffer:PByte): Integer;
var
  lvBuffer:PByte;
  lvBlock:PBufferBlock; 
begin
  lvBuffer := pvBuffer;
  Dec(lvBuffer, BLOCK_SIZE);
  lvBlock := PBufferBlock(lvBuffer);
  Assert(lvBlock.flag = block_flag, 'invalid DBufferBlock');
  Result := AtomicIncrement(lvBlock.refcounter);
  AtomicIncrement(lvBlock.owner.FAddRef);
end;

function ReleaseRef(pvBuffer:PByte): Integer;
var
  lvBuffer:PByte;
  lvBlock:PBufferBlock; 
begin
  lvBuffer := pvBuffer;
  Dec(lvBuffer, BLOCK_SIZE);
  lvBlock := PBufferBlock(lvBuffer);
  Assert(lvBlock.flag = block_flag, 'invalid DBufferBlock');
  Result := AtomicDecrement(lvBlock.refcounter);
  AtomicIncrement(lvBlock.owner.FReleaseRef);
  if Result = 0 then
  begin
    FreeBuffer(lvBlock);
  end else
  begin
    Assert(Result > 0, 'DBuffer error release');
  end;

end;

function NewBufferPool(pvBlockSize: Integer = 1024): PBufferPool;
begin
  New(Result);
  Result.FBlockSize := pvBlockSize;
  Result.FHead := nil;
  {$IFDEF USE_SPINLOCK}
  Result.FSpinLock := 0;
  Result.FLockWaitCounter := 0;
  {$ELSE}
  Result.FLocker := TCriticalSection.Create;
  {$ENDIF}

  Result.FGet := 0;
  Result.FSize := 0;
  Result.FPut := 0;
  Result.FAddRef := 0;
  Result.FReleaseRef :=0;
  
end;

procedure FreeBufferPool(buffPool:PBufferPool);
var
  lvBlock, lvNext:PBufferBlock;
begin
  Assert(buffPool.FGet = buffPool.FPut,
    Format('DBuffer Leak, get:%d, put:%d', [buffPool.FGet, buffPool.FPut]));

  lvBlock := buffPool.FHead;
  while lvBlock <> nil do
  begin
    lvNext := lvBlock.next;
    FreeMem(lvBlock);
    lvBlock := lvNext;
  end;
  {$IFDEF USE_SPINLOCK}
  ;
  {$ELSE}
  buffPool.FLocker.Free;
  {$ENDIF}

  Dispose(buffPool);
end;

function CheckBufferBounds(ABuffPool:PBufferPool): Integer;
var
  lvBlock, lvNext:PBufferBlock;  
begin
  Result := 0;
  if protect_size = 0 then
  begin   // 没有保护边界的大小
    Result := -1;
    Exit;
  end;
  {$IFDEF USE_SPINLOCK}
  SpinLock(ABuffPool.FSpinLock, ABuffPool.FLockWaitCounter);
  {$ELSE}
  ABuffPool.FLocker.Enter;
  {$ENDIF}
  lvBlock := ABuffPool.FHead;
  while lvBlock <> nil do
  begin
    if not CheckBufferBlockBounds(lvBlock) then Inc(Result);

    lvBlock := lvBlock.next;
  end;
  {$IFDEF USE_SPINLOCK}
  SpinUnLock(ABuffPool.FSpinLock);
  {$ELSE}
  ABuffPool.FLocker.Leave;
  {$ENDIF}
end;


end.
