## nim_termctl/event.nim - typed events from the terminal.
##
## All public types are value `object` / `enum`. `Event` is a typed
## variant that callers consume via `case ev.kind`. No `ref`s.

import std/unicode

type
  EventKind* = enum
    ekKey, ekMouse, ekResize, ekFocus, ekPaste

  KeyCode* = enum
    ## Named key codes. `kcChar` means "see `rune`"; everything else is a
    ## non-printable named key.
    kcChar
    kcEnter
    kcEsc
    kcTab
    kcBackTab
    kcBackspace
    kcInsert
    kcDelete
    kcHome
    kcEnd
    kcPageUp
    kcPageDown
    kcUp
    kcDown
    kcLeft
    kcRight
    kcF1, kcF2, kcF3, kcF4, kcF5, kcF6,
    kcF7, kcF8, kcF9, kcF10, kcF11, kcF12
    kcUnknown

  KeyMod* = enum
    kmShift, kmCtrl, kmAlt, kmSuper, kmHyper, kmMeta, kmCapsLock, kmNumLock

  KeyMods* = set[KeyMod]

  KeyEventKind* = enum
    ## Press/Repeat/Release - only Press/Release are meaningful without
    ## the Kitty keyboard protocol enabled. Repeat fires for held keys
    ## under Kitty's progressive enhancement.
    kkPress, kkRepeat, kkRelease

  KeyEvent* = object
    code*: KeyCode
    rune*: Rune
      ## Only meaningful when `code == kcChar`.
    mods*: KeyMods
    kind*: KeyEventKind
    state*: uint8
      ## Lock-key state (Caps/Num/Scroll/etc.) under Kitty protocol.

  MouseKind* = enum
    mkDown, mkUp, mkDrag, mkMoved,
    mkScrollUp, mkScrollDown, mkScrollLeft, mkScrollRight

  MouseButton* = enum
    mbNone, mbLeft, mbMiddle, mbRight

  MouseEvent* = object
    kind*: MouseKind
    button*: MouseButton
    col*: int  ## 1-based.
    row*: int  ## 1-based.
    mods*: KeyMods

  ResizeEvent* = object
    cols*: int
    rows*: int

  FocusEvent* = object
    gained*: bool

  Event* = object
    case kind*: EventKind
    of ekKey: key*: KeyEvent
    of ekMouse: mouse*: MouseEvent
    of ekResize: resize*: ResizeEvent
    of ekFocus: focus*: FocusEvent
    of ekPaste: paste*: string

# ---------------------------------------------------------------------------
# Comparison helpers - tests use these.
# ---------------------------------------------------------------------------

proc `==`*(a, b: KeyEvent): bool =
  a.code == b.code and a.rune == b.rune and a.mods == b.mods and
    a.kind == b.kind and a.state == b.state

proc `==`*(a, b: MouseEvent): bool =
  a.kind == b.kind and a.button == b.button and
    a.col == b.col and a.row == b.row and a.mods == b.mods

proc `==`*(a, b: ResizeEvent): bool =
  a.cols == b.cols and a.rows == b.rows

proc `==`*(a, b: FocusEvent): bool =
  a.gained == b.gained

proc `==`*(a, b: Event): bool =
  if a.kind != b.kind: return false
  case a.kind
  of ekKey: a.key == b.key
  of ekMouse: a.mouse == b.mouse
  of ekResize: a.resize == b.resize
  of ekFocus: a.focus == b.focus
  of ekPaste: a.paste == b.paste

# ---------------------------------------------------------------------------
# Convenient builders for tests / users.
# ---------------------------------------------------------------------------

proc charKey*(c: char; mods: KeyMods = {}): KeyEvent =
  KeyEvent(code: kcChar, rune: Rune(ord(c)), mods: mods,
           kind: kkPress, state: 0)

proc namedKey*(code: KeyCode; mods: KeyMods = {}): KeyEvent =
  KeyEvent(code: code, rune: Rune(0), mods: mods, kind: kkPress, state: 0)
