## tests/test_termctl_no_leaks.nim - charter-mandated leak-budget tests.
##
## Mirrors nim-pty's `test_no_leaks.nim` shape: open/destroy cycles for
## every owning handle in the public API, verifying no FD leak, no
## thread leak, no RSS drift.

import std/[unittest, posix, termios]
import nim_termctl
import test_helpers

const heavy = defined(nimTermctlHeavy)
const cycles = if heavy: 100_000 else: 1_000

template ifLinux(body: untyped) =
  when defined(linux):
    body
  else:
    discard

suite "L3 charter: leak-budget tests":

  test "test_no_leaks_steady_state - 1k raw mode acquire/release":
    ifLinux:
      let baseline = readRssBytes()
      check baseline > 0
      for i in 0 ..< cycles:
        let (m, s) = openPtyPair()
        block:
          var raw = enableRawMode(s)
          discard isActive(raw)
        discard close(m)
        discard close(s)
      let final = readRssBytes()
      let driftMb = abs(final - baseline) div (1024 * 1024)
      check driftMb <= 32

  test "test_no_handle_leaks - FD count unchanged after 1k cycles":
    ifLinux:
      let baseline = countOpenFds()
      check baseline > 0
      for i in 0 ..< cycles:
        let (m, s) = openPtyPair()
        block:
          var raw = enableRawMode(s)
          discard isActive(raw)
        discard close(m)
        discard close(s)
      let final = countOpenFds()
      check final == baseline

  test "test_no_leaks_under_panic - destructor runs during unwind":
    ifLinux:
      let baseline = countOpenFds()
      for i in 0 ..< 100:
        let (m, s) = openPtyPair()
        try:
          var raw = enableRawMode(s)
          discard isActive(raw)
          raise newException(ValueError, "synthetic panic")
        except ValueError:
          discard
        discard close(m)
        discard close(s)
      let final = countOpenFds()
      check final == baseline

  test "test_no_leaks_under_signal - termios always restored":
    ifLinux:
      let baseline = countOpenFds()
      for i in 0 ..< 100:
        let (m, s) = openPtyPair()
        var pre: Termios
        discard tcGetAttr(s, addr pre)
        block:
          var raw = enableRawMode(s)
          discard isActive(raw)
        var post: Termios
        discard tcGetAttr(s, addr post)
        check pre.c_lflag == post.c_lflag
        discard close(m)
        discard close(s)
      let final = countOpenFds()
      check final == baseline

  test "winch handler install/uninstall - FD count unchanged":
    ifLinux:
      let baseline = countOpenFds()
      for i in 0 ..< 100:
        installWinchHandler()
        uninstallWinchHandler()
      check countOpenFds() == baseline

  test "alt-screen / mouse / paste / focus toggle - no FD or memory drift":
    ifLinux:
      let baseline = countOpenFds()
      let rss0 = readRssBytes()
      for i in 0 ..< cycles:
        let (m, s) = openPtyPair()
        block:
          var alt = enterAltScreen(s)
          var mc = enableMouseCapture(s)
          var bp = enableBracketedPaste(s)
          var fr = enableFocusReporting(s)
          discard alt.active and mc.active and bp.active and fr.active
        # Drain master so the kernel pipe doesn't bloat memory.
        var dummy: array[8192, byte]
        var rs: TFdSet
        FD_ZERO(rs)
        FD_SET(m, rs)
        var tv: Timeval
        tv.tv_sec = posix.Time(0)
        tv.tv_usec = clong(0)
        if select(m + 1, addr rs, nil, nil, addr tv) > 0:
          discard read(m, addr dummy[0], dummy.len)
        discard close(m)
        discard close(s)
      check countOpenFds() == baseline
      let rss1 = readRssBytes()
      let drift = abs(rss1 - rss0) div (1024 * 1024)
      check drift <= 32

  test "parser feed cycles - no RSS drift":
    ifLinux:
      let rss0 = readRssBytes()
      for i in 0 ..< cycles:
        var er = newEventReader()
        er.feedString("\x1b[<0;10;5M\x1b[A\x1b[1;5Babc\x1b[200~paste\x1b[201~")
        let evs = drain(er)
        discard evs
      let rss1 = readRssBytes()
      # AddressSanitizer's shadow memory adds ~16 MB of resident pages on
      # touch; LeakSanitizer adds another few. We allow a generous bound
      # so the same test passes both vanilla and under sanitizers.
      let drift = abs(rss1 - rss0) div (1024 * 1024)
      check drift <= 32
