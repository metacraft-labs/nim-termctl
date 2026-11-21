## tests/test_termctl_sigwinch_any_thread.nim - a resize is not lost when the
## kernel hands SIGWINCH to a thread other than the one that installed the
## handler.
##
## SIGWINCH sent to a process (`kill(pid, SIGWINCH)`, or the kernel's own on a
## window-size change of the controlling terminal) is process-directed: POSIX
## says it is delivered to exactly one thread that does not block it, chosen by
## the system ("Signal Generation and Delivery", XSH 2.4.1,
## https://pubs.opengroup.org/onlinepubs/9799919799/functions/V2_chap02.html#tag_16_04_01),
## and Linux's signal(7) says the same ("the kernel chooses an arbitrary thread
## to which to deliver the signal",
## https://man7.org/linux/man-pages/man7/signal.7.html). An application with
## worker threads therefore runs the SIGWINCH handler on a worker some of the
## time. The handler writes to the self-pipe, so the pipe's descriptors must be
## the process's: kept per thread, a handler on a worker saw descriptor 0 (the
## zero a fresh thread's variables start at), wrote the byte to standard input
## and the resize was lost.
##
## The pipe descriptors also read as -1 until the handler is installed, as
## `winchPipeReadFd` documents: with a 0 there, the handler and
## `drainWinchPipe` would read and write standard input.
##
## No mocks: the main thread installs the real handler and then BLOCKS
## SIGWINCH, a worker leaves it unblocked, and the signal is sent to the whole
## process, so the kernel can deliver it only to the worker. The byte must
## arrive on the real pipe.

when defined(windows):
  # Windows has no SIGWINCH; console resizes arrive as input records and are
  # covered by test_termctl_sigwinch_resize.nim.
  import std/unittest
  suite "L3: SIGWINCH on another thread":
    test "POSIX only":
      skip()
else:
  import std/[atomics, os, posix, unittest]
  import nim_termctl

  var TestSIGWINCH {.importc: "SIGWINCH", header: "<signal.h>".}: cint

  var
    workerReady: Atomic[bool]
    workerDone: Atomic[bool]
    workerUnblockResult: Atomic[int]

  proc winchMask(): Sigset =
    discard sigemptyset(result)
    discard sigaddset(result, TestSIGWINCH)

  proc worker() {.thread.} =
    # A thread starts with its creator's mask; make sure SIGWINCH is
    # deliverable here whatever the creator had.
    var mask = winchMask()
    var old: Sigset
    workerUnblockResult.store(int(pthread_sigmask(SIG_UNBLOCK, mask, old)))
    workerReady.store(true)
    while not workerDone.load:
      sleep(5)

  proc waitReadable(fd: cint; ms: int): bool =
    var rs: TFdSet
    FD_ZERO(rs)
    FD_SET(fd, rs)
    var tv = Timeval(tv_sec: posix.Time(ms div 1000),
                     tv_usec: Suseconds((ms mod 1000) * 1000))
    select(fd + 1, addr rs, nil, nil, addr tv) > 0

  suite "L3: SIGWINCH on another thread":
    test "the pipe reads -1 before the handler is installed":
      check winchPipeReadFd() == -1

    test "a SIGWINCH a worker takes still reaches the self-pipe":
      installWinchHandler()
      defer: uninstallWinchHandler()
      drainWinchPipe()
      let fd = winchPipeReadFd()
      check fd >= 0

      var t: Thread[void]
      createThread(t, worker)
      while not workerReady.load:
        sleep(1)
      check workerUnblockResult.load == 0

      # Only the worker may take it from here on.
      var mask = winchMask()
      var previous: Sigset
      check pthread_sigmask(SIG_BLOCK, mask, previous) == 0

      check kill(getpid(), TestSIGWINCH) == 0
      let arrived = waitReadable(fd, 2000)
      var b: byte
      let n = if arrived: read(fd, addr b, 1) else: -1
      checkpoint "pipe readable: " & $arrived & ", read returned " & $n

      workerDone.store(true)
      joinThread(t)
      # Nothing is pending on the main thread: the worker took the signal.
      var pending: Sigset
      check sigpending(pending) == 0
      check sigismember(pending, TestSIGWINCH) == 0
      var ignored: Sigset
      check pthread_sigmask(SIG_SETMASK, previous, ignored) == 0

      check arrived
      check n == 1
