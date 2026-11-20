## tests/test_termctl_restore_from_any_thread.nim - the restore runs whichever
## thread the kernel hands the signal to.
##
## A signal sent to a PROCESS (`kill(pid, sig)`, a `kill` from a shell, a
## terminal's hangup) is delivered to any one of its threads that does not
## block it, and the kernel picks. An application with worker threads (a
## syntax highlighter, a file reader) therefore runs its signal handler on a
## worker some of the time. The terminal is the process's, so the state the
## restore reads (what was turned on, the saved termios) has to be the
## process's too: kept per thread, a handler on a worker read "nothing to
## restore" and the process died with the terminal still in the alternate
## screen, in raw mode and in the Kitty keyboard protocol.
##
## No mocks: a forked child on a REAL pty turns the modes on from its main
## thread, starts a worker, then BLOCKS the signal on the main thread, so the
## kernel can deliver it only to the worker. The parent reads what the child
## told the terminal and checks the termios it left behind.

when defined(windows):
  # Windows has no process-directed signals, but the same thing happens on
  # another road: a console control handler always runs on a NEW thread. So
  # the case here is the state set on the main thread, read from a thread
  # that did not set it, through the library's own accessors.
  import std/[unittest, strutils]
  import nim_termctl
  import windows_console_fixture

  const childCompleted = "TERMCTL_RESTORE_FROM_ANY_THREAD_COMPLETED"

  var seenNeedsRestore: bool
  var seenExtra: string

  proc reader() {.thread.} =
    {.cast(gcsafe).}:
      seenNeedsRestore = rawNeedsRestore()
      seenExtra = extraRestore()

  proc runWindowsCases() =
    let console = openOwnedTestConsole()
    countPrivateConsoleCases()
    suite "the restore state is the process's, not the thread's":
      test "raw mode and the extra restore set on main are seen from a worker":
        check setExtraRestore("\e[?2026l")
        var raw = enableRawMode()
        check rawNeedsRestore()
        var th: Thread[void]
        createThread(th, reader)
        joinThread(th)
        check seenNeedsRestore
        check seenExtra == "\e[?2026l"
        disableRawMode(raw)
        check not rawNeedsRestore()
        discard setExtraRestore("")
    discard console
    reportPrivateConsoleCompletion(childCompleted, 1)

  if isPrivateConsoleChild():
    runWindowsCases()
  else:
    suite "restore from any thread: retained private Windows console fixture":
      test "the native case completes with actual console and child wait":
        let run = runPrivateConsoleChild()
        checkpoint run.output
        check not run.timedOut
        check run.exitCode == 0
        check childCompleted in run.output
else:
  import std/[unittest, posix, strutils, termios]
  import nim_termctl
  import test_helpers

  var CHECKS = 0
  template ck(cond: untyped) =
    inc CHECKS
    check(cond)

  proc drain(master: cint; budgetMs = 3000): string =
    ## Everything the child wrote, until EOF/EIO (the slave closed) or the
    ## budget runs out.
    var waited = 0
    var buf: array[4096, char]
    while waited < budgetMs:
      var pfd = TPollfd(fd: master, events: POLLIN)
      let r = poll(addr pfd, 1, 50)
      if r > 0:
        let n = read(master, addr buf[0], buf.len)
        if n <= 0: break
        for i in 0 ..< n: result.add buf[i]
      else:
        waited += 50

  proc worker() {.thread.} =
    ## Takes the signal: the main thread blocks it.
    while true:
      discard posix.usleep(10_000)

  type ChildEnd = tuple[bytes: string, signalled: bool, signal: cint,
                        cooked: bool]

  proc runChild(sig: cint): ChildEnd =
    let (master, slave) = openPtyPair()
    var pre: Termios
    discard tcGetAttr(slave, addr pre)
    let pid = fork()
    if pid == 0:
      discard close(master)
      discard dup2(slave, STDIN_FILENO)
      discard dup2(slave, STDOUT_FILENO)
      discard close(slave)
      var raw = enableRawMode(STDIN_FILENO)
      var alt = enterAltScreen()
      var keys = enableKeyReporting(krmKitty)
      installCtrlCHandler(proc () {.gcsafe.} = discard)
      var th: Thread[void]
      createThread(th, worker)
      var only: Sigset
      discard sigemptyset(only)
      discard sigaddset(only, sig)
      var old: Sigset
      discard pthread_sigmask(SIG_BLOCK, only, old)
      discard posix.write(STDOUT_FILENO, cstring("<MARK>"), 6)
      discard kill(getpid(), sig)
      # The worker's handler ends the process; the main thread only waits.
      for _ in 0 ..< 500:
        discard posix.usleep(10_000)
      discard posix.write(STDOUT_FILENO, cstring("<SURVIVED>"), 10)
      exitnow(0)
    result.bytes = drain(master)
    var status: cint
    discard waitpid(pid, status, 0)
    result.signalled = WIFSIGNALED(status)
    result.signal = (if result.signalled: WTERMSIG(status) else: 0)
    var post: Termios
    discard tcGetAttr(slave, addr post)
    result.cooked = post.c_lflag == pre.c_lflag and post.c_iflag == pre.c_iflag
    discard close(slave)
    discard close(master)

  proc after(bytes, mark: string): string =
    let at = bytes.find(mark)
    if at < 0: "" else: bytes[at + mark.len .. ^1]

  suite "the restore runs on a thread that did not turn the modes on":

    for (sig, name) in [(SIGTERM, "SIGTERM"), (SIGHUP, "SIGHUP"),
                        (SIGINT, "SIGINT"), (SIGABRT, "SIGABRT"),
                        (SIGSEGV, "SIGSEGV")]:
      test name & " taken by a worker thread restores the terminal":
        let r = runChild(sig)
        checkpoint("bytes " & r.bytes.escape)
        ck r.signalled
        ck r.signal == sig
        ck "<SURVIVED>" notin r.bytes
        let tail = r.bytes.after("<MARK>")
        ck tail.count(KittyPopSeq) == 1
        let leave = tail.find("\e[?1049l")
        ck leave >= 0
        ck tail.find(KittyPopSeq) < leave
        ck r.cooked

  suite "restore from any thread - assertion tally":
    test "CHECKS":
      echo "CHECKS: ", CHECKS
      check CHECKS == 5 * 7
