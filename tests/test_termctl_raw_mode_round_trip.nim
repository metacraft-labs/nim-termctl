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
