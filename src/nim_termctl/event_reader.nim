## nim_termctl/event_reader.nim - blocking and non-blocking event reads.
##
## Wraps `parser.nim` with the I/O machinery that drains stdin into the
## parser. POSIX uses `select(2)` on stdin + the SIGWINCH self-pipe so
## resizes interleave correctly with key/mouse events. Windows reads
## from the input handle (real implementation deferred alongside the
## structured-record decoder).
##
## Usage:
##
## ```nim
## var er = newEventReader()
## while true:
##   let ev = pollEvent(er, initDuration(milliseconds = 100))
##   if ev.isSome:
##     ...
## ```

import std/[options, monotimes, times, oserrors]
import ./parser
import ./event

when defined(windows):
  import ./windows_backend
else:
  import std/posix
  import ./posix_backend

type
  EventReader* = object
    ## Owns the parser plus a small read buffer. Hold by value; no
    ## destructor needed (the parser, buffer, and queue are all plain
    ## owned types managed by Nim's synthesized destructor).
    parser*: Parser
    readBuf*: array[4096, byte]
    fd*: cint  ## Input FD - usually STDIN_FILENO.

proc `=copy`*(dest: var EventReader; src: EventReader) {.error.}

proc newEventReader*(fd: cint = STDIN_FILENO): EventReader =
  result.parser = initParser()
  result.fd = fd

proc enableKittyKeyboard*(er: var EventReader) =
  ## Tell the *parser* to decode `CSI ... u` as Kitty events. Does not
  ## emit the protocol-enable escape - call `pushKittyKeyboardSeq()` and
  ## write it yourself if you want the terminal to actually start
  ## sending Kitty events.
  enableKittyKeyboard(er.parser)

proc pushKittyKeyboardSeq*(flags: int = 1): string =
  ## Build the CSI `>{flags}u` sequence to push Kitty progressive
  ## enhancement flags. Default `flags=1` enables disambiguation.
  "\x1b[>" & $flags & "u"

proc popKittyKeyboardSeq*(): string = "\x1b[<u"

# ---------------------------------------------------------------------------
# POSIX poll/read implementation.
# ---------------------------------------------------------------------------

when not defined(windows):

  proc readSomeInto(er: var EventReader): int =
    ## Non-blocking read of up to readBuf.len bytes. Returns 0 on
    ## EAGAIN/EOF; -1 on real errors (rare).
    let n = posix.read(er.fd, addr er.readBuf[0], er.readBuf.len)
    if n > 0:
      er.parser.feed(er.readBuf.toOpenArray(0, int(n) - 1))
      return int(n)
    if n == 0:
      er.parser.flush()
      return 0
    let e = osLastError()
    if cint(e) == EAGAIN or cint(e) == EINTR:
      return 0
    return -1

  proc pollEvent*(er: var EventReader; timeout: Duration): Option[Event] =
    ## Returns the next event if one arrives within `timeout`. Bytes
    ## that don't yet form a complete event accumulate in the parser's
    ## internal buffer and resolve on the next call.
    if er.parser.pending() > 0:
      return er.parser.pop()
    er.parser.tick()
    if er.parser.pending() > 0:
      return er.parser.pop()
    let deadline = getMonoTime() + timeout
    while true:
      var rs: TFdSet
      FD_ZERO(rs)
      FD_SET(er.fd, rs)
      var maxFd = er.fd
      let winchFd = winchPipeReadFd()
      if winchFd >= 0:
        FD_SET(winchFd, rs)
        if winchFd > maxFd: maxFd = winchFd
      let now = getMonoTime()
      if now >= deadline: return none(Event)
      let remaining = deadline - now
      var tv: Timeval
      tv.tv_sec = posix.Time(remaining.inSeconds)
      let ms = remaining.inMilliseconds - remaining.inSeconds * 1000
      tv.tv_usec = clong(ms * 1000)
      let n = select(cint(maxFd) + 1, addr rs, nil, nil, addr tv)
      if n == 0:
        # Tick the parser before giving up - a pending bare-Escape may
        # have aged past the disambiguation window.
        er.parser.tick()
        if er.parser.pending() > 0:
          return er.parser.pop()
        return none(Event)
      if n == -1:
        let e = osLastError()
        if cint(e) == EINTR: continue
        return none(Event)
      if winchFd >= 0 and FD_ISSET(winchFd, rs) != 0:
        drainWinchPipe()
        let sz = terminalSize()
        return some(Event(kind: ekResize,
                          resize: ResizeEvent(cols: sz.cols, rows: sz.rows)))
      if FD_ISSET(er.fd, rs) != 0:
        discard readSomeInto(er)
        if er.parser.pending() > 0:
          return er.parser.pop()
      # Loop again; partial sequence still in flight.

  proc readEvent*(er: var EventReader): Event =
    ## Blocking read until an event arrives.
    while true:
      let ev = pollEvent(er, initDuration(seconds = 365 * 24 * 3600))
      if ev.isSome: return ev.get()
else:
  proc pollEvent*(er: var EventReader; timeout: Duration): Option[Event] =
    raise newException(TermctlUnimplementedError,
      "Windows event reader is deferred - structured-record decoder " &
      "ships alongside the ConPTY backend")
  proc readEvent*(er: var EventReader): Event =
    raise newException(TermctlUnimplementedError,
      "Windows event reader is deferred")

# ---------------------------------------------------------------------------
# Direct byte-feed - used by tests that pump a corpus through the parser
# without involving real stdin.
# ---------------------------------------------------------------------------

proc feedBytes*(er: var EventReader; bytes: openArray[byte]) =
  ## Feed bytes directly to the parser. Used by tests and by callers
  ## that read stdin themselves and want only the parsing logic.
  er.parser.feed(bytes)

proc feedString*(er: var EventReader; s: string) =
  if s.len == 0: return
  var b = newSeq[byte](s.len)
  for i in 0 ..< s.len: b[i] = byte(s[i])
  er.parser.feed(b)

proc drain*(er: var EventReader): seq[Event] =
  ## Pop every event currently in the queue. Used by tests.
  while er.parser.pending() > 0:
    let ev = er.parser.pop()
    if ev.isNone: break
    result.add ev.get()
