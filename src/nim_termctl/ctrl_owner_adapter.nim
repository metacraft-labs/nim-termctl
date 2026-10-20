## Included after CtrlCallback in windows_backend.nim. Internal native state
## never owns a Nim closure; only installer-thread value owners do.
import std/[os, exitprocs]
const ctrlOwnerHeader = currentSourcePath().parentDir / "ctrl_owner.h"
{.compile: "ctrl_owner.c".}
type
  NativeCtrlOwner {.importc: "TcCtrlOwner", header: ctrlOwnerHeader, incompleteStruct.} = object
  NativeCtrlInvoke = proc(owner: ptr NativeCtrlOwner; code, environment: pointer) {.cdecl, gcsafe, raises: [].}
  CtrlRegistration* = object
    ## Noncopyable, installer-thread-owned synchronous control registration.
    ## Keep this value alive for the desired registration lifetime. Moving
    ## it to a different thread is unsupported, as with its captured heap.
    native: ptr NativeCtrlOwner
    callback: CtrlCallback

proc prepareCtrl(code, environment: pointer; invoke: NativeCtrlInvoke): ptr NativeCtrlOwner {.importc: "tc_ctrl_prepare", header: ctrlOwnerHeader.}
proc publishCtrl(owner: ptr NativeCtrlOwner): cint {.importc: "tc_ctrl_publish", header: ctrlOwnerHeader.}
proc retireBorrowedCtrl(owner: ptr NativeCtrlOwner): cint {.importc: "tc_ctrl_retire", header: ctrlOwnerHeader.}
proc retireCurrentCtrl(): cint {.importc: "tc_ctrl_retire_current", header: ctrlOwnerHeader.}
proc destroyCtrl(owner: ptr ptr NativeCtrlOwner): cint {.importc: "tc_ctrl_destroy", header: ctrlOwnerHeader.}
proc ctrlOwnerThread(owner: ptr NativeCtrlOwner): DWORD {.importc: "tc_ctrl_owner_thread", header: ctrlOwnerHeader.}
proc ctrlIsRetired(owner: ptr NativeCtrlOwner): cint {.importc: "tc_ctrl_is_retired", header: ctrlOwnerHeader.}
proc borrowCtrlEvent(): HANDLE {.importc: "tc_ctrl_borrow_event", header: ctrlOwnerHeader.}
proc waitCtrl(timeout: DWORD): cint {.importc: "tc_ctrl_wait", header: ctrlOwnerHeader.}
proc receivedCtrl(): cint {.importc: "tc_ctrl_received", header: ctrlOwnerHeader.}
proc resetCtrl(): cint {.importc: "tc_ctrl_reset", header: ctrlOwnerHeader.}
proc ctrlCurrentThreadId(): DWORD {.importc: "GetCurrentThreadId", header: "<windows.h>", stdcall.}

const ctrlForeignRuntime = compileOption("threads") and not compileOption("tlsEmulation")
var
  inCtrlCallback {.threadvar.}: bool
  callbackBorrow {.threadvar.}: ptr NativeCtrlOwner
proc abortCtrlCallback() {.importc: "abort", header: "<stdlib.h>", cdecl, noreturn, raises: [].}

proc invokeCtrl(owner: ptr NativeCtrlOwner; code, environment: pointer) {.cdecl, gcsafe, raises: [].} =
  # The exact selected Nim runtime initializes a FOREIGN thread's GC here;
  # ARC/ORC implementations are no-ops. No owning closure copy is made.
  when ctrlForeignRuntime:
    setupForeignThreadGc()
    let previousBorrow = callbackBorrow
    let previousCallback = inCtrlCallback
    callbackBorrow = owner
    inCtrlCallback = true
    try:
      try:
        # Documented rawProc/rawEnv ABI: a nonnil environment is the final
        # pointer argument. These are plain nimcall function pointers, not
        # managed proc-closure temporaries.
        if environment == nil:
          cast[proc() {.nimcall, gcsafe.}](code)()
        else:
          cast[proc(environment: pointer) {.nimcall, gcsafe.}](code)(environment)
      except CatchableError:
        discard
      except Exception:
        # Preserve the public callback's broad effect without allowing Nim
        # unwinding through Win32. Noncatchable faults remain fatal; only
        # the original CatchableError class is silently consumed.
        abortCtrlCallback()
    finally:
      callbackBorrow = previousBorrow
      inCtrlCallback = previousCallback
      tearDownForeignThreadGc()
  else:
    # A nil callback never reaches this trampoline. Selected Nim explicitly
    # lacks the required foreign GC/TLS contract in this configuration.
    doAssert false, "Unsupported foreign Nim runtime reached control callback"

proc `=copy`*(dest: var CtrlRegistration; src: CtrlRegistration) {.error.}
proc `=destroy`*(value: var CtrlRegistration) {.gcsafe, raises: [].} =
  if value.native != nil:
    doAssert ctrlOwnerThread(value.native) == ctrlCurrentThreadId(),
      "CtrlRegistration must be destroyed by its installing thread"
    # Synchronous FFI pointer-to-slot; it never escapes this call. A
    # successful native drain zeros the slot before the typed root releases.
    let status = destroyCtrl(addr value.native)
    doAssert value.native == nil and status != 0, "Win32 control-owner cleanup failed"
  value.callback = nil

proc acquireCtrlCHandler*(callback: CtrlCallback): CtrlRegistration {.gcsafe.} =
  ## Captured callback identity is retained, not deep-copied. Capturing
  ## registration/replacement from the foreign handler cannot acquire a new
  ## owner heap: reject BEFORE changing the existing registration.
  when not ctrlForeignRuntime:
    if callback != nil:
      raise newException(TermctlError, "Nim foreign callbacks require supported native thread/TLS runtime")
  if inCtrlCallback:
    raise newException(TermctlError, "Acquire a lexical CtrlRegistration on its Nim owner thread")
  result.callback = callback
  result.native = prepareCtrl(rawProc(callback), rawEnv(callback), invokeCtrl)
  if result.native == nil:
    raise newException(TermctlError, "Preparing native control registration failed")
  if publishCtrl(result.native) == 0:
    raise newException(TermctlError, "Installing native control registration failed")

# Compatibility roots: main is a NON-TLS global value, so normal main-return
# global destruction runs on its owner. Worker TLS is explicitly drained by
# the Nim worker wrapper's onThreadDestruction BEFORE its heap is destroyed.
# Ordinary threadvar destruction is NOT assumed (Nim2.2.4 skips it).
type
  CtrlRegistry = object
    roots: seq[CtrlRegistration]
    main: bool
var
  moduleOwnerThread = ctrlCurrentThreadId()
  mainRegistryClosed: bool

proc releaseRegistry(registry: var CtrlRegistry) {.gcsafe, raises: [].} =
  if registry.main: mainRegistryClosed = true
  # Explicitly reset each value owner on this thread in EVERY memory mode;
  # a refc heap finalizer/seq collection is not used as handle ownership.
  for index in 0 ..< registry.roots.len:
    reset(registry.roots[index])
  reset(registry.roots)
proc `=destroy`(registry: var CtrlRegistry) {.gcsafe, raises: [].} = releaseRegistry(registry)

var
  mainRegistry = CtrlRegistry(main: true)
  workerRegistry {.threadvar.}: CtrlRegistry
  workerCleanupRegistered {.threadvar.}: bool
  workerRegistryClosing {.threadvar.}: bool
proc cleanupWorkerRegistry() {.gcsafe, raises: [].} =
  workerRegistryClosing = true
  releaseRegistry(workerRegistry)
proc cleanupMainRegistry() {.noconv.} =
  # On normal return the global owner already ran: never inspect its dead
  # managed fields then. Early C exit on the main owner still drains it.
  if not mainRegistryClosed and ctrlCurrentThreadId() == moduleOwnerThread:
    releaseRegistry(mainRegistry)
addExitProc(cleanupMainRegistry)

proc collectRetired(registry: var CtrlRegistry) =
  var index = registry.roots.len
  while index > 0:
    dec index
    if ctrlIsRetired(registry.roots[index].native) != 0:
      # Explicit destruction precedes removal in every memory manager. The
      # selected refc seq.delete implementation uses shallowCopy, so it must
      # not relocate live noncopyable owners and truncate an aliased handle.
      reset(registry.roots[index])
      let last = registry.roots.high
      if index != last:
        swap(registry.roots[index], registry.roots[last])
      registry.roots.setLen(last)
proc ownerRegistry(): ptr CtrlRegistry {.gcsafe.} =
  # The legacy non-main-thread contract is a Nim-created worker: the selected
  # onThreadDestruction API runs when that .thread procedure returns. Its
  # presence is not a dynamic certificate for arbitrary external C threads.
  # Each managed registry is touched only by its native owner identity.
  # This cast does not authorize a managed copy in a foreign callback.
  {.cast(gcsafe).}:
    if ctrlCurrentThreadId() == moduleOwnerThread:
      if mainRegistryClosed: raise newException(TermctlError, "Main owner is already shutting down")
      return addr mainRegistry
    if workerRegistryClosing: raise newException(TermctlError, "Worker owner is already shutting down")
    when declared(onThreadDestruction):
      if not workerCleanupRegistered:
        onThreadDestruction(cleanupWorkerRegistry)
        workerCleanupRegistered = true
      result = addr workerRegistry
    else:
      raise newException(TermctlError, "Legacy captured registration requires a Nim-managed owner thread")

proc installCtrlCHandler*(callback: CtrlCallback) {.gcsafe.} =
  ## Existing compatibility API. Automatic roots are owned by the main
  ## value registry or an explicitly registered Nim worker-exit hook.
  ## Foreign handler replacement never writes a managed owner registry.
  when not ctrlForeignRuntime:
    if callback != nil:
      raise newException(TermctlError, "Nim foreign callbacks require supported native thread/TLS runtime")
  if inCtrlCallback:
    raise newException(TermctlError, "Install control callbacks on their Nim owner thread")
  {.cast(gcsafe).}:
    let registry = ownerRegistry()
    collectRetired(registry[])
    # Preparation/OS registration failure preserves the existing registration.
    # Successful publish atomically retires the prior generation. The new
    # typed stack value roots its captured environment while old borrows drain;
    # no foreign callback ever copies or retires another generation's root.
    var registration = acquireCtrlCHandler(callback)
    collectRetired(registry[])
    registry.roots.add(move(registration))

proc drainCurrentOwner() {.gcsafe.} =
  if inCtrlCallback: return
  # Authoritative native thread comparison precedes every main-root access;
  # worker state is owner-local TLS with a registered BEFORE-heap-exit hook.
  {.cast(gcsafe).}:
    if ctrlCurrentThreadId() == moduleOwnerThread:
      if not mainRegistryClosed: collectRetired(mainRegistry)
    elif workerCleanupRegistered and not workerRegistryClosing:
      collectRetired(workerRegistry)
proc uninstallCtrlCHandler*() {.gcsafe.} =
  # A delayed old-generation handler must not uninstall a newly published
  # registration. Its borrowed descriptor remains alive until this callback
  # returns; the native owner drain is what grants that pointer lifetime.
  let status = if inCtrlCallback: retireBorrowedCtrl(callbackBorrow)
               else: retireCurrentCtrl()
  # Do NOT return merely because already uninstalled: self-uninstall can
  # leave the final typed root awaiting its actual owner-side drain.
  drainCurrentOwner()
  if status == 0:
    raise newException(TermctlError, "Unregistering native control handler failed")
proc signalEventHandle*(): HANDLE = borrowCtrlEvent()
proc ctrlEventReceived*(): bool = receivedCtrl() != 0
proc resetCtrlEventReceived*() =
  if resetCtrl() == 0: raise newException(TermctlError, "Resetting native control event failed")
proc waitForCtrlEvent*(timeoutMs: int): bool =
  # -1 is Win32 INFINITE. Convert it explicitly: checked int-to-DWORD
  # conversion must not reject the documented infinite-wait sentinel.
  if timeoutMs < -1 or (timeoutMs >= 0 and uint64(timeoutMs) > uint64(high(DWORD))):
    raise newException(TermctlError, "Control wait timeout is outside Win32 range")
  let timeout = if timeoutMs == -1: high(DWORD) else: DWORD(timeoutMs)
  result = waitCtrl(timeout) != 0
  drainCurrentOwner()
