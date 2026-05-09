## tests/test_windows_window_resize.nim - L3 Windows-only test.
##
## Programmatic resize-event delivery: install the winch handler, write
## a synthetic =WINDOW_BUFFER_SIZE_EVENT= record into the console input
## buffer via =WriteConsoleInputW=, then drain via =pollWindowBufferSize=
## and assert the dimensions surface.
##
## We don't call =SetConsoleScreenBufferSize= directly because under a
## CI runner the parent console may refuse to shrink below a minimum -
## =WriteConsoleInputW= produces a deterministic record either way and
## exercises the same drain path =pollEvent= will use in production.
##
## Gated with =when defined(windows)=. CI runs this on the Windows lane.

import std/unittest

when not defined(windows):
  suite "L3: Windows window-resize (skipped on non-Windows)":
    test "skipped":
      skip()
else:
  import nim_termctl

  suite "L3: Windows window-resize":

    test "WINDOW_BUFFER_SIZE_EVENT round-trip via WriteConsoleInputW":
      installWinchHandler()
      defer: uninstallWinchHandler()

      # Drain anything that may already be queued (the runner may have
      # produced a stray event during startup).
      discard pollWindowBufferSize()

      # Inject a known size into the input buffer.
      check injectWindowBufferSizeEvent(120, 40)

      let r = pollWindowBufferSize()
      check r.hadResize
      check r.cols == 120
      check r.rows == 40

    test "drain coalesces multiple resize records into the latest size":
      installWinchHandler()
      defer: uninstallWinchHandler()

      discard pollWindowBufferSize()

      check injectWindowBufferSizeEvent(80, 24)
      check injectWindowBufferSizeEvent(132, 50)
      check injectWindowBufferSizeEvent(200, 60)

      let r = pollWindowBufferSize()
      check r.hadResize
      # We accept the *latest* of the injected sizes - that's the
      # documented coalescing behaviour. Production code that wants to
      # see every record should drain more often.
      check r.cols == 200
      check r.rows == 60

    test "no-op poll returns hadResize=false":
      installWinchHandler()
      defer: uninstallWinchHandler()
      # Drain anything pending first.
      discard pollWindowBufferSize()
      let r = pollWindowBufferSize()
      check not r.hadResize
