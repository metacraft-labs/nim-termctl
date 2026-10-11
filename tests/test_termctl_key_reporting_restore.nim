## tests/test_termctl_key_reporting_restore.nim - extended key reporting is
## undone on every exit path, including the ones that never run a destructor.
##
## A terminal left in the Kitty keyboard protocol's disambiguate mode sends
## `CSI 99 ; 5 u` for Ctrl+c to the user's shell after the program is gone;
## one left in `modifyOtherKeys` sends `CSI 27 ; 5 ; 99 ~`. So the undo has to
## run from the destructor, from `disableKeyReporting`, from the
## async-signal-safe restore on SIGTERM / SIGHUP, and from the fatal-signal
## restore on a crash.
##
## No mocks: each signal case forks a REAL child whose stdout is the slave of
## a REAL pty (`openpty(3)`), which enters the alternate screen, turns key
## reporting on and then is killed by a real signal. The parent reads the
## bytes the child wrote to the terminal off the master and asserts what a
## terminal would have been told, and in what order: the Kitty pop must reach
## the alternate screen it was pushed on (the flag stack is per screen), so
## it precedes the alternate-screen leave.

import std/[unittest, posix, strutils]
import nim_termctl
import test_helpers

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc drain(master: cint; budgetMs = 2000): string =
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

type ChildEnd = tuple[bytes: string, signalled: bool, signal: cint]

proc runChild(mode: KeyReportingMode; sig: cint): ChildEnd =
  ## Fork a child on a fresh pty that enters raw mode and the alternate
  ## screen, turns `mode` on, writes a marker, and raises `sig` at itself.
  let (master, slave) = openPtyPair()
  let pid = fork()
  if pid == 0:
    discard close(master)
    discard dup2(slave, STDIN_FILENO)
    discard dup2(slave, STDOUT_FILENO)
    discard close(slave)
    var raw = enableRawMode(STDIN_FILENO)
    var alt = enterAltScreen()
    var keys = enableKeyReporting(mode)
    discard posix.write(STDOUT_FILENO, cstring("<MARK>"), 6)
    discard kill(getpid(), sig)
    # Not reached: the restore re-raises with the previous action.
    discard posix.write(STDOUT_FILENO, cstring("<SURVIVED>"), 10)
    exitnow(0)
  discard close(slave)
  result.bytes = drain(master)
  var status: cint
  discard waitpid(pid, status, 0)
  result.signalled = WIFSIGNALED(status)
  result.signal = (if result.signalled: WTERMSIG(status) else: 0)
  discard close(master)

proc after(bytes, mark: string): string =
  let at = bytes.find(mark)
  if at < 0: "" else: bytes[at + mark.len .. ^1]

suite "extended key reporting: the bytes and the RAII paths":

  test "the push and pop sequences are the protocols' own":
    ck KittyPushDisambiguateSeq == "\e[>1u"
    ck KittyPopSeq == "\e[<u"
    ck ModifyOtherKeysOnSeq == "\e[>4;2m"
    ck ModifyOtherKeysOffSeq == "\e[>4;0m"
    ck keyReportingLeaveSeq(krmKitty) == KittyPopSeq
    ck keyReportingLeaveSeq(krmModifyOtherKeys) == ModifyOtherKeysOffSeq

  test "disableKeyReporting writes the undo once, and the destructor then nothing":
    let (master, slave) = openPtyPair()
    defer:
      discard close(master)
      discard close(slave)
    block:
      var k = enableKeyReporting(krmKitty, slave)
      ck k.active
      disableKeyReporting(k)
      ck not k.active
      disableKeyReporting(k)
    let bytes = drain(master, 200)
    ck bytes == KittyPushDisambiguateSeq & KittyPopSeq

  test "the destructor undoes the mode at end of scope":
    let (master, slave) = openPtyPair()
    defer:
      discard close(master)
      discard close(slave)
    block:
      var k = enableKeyReporting(krmModifyOtherKeys, slave)
      ck k.active
    let bytes = drain(master, 200)
    ck bytes == ModifyOtherKeysOnSeq & ModifyOtherKeysOffSeq

suite "extended key reporting: undone when the process is signalled":

  for (mode, push, pop) in [(krmKitty, KittyPushDisambiguateSeq, KittyPopSeq),
                            (krmModifyOtherKeys, ModifyOtherKeysOnSeq,
                             ModifyOtherKeysOffSeq)]:
    for (sig, name) in [(SIGTERM, "SIGTERM"), (SIGHUP, "SIGHUP"),
                        (SIGSEGV, "SIGSEGV"), (SIGABRT, "SIGABRT")]:
      test $mode & " is undone on " & name & ", before the alternate screen is left":
        let r = runChild(mode, sig)
        checkpoint("bytes " & r.bytes.escape)
        # The child really was killed by the signal: the restore handed it
        # back rather than swallowing it.
        ck r.signalled
        ck r.signal == sig
        ck "<SURVIVED>" notin r.bytes
        # It was on: the push precedes the marker.
        let before = r.bytes[0 ..< max(0, r.bytes.find("<MARK>"))]
        ck push in before
        # And it was undone after it, exactly once, before the screen left.
        let tail = r.bytes.after("<MARK>")
        ck tail.count(pop) == 1
        let leave = tail.find("\e[?1049l")
        ck leave >= 0
        ck tail.find(pop) < leave

suite "key reporting restore - assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS == 6 + 3 + 2 + 7 * 8
