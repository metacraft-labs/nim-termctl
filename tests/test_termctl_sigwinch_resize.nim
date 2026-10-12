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

# TIOCSWINSZ is a C macro, so use it without emitting a variable declaration.
let TIOCSWINSZ {.importc, header: "<sys/ioctl.h>", nodecl.}: culong
let TIOCSCTTY {.importc, header: "<sys/ioctl.h>", nodecl.}: culong

type
  WinsizeC {.importc: "struct winsize", header: "<sys/ioctl.h>",
             pure, final.} = object
    ws_row: cushort
    ws_col: cushort
    ws_xpixel: cushort
    ws_ypixel: cushort

proc cIoctl(fd: cint; request: culong): cint
  {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

proc winchChildMain(slave, readyFd: cint): int32 =
  ## Body of the forked child in the pty resize test. Makes `slave` the
  ## controlling terminal, signals readiness and waits for SIGWINCH to
  ## reach the self-pipe. Returns an exit code instead of raising, so
  ## the child never unwinds into the unittest runner.
  if setsid() < 0 or cIoctl(slave, TIOCSCTTY, 0) != 0:
    return 2
  try:
    installWinchHandler()
    var ready = 'r'
    discard write(readyFd, addr ready, 1)
    # The signal usually lands while select is blocked, which
    # interrupts it with EINTR; retry so the pipe byte is seen.
    let fd = winchPipeReadFd()
    var n: cint
    for _ in 0 ..< 10:
      var rs: TFdSet
      FD_ZERO(rs)
      FD_SET(fd, rs)
      var tv: Timeval
      tv.tv_sec = posix.Time(5)
      tv.tv_usec = clong(0)
      n = select(fd + 1, addr rs, nil, nil, addr tv)
      if n != -1 or errno != EINTR: break
    if n != 1:
      return 3
    let sz = terminalSize(slave)
    if sz.cols != 100 or sz.rows != 30:
      return 4
    return 0
  except CatchableError:
    return 5

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
    var ws = WinsizeC(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
    check cIoctl(slave, TIOCSWINSZ, addr ws) == 0
    let sz = terminalSize(slave)
    check sz.cols == 100
    check sz.rows == 30

  test "resizing the controlling pty delivers SIGWINCH to the self-pipe":
    # The kernel sends SIGWINCH to the foreground process group of the
    # resized terminal, and the test runner is not in the pty's session.
    # A forked child takes the pty slave as its controlling terminal and
    # waits on the self-pipe while the parent resizes via the master.
    when defined(linux) or defined(macosx):
      let (master, slave) = openPtyPair()
      defer:
        discard close(master)
        discard close(slave)
      var sync: array[2, cint]
      check pipe(sync) == 0
      let pid = fork()
      if pid == 0:
        discard close(sync[0])
        exitnow(winchChildMain(slave, sync[1]))
      check pid > 0
      discard close(sync[1])
      var ready: char
      let got = read(sync[0], addr ready, 1)
      discard close(sync[0])
      var ws = WinsizeC(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
      if got == 1:
        check cIoctl(master, TIOCSWINSZ, addr ws) == 0
      var status: cint
      check waitpid(pid, status, 0) == pid
      check WIFEXITED(status)
      check WEXITSTATUS(status) == 0
    else:
      skip()
