## Source-only actual OS control-event oracle, compiled/run only on an
## allocated native Windows host under each original supported memory mode.
when not defined(windows):
  {.error: "Actual Windows control event required".}
import std/[os, atomics, monotimes, times]
import nim_termctl/windows_backend
import windows_console_fixture

proc generateConsoleCtrlEvent(kind, group: uint32): int32
  {.importc: "GenerateConsoleCtrlEvent", header: "<windows.h>", stdcall.}
var callbacks: Atomic[int]
proc waitCallback() =
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while callbacks.load() == 0 and getMonoTime() < deadline:
    sleep(1)
  doAssert callbacks.load() == 1, "actual OS callback was not delivered once"

let ownedConsole = openOwnedTestConsole()
let scenario = getEnv("TERMCTL_CONTROL_SCENARIO")
case scenario
of "event":
  installCtrlCHandler(proc() {.gcsafe.} = discard callbacks.fetchAdd(1))
  doAssert signalEventHandle() != nil
  doAssert generateConsoleCtrlEvent(1, 0) != 0
  waitCallback()
  doAssert ctrlEventReceived()
  doAssert waitForCtrlEvent(1000), "handler must signal the process event across OS threads"
  resetCtrlEventReceived()
  doAssert not ctrlEventReceived()
  doAssert not waitForCtrlEvent(0)
  uninstallCtrlCHandler()
  doAssert signalEventHandle() == nil
of "reentrant-uninstall":
  installCtrlCHandler(proc() {.gcsafe.} =
    uninstallCtrlCHandler()
    discard callbacks.fetchAdd(1))
  doAssert generateConsoleCtrlEvent(1, 0) != 0
  waitCallback()
  doAssert signalEventHandle() == nil
  uninstallCtrlCHandler()
of "default-termination":
  installCtrlCHandler(proc() {.gcsafe.} = discard callbacks.fetchAdd(1))
  uninstallCtrlCHandler()
  # AllocConsole restored default control handling in this isolated child.
  # Group zero refers only to its private console, never the runner console.
  doAssert generateConsoleCtrlEvent(1, 0) != 0
  sleep(5000)
  doAssert false, "default CTRL_BREAK termination did not happen"
else:
  raise newException(ValueError, "Unknown explicit control scenario")
echo "TERMCTL_REAL_CONTROL_PASS:", scenario
