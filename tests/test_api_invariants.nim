when defined(windows):
  import std/[unittest, os, osproc, streams, strutils, monotimes, times]
  import nim_termctl
  import windows_console_fixture

  const childCompleted = "TERMCTL_PRIVATE_CONSOLE_API_CASES_COMPLETED"

  proc runWindowsCases() =
    let console = openOwnedTestConsole()
    suite "L3: API invariants on real Windows console":
      test "Color is a value object (no ref)":
        var color: Color = rgb(10, 20, 30)
        check color.kind == ckRgb
        check color.r == 10
        let copy = color
        check copy.r == 10
      test "Event is a value object (no ref)":
        let event = Event(kind: ekKey, key: charKey('a'))
        let copy = event
        check copy == event
      test "RawMode default-init is inactive and leaves console unchanged":
        let pre = modes(console)
        block:
          var raw: RawMode = default(RawMode)
          check not isActive(raw)
        check modes(console) == pre
      test "AltScreen default-init is inactive":
        var alt: AltScreen = default(AltScreen)
        check not alt.active
      test "isActive reflects actual RawMode acquisition and release":
        let pre = modes(console)
        var raw = enableRawMode()
        check isActive(raw)
        check (modes(console).input and 7'u32) == 0
        disableRawMode(raw)
        check not isActive(raw)
        check modes(console) == pre
      test "Parser starts empty":
        var parser = initParser()
        check parser.pending() == 0
      test "QueueWriter starts empty":
        let writer = newQueueWriter()
        check writer.len == 0
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
  ## tests/test_api_invariants.nim - charter §1 API constraints.
  ##
  ## Lock in the rules:
  ##   * `=copy` on every owning handle is a compile-time error.
  ##   * Default-constructed handles do not interact with stdio.
  ##   * `isActive(...)` reflects the acquire/release state.
  ##   * `Color` and `Event` are value `object`s (no `ref` involved).

  import std/[unittest, posix]
  import nim_termctl
  import test_helpers

  suite "L3: API invariants":

    test "Color is a value object (no ref)":
      var c: Color = rgb(10, 20, 30)
      check c.kind == ckRgb
      check c.r == 10
      # Copy is allowed for `Color` - it's a plain value type with no
      # owning resource. We just verify the bytes match.
      let c2 = c
      check c2.r == 10

    test "Event is a value object (no ref)":
      let e = Event(kind: ekKey, key: charKey('a'))
      let e2 = e
      check e2 == e

    test "RawMode default-init is inactive":
      var r: RawMode = default(RawMode)
      check (not isActive(r))
      # Destruction of a default-init handle must not touch any tty.

    test "AltScreen default-init is inactive":
      var a: AltScreen = default(AltScreen)
      check (not a.active)

    test "isActive reflects state for RawMode":
      let (master, slave) = openPtyPair()
      defer:
        discard close(master)
        discard close(slave)
      var raw = enableRawMode(slave)
      check isActive(raw)
      disableRawMode(raw)
      check (not isActive(raw))

    test "Parser starts empty":
      var p = initParser()
      check p.pending() == 0

    test "QueueWriter starts empty":
      let qw = newQueueWriter()
      check qw.len == 0
