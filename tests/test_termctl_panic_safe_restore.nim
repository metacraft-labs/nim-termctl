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
