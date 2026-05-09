## tests/test_windows_signals_compile.nim - L3 Windows signal-handling
## compile-only check.
##
## This test imports the public surface and references every Windows
## signal-handling symbol so the cross-compile gate
## (=nim c --os:windows ...=) verifies the Windows code path actually
## type-checks. On Linux it runs as a no-op smoke test that asserts the
## cross-platform =installCtrlCHandler= surface is present.
##
## Charter rule: real APIs only. The Windows symbols below are imported
## from =nim_termctl.windows_backend= which calls =SetConsoleCtrlHandler=
## / =CreateEventW= / =ReadConsoleInputW= via direct =importc=. There is
## no stub or shim; if Windows ever drops one of these symbols, the
## cross-compile will fail and the test fails with it.

import std/unittest
import nim_termctl

suite "L3: Windows signal-handling compile gate":

  test "installCtrlCHandler is exposed cross-platform":
    var fired = false
    proc cb() {.gcsafe.} = fired = true
    # Just take its address - we don't actually call it on Linux because
    # that would install a real SIGINT handler in the test runner.
    let p = installCtrlCHandler
    check p != nil
    when defined(windows):
      # On Windows the symbols below all link against kernel32. The
      # compile-only gate is enough; the runtime checks live in
      # test_windows_ctrl_c_handler.nim and test_windows_window_resize.nim.
      let h = signalEventHandle
      let r = ctrlEventReceived
      let w = waitForCtrlEvent
      let pw = pollWindowBufferSize
      let ij = injectWindowBufferSizeEvent
      check h != nil
      check r != nil
      check w != nil
      check pw != nil
      check ij != nil
    discard fired
