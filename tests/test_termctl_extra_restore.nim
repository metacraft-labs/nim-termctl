## test_termctl_extra_restore.nim — the application's own modes are reset by
## the same restore as nim-termctl's (`setExtraRestore`), on a normal exit
## and on SIGTERM.
##
## No mocks: a real pty (`openpty`), a real child process that enables raw
## mode and registers the bytes, and the bytes read off the pty master.

import std/[os, posix, strutils, unittest]

import nim_termctl

proc openpty(amaster, aslave: ptr cint; name: cstring; termp: pointer;
             winp: pointer): cint {.importc, header: "<pty.h>".}

const
  Sequence = "\e[?2027l\e[?2026l\e[?1016l\e[?1003l"

proc childMain(mode: string) =
  var rm = enableRawMode(STDIN_FILENO)
  doAssert setExtraRestore(Sequence)
  doAssert extraRestore() == Sequence
  stdout.write "READY\n"
  stdout.flushFile()
  if mode == "normal":
    writeExtraRestore()
    disableRawMode(rm)
    quit(0)
  # Wait to be killed.
  while true:
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

proc runChild(mode: string; kill: bool): string =
  var master, slave: cint
  doAssert openpty(addr master, addr slave, nil, nil, nil) == 0
  let pid = fork()
  if pid == 0:
    discard close(master)
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
  if kill:
    discard posix.kill(pid, SIGTERM)
  var status: cint
  discard waitpid(pid, status, 0)
  seen.add readAll(master, 300)
  discard close(master)
  seen

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
