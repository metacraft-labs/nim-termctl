## tests/test_windows_ctrl_c_handler.nim - L3 Windows-only test.
##
## Exercises the real =SetConsoleCtrlHandler= path: install a handler,
## raise a CTRL_BREAK_EVENT at our own process group via
## =GenerateConsoleCtrlEvent=, then wait on the manual-reset event the
## handler signals. The test asserts:
##
##   1. =waitForCtrlEvent= returns true within the timeout (event fired).
##   2. The user callback we registered ran (=fired= flag flipped).
##   3. =ctrlEventReceived()= returns true.
##   4. =resetCtrlEventReceived= clears the flag.
##
## We use CTRL_BREAK_EVENT, not CTRL_C_EVENT: per MSDN,
## GenerateConsoleCtrlEvent only delivers CTRL_C_EVENT to processes that
## share a console *and* haven't disabled it. CTRL_BREAK_EVENT is the
## reliable choice for a programmatic test - it goes through the same
## SetConsoleCtrlHandler path and is what production code that wants to
## signal a sibling process uses.
##
## Gated with =when defined(windows)=. CI runs this on the Windows lane.
##
## The cases run in an isolated child that owns a PRIVATE console
## (=windows_console_fixture=). Process group 0 means every process attached
## to the caller's console, so raising CTRL_BREAK_EVENT from the runner's
## own console also reached the build tool and the shell that started the
## test: under =repro test= PowerShell answered it by entering its debugger
## and the job failed. In the private console the child is the only
## process the event reaches. The child also keeps a test-owned guard
## handler registered beneath the product's, so the break raised after
## =uninstallCtrlCHandler= is absorbed instead of terminating the child --
## the old comment assumed "the test runner has its own handler installed",
## which nothing guarantees.

import std/unittest

when not defined(windows):
  # On non-Windows the test compiles to a no-op suite that immediately
  # passes. The compile-only check (=tests/test_windows_signals_compile=)
  # is the cross-platform gate; this file's job is the runtime
  # behaviour, and that only makes sense on Windows.
  suite "L3: Windows Ctrl-C handler (skipped on non-Windows)":
    test "skipped":
      skip()
else:
  import nim_termctl
  import std/[os, strutils]
  import windows_console_fixture

  const childCompleted = "TERMCTL_PRIVATE_CONSOLE_CTRL_HANDLER_CASES_COMPLETED"

  proc setGuardHandler(handler: proc (ctrlType: culong): int32 {.stdcall.};
                       add: int32): int32
    {.importc: "SetConsoleCtrlHandler", header: "<windows.h>", stdcall.}

  proc absorbCtrlEvent(ctrlType: culong): int32 {.stdcall.} =
    ## Test-owned guard: claims every event that reaches it, so an event
    ## raised while no product handler is installed cannot end the child.
    1

  proc runCtrlHandlerCases() =
    let console = openOwnedTestConsole()
    discard modes(console)
    countPrivateConsoleCases()
    if setGuardHandler(absorbCtrlEvent, 1) == 0:
      raise newException(OSError, "SetConsoleCtrlHandler(guard) failed")
    defer: discard setGuardHandler(absorbCtrlEvent, 0)

    suite "L3: Windows Ctrl-C handler":

      test "SetConsoleCtrlHandler dispatches to user callback":
        var fired = 0
        proc cb() {.gcsafe.} = inc fired
        installCtrlCHandler(cb)
        defer: uninstallCtrlCHandler()

        resetCtrlEventReceived()
        check not ctrlEventReceived()

        # Fire CTRL_BREAK_EVENT at process group 0: every process attached
        # to this child's private console, i.e. only the child. The handler
        # runs on a Win32-spawned thread; we wait up to 5 s for it.
        let ok = generateConsoleCtrlEvent(CTRL_BREAK_EVENT, 0)
        check ok != 0

        # WaitForSingleObject on the manual-reset event the handler signals.
        check waitForCtrlEvent(5_000)

        # The handler thread signals BEFORE running the user callback, so
        # give it a moment before reading =fired=.
        sleep(50)
        check fired >= 1
        check ctrlEventReceived()

      test "uninstallCtrlCHandler stops further dispatch":
        var fired = 0
        proc cb() {.gcsafe.} = inc fired
        installCtrlCHandler(cb)
        uninstallCtrlCHandler()

        let ok = generateConsoleCtrlEvent(CTRL_BREAK_EVENT, 0)
        check ok != 0
        sleep(50)
        # After uninstall the callback must not run again; the guard
        # handler absorbs the event.
        check fired == 0

    reportPrivateConsoleCompletion(childCompleted, 2)

  if isPrivateConsoleChild():
    runCtrlHandlerCases()
  else:
    suite "L3: isolated Windows Ctrl-C handler fixture":
      test "both control-handler cases pass in a private console":
        let run = runPrivateConsoleChild()
        checkpoint run.output
        check not run.timedOut
        check run.exitCode == 0
        check childCompleted in run.output
