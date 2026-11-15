## test_termctl_extra_restore.nim — the application's own modes are reset by
## the same restore as nim-termctl's (`setExtraRestore`), on every exit path:
## a normal exit, SIGTERM, SIGHUP, a crash (SIGSEGV) — and before a stop
## (SIGTSTP), after which a continue (SIGCONT) takes the terminal again: raw
## mode back, the application's own modes back (`setExtraResume`), and
## `takeResumed` true so the application paints a whole frame.
##
## No mocks: a real pty (`openpty`), a real child process that enables raw
## mode and registers the bytes, and the bytes read off the pty master.

import std/[os, posix, strutils, termios, times, unittest, volatile]

import nim_termctl

# openpty(3) is declared in <pty.h> on Linux and in <util.h> on macOS/BSD.
const ptyHeader = when defined(macosx) or defined(bsd): "<util.h>" else: "<pty.h>"

proc openpty(amaster, aslave: ptr cint; name: cstring; termp: pointer;
             winp: pointer): cint {.importc, header: ptyHeader.}

const
  Sequence = "\e[?2027l\e[?2026l\e[?1016l\e[?1003l"
  Resume = "\e[?2027h\e[?1003h"

proc childMain(mode: string) =
  var rm = enableRawMode(STDIN_FILENO)
  doAssert setExtraRestore(Sequence)
  doAssert extraRestore() == Sequence
  doAssert setExtraResume(Resume)
  doAssert extraResume() == Resume
  stdout.write "READY\n"
  stdout.flushFile()
  if mode == "normal":
    writeExtraRestore()
    disableRawMode(rm)
    quit(0)
  if mode == "segv":
    # A real fault, not a `kill`: the crash handler restores, then the
    # runtime's own handler (or the default) ends the process.
    # A volatile store: a plain write through a constant nil pointer is
    # undefined behaviour that clang at -O3 is free to delete, and on macOS
    # it did, so the child never faulted and waited forever (m4, at
    # 6025f07). The volatile store must be emitted and really faults.
    let p = cast[ptr int](0)
    volatileStore(p, 1)
  # Wait to be killed — or stopped and continued.
  while true:
    if takeResumed():
      var t: Termios
      discard tcGetAttr(STDIN_FILENO, addr t)
      stdout.write(if (t.c_lflag and ICANON) == 0: "RESUMED RAW\n"
                   else: "RESUMED COOKED\n")
      stdout.flushFile()
    sleep(50)

proc readAll(fd: cint; timeoutMs: int): string =
  var waited = 0
  var buf: array[256, char]
  while waited < timeoutMs:
    var fds = TPollfd(fd: fd, events: POLLIN)
    let r = poll(addr fds, 1, 50)
    if r > 0:
      let n = posix.read(fd, addr buf[0], buf.len)
      if n <= 0: break
      for i in 0 ..< n: result.add buf[i]
    else:
      waited += 50

proc waitReading(pid: Pid; master: cint; status: var cint;
                 options: cint = 0): string =
  ## waitpid while draining the master, as a real terminal emulator does.
  ## The restore ends with tcsetattr(TCSAFLUSH), which waits for the output
  ## already written to reach the other side. On macOS that blocks until
  ## the master reads it, so a parent that only reads after waitpid
  ## returns deadlocks with its child (m4, at ff73591: the child blocked in
  ## tcsetattr inside the SIGTERM handler, the parent in wait4).
  ## Bounded: a child that never reaches the awaited state fails the case
  ## with what it wrote, instead of holding the runner until its job
  ## timeout (the Valgrind job did, for six hours, at 1bb688c).
  let deadline = epochTime() + 30.0
  while true:
    result.add readAll(master, 50)
    let r = waitpid(pid, status, options or WNOHANG)
    if r == pid: break
    doAssert r == 0, "waitpid failed"
    if epochTime() > deadline:
      discard posix.kill(pid, SIGKILL)
      discard waitpid(pid, status, 0)
      raise newException(AssertionDefect,
        "child did not reach the awaited state within 30 s; it wrote: " &
        result.escape)

proc spawnChild(mode: string): tuple[pid: Pid; master: cint; seen: string] =
  var master, slave: cint
  doAssert openpty(addr master, addr slave, nil, nil, nil) == 0
  let pid = fork()
  if pid == 0:
    discard close(master)
    if mode == "stop":
      # Its own process group in THIS session, as a shell's job is: a stop
      # sent to a process in an orphaned group (a new session's, whose
      # parent is elsewhere) is discarded by the kernel.
      discard setpgid(0, 0)
    else:
      discard setsid()
    discard dup2(slave, 0)
    discard dup2(slave, 1)
    discard dup2(slave, 2)
    childMain(mode)
    quit(0)
  discard close(slave)
  var seen = ""
  while not seen.contains("READY"):
    let got = readAll(master, 200)
    if got.len == 0: break
    seen.add got
  (pid, master, seen)

proc runChild(mode: string; kill: bool; sig = SIGTERM): string =
  var (pid, master, seen) = spawnChild(mode)
  if kill:
    discard posix.kill(pid, sig)
  var status: cint
  seen.add waitReading(pid, master, status)
  seen.add readAll(master, 300)
  discard close(master)
  seen

proc afterReady(s: string): string =
  let at = s.find("READY")
  if at < 0: "" else: s[at + "READY".len .. ^1]

proc runningUnderValgrind(): bool =
  ## Valgrind runs its guest with its core preload library on LD_PRELOAD
  ## (vgpreload_core-<platform>.so) and that variable is inherited by a
  ## forked child, so this answers for the child as well. It is the same
  ## fact valgrind.h's RUNNING_ON_VALGRIND reports, without making this test
  ## depend on the Valgrind headers on every platform it compiles for.
  "vgpreload_core" in getEnv("LD_PRELOAD")

suite "setExtraRestore":
  test "too long a sequence is refused and changes nothing":
    check setExtraRestore("abc")
    check not setExtraRestore(repeat('x', ExtraRestoreCapacity + 1))
    check extraRestore() == "abc"
    check setExtraRestore("")

  test "a normal exit writes the registered bytes":
    let out1 = runChild("normal", kill = false)
    check out1.contains(Sequence)

  test "SIGTERM writes the registered bytes from the signal handler":
    let out2 = runChild("signal", kill = true)
    check out2.contains(Sequence)

  test "SIGHUP writes the registered bytes from the signal handler":
    let out3 = runChild("signal", kill = true, sig = SIGHUP)
    check out3.afterReady.contains(Sequence)

  test "a crash (SIGSEGV) writes the registered bytes before it ends":
    let out4 = runChild("segv", kill = false)
    check out4.afterReady.contains(Sequence)

  test "SIGTSTP writes them before the stop; SIGCONT takes the terminal again":
    if runningUnderValgrind():
      # EXEMPT UNDER VALGRIND ONLY, by operator decision (Zahary Karadjov,
      # 2026-11-14). Valgrind 3.26 does not stop a process that re-raises
      # SIGTSTP with SIG_DFL from inside its own SIGTSTP handler -- the
      # job-control idiom the backend's onSuspend uses -- so the child never
      # stops and this case cannot be observed there. Natively it stops, and
      # this case runs in every other job (all memory managers, modes and
      # threading settings on Linux and macOS, the sanitizer cells).
      # Defect, upstream report and removal condition:
      # isonim-pm issues/2026-11-16-valgrind-does-not-stop-a-process-that-re-raises-sigtstp-from-its-handler.md
      # Remove this exemption once the Valgrind the dev shell provides
      # carries the upstream fix.
      skip()
    else:
      var (pid, master, seen) = spawnChild("stop")
      discard posix.kill(pid, SIGTSTP)
      var status: cint
      # The child STOPS (WUNTRACED reports it) — after writing the restore.
      var stopped = waitReading(pid, master, status, WUNTRACED)
      check WIFSTOPPED(status)
      stopped.add readAll(master, 300)
      check stopped.contains(Sequence)
      check not stopped.contains(Resume)
      # Continued: raw mode back, the application's modes back, and the
      # application told (`takeResumed`).
      discard posix.kill(pid, SIGCONT)
      var back = ""
      for i in 0 ..< 40:
        back.add readAll(master, 100)
        if back.contains("RESUMED"): break
      checkpoint("after SIGCONT: " & back.escape)
      check back.contains(Resume)
      check back.contains("RESUMED RAW")
      # And it still restores on the way out.
      discard posix.kill(pid, SIGTERM)
      var last = waitReading(pid, master, status)
      last.add readAll(master, 300)
      check last.contains(Sequence)
      discard close(master)
      discard seen
