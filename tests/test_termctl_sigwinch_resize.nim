## tests/test_termctl_sigwinch_resize.nim - L3 spec test.
##
## Install the SIGWINCH handler, raise SIGWINCH at ourselves, and
## verify the self-pipe receives the byte. Then drain it and check the
## state is reset.
##
## We don't drive `pollEvent` end-to-end here because the public path
## reads from STDIN_FILENO which the test runner has captured for its
## own output - mixing in fake input would clobber unittest's own
## stdout. The lower-level `winchPipeReadFd` and `drainWinchPipe`
## hooks are the load-bearing primitives; testing them directly is a
## stronger contract.

import std/[unittest, posix]
import nim_termctl
import test_helpers

# Local SIGWINCH constant (std/posix doesn't declare it).
var
  TestSIGWINCH {.importc: "SIGWINCH", header: "<signal.h>".}: cint

suite "L3: SIGWINCH self-pipe":

  test "SIGWINCH writes a byte to the pipe":
    when defined(linux):
      let fdsBefore = countOpenFds()
      installWinchHandler()
      defer: uninstallWinchHandler()
      let fdsAfter = countOpenFds()
      check fdsAfter == fdsBefore + 2  # read + write end of the pipe

      check winchPipeReadFd() >= 0

      # Raise SIGWINCH at ourselves; the handler writes one byte.
      discard kill(getpid(), TestSIGWINCH)

      # Wait briefly for the byte to land.
      var rs: TFdSet
      FD_ZERO(rs)
      let fd = winchPipeReadFd()
      FD_SET(fd, rs)
      var tv: Timeval
      tv.tv_sec = posix.Time(1)
      tv.tv_usec = clong(0)
      let n = select(fd + 1, addr rs, nil, nil, addr tv)
      check n == 1

      # drainWinchPipe consumes the byte.
      drainWinchPipe()

      # After drain, the pipe is empty (select with 0 timeout returns 0).
      FD_ZERO(rs)
      FD_SET(fd, rs)
      var tv0: Timeval
      tv0.tv_sec = posix.Time(0)
      tv0.tv_usec = clong(0)
      let n2 = select(fd + 1, addr rs, nil, nil, addr tv0)
      check n2 == 0
    else:
      skip()

  test "uninstall closes the pipe FDs cleanly":
    when defined(linux):
      let baseline = countOpenFds()
      installWinchHandler()
      uninstallWinchHandler()
      check countOpenFds() == baseline
      check winchPipeReadFd() == -1
    else:
      skip()

  test "terminalSize on a pty returns the kernel-recorded size":
    let (master, slave) = openPtyPair()
    defer:
      discard close(master)
      discard close(slave)
    # The default size on a fresh pty is 0x0; we set it via TIOCSWINSZ
    # to verify that terminalSize reads the up-to-date value.
    type
      WinsizeC {.importc: "struct winsize", header: "<sys/ioctl.h>",
                 pure, final.} = object
        ws_row: cushort
        ws_col: cushort
        ws_xpixel: cushort
        ws_ypixel: cushort
    var ws = WinsizeC(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
    var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong
    proc cIoctl(fd: cint; request: culong): cint
      {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}
    check cIoctl(slave, TIOCSWINSZ, addr ws) == 0
    let sz = terminalSize(slave)
    check sz.cols == 100
    check sz.rows == 30
