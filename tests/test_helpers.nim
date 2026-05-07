## tests/test_helpers.nim - shared utilities for nim-termctl integration
## tests.
##
## Most tests need a real pty so the parent can drive a child that sees
## a real tty fd; we use `nim-pty` if it's available, otherwise we open
## a pty pair via `openpty(3)` directly.

import std/[strutils, os]

# `findBin` -- locate a binary via $PATH without resolving its symlink.
proc findBin*(name: string): string =
  let pathEnv = getEnv("PATH")
  for dir in pathEnv.split(':'):
    if dir.len == 0: continue
    let candidate = dir / name
    if fileExists(candidate):
      return candidate
  for fallback in ["/bin/" & name, "/usr/bin/" & name]:
    if fileExists(fallback):
      return fallback
  return ""

proc requireBin*(name: string): string =
  let p = findBin(name)
  if p.len == 0:
    raise newException(IOError, "required test binary not found: " & name)
  return p

# ---------------------------------------------------------------------------
# Process introspection - used by leak-budget tests.
# ---------------------------------------------------------------------------

proc readRssBytes*(): int =
  when defined(linux):
    let path = "/proc/self/status"
    if not fileExists(path): return 0
    for line in lines(path):
      if line.startsWith("VmRSS:"):
        let parts = line.splitWhitespace()
        if parts.len >= 3:
          try: return parseInt(parts[1]) * 1024
          except CatchableError: return 0
    return 0
  else:
    return 0

proc countOpenFds*(): int =
  when defined(linux):
    let dir = "/proc/self/fd"
    if not dirExists(dir): return -1
    var n = 0
    for kind, _ in walkDir(dir):
      if kind in {pcFile, pcLinkToFile, pcDir, pcLinkToDir}:
        inc n
    return n
  else:
    return -1

# ---------------------------------------------------------------------------
# Open a real pty pair via openpty(3). The parent uses the master fd
# wherever it would normally have used STDIN_FILENO / STDOUT_FILENO so
# the test exercises the same code path the production library does.
# ---------------------------------------------------------------------------

when defined(linux):
  const ptyHeader = "<pty.h>"
elif defined(macosx) or defined(bsd):
  const ptyHeader = "<util.h>"
else:
  const ptyHeader = "<pty.h>"

proc cOpenpty*(amaster, aslave: ptr cint;
              name: ptr cchar;
              termp, winp: pointer): cint
  {.importc: "openpty", header: ptyHeader.}

proc openPtyPair*(): tuple[master, slave: cint] =
  ## Allocate a master/slave pty pair for tests. Both FDs are returned to
  ## the caller; the caller is responsible for closing them.
  var m, s: cint = -1
  if cOpenpty(addr m, addr s, nil, nil, nil) == -1:
    raise newException(IOError, "openpty failed")
  result = (master: m, slave: s)
