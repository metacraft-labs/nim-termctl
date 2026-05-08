## nim_termctl/parser.nim - byte-stream -> typed-event parser.
##
## Stateful, incremental parser. Mirrors the shape of Textual's
## `_xterm_parser.py` but in pure Nim and with the full event type from
## `event.nim`. Owned types are value `object`s.
##
## Responsibilities:
##   * Split incoming bytes into typed events: keys, mouse, resize, focus,
##     paste, plain runes.
##   * Handle partial UTF-8 across reads (a 4-byte emoji split across two
##     reads must coalesce).
##   * Handle partial CSI / SS3 / DCS / OSC across reads (the user might
##     receive `\x1b[1` and then `;2H` in two separate `read` calls).
##   * Disambiguate bare-ESC (a real Escape key) from the start of an
##     ESC-prefixed sequence via an `escDelay` timeout. Configured at
##     32 ms by default - matches Crossterm's `ESCAPE_DELAY`.
##   * Decode SGR-1006 mouse, bracketed paste content, focus events (in/out),
##     Kitty extended keyboard, and modify-other-keys.
##
## The parser does NOT do I/O. It accepts `feed(bytes)` and emits
## `Event`s into an internal queue that callers drain via `poll()`. The
## actual stdin reading happens in `event.nim` against the POSIX or
## Windows backend.

import std/[options, monotimes, times, unicode, strutils]
import ./event

const
  escapeDelayMs* = 32
    ## Default bare-Escape disambiguation window. Pressing Escape and then
    ## a key fast enough that the terminal merges them into ESC<key> is
    ## indistinguishable from Alt+<key> at the byte level - we resolve
    ## ambiguity by waiting `escapeDelayMs` for a continuation; if none
    ## arrives, emit a bare Escape.

type
  ParserState* = enum
    ## Parser FSM state. We track exactly one branch at a time so partial
    ## buffers stay coherent across `feed` calls.
    psGround       ## No partial sequence in flight.
    psEscaped      ## Saw ESC; awaiting continuation byte or `escDelay`.
    psCsi          ## Saw ESC[ ; collecting CSI parameters/intermediates.
    psSs3          ## Saw ESCO ; collecting one SS3 final byte.
    psOsc          ## Saw ESC] ; collecting until BEL or ST.
    psDcs          ## Saw ESCP ; collecting until ST.
    psApc          ## Saw ESC_ ; collecting until ST.
    psPaste        ## Inside a bracketed-paste body.
    psUtf8         ## Mid UTF-8 codepoint.

  Parser* = object
    ## Incremental byte-stream parser. Hold by value; no destructor needed.
    state*: ParserState
    buf*: string
      ## Accumulator for the current sequence (CSI parameters, OSC body,
      ## paste content, partial UTF-8, ...). Cleared when the parser
      ## emits or transitions back to ground.
    pasteBuf*: string
      ## Separate buffer for paste content - paste can contain ESC bytes
      ## that would otherwise look like sequence starts.
    utf8Need*: int
      ## Bytes still needed to complete a UTF-8 codepoint when `state ==
      ## psUtf8`.
    utf8Have*: string
      ## Bytes accumulated for the current UTF-8 codepoint.
    queue*: seq[Event]
      ## Decoded events ready to be drained.
    escapeStartedAt*: MonoTime
      ## When `state == psEscaped` last fired with no follow-up byte. Used
      ## by `tick()` to decide whether to flush a bare Escape.
    kittyKeyboard*: bool
      ## When true, decode `CSI ... u` Kitty key events.

# ---------------------------------------------------------------------------
# Constructors / accessors
# ---------------------------------------------------------------------------

proc initParser*(): Parser =
  Parser(state: psGround,
         buf: "",
         pasteBuf: "",
         utf8Need: 0,
         utf8Have: "",
         queue: @[],
         kittyKeyboard: false)

proc enableKittyKeyboard*(p: var Parser) =
  p.kittyKeyboard = true

proc pending*(p: Parser): int {.inline.} =
  ## Number of decoded events waiting to be drained.
  p.queue.len

proc pop*(p: var Parser): Option[Event] =
  ## Pop the oldest decoded event. Returns `none` if the queue is empty.
  if p.queue.len == 0:
    return none(Event)
  let ev = p.queue[0]
  p.queue.delete(0)
  some(ev)

# ---------------------------------------------------------------------------
# UTF-8 helpers
# ---------------------------------------------------------------------------

proc utf8Length(b: byte): int =
  ## Returns the number of bytes in the UTF-8 codepoint starting with `b`,
  ## or 0 if `b` is a continuation byte / invalid leader.
  if (b and 0x80'u8) == 0'u8: 1
  elif (b and 0xE0'u8) == 0xC0'u8: 2
  elif (b and 0xF0'u8) == 0xE0'u8: 3
  elif (b and 0xF8'u8) == 0xF0'u8: 4
  else: 0

proc decodeUtf8Rune(s: string): Rune =
  ## Decode a fully-formed UTF-8 codepoint to a Rune. Caller guarantees
  ## the byte count matches the leader.
  var r: Rune
  fastRuneAt(s, 0, r, doInc = false)
  r

# ---------------------------------------------------------------------------
# Modifier and named-key decoding
# ---------------------------------------------------------------------------

proc modsFromMask(mask: int): KeyMods =
  ## xterm modifier mask. Bits, after subtracting 1:
  ##   1 = Shift, 2 = Alt, 4 = Control, 8 = Super (sometimes Meta), 16 =
  ##   Hyper, 32 = Meta. Crossterm and Kitty agree on this layout.
  ##
  ## CSI sequences send the modifier as `mask + 1` (e.g. `;5;` for Ctrl).
  ## Kitty sends raw bits with no offset; callers using Kitty form must
  ## pre-subtract 0 (no offset) and use `modsFromKittyMask` instead.
  result = {}
  let m = if mask > 0: mask - 1 else: 0
  if (m and 1) != 0: result.incl kmShift
  if (m and 2) != 0: result.incl kmAlt
  if (m and 4) != 0: result.incl kmCtrl
  if (m and 8) != 0: result.incl kmSuper
  if (m and 16) != 0: result.incl kmHyper
  if (m and 32) != 0: result.incl kmMeta

proc keyOf(code: KeyCode): KeyEvent =
  KeyEvent(code: code, rune: Rune(0), mods: {}, kind: kkPress, state: 0)

proc keyOf(code: KeyCode; mods: KeyMods): KeyEvent =
  KeyEvent(code: code, rune: Rune(0), mods: mods, kind: kkPress, state: 0)

proc keyChar(rune: Rune; mods: KeyMods = {}): KeyEvent =
  KeyEvent(code: kcChar, rune: rune, mods: mods, kind: kkPress, state: 0)

proc emitKey(p: var Parser; ev: KeyEvent) =
  p.queue.add Event(kind: ekKey, key: ev)

proc emitMouse(p: var Parser; ev: MouseEvent) =
  p.queue.add Event(kind: ekMouse, mouse: ev)

proc emitResize(p: var Parser; cols, rows: int) =
  p.queue.add Event(kind: ekResize, resize: ResizeEvent(cols: cols, rows: rows))

proc emitFocus(p: var Parser; gained: bool) =
  p.queue.add Event(kind: ekFocus, focus: FocusEvent(gained: gained))

proc emitPaste(p: var Parser; content: string) =
  p.queue.add Event(kind: ekPaste, paste: content)

# ---------------------------------------------------------------------------
# CSI parameter parsing
# ---------------------------------------------------------------------------

proc parseCsiParams(s: string): tuple[params: seq[int], priv: char,
                                      final: char, intermediate: string,
                                      ok: bool] =
  ## Parse a CSI body like `?1;2;3:4 q` into:
  ##   * `priv` - the leader byte if any (`?`, `<`, `=`, `>`)
  ##   * `params` - integer parameters (sub-params with `:` collapsed to a
  ##     single value containing the first sub-param; full sub-param
  ##     handling is in dedicated decoders below)
  ##   * `intermediate` - bytes in `0x20..0x2F` between parameters and final
  ##   * `final` - the final byte in `0x40..0x7E`
  result.priv = '\0'
  result.final = '\0'
  result.intermediate = ""
  result.ok = false
  result.params = @[]
  if s.len == 0: return
  var i = 0
  if s[0] in {'?', '<', '=', '>'}:
    result.priv = s[0]
    i = 1
  var cur = ""
  while i < s.len:
    let c = s[i]
    if c >= '0' and c <= '9':
      cur.add c
    elif c == ';' or c == ':':
      if cur.len == 0:
        result.params.add(0)
      else:
        try: result.params.add(parseInt(cur))
        except CatchableError: result.params.add(0)
        cur.setLen(0)
      # `:` is a sub-parameter separator; for now we collapse sub-params
      # by treating them as their own parameter slots. The Kitty decoder
      # below re-reads the raw buffer when it needs precision.
    elif c >= '\x20' and c <= '\x2F':
      result.intermediate.add c
    elif c >= '\x40' and c <= '\x7E':
      result.final = c
      if cur.len > 0:
        try: result.params.add(parseInt(cur))
        except CatchableError: result.params.add(0)
      result.ok = true
      return
    inc i

# `parseInt` comes from std/strutils (imported at the top).

# ---------------------------------------------------------------------------
# CSI dispatch
# ---------------------------------------------------------------------------

proc dispatchCsi(p: var Parser; body: string) =
  ## `body` does NOT include the leading `ESC[` or the final byte's
  ## absence. `parseCsiParams` extracts the final byte from the end of
  ## `body`.
  let parsed = parseCsiParams(body)
  if not parsed.ok:
    return
  let final = parsed.final
  let params = parsed.params

  # ---------------------------------------------------------------------
  # Mouse SGR-1006: CSI < b ; col ; row M / m
  # ---------------------------------------------------------------------
  if parsed.priv == '<' and (final == 'M' or final == 'm') and params.len >= 3:
    let b = params[0]
    let col = params[1]
    let row = params[2]
    var mods: KeyMods = {}
    if (b and 4) != 0: mods.incl kmShift
    if (b and 8) != 0: mods.incl kmAlt
    if (b and 16) != 0: mods.incl kmCtrl
    let isMotion = (b and 32) != 0
    let buttonBits = b and 0x43  # bits 0,1,6
    var kind: MouseKind = mkMoved
    var btn: MouseButton = mbNone
    case buttonBits
    of 0:
      btn = mbLeft
      kind = if isMotion: mkDrag elif final == 'M': mkDown else: mkUp
    of 1:
      btn = mbMiddle
      kind = if isMotion: mkDrag elif final == 'M': mkDown else: mkUp
    of 2:
      btn = mbRight
      kind = if isMotion: mkDrag elif final == 'M': mkDown else: mkUp
    of 3:
      # Release in legacy mode; rarely seen in SGR (which uses lower-case
      # `m`) but possible. Treat as Up.
      kind = mkUp
    of 64:
      btn = mbNone
      kind = mkScrollUp
    of 65:
      btn = mbNone
      kind = mkScrollDown
    of 66:
      btn = mbNone
      kind = mkScrollLeft
    of 67:
      btn = mbNone
      kind = mkScrollRight
    else:
      kind = mkMoved
    if isMotion and buttonBits in {64, 65, 66, 67}:
      # Motion + scroll bit shouldn't combine - ignore.
      kind = mkMoved
    if isMotion and buttonBits == 3:
      # Pure motion (no button held).
      kind = mkMoved
      btn = mbNone
    emitMouse(p, MouseEvent(kind: kind, button: btn,
                            col: col, row: row, mods: mods))
    return

  # ---------------------------------------------------------------------
  # Focus events: CSI I (gained), CSI O (lost)
  # ---------------------------------------------------------------------
  if parsed.priv == '\0' and parsed.intermediate.len == 0 and params.len == 0:
    case final
    of 'I': emitFocus(p, true); return
    of 'O': emitFocus(p, false); return
    else: discard

  # ---------------------------------------------------------------------
  # In-band resize: CSI 48 ; rows ; cols t  (xterm CSI 14t / 18t replies)
  # We accept the variant some terminals emit for SIGWINCH push.
  # ---------------------------------------------------------------------
  if final == 't' and params.len >= 3 and params[0] == 48:
    emitResize(p, params[2], params[1])
    return

  # ---------------------------------------------------------------------
  # Cursor position report: CSI Pl ; Pc R - response to CSI 6n. Not really
  # an `Event` we want to surface to the user, but we add a synthetic
  # paste-style event so callers polling for the reply can see it.
  # `position()` in terminal.nim short-circuits this path by reading raw
  # bytes directly.
  # ---------------------------------------------------------------------
  if parsed.priv == '\0' and final == 'R' and params.len >= 2:
    # Don't surface as a key event; the public API skips this.
    return

  # ---------------------------------------------------------------------
  # Function keys via CSI ~ (xterm form): CSI N ; M ~
  # ---------------------------------------------------------------------
  if final == '~' and params.len >= 1:
    let n = params[0]
    let mods = if params.len >= 2: modsFromMask(params[1]) else: {}
    let code = case n
      of 1, 7: kcHome
      of 2: kcInsert
      of 3: kcDelete
      of 4, 8: kcEnd
      of 5: kcPageUp
      of 6: kcPageDown
      of 11: kcF1
      of 12: kcF2
      of 13: kcF3
      of 14: kcF4
      of 15: kcF5
      of 17: kcF6
      of 18: kcF7
      of 19: kcF8
      of 20: kcF9
      of 21: kcF10
      of 23: kcF11
      of 24: kcF12
      of 200:
        # Bracketed-paste START - shouldn't reach here (handled inline in
        # feed() via the literal byte sequence). Emit nothing.
        return
      of 201:
        return
      else: kcUnknown
    if code != kcUnknown:
      emitKey(p, keyOf(code, mods))
    return

  # ---------------------------------------------------------------------
  # Cursor / arrow / function via CSI <letter> (xterm form): CSI 1 ; M <X>
  # ---------------------------------------------------------------------
  if parsed.priv == '\0' and parsed.intermediate.len == 0:
    var mods: KeyMods = {}
    if params.len >= 2:
      mods = modsFromMask(params[1])
    let code = case final
      of 'A': kcUp
      of 'B': kcDown
      of 'C': kcRight
      of 'D': kcLeft
      of 'E': kcChar  # KP 5 - skip
      of 'F': kcEnd
      of 'H': kcHome
      of 'P': kcF1
      of 'Q': kcF2
      of 'R': kcF3
      of 'S': kcF4
      of 'Z':
        # Shift+Tab.
        emitKey(p, keyOf(kcBackTab, {kmShift}))
        return
      else: kcUnknown
    if code != kcUnknown and code != kcChar:
      emitKey(p, keyOf(code, mods))
      return

  # ---------------------------------------------------------------------
  # Kitty keyboard: CSI key-code ; mods : event-type ; text ... u
  # ---------------------------------------------------------------------
  if final == 'u' and parsed.priv == '\0' and params.len >= 1:
    let keyCp = params[0]
    var mods: KeyMods = {}
    var kind = kkPress
    if params.len >= 2 and params[1] > 0:
      mods = modsFromMask(params[1])
    # Kitty event-type lives as a sub-param of the modifier; with our
    # collapsed param parsing we scan the raw buffer for `:N` after the
    # modifier value.
    var idx = 0
    var seen = 0
    while idx < body.len and seen < 1:
      if body[idx] == ';': inc seen
      inc idx
    # `idx` now points just past the first `;`.
    var inSub = false
    var subBuf = ""
    while idx < body.len and body[idx] != ';' and body[idx] != 'u':
      if body[idx] == ':':
        inSub = true
      elif inSub and body[idx] >= '0' and body[idx] <= '9':
        subBuf.add body[idx]
      inc idx
    if subBuf.len > 0:
      try:
        let evType = parseInt(subBuf)
        kind = case evType
          of 1: kkPress
          of 2: kkRepeat
          of 3: kkRelease
          else: kkPress
      except CatchableError: discard
    let ev = case keyCp
      of 13: keyOf(kcEnter, mods)
      of 9: keyOf(kcTab, mods)
      of 127: keyOf(kcBackspace, mods)
      of 27: keyOf(kcEsc, mods)
      of 57399 .. 57400: keyOf(kcChar, mods)
      else:
        if keyCp >= 32 and keyCp < 0x110000:
          var k = keyChar(Rune(keyCp), mods)
          k.kind = kind
          k
        else:
          keyOf(kcUnknown, mods)
    var ev2 = ev
    ev2.kind = kind
    emitKey(p, ev2)
    return

# ---------------------------------------------------------------------------
# Single-byte / SS3 dispatch
# ---------------------------------------------------------------------------

proc dispatchSs3(p: var Parser; final: char) =
  ## SS3 (single-shift G3): ESC O <final>. Common keys: arrows in
  ## application-cursor mode (`SS3 A` etc.), function keys F1-F4 in
  ## VT100-compatible mode.
  let code = case final
    of 'P': kcF1
    of 'Q': kcF2
    of 'R': kcF3
    of 'S': kcF4
    of 'A': kcUp
    of 'B': kcDown
    of 'C': kcRight
    of 'D': kcLeft
    of 'F': kcEnd
    of 'H': kcHome
    of 'M': kcEnter
    else: kcUnknown
  if code != kcUnknown:
    emitKey(p, keyOf(code))

proc dispatchControl(p: var Parser; b: byte) =
  ## Bytes 0x00-0x1F (with ESC handled separately). Translates control
  ## codes to their canonical keys.
  case b
  of 0x00:
    emitKey(p, keyOf(kcChar, {kmCtrl}))  # Ctrl+@ / Ctrl+Space
  of 0x09:
    emitKey(p, keyOf(kcTab))
  of 0x0A, 0x0D:
    emitKey(p, keyOf(kcEnter))
  of 0x08, 0x7F:
    emitKey(p, keyOf(kcBackspace))
  of 0x01 .. 0x07, 0x0B, 0x0C, 0x0E .. 0x1A:
    # Ctrl+letter. 0x01='A', 0x1A='Z'.
    let letter = char(b + 0x60)  # produces lowercase a..z
    var k = keyChar(Rune(ord(letter)), {kmCtrl})
    emitKey(p, k)
  else:
    discard  # 0x1B (ESC) is consumed by feed(); other bytes ignored.

# ---------------------------------------------------------------------------
# OSC dispatch
# ---------------------------------------------------------------------------

proc dispatchOsc(p: var Parser; body: string) =
  ## The body of an OSC sequence (without the leading ESC] and trailing
  ## BEL/ST). We currently surface no events for OSC - they're host->term,
  ## not term->host. Kept as a hook for future hyperlink callbacks.
  discard

# ---------------------------------------------------------------------------
# Main feed driver
# ---------------------------------------------------------------------------

proc transitionToGround(p: var Parser) =
  p.state = psGround
  p.buf.setLen(0)

proc feed*(p: var Parser; bytes: openArray[byte]) =
  ## Feed bytes into the parser. May produce zero or more events into the
  ## queue.
  for i in 0 ..< bytes.len:
    let b = bytes[i]
    case p.state
    of psGround:
      if b == 0x1B'u8:
        p.state = psEscaped
        p.escapeStartedAt = getMonoTime()
      elif b < 0x20'u8:
        dispatchControl(p, b)
      elif b == 0x7F'u8:
        emitKey(p, keyOf(kcBackspace))
      elif (b and 0x80'u8) == 0'u8:
        # Plain ASCII printable.
        emitKey(p, keyChar(Rune(int(b))))
      else:
        # UTF-8 leader.
        let n = utf8Length(b)
        if n <= 1:
          # Invalid leader - skip silently.
          discard
        else:
          p.state = psUtf8
          p.utf8Need = n - 1
          p.utf8Have = ""
          p.utf8Have.add(char(b))
    of psUtf8:
      p.utf8Have.add(char(b))
      dec p.utf8Need
      if p.utf8Need <= 0:
        let r = decodeUtf8Rune(p.utf8Have)
        emitKey(p, keyChar(r))
        p.state = psGround
        p.utf8Have = ""
    of psEscaped:
      case b
      of 0x1B'u8:
        # Two ESCs in a row - the first one is bare Escape, the second
        # starts a new sequence.
        emitKey(p, keyOf(kcEsc))
        p.escapeStartedAt = getMonoTime()
      of byte('['):
        p.state = psCsi
        p.buf.setLen(0)
      of byte('O'):
        p.state = psSs3
      of byte(']'):
        p.state = psOsc
        p.buf.setLen(0)
      of byte('P'):
        p.state = psDcs
        p.buf.setLen(0)
      of byte('_'):
        p.state = psApc
        p.buf.setLen(0)
      else:
        # ESC <printable> = Alt+<key>. ESC followed by a control char =
        # Alt+Ctrl+<key>.
        if b < 0x20'u8:
          # Re-dispatch control through the control path with kmAlt added.
          # Easiest: add Alt to the most recently emitted key, but we
          # haven't emitted yet. Build a synthetic key instead.
          if b == 0x09'u8:
            emitKey(p, keyOf(kcTab, {kmAlt}))
          elif b == 0x0D'u8:
            emitKey(p, keyOf(kcEnter, {kmAlt}))
          elif b == 0x08'u8 or b == 0x7F'u8:
            emitKey(p, keyOf(kcBackspace, {kmAlt}))
          else:
            discard
        elif (b and 0x80'u8) == 0'u8:
          emitKey(p, keyChar(Rune(int(b)), {kmAlt}))
        else:
          # Alt + multi-byte UTF-8 - rare; treat as Alt+(decoded rune).
          let n = utf8Length(b)
          if n > 1:
            p.state = psUtf8
            p.utf8Need = n - 1
            p.utf8Have = ""
            p.utf8Have.add(char(b))
            # We won't be able to mark mods=Alt here because the rune
            # arrives later; this is a rare corner. Most terminals send
            # UTF-8 unprefixed for non-ASCII, and Alt+<unicode> is
            # generally Kitty-keyboard territory anyway.
            continue
        p.state = psGround
    of psCsi:
      if b >= 0x40'u8 and b <= 0x7E'u8:
        p.buf.add char(b)
        dispatchCsi(p, p.buf)
        # Special-case bracketed paste start.
        if p.buf == "200~":
          p.state = psPaste
          p.pasteBuf.setLen(0)
        else:
          transitionToGround(p)
      else:
        # Parameter / intermediate byte.
        p.buf.add char(b)
        # Reissue-on-overlength: if the CSI body grows past the
        # sanity limit (32 bytes, per Textual's `_xterm_parser`) without
        # finding a final byte, the input is malformed or non-CSI.
        # Re-emit the buffered prefix as per-character key events
        # (skipping the leading `[` already consumed by `psEscaped`)
        # so callers see the bytes instead of silent loss.
        const csiReissueLimit = 32
        if p.buf.len > csiReissueLimit:
          # Synthesise an ESC keypress for the original ESC byte, then
          # re-feed `[` and every accumulated parameter byte as plain
          # printable / control characters.
          emitKey(p, keyOf(kcEsc))
          # Re-dispatch the `[` and the buffered bytes through the
          # ground-state path, mirroring Textual's reissue. We can't
          # call `feed` recursively without re-entering the CSI state;
          # instead, emit each byte as a char key (this is the
          # documented fallback path).
          emitKey(p, keyChar(Rune(int('['))))
          for ch in p.buf:
            let cb = byte(ch)
            if cb >= 0x20'u8 and cb < 0x7F'u8:
              emitKey(p, keyChar(Rune(int(cb))))
            elif cb < 0x20'u8:
              dispatchControl(p, cb)
            # Bytes >= 0x80 inside an unterminated CSI parameter list
            # are unusual; drop them rather than emit a corrupt rune.
          transitionToGround(p)
    of psSs3:
      dispatchSs3(p, char(b))
      transitionToGround(p)
    of psOsc:
      if b == 0x07'u8:
        dispatchOsc(p, p.buf)
        transitionToGround(p)
      elif b == 0x1B'u8:
        # Possibly ST (ESC \). Check next byte.
        # Stash a pending-ST flag in the state by switching to a synthetic
        # transition: we store an extra ESC in buf and keep going.
        p.buf.add char(b)
      elif b == 0x5C'u8 and p.buf.len > 0 and p.buf[^1] == '\x1B':
        p.buf.setLen(p.buf.len - 1)
        dispatchOsc(p, p.buf)
        transitionToGround(p)
      else:
        p.buf.add char(b)
        if p.buf.len > 4096:
          transitionToGround(p)
    of psDcs, psApc:
      if b == 0x1B'u8:
        p.buf.add char(b)
      elif b == 0x5C'u8 and p.buf.len > 0 and p.buf[^1] == '\x1B':
        p.buf.setLen(p.buf.len - 1)
        # We don't surface DCS/APC payloads as user events.
        transitionToGround(p)
      else:
        p.buf.add char(b)
        if p.buf.len > 1024 * 1024:  # 1 MB cap for image payloads
          transitionToGround(p)
    of psPaste:
      # Bracketed-paste body. Look for the literal terminator
      # `\x1b[201~`. Append byte; if pasteBuf ends with the terminator,
      # emit the paste and return to ground.
      p.pasteBuf.add char(b)
      const term = "\x1b[201~"
      if p.pasteBuf.len >= term.len and
         p.pasteBuf[p.pasteBuf.len - term.len ..< p.pasteBuf.len] == term:
        let body = p.pasteBuf[0 ..< p.pasteBuf.len - term.len]
        emitPaste(p, body)
        p.pasteBuf.setLen(0)
        transitionToGround(p)

proc tick*(p: var Parser; now: MonoTime = getMonoTime()) =
  ## Resolve a pending bare-Escape if `escapeDelayMs` has elapsed since
  ## entering `psEscaped`. Call from the event loop on each iteration so
  ## standalone Escape keys eventually surface.
  if p.state == psEscaped:
    let dt = now - p.escapeStartedAt
    if dt.inMilliseconds >= escapeDelayMs:
      emitKey(p, keyOf(kcEsc))
      p.state = psGround

proc flush*(p: var Parser) =
  ## Force any pending bare Escape to surface immediately. Used when a
  ## reader knows no further bytes are coming (EOF on the input fd).
  if p.state == psEscaped:
    emitKey(p, keyOf(kcEsc))
    p.state = psGround
