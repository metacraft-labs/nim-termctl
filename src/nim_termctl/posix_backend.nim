## nim_termctl/posix_backend.nim - POSIX backend for nim-termctl.
##
## Wraps termios save/restore, alt-screen toggling, mouse-mode toggling,
## bracketed-paste, focus reporting, ioctl(TIOCGWINSZ) for terminal size,
## SIGWINCH-via-self-pipe for async-signal-safe resize delivery, and
## SIGINT/SIGTERM/SIGHUP handlers for clean restoration on signals.
##
## Charter §1 invariants:
##   * `RawMode`, `AltScreen`, `MouseCapture`, `BracketedPaste`,
##     `FocusReporting` are value `object`s. `=copy` is disabled.
##     `=destroy` releases.
##   * No `ref object`. No raw `ptr` in the public API.
##   * `cast` only at the FFI boundary, with comments.

{.push hint[XDeclaredButNotUsed]: off.}

import std/[oserrors, posix, termios]
export termios.Termios

# SIGWINCH is not declared by std/posix - importc it directly. Same for
# the few other constants we need beyond the std/posix vocabulary.
var
  SIGWINCH {.importc, header: "<signal.h>".}: cint

# ---------------------------------------------------------------------------
# FFI declarations
# ---------------------------------------------------------------------------

type
  WinsizeC {.importc: "struct winsize", header: "<sys/ioctl.h>",
             pure, final.} = object
    ws_row: cushort
    ws_col: cushort
    ws_xpixel: cushort
    ws_ypixel: cushort

var
  TIOCGWINSZ {.importc, header: "<sys/ioctl.h>".}: culong
  EAGAIN {.importc, header: "<errno.h>".}: cint

proc cIoctl(fd: cint; request: culong): cint
  {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

# `tcgetattr`, `tcsetattr` come from std/termios as `tcGetAttr` / `tcSetAttr`.
# `cfmakeraw` is not in std/termios (BSD extension), so we declare it.
proc cCfmakeraw(t: ptr Termios)
  {.importc: "cfmakeraw", header: "<termios.h>".}

proc cWrite(fd: cint; buf: pointer; count: csize_t): clong
  {.importc: "write", header: "<unistd.h>".}

proc cRead(fd: cint; buf: pointer; count: csize_t): clong
  {.importc: "read", header: "<unistd.h>".}

proc cPipe2(p: ptr cint; flags: cint): cint
  {.importc: "pipe2", header: "<unistd.h>".}

proc cClose(fd: cint): cint
  {.importc: "close", header: "<unistd.h>".}

proc cAtexit(fn: proc () {.cdecl.}): cint
  {.importc: "atexit", header: "<stdlib.h>".}

# `STDIN_FILENO`, `STDOUT_FILENO`, `O_NONBLOCK`, `O_CLOEXEC` come from
# std/posix.  `TCSAFLUSH`, `TCSANOW` come from std/termios.

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

type
  TermctlError* = object of CatchableError
    ## Raised when a termios / ioctl / write fails.

proc raiseOSError(ctx: string) {.noreturn.} =
  let e = osLastError()
  raise newException(TermctlError,
    ctx & ": " & osErrorMsg(e) & " (errno=" & $int(e) & ")")

# ---------------------------------------------------------------------------
# Async-signal-safe restoration state.
# ---------------------------------------------------------------------------
#
# The whole point of this module is that *any* path that could leave the
# terminal in raw mode must restore it. That includes:
#   * Normal scope exit (destructor).
#   * SIGINT / SIGTERM / SIGHUP delivered while raw mode is active.
#   * `atexit` (covers `quit()` and unhandled exception paths).
#   * Panic via destructor calls during stack unwinding.
#
# All of these except the destructor must be async-signal-safe: only
# `tcsetattr` and `write(2)` are allowed - no malloc, no Nim-level
# allocation. We therefore keep the saved termios in a module-level
# variable and run the restore logic from a single C-callable function.
#
# `gActiveTty` holds the FD we last enabled raw mode on (typically
# STDIN_FILENO). `gSavedTermios` holds the original attributes.
# `gNeedsRestore` is the gate that disables double-restore.

var
  gActiveTty {.threadvar.}: cint
  gSavedTermios {.threadvar.}: Termios
  gNeedsRestore {.threadvar.}: bool
  gAltScreenActive {.threadvar.}: bool
  gMouseActive {.threadvar.}: bool
  gPasteActive {.threadvar.}: bool
  gFocusActive {.threadvar.}: bool
  gKeyReportingActive {.threadvar.}: int
    ## Which extended key reporting `enableKeyReporting` turned on: 0 none,
    ## 1 Kitty, 2 `modifyOtherKeys`. An int and not a string so the signal
    ## handler reads a word and writes a constant, allocating and freeing
    ## nothing.
  gAtexitInstalled {.threadvar.}: bool
  gSigHandlersInstalled {.threadvar.}: bool

const
  altScreenLeaveSeq = "\x1b[?1049l"
  mouseLeaveSeq = "\x1b[?1006l\x1b[?1000l"
  pasteLeaveSeq = "\x1b[?2004l"
  focusLeaveSeq = "\x1b[?1004l"
  showCursorSeqLocal = "\x1b[?25h"
  kittyPopSeqLocal = "\x1b[<u"
  modifyOtherKeysOffSeqLocal = "\x1b[>4;0m"

proc writeAllSafe(fd: cint; s: string) =
  ## Async-signal-safe `write(2)` - no Nim allocation. Used by the signal
  ## handler. Best-effort - we ignore short writes because we may be in
  ## an aborting process.
  if s.len == 0: return
  # cast: turn `cstring` into a raw `pointer` for the libc write.
  # Justified: cstring is the Nim view of the immutable string buffer;
  # no allocation, no copy.
  let buf = cstring(s)
  discard cWrite(fd, cast[pointer](buf), csize_t(s.len))

proc restoreTerminalSafe() {.cdecl.} =
  ## Async-signal-safe terminal restore. Called from atexit and from
  ## signal handlers. Idempotent - the gate flips once per acquire/release
  ## cycle.
  if not gNeedsRestore:
    return
  gNeedsRestore = false
  # Order matters: undo extended key reporting FIRST — the Kitty protocol
  # keeps one flag stack per screen, so its pop must reach the alternate
  # screen it was pushed on, before that screen is left. A terminal left in
  # disambiguate mode sends `CSI 99 ; 5 u` for Ctrl+c to the user's shell.
  # Then leave alt-screen and mouse mode so the visible output (cursor
  # visibility, normal scroll buffer) is what users see post-restore. Then
  # drop termios back to cooked.
  if gKeyReportingActive == 1:
    writeAllSafe(STDOUT_FILENO, kittyPopSeqLocal)
  elif gKeyReportingActive == 2:
    writeAllSafe(STDOUT_FILENO, modifyOtherKeysOffSeqLocal)
  gKeyReportingActive = 0
  if gAltScreenActive:
    writeAllSafe(STDOUT_FILENO, altScreenLeaveSeq)
    gAltScreenActive = false
  if gMouseActive:
    writeAllSafe(STDOUT_FILENO, mouseLeaveSeq)
    gMouseActive = false
  if gPasteActive:
    writeAllSafe(STDOUT_FILENO, pasteLeaveSeq)
    gPasteActive = false
  if gFocusActive:
    writeAllSafe(STDOUT_FILENO, focusLeaveSeq)
    gFocusActive = false
  writeAllSafe(STDOUT_FILENO, showCursorSeqLocal)
  if gActiveTty >= 0:
    discard tcSetAttr(gActiveTty, TCSAFLUSH, addr gSavedTermios)

type
  CtrlCallback* = proc () {.gcsafe.}
    ## User-supplied Ctrl-C / Ctrl-Break notification callback. Mirrors
    ## the Windows-side surface (=signals_windows.nim=) so cross-platform
    ## consumers register a single shape regardless of OS. On POSIX the
    ## callback is dispatched from the SIGINT / SIGTERM signal handler,
    ## so it MUST be async-signal-safe: no Nim allocation, no I/O beyond
    ## =write(2)= / =setEvent= equivalents. Most callers should just push
    ## a token into a self-pipe.

var
  gCtrlCallback {.threadvar.}: CtrlCallback
  gCtrlEventReceived {.threadvar.}: bool

proc onSignal(sig: cint) {.noconv.} =
  ## Signal handler. Restore terminal state, dispatch the user's Ctrl-C
  ## callback if one is registered, then re-raise the signal with the
  ## default action so the process actually dies the way it would have.
  restoreTerminalSafe()
  gCtrlEventReceived = true
  let cb = gCtrlCallback
  if cb != nil:
    try:
      cb()
    except CatchableError:
      discard
  # Reset to default and re-raise so default action (terminate) runs.
  var sa = Sigaction()
  sa.sa_handler = SIG_DFL
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(sig, sa, nil)
  discard kill(getpid(), sig)

let FatalSignals = [SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT]
  ## A CRASH. The process is dying either way; what is ours to do is give the
  ## terminal back first — a terminal left in the alternate screen, in raw
  ## mode, or with the Kitty keyboard protocol on (`Ctrl+c` arriving at the
  ## user's shell as `CSI 99 ; 5 u`) is the crash's damage outliving it.
  ##
  ## `let`, NOT `const`, and that is forced by the platform rather than a
  ## preference. Nim's `posix` module defines these as compile-time values on
  ## Linux (`posix_linux_amd64_consts.nim`: `const SIGSEGV* = cint(11)`) but
  ## as C globals read from the header everywhere else
  ## (`posix_other_consts.nim`: `var SIGSEGV* {.importc: "SIGSEGV",
  ## header: "<signal.h>".}: cint`), which is what macOS uses. A `const`
  ## array of them therefore compiles on Linux and CANNOT compile on macOS:
  ## `Error: cannot evaluate at compile time: SIGSEGV`. Nothing here needs
  ## them at compile time — both uses below are ordinary runtime loops.

var gPreviousFatal: array[FatalSignals.len, Sigaction]
  ## Whatever handled each fatal signal before us (the language runtime's
  ## stack-trace printer, or the default). Not thread-local: a crash is
  ## delivered to whichever thread faulted.

proc onFatalSignal(sig: cint) {.noconv.} =
  ## Restore the terminal, then hand the signal back to the handler that was
  ## there before: reinstate it and raise the signal again. The signal is
  ## blocked while this handler runs, so the re-raise is delivered — to the
  ## previous action — the moment this returns, whether the crash was a real
  ## fault or a `kill`.
  restoreTerminalSafe()
  for i, fatal in FatalSignals:
    if fatal == sig:
      discard sigaction(sig, gPreviousFatal[i], nil)
  discard kill(getpid(), sig)

proc installSignalHandlers() =
  if gSigHandlersInstalled: return
  gSigHandlersInstalled = true
  var sa = Sigaction()
  sa.sa_handler = onSignal
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(SIGINT, sa, nil)
  discard sigaction(SIGTERM, sa, nil)
  discard sigaction(SIGHUP, sa, nil)
  discard sigaction(SIGQUIT, sa, nil)
  var fatal = Sigaction()
  fatal.sa_handler = onFatalSignal
  discard sigemptyset(fatal.sa_mask)
  fatal.sa_flags = 0
  for i, sig in FatalSignals:
    discard sigaction(sig, fatal, addr gPreviousFatal[i])

proc installCtrlCHandler*(callback: CtrlCallback) =
  ## POSIX-side parity surface for the Windows =installCtrlCHandler=. On
  ## POSIX the underlying signals are SIGINT / SIGTERM / SIGHUP /
  ## SIGQUIT (which the existing =installSignalHandlers= already wires
  ## up); this proc just slots the user callback into the same handler.
  ##
  ## Idempotent: calling it twice replaces the callback in place and
  ## does not re-register the underlying =sigaction=.
  gCtrlCallback = callback
  installSignalHandlers()

proc uninstallCtrlCHandler*() =
  ## Drop the user callback and reset the SIG_DFL sigactions for the
  ## four signals we manage. Intended for tests; production code rarely
  ## needs to uninstall (process is exiting).
  gCtrlCallback = nil
  if not gSigHandlersInstalled: return
  gSigHandlersInstalled = false
  var sa = Sigaction()
  sa.sa_handler = SIG_DFL
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(SIGINT, sa, nil)
  discard sigaction(SIGTERM, sa, nil)
  discard sigaction(SIGHUP, sa, nil)
  discard sigaction(SIGQUIT, sa, nil)

proc ctrlEventReceived*(): bool {.inline.} =
  ## True if a Ctrl-C / SIGINT / SIGTERM handler has fired since the last
  ## reset. Mirrors the Windows surface for cross-platform tests.
  gCtrlEventReceived

proc resetCtrlEventReceived*() {.inline.} =
  ## Clear the =ctrlEventReceived= flag. Tests call this between cases.
  gCtrlEventReceived = false

proc atexitTrampoline() {.cdecl.} =
  restoreTerminalSafe()

proc installAtexit() =
  if gAtexitInstalled: return
  gAtexitInstalled = true
  discard cAtexit(atexitTrampoline)

# ---------------------------------------------------------------------------
# RawMode handle
# ---------------------------------------------------------------------------

type
  RawMode* = object
    ## RAII handle for raw-mode acquisition. While alive, the terminal is
    ## in raw mode; on destruction (or signal/atexit) it returns to the
    ## previously-saved attributes.
    ##
    ## Charter §1: value `object`, no `ref`, `=copy` disabled, `=destroy`
    ## releases.
    fd*: cint
    saved*: Termios
    active*: bool

proc `=copy`*(dest: var RawMode; src: RawMode) {.error.}
  ## Raw-mode acquisition is a unique-ownership token. Move via `sink`.

proc disableRawModeImpl(rm: var RawMode) =
  if not rm.active: return
  rm.active = false
  # Local termios restore - the global `restoreTerminalSafe` would also
  # do this, but we want to clear the global gate too so other handles
  # don't double-restore.
  discard tcSetAttr(rm.fd, TCSAFLUSH, addr rm.saved)
  if gNeedsRestore and gActiveTty == rm.fd:
    gNeedsRestore = false
    gActiveTty = -1

template rawModeDestroyBody(rm: untyped) =
  ## Shared body for the two destructor signatures (gcDestructors vs refc).
  ## Charter rule: don't `= discard` here; the synthesized destructor of
  ## the embedded `Termios` (a plain object) is trivial, so we can take
  ## over the body.
  if rm.active:
    discard tcSetAttr(rm.fd, TCSAFLUSH, addr rm.saved)
    if gNeedsRestore and gActiveTty == rm.fd:
      gNeedsRestore = false
      gActiveTty = -1

when defined(gcDestructors):
  proc `=destroy`*(rm: RawMode) =
    rawModeDestroyBody(rm)
else:
  proc `=destroy`*(rm: var RawMode) =
    rawModeDestroyBody(rm)

proc enableRawMode*(fd: cint = STDIN_FILENO): RawMode =
  ## Save the current termios on `fd` and switch to raw. Installs the
  ## signal/atexit handlers on first call so SIGINT etc. restore even if
  ## the destructor doesn't get to run.
  ##
  ## The returned `RawMode` value owns the restoration responsibility.
  ## Drop it (let it go out of scope, or move it into a `defer`) and the
  ## terminal returns to cooked.
  var saved: Termios
  if tcGetAttr(fd, addr saved) != 0:
    raiseOSError("tcgetattr")
  var raw = saved
  cCfmakeraw(addr raw)
  if tcSetAttr(fd, TCSAFLUSH, addr raw) != 0:
    raiseOSError("tcsetattr (raw)")
  gActiveTty = fd
  gSavedTermios = saved
  gNeedsRestore = true
  installSignalHandlers()
  installAtexit()
  result = RawMode(fd: fd, saved: saved, active: true)

proc disableRawMode*(rm: var RawMode) =
  ## Explicit release. Idempotent.
  disableRawModeImpl(rm)

proc isActive*(rm: RawMode): bool {.inline.} = rm.active

proc savedAttributes*(rm: RawMode): Termios {.inline.} = rm.saved
  ## Read-only view of the saved attributes. Tests use this to verify the
  ## save/restore round-trip.

# ---------------------------------------------------------------------------
# AltScreen handle
# ---------------------------------------------------------------------------

type
  AltScreen* = object
    ## RAII handle for alt-screen acquisition.
    fd*: cint
    active*: bool

proc `=copy`*(dest: var AltScreen; src: AltScreen) {.error.}

proc writeStringRaw*(fd: cint; s: string) =
  ## Synchronous write to a raw FD. Returns silently on EAGAIN/EINTR.
  if s.len == 0: return
  var written: int = 0
  while written < s.len:
    # cast: see writeAllSafe rationale - bridge openArray[byte]/string to
    # the libc pointer. Charter-justified: FFI boundary only.
    let p = cast[pointer](addr s[written])
    let n = cWrite(fd, p, csize_t(s.len - written))
    if n == -1:
      let e = osLastError()
      if cint(e) == EINTR or cint(e) == EAGAIN:
        continue
      raiseOSError("write")
    written += int(n)

template altScreenDestroyBody(a: untyped) =
  if a.active:
    discard cWrite(a.fd, cast[pointer](cstring("\x1b[?1049l")),
                   csize_t("\x1b[?1049l".len))
    if gAltScreenActive:
      gAltScreenActive = false

when defined(gcDestructors):
  proc `=destroy`*(a: AltScreen) =
    altScreenDestroyBody(a)
else:
  proc `=destroy`*(a: var AltScreen) =
    altScreenDestroyBody(a)

proc enterAltScreen*(fd: cint = STDOUT_FILENO): AltScreen =
  ## DEC mode 1049: switch to alt-screen, save cursor, clear. The
  ## destructor sends `?1049l` which restores the original screen.
  writeStringRaw(fd, "\x1b[?1049h")
  gAltScreenActive = true
  result = AltScreen(fd: fd, active: true)

proc leaveAltScreen*(a: var AltScreen) =
  if not a.active: return
  writeStringRaw(a.fd, "\x1b[?1049l")
  a.active = false
  gAltScreenActive = false

# ---------------------------------------------------------------------------
# Extended key reporting (the Kitty keyboard protocol, xterm modifyOtherKeys)
# ---------------------------------------------------------------------------

type
  KeyReportingMode* = enum
    ## How the terminal is asked to report keys.
    krmKitty        ## Kitty progressive enhancement, flag 1 (disambiguate)
    krmModifyOtherKeys ## xterm `modifyOtherKeys` level 2

  KeyReporting* = object
    ## RAII handle for extended key reporting. While alive the terminal
    ## reports modified keys unambiguously; on destruction, on
    ## `disableKeyReporting`, and from the signal / atexit restore, the mode is
    ## undone — the Kitty flags popped, `modifyOtherKeys` reset.
    fd*: cint
    mode*: KeyReportingMode
    active*: bool

const
  KittyPushDisambiguateSeq* = "\x1b[>1u"
  KittyPopSeq* = "\x1b[<u"
  ModifyOtherKeysOnSeq* = "\x1b[>4;2m"
  ModifyOtherKeysOffSeq* = "\x1b[>4;0m"

func keyReportingLeaveSeq*(mode: KeyReportingMode): string =
  ## The bytes that undo `mode`.
  case mode
  of krmKitty: KittyPopSeq
  of krmModifyOtherKeys: ModifyOtherKeysOffSeq

proc `=copy`*(dest: var KeyReporting; src: KeyReporting) {.error.}

template keyReportingDestroyBody(k: untyped) =
  if k.active:
    let leave = keyReportingLeaveSeq(k.mode)
    discard cWrite(k.fd, cast[pointer](cstring(leave)), csize_t(leave.len))
    gKeyReportingActive = 0

when defined(gcDestructors):
  proc `=destroy`*(k: KeyReporting) = keyReportingDestroyBody(k)
else:
  proc `=destroy`*(k: var KeyReporting) = keyReportingDestroyBody(k)

proc enableKeyReporting*(mode: KeyReportingMode;
                        fd: cint = STDOUT_FILENO): KeyReporting =
  ## Ask the terminal for extended key reporting. Call AFTER `enterAltScreen`:
  ## the Kitty flag stack is per screen. The undo sequence is registered with
  ## the async-signal-safe restore before this returns, so a SIGTERM, a SIGHUP
  ## or a crash from here on leaves the terminal in its legacy encoding.
  gKeyReportingActive = (if mode == krmKitty: 1 else: 2)
  case mode
  of krmKitty: writeStringRaw(fd, KittyPushDisambiguateSeq)
  of krmModifyOtherKeys: writeStringRaw(fd, ModifyOtherKeysOnSeq)
  result = KeyReporting(fd: fd, mode: mode, active: true)

proc disableKeyReporting*(k: var KeyReporting) =
  if not k.active: return
  writeStringRaw(k.fd, keyReportingLeaveSeq(k.mode))
  k.active = false
  gKeyReportingActive = 0

# ---------------------------------------------------------------------------
# Mouse capture / bracketed paste / focus reporting
# ---------------------------------------------------------------------------

type
  MouseCapture* = object
    fd*: cint
    active*: bool
  BracketedPaste* = object
    fd*: cint
    active*: bool
  FocusReporting* = object
    fd*: cint
    active*: bool

proc `=copy`*(dest: var MouseCapture; src: MouseCapture) {.error.}
proc `=copy`*(dest: var BracketedPaste; src: BracketedPaste) {.error.}
proc `=copy`*(dest: var FocusReporting; src: FocusReporting) {.error.}

template mouseDestroyBody(m: untyped) =
  if m.active:
    discard cWrite(m.fd, cast[pointer](cstring("\x1b[?1006l\x1b[?1000l")),
                   csize_t("\x1b[?1006l\x1b[?1000l".len))
    if gMouseActive: gMouseActive = false

template pasteDestroyBody(b: untyped) =
  if b.active:
    discard cWrite(b.fd, cast[pointer](cstring("\x1b[?2004l")),
                   csize_t("\x1b[?2004l".len))
    if gPasteActive: gPasteActive = false

template focusDestroyBody(f: untyped) =
  if f.active:
    discard cWrite(f.fd, cast[pointer](cstring("\x1b[?1004l")),
                   csize_t("\x1b[?1004l".len))
    if gFocusActive: gFocusActive = false

when defined(gcDestructors):
  proc `=destroy`*(m: MouseCapture) = mouseDestroyBody(m)
  proc `=destroy`*(b: BracketedPaste) = pasteDestroyBody(b)
  proc `=destroy`*(f: FocusReporting) = focusDestroyBody(f)
else:
  proc `=destroy`*(m: var MouseCapture) = mouseDestroyBody(m)
  proc `=destroy`*(b: var BracketedPaste) = pasteDestroyBody(b)
  proc `=destroy`*(f: var FocusReporting) = focusDestroyBody(f)

proc enableMouseCapture*(fd: cint = STDOUT_FILENO): MouseCapture =
  ## Enable mouse reporting in SGR-1006 mode (the modern format - no
  ## coordinate truncation past column 95).
  writeStringRaw(fd, "\x1b[?1000h\x1b[?1006h")
  gMouseActive = true
  result = MouseCapture(fd: fd, active: true)

proc disableMouseCapture*(m: var MouseCapture) =
  if not m.active: return
  writeStringRaw(m.fd, "\x1b[?1006l\x1b[?1000l")
  m.active = false
  gMouseActive = false

proc enableBracketedPaste*(fd: cint = STDOUT_FILENO): BracketedPaste =
  writeStringRaw(fd, "\x1b[?2004h")
  gPasteActive = true
  result = BracketedPaste(fd: fd, active: true)

proc disableBracketedPaste*(b: var BracketedPaste) =
  if not b.active: return
  writeStringRaw(b.fd, "\x1b[?2004l")
  b.active = false
  gPasteActive = false

proc enableFocusReporting*(fd: cint = STDOUT_FILENO): FocusReporting =
  writeStringRaw(fd, "\x1b[?1004h")
  gFocusActive = true
  result = FocusReporting(fd: fd, active: true)

proc disableFocusReporting*(f: var FocusReporting) =
  if not f.active: return
  writeStringRaw(f.fd, "\x1b[?1004l")
  f.active = false
  gFocusActive = false

# ---------------------------------------------------------------------------
# Terminal queries
# ---------------------------------------------------------------------------

proc terminalSize*(fd: cint = STDOUT_FILENO): tuple[cols, rows: int] =
  ## Returns the current terminal size via `ioctl(TIOCGWINSZ)`. Raises
  ## `TermctlError` on failure (e.g. when `fd` isn't a tty).
  var ws = WinsizeC()
  if cIoctl(fd, TIOCGWINSZ, addr ws) == -1:
    raiseOSError("ioctl(TIOCGWINSZ)")
  (cols: int(ws.ws_col), rows: int(ws.ws_row))

# ---------------------------------------------------------------------------
# SIGWINCH self-pipe
# ---------------------------------------------------------------------------
#
# Async-signal-safe path: SIGWINCH handler writes a single byte to a
# non-blocking pipe; pollers select on the read end and consume bytes
# in the foreground. The handler itself does NOT call ioctl - that
# might allocate or be interrupted again. The reader does the real work.

var
  gWinchPipeR {.threadvar.}: cint
  gWinchPipeW {.threadvar.}: cint
  gWinchHandlerInstalled {.threadvar.}: bool

proc onWinch(sig: cint) {.noconv.} =
  if gWinchPipeW >= 0:
    var b: byte = 1
    discard cWrite(gWinchPipeW, addr b, csize_t(1))

proc winchPipeReadFd*(): cint =
  ## The read end of the SIGWINCH pipe. `event.nim` selects on this
  ## alongside stdin. Returns -1 if `installWinch` hasn't been called.
  gWinchPipeR

proc drainWinchPipe*() =
  ## Consume any pending SIGWINCH notifications.  Returns immediately if
  ## the pipe isn't installed.
  if gWinchPipeR < 0: return
  var buf: array[64, byte]
  while true:
    let n = cRead(gWinchPipeR, addr buf[0], csize_t(buf.len))
    if n <= 0: break
    if n < buf.len.clong: break

proc installWinchHandler*() =
  ## Install a SIGWINCH handler that writes to a self-pipe. Idempotent.
  if gWinchHandlerInstalled:
    return
  gWinchHandlerInstalled = true
  var fds: array[2, cint]
  if cPipe2(addr fds[0], O_NONBLOCK or O_CLOEXEC) != 0:
    raiseOSError("pipe2 (winch)")
  gWinchPipeR = fds[0]
  gWinchPipeW = fds[1]
  var sa = Sigaction()
  sa.sa_handler = onWinch
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = SA_RESTART
  discard sigaction(SIGWINCH, sa, nil)

proc uninstallWinchHandler*() =
  ## Reverse `installWinchHandler`. Tests that exercise multiple installs
  ## use this to reset state between cases.
  if not gWinchHandlerInstalled: return
  var sa = Sigaction()
  sa.sa_handler = SIG_DFL
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(SIGWINCH, sa, nil)
  if gWinchPipeR >= 0:
    discard cClose(gWinchPipeR); gWinchPipeR = -1
  if gWinchPipeW >= 0:
    discard cClose(gWinchPipeW); gWinchPipeW = -1
  gWinchHandlerInstalled = false

# ---------------------------------------------------------------------------
# Test-only hooks
# ---------------------------------------------------------------------------

proc isTty*(fd: cint): bool {.inline.} =
  ## True if `fd` refers to a real terminal device. Used by tests to
  ## skip themselves when running under CI without a tty.
  isatty(fd) == 1

proc rawSavedFd*(): cint {.inline.} = gActiveTty
proc rawNeedsRestore*(): bool {.inline.} = gNeedsRestore
  ## Test-only introspection of the global restore gate.

{.pop.}
