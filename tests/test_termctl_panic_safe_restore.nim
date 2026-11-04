when defined(windows):
  import std/[unittest, os, osproc, streams, strutils, monotimes, times]
  import nim_termctl
  import windows_console_fixture

  const childCompleted = "TERMCTL_PRIVATE_CONSOLE_PANIC_CASE_COMPLETED"

  proc runWindowsCases() =
    let console = openOwnedTestConsole()
    suite "L3: panic-safe restore on real Windows console":
      test "actual assertion unwind restores complete console modes":
        let pre = modes(console)
        var caught = false
        try:
          var raw = enableRawMode()
          check isActive(raw)
          check (modes(console).input and 7'u32) == 0
          doAssert false, "synthetic panic"
        except AssertionDefect:
          caught = true
        check caught
        check modes(console) == pre
    if programResult == 0:
      echo childCompleted

  if paramCount() == 1 and paramStr(1) == rawConsoleChildArgument:
    runWindowsCases()
  else:
    suite "L3: retained private Windows console fixture":
      test "all native cases complete with actual console and child wait":
        let child = startProcess(getAppFilename(), args = @[rawConsoleChildArgument],
          options = {poStdErrToStdOut})
        try:
          let deadline = getMonoTime() + initDuration(seconds = 15)
          while child.running() and getMonoTime() < deadline:
            sleep(10)
          let timedOut = child.running()
          if timedOut:
            child.terminate()
          let exitCode = child.waitForExit()
          let output = child.outputStream.readAll()
          checkpoint output
          check not timedOut
          check exitCode == 0
          check childCompleted in output
        finally:
          if child.running():
            child.terminate()
          discard child.waitForExit()
          child.close()
else:
  ## tests/test_termctl_panic_safe_restore.nim - L3 spec test.
  ##
  ## A `doAssert` panic inside raw-mode scope must still restore termios
  ## via the destructor that runs during unwinding. This verifies that
  ## the L2 `=destroy = discard` foot-gun isn't present here.

  import std/[unittest, posix, termios]
  import nim_termctl
  import test_helpers

  suite "L3: panic-safe restore":

    test "panic via doAssert restores termios via destructor":
      let (master, slave) = openPtyPair()
      defer:
        discard close(master)
        discard close(slave)
      var pre: Termios
      check tcGetAttr(slave, addr pre) == 0

      try:
        var raw = enableRawMode(slave)
        # The discard-of-result trick keeps the compiler from optimising
        # `raw` away under `-d:danger`.
        check isActive(raw)
        doAssert false, "synthetic panic"
      except AssertionDefect:
        discard

      var post: Termios
      check tcGetAttr(slave, addr post) == 0
      check pre.c_lflag == post.c_lflag
      check pre.c_iflag == post.c_iflag
      check pre.c_oflag == post.c_oflag
      check pre.c_cflag == post.c_cflag
