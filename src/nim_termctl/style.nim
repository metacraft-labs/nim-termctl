## nim_termctl/style.nim - SGR styling primitives.
##
## Public types are value `object` / `enum` per charter §1.
## All ANSI sequence emission goes through `setForeground` / `setBackground`
## / `setAttributes` / `resetStyle` which write to a writer (stdout by
## default, but `nim_termctl/queue.nim` redirects them into a batch buffer).

import std/strutils

type
  ColorKind* = enum
    ## Variant tag for `Color`.
    ckReset      ## Reset to terminal default.
    ckNamed      ## ANSI-16 named color (Black, Red, ..., BrightWhite).
    ckIndexed    ## 256-color palette index (0..255).
    ckRgb        ## 24-bit truecolor.

  NamedColor* = enum
    ## ANSI-16 named colors. The bright variants live above the regular ones
    ## so consumers can do `c.named.int and 7` to fold to the dim code.
    ncBlack, ncRed, ncGreen, ncYellow, ncBlue, ncMagenta, ncCyan, ncWhite,
    ncBrightBlack, ncBrightRed, ncBrightGreen, ncBrightYellow,
    ncBrightBlue, ncBrightMagenta, ncBrightCyan, ncBrightWhite

  Color* = object
    ## A typed color value. Always passed by value. Use the helper
    ## constructors below or build literally with `Color(kind: ...)`.
    case kind*: ColorKind
    of ckReset:
      discard
    of ckNamed:
      named*: NamedColor
    of ckIndexed:
      index*: uint8
    of ckRgb:
      r*, g*, b*: uint8

  Attr* = enum
    ## SGR attributes. Order chosen so a `set[Attr]` produces a stable
    ## emission order in `setAttributes`.
    atReset
    atBold
    atDim
    atItalic
    atUnderline
    atBlink
    atReverse
    atHidden
    atStrike
    atDoubleUnderline
    atOverline

  Attrs* = set[Attr]

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc reset*(): Color {.inline.} = Color(kind: ckReset)

proc named*(c: NamedColor): Color {.inline.} =
  Color(kind: ckNamed, named: c)

proc indexed*(idx: uint8): Color {.inline.} =
  Color(kind: ckIndexed, index: idx)

proc rgb*(r, g, b: uint8): Color {.inline.} =
  Color(kind: ckRgb, r: r, g: g, b: b)

# ---------------------------------------------------------------------------
# Sequence emission
# ---------------------------------------------------------------------------

proc fgSeq*(c: Color): string =
  ## Build the CSI sequence that sets the foreground color. Pure - no I/O.
  case c.kind
  of ckReset:
    "\x1b[39m"
  of ckNamed:
    let n = int(c.named)
    if n < 8:
      "\x1b[" & $(30 + n) & "m"
    else:
      "\x1b[" & $(90 + (n - 8)) & "m"
  of ckIndexed:
    "\x1b[38;5;" & $int(c.index) & "m"
  of ckRgb:
    "\x1b[38;2;" & $int(c.r) & ";" & $int(c.g) & ";" & $int(c.b) & "m"

proc bgSeq*(c: Color): string =
  ## Build the CSI sequence that sets the background color.
  case c.kind
  of ckReset:
    "\x1b[49m"
  of ckNamed:
    let n = int(c.named)
    if n < 8:
      "\x1b[" & $(40 + n) & "m"
    else:
      "\x1b[" & $(100 + (n - 8)) & "m"
  of ckIndexed:
    "\x1b[48;5;" & $int(c.index) & "m"
  of ckRgb:
    "\x1b[48;2;" & $int(c.r) & ";" & $int(c.g) & ";" & $int(c.b) & "m"

proc attrCode(a: Attr): int =
  case a
  of atReset:           0
  of atBold:            1
  of atDim:             2
  of atItalic:          3
  of atUnderline:       4
  of atBlink:           5
  of atReverse:         7
  of atHidden:          8
  of atStrike:          9
  of atDoubleUnderline: 21
  of atOverline:        53

proc attrSeq*(s: Attrs): string =
  ## Build the CSI sequence that sets a set of attributes.
  if s.card == 0: return ""
  var codes: seq[string] = @[]
  for a in s:
    codes.add($attrCode(a))
  "\x1b[" & codes.join(";") & "m"

proc resetSeq*(): string {.inline.} = "\x1b[0m"
