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
    tv.tv_usec = clong(timeoutMs * 1000 div 50)
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
