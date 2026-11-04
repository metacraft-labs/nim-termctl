## Actual native OS callbacks/owner teardown. No fake dispatch, clock, wait,
## callback image, or kernel result. Compile only on allocated native Windows.
when not defined(windows):
  {.error: "Real Windows control ownership controls required".}
# Import order is part of the real console/main teardown fixture contract.
import ctrl_owner_lifetime_probe
import nim_termctl/windows_backend
import std/[os, atomics, monotimes, times]

type KernelEvent = object
  handle: pointer
proc createEvent(security: pointer; manual, initial: int32; name: pointer): pointer
  {.importc: "CreateEventW", header: "<windows.h>", stdcall.}
proc setEvent(event: pointer): int32 {.importc: "SetEvent", header: "<windows.h>", stdcall.}
proc closeEvent(event: pointer): int32 {.importc: "CloseHandle", header: "<windows.h>", stdcall.}
proc waitEvent(event: pointer; timeout: uint32): uint32
  {.importc: "WaitForSingleObject", header: "<windows.h>", stdcall.}
proc generate(kind, group: uint32): int32
  {.importc: "GenerateConsoleCtrlEvent", header: "<windows.h>", stdcall.}
proc cFatalMarker(text: cstring): cint {.importc: "puts", header: "<stdio.h>", cdecl, raises: [].}
proc cFlushFatal(stream: pointer): cint {.importc: "fflush", header: "<stdio.h>", cdecl, raises: [].}
proc processHandle(): pointer {.importc: "GetCurrentProcess", header: "<windows.h>", stdcall.}
proc handleCount(process: pointer; count: ptr uint32): int32
  {.importc: "GetProcessHandleCount", header: "<windows.h>", stdcall.}
proc `=copy`(target: var KernelEvent; source: KernelEvent) {.error.}
proc `=destroy`(event: var KernelEvent) =
  if event.handle != nil:
    doAssert closeEvent(event.handle) != 0
    event.handle = nil
proc newEvent(): KernelEvent =
  result.handle = createEvent(nil, 1, 0, nil)
  doAssert result.handle != nil
proc handles(): uint32 = doAssert handleCount(processHandle(), addr result) != 0
proc awaitCount(counter: var Atomic[int]; expected: int) =
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while counter.load() != expected and getMonoTime() < deadline: sleep(1)
  doAssert counter.load() == expected

proc runScenario(scenario: string) =
  case scenario
  of "lexical-captured-identity":
    let baseline = handles()
    ownerStats.expectedThread.store(int(currentThread()))
    block:
      var registration = acquireCtrlCHandler(makeRootedCallback(addr ownerStats))
      doAssert signalEventHandle() != nil
      doAssert generate(1, 0) != 0
      awaitCount(ownerStats.callbacks, 1)
      doAssert waitForCtrlEvent(1000)
    when not defined(gcDestructors): GC_fullCollect()
    doAssert signalEventHandle() == nil
    doAssert ownerStats.destroyed.load() == 1
    doAssert ownerStats.destroyThread.load() == ownerStats.expectedThread.load()
    doAssert handles() == baseline
  of "callback-catchable-exception":
    var callbacks: Atomic[int]
    for dispatch in 1 .. 2:
      # Each exception is allocated by its Nim owner before registration. The
      # real owner drain joins this callback before another dispatch can reuse
      # state or release a captured root. No direct trampoline call qualifies.
      let failure = newException(ValueError, "Actual preallocated callback failure")
      var registration = acquireCtrlCHandler(proc() {.gcsafe.} =
        discard callbacks.fetchAdd(1)
        raise failure)
      doAssert generate(1, 0) != 0
      awaitCount(callbacks, dispatch)
      doAssert waitForCtrlEvent(1000)
      reset(registration)
      doAssert signalEventHandle() == nil
  of "callback-base-exception", "callback-defect":
    let failure: ref Exception =
      if scenario == "callback-defect":
        newException(AssertionDefect, "Actual preallocated callback defect")
      else:
        newException(Exception, "Actual preallocated base callback failure")
    let marker: cstring =
      if scenario == "callback-defect":
        "TERMCTL_FATAL_CALLBACK_RAISE:callback-defect"
      else:
        "TERMCTL_FATAL_CALLBACK_RAISE:callback-base-exception"
    var entered: Atomic[int]
    var registration = acquireCtrlCHandler(proc() {.gcsafe.} =
      # Static C text is flushed before the genuine throw; no Nim echo or
      # exception allocation occurs on the foreign callback thread.
      doAssert cFatalMarker(marker) >= 0
      doAssert cFlushFatal(nil) == 0
      entered.store(1)
      raise failure)
    doAssert generate(1, 0) != 0
    awaitCount(entered, 1)
    reset(registration)
    # If the product silently consumes this fatal class, drain returns and
    # this child deliberately exits ZERO. It cannot satisfy abnormal-exit
    # expectations via a later assertion or deadline failure.
    quit(0)
  of "automatic-main-return", "automatic-main-quit":
    ownerStats.expectedThread.store(int(currentThread()))
    automaticExitExpected = true
    installCtrlCHandler(makeRootedCallback(addr ownerStats))
    doAssert signalEventHandle() != nil
    # No manual uninstall/drain. The probe's real later atexit observer checks
    # the root destructor ran on the main owner and emits the required marker.
    if scenario == "automatic-main-quit":
      echo "TERMCTL_OWNER_CONTROL_PASS:", scenario
      quit(0)
  of "automatic-worker-return":
    proc worker(stats: ptr OwnerProbeStats) {.thread.} =
      stats.expectedThread.store(int(currentThread()))
      installCtrlCHandler(makeRootedCallback(stats))
      doAssert signalEventHandle() != nil
      # No manual uninstall: actual Nim .thread wrapper finally owns teardown.
    var thread: Thread[ptr OwnerProbeStats]
    createThread(thread, worker, addr ownerStats)
    joinThread(thread)
    doAssert signalEventHandle() == nil
    doAssert ownerStats.destroyed.load() == 1
    doAssert ownerStats.destroyThread.load() == ownerStats.expectedThread.load()
  of "overlap-generation-self-uninstall":
    var entered = newEvent()
    var release = newEvent()
    var oldDone = newEvent()
    let enteredHandle = entered.handle
    let releaseHandle = release.handle
    let doneHandle = oldDone.handle
    var newerCallbacks: Atomic[int]
    var older = acquireCtrlCHandler(proc() {.gcsafe.} =
      doAssert setEvent(enteredHandle) != 0
      # Deliberate real kernel hold tests in-flight root lifetime. Parent has
      # an independent actual-process deadline; this is not a production path.
      doAssert waitEvent(releaseHandle, 5000) == 0
      uninstallCtrlCHandler()
      doAssert setEvent(doneHandle) != 0)
    doAssert generate(1, 0) != 0
    doAssert waitEvent(enteredHandle, 5000) == 0
    var newer = acquireCtrlCHandler(proc() {.gcsafe.} = discard newerCallbacks.fetchAdd(1))
    let newEventHandle = signalEventHandle()
    doAssert newEventHandle != nil
    doAssert setEvent(releaseHandle) != 0
    doAssert waitEvent(doneHandle, 5000) == 0
    reset(older) # Real owner-side drain joins the old foreign callback.
    doAssert signalEventHandle() == newEventHandle
    doAssert generate(1, 0) != 0
    awaitCount(newerCallbacks, 1)
    doAssert waitForCtrlEvent(1000)
    reset(newer)
    doAssert signalEventHandle() == nil
  of "foreign-captured-replacement-refusal":
    var rejected: Atomic[int]
    var replacementCalls: Atomic[int]
    let replacement: CtrlCallback = proc() {.gcsafe.} = discard replacementCalls.fetchAdd(1)
    var original = acquireCtrlCHandler(proc() {.gcsafe.} =
      try:
        # This closure was captured on the owner before OS dispatch. The
        # library must reject foreign installation before acquiring its root.
        var forbidden = acquireCtrlCHandler(replacement)
        doAssert false, "Foreign captured replacement unexpectedly accepted"
      except TermctlError:
        rejected.store(1))
    let originalEvent = signalEventHandle()
    doAssert generate(1, 0) != 0
    awaitCount(rejected, 1)
    doAssert replacementCalls.load() == 0
    doAssert signalEventHandle() == originalEvent
    doAssert waitForCtrlEvent(1000)
    reset(original)
  of "bounded-legacy-replacement":
    let baseline = handles()
    for cycle in 0 ..< 1000:
      installCtrlCHandler(nil)
      doAssert signalEventHandle() != nil
      doAssert handles() == baseline + 2
    uninstallCtrlCHandler()
    uninstallCtrlCHandler() # Already-false owner drain remains idempotent.
    doAssert signalEventHandle() == nil
    doAssert handles() == baseline
  of "pending-wait-cancellation":
    var entered = newEvent()
    var finished = newEvent()
    var beginWait = newEvent()
    var result: Atomic[int]
    type WaitState = object
      entered, finished, beginWait: pointer
      result: ptr Atomic[int]
    proc waiter(state: WaitState) {.thread.} =
      doAssert setEvent(state.entered) != 0
      doAssert waitEvent(state.beginWait, 5000) == 0
      let received = waitForCtrlEvent(-1) # Real infinite wait must cancel.
      state.result[].store(if received: 1 else: -1)
      doAssert setEvent(state.finished) != 0
    var registration = acquireCtrlCHandler(nil)
    var thread: Thread[WaitState]
    createThread(thread, waiter, WaitState(entered: entered.handle,
      finished: finished.handle, beginWait: beginWait.handle, result: addr result))
    doAssert waitEvent(entered.handle, 5000) == 0
    # The worker is already initialized and held on beginWait. In this private
    # process its only subsequent handle-producing operation is the actual
    # product DuplicateHandle. Require that real lease to exist before retiring
    # its source event; no fabricated callback or kernel wait result is used.
    let beforeLease = handles()
    doAssert setEvent(beginWait.handle) != 0
    let leaseDeadline = getMonoTime() + initDuration(seconds = 5)
    while handles() != beforeLease + 1 and getMonoTime() < leaseDeadline: sleep(1)
    doAssert handles() == beforeLease + 1
    reset(registration)
    doAssert waitEvent(finished.handle, 5000) == 0
    joinThread(thread)
    doAssert result.load() == -1
  else:
    raise newException(ValueError, "Unknown explicit ownership scenario")
  echo "TERMCTL_OWNER_CONTROL_PASS:", scenario

runScenario(getEnv("TERMCTL_OWNER_SCENARIO"))
