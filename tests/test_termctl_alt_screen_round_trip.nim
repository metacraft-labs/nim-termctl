when defined(windows):
  import std/[unittest, strutils]
  import nim_termctl
  import windows_console_fixture

  const
    childCompleted = "TERMCTL_PRIVATE_CONSOLE_VT_CASES_COMPLETED"
    beginAlt = "TERMCTL_ALT_DESTRUCTOR_BEGIN|"
    endAlt = "TERMCTL_ALT_DESTRUCTOR_END"
    beginExplicit = "TERMCTL_ALT_EXPLICIT_BEGIN|"
    endExplicit = "TERMCTL_ALT_EXPLICIT_END"
    beginModes = "TERMCTL_MODES_BEGIN|"
    endModes = "TERMCTL_MODES_END"

  proc runWindowsVtCases() =
    # Production Windows VT helpers write to the actual CRT stdout stream.
    # Its real kernel pipe is captured by the parent; Win32 console slots
    # belong to this private child, never the runner's parent console.
    let console = openOwnedTestConsole()
    discard modes(console)
    countPrivateConsoleCases()
    suite "L3: real Windows VT output":
      test "enterAltScreen and destructor emit matching transitions":
        stdout.write beginAlt
        stdout.flushFile()
        block:
          var alt = enterAltScreen()
          check alt.active
        echo endAlt
      test "explicit leaveAltScreen is idempotent":
        stdout.write beginExplicit
        stdout.flushFile()
        var alt = enterAltScreen()
        leaveAltScreen(alt)
        leaveAltScreen(alt)
        check not alt.active
        echo endExplicit
      test "mouse, paste and focus toggles emit matching transitions":
        stdout.write beginModes
        stdout.flushFile()
        block:
          var mouse = enableMouseCapture()
          var paste = enableBracketedPaste()
          var focus = enableFocusReporting()
          check mouse.active and paste.active and focus.active
        echo endModes
    reportPrivateConsoleCompletion(childCompleted, 3)

  proc capturedWindowsVtOutput(): string =
    let run = runPrivateConsoleChild()
    result = run.output
    if run.timedOut or run.exitCode != 0 or childCompleted notin result:
      raise newException(IOError, "Real Windows VT child failed: " & result)

  proc segment(output, first, last: string): string =
    let start = output.find(first)
    if start < 0:
      raise newException(IOError, "Missing Windows VT begin marker " & first &
        " in child output: " & output.escape)
    let finish = output.find(last, start + first.len)
    if finish < 0:
      raise newException(IOError, "Missing Windows VT end marker " & last &
        " in child output: " & output.escape)
    result = output[start + first.len ..< finish]

  if isPrivateConsoleChild():
    runWindowsVtCases()
  else:
    let output = capturedWindowsVtOutput()
    suite "L3: Windows VT bytes across an actual kernel pipe":
      test "destructor emits the exact alt-screen enter/leave pair":
        check segment(output, beginAlt, endAlt) == "\x1b[?1049h\x1b[?1049l"
      test "explicit disable emits one leave despite being called twice":
        check segment(output, beginExplicit, endExplicit) == "\x1b[?1049h\x1b[?1049l"
      test "every mouse/paste/focus enable and disable crosses the pipe":
        let emitted = segment(output, beginModes, endModes)
        for sequence in ["\x1b[?1000h", "\x1b[?1006h", "\x1b[?2004h",
                         "\x1b[?1004h", "\x1b[?1006l", "\x1b[?1000l",
                         "\x1b[?2004l", "\x1b[?1004l"]:
          check emitted.count(sequence) == 1
else:
  ## tests/test_termctl_alt_screen_round_trip.nim - L3 spec test.
  ##
  ## Drive a real pty with the alt-screen toggle and verify the byte
  ## stream contains the canonical CSI ?1049 enter / leave pairs. The
  ## test asserts on bytes (not on a parsed VT) because alt-screen state
  ## is not directly observable via termios; the visible behaviour we
  ## care about is "the right escape sequences land on the master".

  import std/[unittest, posix, strutils]
  import nim_termctl
  import test_helpers

  proc readAvailable(fd: cint; timeoutMs: int): string =
    ## Drain the master side of a pty for up to `timeoutMs`.
    result = ""
    var rs: TFdSet
    for _ in 0 .. 50:
      FD_ZERO(rs)
      FD_SET(fd, rs)
      var tv: Timeval
      tv.tv_sec = posix.Time(0)
      tv.tv_usec = typeof(tv.tv_usec)(timeoutMs * 1000 div 50)
      let n = select(fd + 1, addr rs, nil, nil, addr tv)
      if n <= 0: break
      var buf: array[4096, byte]
      let got = read(fd, addr buf[0], buf.len)
      if got <= 0: break
      for i in 0 ..< got:
        result.add char(buf[i])

  suite "L3: alt-screen round-trip on a real pty":

    test "enterAltScreen emits CSI ?1049h; destroy emits ?1049l":
      let (master, slave) = openPtyPair()
      defer:
        discard close(master)
        discard close(slave)
      block:
        var alt = enterAltScreen(slave)
        check alt.active
      let drained = readAvailable(master, 50)
      # We expect exactly the enter and the leave to have crossed the wire.
      check drained.contains("\x1b[?1049h")
      check drained.contains("\x1b[?1049l")

    test "explicit leaveAltScreen is idempotent":
      let (master, slave) = openPtyPair()
      defer:
        discard close(master)
        discard close(slave)
      var alt = enterAltScreen(slave)
      leaveAltScreen(alt)
      leaveAltScreen(alt)
      check (not alt.active)

    test "mouse / paste / focus toggles emit the right escapes":
      let (master, slave) = openPtyPair()
      defer:
        discard close(master)
        discard close(slave)
      block:
        var m = enableMouseCapture(slave)
        var p = enableBracketedPaste(slave)
        var f = enableFocusReporting(slave)
        check m.active and p.active and f.active
      let drained = readAvailable(master, 50)
      check drained.contains("\x1b[?1000h")
      check drained.contains("\x1b[?1006h")
      check drained.contains("\x1b[?2004h")
      check drained.contains("\x1b[?1004h")
      # Destruction emits the matching `l` sequences.
      check drained.contains("\x1b[?1006l")
      check drained.contains("\x1b[?2004l")
      check drained.contains("\x1b[?1004l")
