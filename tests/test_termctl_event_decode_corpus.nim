## tests/test_termctl_event_decode_corpus.nim - L3 spec test.
##
## Feed a small but representative corpus of byte streams through the
## parser and assert on the typed events that come out. The corpus
## covers:
##
##   * Plain ASCII / UTF-8 keystrokes
##   * Control characters (Ctrl-letter, Tab, Enter, Backspace)
##   * Arrow keys (CSI form)
##   * Function keys (CSI ~ form for F5+, CSI <letter> for F1-F4)
##   * Modifier-mod arrows (CSI 1;5A = Ctrl+Up)
##   * SGR mouse press/release/drag (CSI < ... M / m)
##   * Bracketed paste (\x1b[200~ ... \x1b[201~)
##   * Focus events (\x1b[I and \x1b[O)
##   * Bare Escape via the `flush()` path
##
## All events are compared structurally - no mocks, no parsing of the
## byte stream by hand in the test.

import std/[unittest, unicode]
import nim_termctl

proc parse(s: string): seq[Event] =
  ## Run the parser over `s` and return the queued events.
  var er = newEventReader()
  er.feedString(s)
  er.parser.flush()
  result = drain(er)

suite "L3: event decode corpus":

  test "plain ASCII -> char keys":
    let evs = parse("abc")
    check evs.len == 3
    check evs[0] == Event(kind: ekKey, key: charKey('a'))
    check evs[1] == Event(kind: ekKey, key: charKey('b'))
    check evs[2] == Event(kind: ekKey, key: charKey('c'))

  test "UTF-8 multi-byte rune across one feed":
    # 'ä' = 0xC3 0xA4
    let evs = parse("\xC3\xA4")
    check evs.len == 1
    check evs[0].kind == ekKey
    check evs[0].key.code == kcChar
    check evs[0].key.rune == Rune(0x00E4)

  test "UTF-8 emoji split across two feeds":
    # '🦀' = U+1F980 = 0xF0 0x9F 0xA6 0x80
    var er = newEventReader()
    er.feedString("\xF0\x9F")
    er.feedString("\xA6\x80")
    let evs = drain(er)
    check evs.len == 1
    check evs[0].kind == ekKey
    check evs[0].key.rune == Rune(0x1F980)

  test "control characters":
    let evs = parse("\x01\x09\x0D\x7F")
    check evs.len == 4
    # Ctrl+A
    check evs[0].kind == ekKey
    check evs[0].key.mods == {kmCtrl}
    # Tab
    check evs[1].kind == ekKey
    check evs[1].key.code == kcTab
    # Enter
    check evs[2].kind == ekKey
    check evs[2].key.code == kcEnter
    # Backspace (DEL)
    check evs[3].kind == ekKey
    check evs[3].key.code == kcBackspace

  test "arrow keys (CSI form)":
    let evs = parse("\x1b[A\x1b[B\x1b[C\x1b[D")
    check evs.len == 4
    check evs[0].key.code == kcUp
    check evs[1].key.code == kcDown
    check evs[2].key.code == kcRight
    check evs[3].key.code == kcLeft

  test "Ctrl+Up (CSI 1;5A)":
    let evs = parse("\x1b[1;5A")
    check evs.len == 1
    check evs[0].key.code == kcUp
    check evs[0].key.mods == {kmCtrl}

  test "function keys F1-F4 (SS3)":
    let evs = parse("\x1bOP\x1bOQ\x1bOR\x1bOS")
    check evs.len == 4
    check evs[0].key.code == kcF1
    check evs[1].key.code == kcF2
    check evs[2].key.code == kcF3
    check evs[3].key.code == kcF4

  test "function keys F5/F6 (CSI ~)":
    let evs = parse("\x1b[15~\x1b[17~")
    check evs.len == 2
    check evs[0].key.code == kcF5
    check evs[1].key.code == kcF6

  test "Home/End/PgUp/PgDn (CSI ~)":
    let evs = parse("\x1b[1~\x1b[4~\x1b[5~\x1b[6~")
    check evs.len == 4
    check evs[0].key.code == kcHome
    check evs[1].key.code == kcEnd
    check evs[2].key.code == kcPageUp
    check evs[3].key.code == kcPageDown

  test "SGR mouse press at (10, 5)":
    # CSI < 0 ; 10 ; 5 M  (left button down)
    let evs = parse("\x1b[<0;10;5M")
    check evs.len == 1
    check evs[0].kind == ekMouse
    check evs[0].mouse.kind == mkDown
    check evs[0].mouse.button == mbLeft
    check evs[0].mouse.col == 10
    check evs[0].mouse.row == 5

  test "SGR mouse release at (10, 5)":
    # CSI < 0 ; 10 ; 5 m
    let evs = parse("\x1b[<0;10;5m")
    check evs.len == 1
    check evs[0].kind == ekMouse
    check evs[0].mouse.kind == mkUp

  test "SGR mouse scroll up":
    let evs = parse("\x1b[<64;1;1M")
    check evs.len == 1
    check evs[0].kind == ekMouse
    check evs[0].mouse.kind == mkScrollUp

  test "bracketed paste":
    let evs = parse("\x1b[200~hello\x1b[201~")
    check evs.len == 1
    check evs[0].kind == ekPaste
    check evs[0].paste == "hello"

  test "focus in / focus out":
    let evs = parse("\x1b[I\x1b[O")
    check evs.len == 2
    check evs[0].kind == ekFocus
    check evs[0].focus.gained
    check evs[1].kind == ekFocus
    check (not evs[1].focus.gained)

  test "bare escape via flush":
    var er = newEventReader()
    er.feedString("\x1b")
    # Without flush, the parser is in psEscaped waiting for a follow-up.
    check er.parser.pending() == 0
    er.parser.flush()
    let evs = drain(er)
    check evs.len == 1
    check evs[0].key.code == kcEsc

  test "Alt+letter via ESC-prefix":
    let evs = parse("\x1ba")
    check evs.len == 1
    check evs[0].key.code == kcChar
    check evs[0].key.rune == Rune(int('a'))
    check evs[0].key.mods == {kmAlt}

  test "Shift+Tab":
    let evs = parse("\x1b[Z")
    check evs.len == 1
    check evs[0].key.code == kcBackTab
    check evs[0].key.mods == {kmShift}

  test "incremental CSI feeding (split mid-sequence)":
    var er = newEventReader()
    er.feedString("\x1b[")
    er.feedString("1;5")
    er.feedString("A")
    let evs = drain(er)
    check evs.len == 1
    check evs[0].key.code == kcUp
    check evs[0].key.mods == {kmCtrl}
