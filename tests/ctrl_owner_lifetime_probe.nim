## Imported BEFORE windows_backend: its private console outlives the backend's
## main registry; its earlier atexit observer runs after backend cleanup.
when not defined(windows):
  {.error: "Real Windows control ownership probe required".}
import std/[atomics, exitprocs]
import windows_console_fixture

type
  OwnerProbeStats* = object
    destroyed*, destroyThread*, expectedThread*, callbacks*: Atomic[int]
  LifetimeProbe = object
    stats: ptr OwnerProbeStats

proc currentThread*(): uint32 {.importc: "GetCurrentThreadId", header: "<windows.h>", stdcall.}
proc cPuts(text: cstring): cint {.importc: "puts", header: "<stdio.h>".}
proc cFlush(stream: pointer): cint {.importc: "fflush", header: "<stdio.h>".}
proc cImmediateExit(code: cint) {.importc: "_Exit", header: "<stdlib.h>", noreturn.}
var
  ownerStats*: OwnerProbeStats
  automaticExitExpected*: bool
let probeConsole = openOwnedTestConsole()

proc `=copy`(target: var LifetimeProbe; source: LifetimeProbe) {.error.}
proc `=destroy`(probe: var LifetimeProbe) {.gcsafe, raises: [].} =
  if probe.stats != nil:
    probe.stats.destroyThread.store(int(currentThread()))
    discard probe.stats.destroyed.fetchAdd(1)
    probe.stats = nil

proc makeRootedCallback*(stats: ptr OwnerProbeStats): proc() {.closure, gcsafe.} =
  ## No callback allocation/RC copy: the actual dispatched closure directly
  ## touches its captured noncopyable owner probe and the shared atomic leaf.
  var probe = LifetimeProbe(stats: stats)
  result = proc() {.gcsafe.} =
    doAssert probe.stats == stats
    discard probe.stats.callbacks.fetchAdd(1)

proc reportAutomaticExit() {.noconv.} =
  if automaticExitExpected:
    if ownerStats.destroyed.load() != 1 or
        ownerStats.destroyThread.load() != ownerStats.expectedThread.load():
      cImmediateExit(91)
    discard cPuts("TERMCTL_AUTOMATIC_OWNER_EXIT_PASS")
    discard cFlush(nil)
addExitProc(reportAutomaticExit)
