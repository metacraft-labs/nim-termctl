when defined(windows):
  import std/[unittest, os, osproc, streams, strutils, monotimes, times]
  import nim_termctl
  import windows_console_fixture

  const childCompleted = "TERMCTL_PRIVATE_CONSOLE_THREE_RAW_CASES_COMPLETED"

  proc runWindowsRawModeCases() =
    let console = openOwnedTestConsole()
    suite "L3: raw-mode round-trip on a real private Win32 console":
      test "enableRawMode + destroy restores complete input/output modes":
        let pre = modes(console)
        check (pre.input and 7'u32) == 7'u32
        block:
          var raw = enableRawMode()
          check isActive(raw)
          let mid = modes(console)
          check (mid.input and 7'u32) == 0
          check (mid.input and 0x0200'u32) != 0
          check (mid.output and 0x0004'u32) != 0
        check modes(console) == pre

      test "explicit disableRawMode is idempotent and restores both modes":
        let pre = modes(console)
        var raw = enableRawMode()
        disableRawMode(raw)
        disableRawMode(raw)
        check not isActive(raw)
        check modes(console) == pre

      test "saved console modes retain the original input/output state":
        let pre = modes(console)
        block:
          var raw = enableRawMode()
          check raw.savedInput == pre.input
          check raw.savedOutput == pre.output
        check modes(console) == pre
    if programResult == 0:
      echo childCompleted

  if paramCount() == 1 and paramStr(1) == rawConsoleChildArgument:
    runWindowsRawModeCases()
  else:
    suite "L3: isolated Windows raw-mode fixture":
      test "three real console cases complete in a retained child":
        let child = startProcess(getAppFilename(), args = @[rawConsoleChildArgument],
          options = {poStdErrToStdOut})
        try:
          # Nim's Windows waitForExit(timeout) can terminate with status0.
          # Keep timeout evidence separate from the child's actual exit code.
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
  ## tests/test_termctl_raw_mode_round_trip.nim - L3 spec test.
  ##
  ## Open a real pty (via openpty(3)) so we have a real tty fd that
  ## supports termios. Capture termios via `tcGetAttr` -> `enableRawMode`
  ## -> verify ICANON and ECHO are cleared in the new state -> destroy
  ## the RawMode handle -> verify termios is byte-identical to the
  ## pre-acquire snapshot.

  import std/[unittest, posix, termios]
  import nim_termctl
  import test_helpers

  suite "L3: raw-mode round-trip on a real pty":

    test "enableRawMode + destroy restores byte-identical termios":
      let (master, slave) = openPtyPair()
      defer:
        discard close(master)
        discard close(slave)

      var pre: Termios
      check tcGetAttr(slave, addr pre) == 0
      # The slave starts in cooked mode - canonical and echo on.
      check (pre.c_lflag and Cflag(ICANON)) != 0
      check (pre.c_lflag and Cflag(ECHO)) != 0

      block:
        # enableRawMode acts on the slave fd inside the test (the production
        # default is STDIN_FILENO).
        var raw = enableRawMode(slave)
        check isActive(raw)

        var mid: Termios
        check tcGetAttr(slave, addr mid) == 0
        # Raw mode strips ICANON, ECHO, ISIG, IEXTEN.
        check (mid.c_lflag and Cflag(ICANON)) == 0
        check (mid.c_lflag and Cflag(ECHO)) == 0

      # Out of `raw`'s scope - destructor has run; termios should match
      # the pre-acquire snapshot byte for byte.
      var post: Termios
      check tcGetAttr(slave, addr post) == 0
      check pre.c_iflag == post.c_iflag
      check pre.c_oflag == post.c_oflag
      check pre.c_cflag == post.c_cflag
      check pre.c_lflag == post.c_lflag

    test "explicit disableRawMode is idempotent":
      let (master, slave) = openPtyPair()
      defer:
        discard close(master)
        discard close(slave)
      var raw = enableRawMode(slave)
      disableRawMode(raw)
      disableRawMode(raw)  # Idempotent - must not panic.
      check (not isActive(raw))

    test "savedAttributes returns the original termios":
      let (master, slave) = openPtyPair()
      defer:
        discard close(master)
        discard close(slave)
      var pre: Termios
      check tcGetAttr(slave, addr pre) == 0
      var raw = enableRawMode(slave)
      let saved = savedAttributes(raw)
      check saved.c_lflag == pre.c_lflag
      check saved.c_iflag == pre.c_iflag
