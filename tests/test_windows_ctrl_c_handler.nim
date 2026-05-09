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
  import std/os

  suite "L3: Windows Ctrl-C handler":

    test "SetConsoleCtrlHandler dispatches to user callback":
      var fired = 0
      proc cb() {.gcsafe.} = inc fired
      installCtrlCHandler(cb)
      defer: uninstallCtrlCHandler()

      resetCtrlEventReceived()
      check not ctrlEventReceived()

      # Fire CTRL_BREAK_EVENT at our own process group (pid 0 means
      # "every process attached to the current console"). The handler
      # runs on a Win32-spawned thread; we wait up to 5 s for it.
      let ok = generateConsoleCtrlEvent(CTRL_BREAK_EVENT, 0)
      check ok != 0

      # WaitForSingleObject on the manual-reset event the handler signals.
      check waitForCtrlEvent(5_000)

      # Belt-and-braces: small sleep to let the handler thread finish
      # invoking the Nim callback before we read =fired=. The thread
      # signals BEFORE running the user callback, so without a barrier
      # there's a tiny race window. 50 ms is generous on every CI we
      # ship to.
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
      # After uninstall the callback must not run again. (The default
      # CTRL_BREAK_EVENT action would normally terminate the process,
      # but the test runner has its own handler installed, so we simply
      # observe the flag stayed 0.)
      check fired == 0
