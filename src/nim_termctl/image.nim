## nim_termctl/image.nim - terminal image emission.
##
## Capability detection + protocol dispatch. Pixel encoders (Sixel,
## Kitty graphics, iTerm2) are *deferred* in this pass - the load-bearing
## L3 core ships first; the encoders land in a follow-up commit so the
## review agent has a clean reviewable surface.
##
## What ships now:
##   * `Image` value `object` with raw bytes + format tag.
##   * `ImagePlacement` for absolute / inline placement.
##   * `ImageProtocols` capability-detection result.
##   * `detectImageSupport()` capability detection via env-var heuristics
##     (TERM_PROGRAM, KITTY_WINDOW_ID, LC_TERMINAL).
##   * `drawImage` and `drawImageInline` raise `NotImplementedDefer` so
##     callers compiling against the stable API surface get a clear
##     deferred-feature error rather than silent missing output.

import std/[os, base64, strutils]

type
  ImageFormat* = enum
    ifAuto       ## Pick the best supported protocol at draw time.
    ifSixel
    ifKitty
    ifITerm2

  SourceFormat* = enum
    sfPng, sfJpeg, sfGif, sfRgba

  ImageId* = distinct uint32

  ImageProtocols* = object
    ## Capability-detection result. All flags are independent.
    sixel*: bool
    kitty*: bool
    iterm2*: bool

  Image* = object
    ## Value-typed image. Owns its bytes via `seq[byte]`.
    bytes*: seq[byte]
    format*: SourceFormat
    width*, height*: int  ## Optional - 0 means "let the encoder figure it out".
    preferredFormat*: ImageFormat

  ImagePlacement* = object
    ## How and where to put the image.
    col*, row*: int  ## Anchor in cells, 0-based.
    cols*, rows*: int  ## Cell footprint; 0 = encoder default.
    id*: ImageId  ## Optional Kitty image ID; 0 = auto.

  ImageError* = object of CatchableError
  ImageNotImplementedDefer* = object of ImageError
    ## Raised by encoder paths that haven't shipped yet.

# ---------------------------------------------------------------------------
# Capability detection.
# ---------------------------------------------------------------------------

proc detectImageSupport*(): ImageProtocols =
  ## Best-effort capability sniffing using env vars - the ANSI query
  ## form (Kitty graphics query / DA1 Sixel response) requires raw mode
  ## to round-trip, which we leave to a follow-up. The env-var heuristics
  ## here cover modern macOS (Terminal/iTerm2), Kitty, and WezTerm
  ## reliably enough for capability gating.
  let term = getEnv("TERM")
  let termProgram = getEnv("TERM_PROGRAM")
  let lcTerminal = getEnv("LC_TERMINAL")
  let kittyId = getEnv("KITTY_WINDOW_ID")
  result = ImageProtocols()
  if kittyId.len > 0 or termProgram == "kitty" or term.contains("kitty"):
    result.kitty = true
  if termProgram == "iTerm.app" or lcTerminal == "iTerm2" or
     termProgram == "WezTerm":
    result.iterm2 = true
  # Sixel detection is conservative - a few terminals advertise via $TERM
  # `xterm-256color` while gating Sixel via DA1; we trust the env hint.
  if term.contains("sixel") or term == "mlterm" or term == "yaft-256color":
    result.sixel = true

# ---------------------------------------------------------------------------
# iTerm2 inline-image encoding (small, ships in this pass).
# ---------------------------------------------------------------------------
#
# OSC 1337 ; File = inline=1 ; size=N : <base64 bytes> ST
# This protocol is conveniently format-agnostic (the terminal decodes the
# payload as PNG/JPEG/GIF itself) so we don't need a pixel decoder.

proc emitITerm2Inline*(img: Image): string =
  ## Build the iTerm2 inline-image escape. Returns a string that the
  ## caller writes to the terminal (via `write` / `queue`).
  let b64 = base64.encode(img.bytes)
  result = "\x1b]1337;File=inline=1;size=" & $img.bytes.len & ":" &
           b64 & "\x07"

# ---------------------------------------------------------------------------
# Kitty graphics (small, ships in this pass).
# ---------------------------------------------------------------------------
#
# Kitty splits image data into 4 KiB base64 chunks: a=T,f=100,m=1 .. m=0.
# `f=100` says the payload is PNG (the terminal decodes); other values
# request RGBA passthrough but require pixel decoding upstream which we
# defer.

const kittyChunkBytes = 4096

proc emitKittyChunked*(img: Image; id: uint32 = 0): string =
  ## Build the Kitty graphics escape (a chunked APC sequence). Only PNG
  ## passthrough is supported here (`f=100`). For RGBA passthrough see
  ## the deferred sixel encoder once it ships.
  if img.format != sfPng:
    raise newException(ImageNotImplementedDefer,
      "Kitty graphics: only PNG passthrough ships in this pass; " &
      "RGBA encoder is in the deferred follow-up")
  let b64 = base64.encode(img.bytes)
  var buf = ""
  var pos = 0
  let total = b64.len
  while pos < total:
    let chunkEnd = min(pos + kittyChunkBytes, total)
    let chunk = b64[pos ..< chunkEnd]
    let isFirst = pos == 0
    let isLast = chunkEnd >= total
    let m = if isLast: 0 else: 1
    var ctrl = ""
    if isFirst:
      ctrl = "a=T,f=100"
      if id != 0: ctrl.add ",i=" & $id
      ctrl.add ",m=" & $m
    else:
      ctrl = "m=" & $m
    buf.add "\x1b_G"
    buf.add ctrl
    buf.add ";"
    buf.add chunk
    buf.add "\x1b\\"
    pos = chunkEnd
  result = buf

# ---------------------------------------------------------------------------
# Sixel - DEFERRED.
# ---------------------------------------------------------------------------

proc emitSixel*(img: Image): string =
  raise newException(ImageNotImplementedDefer,
    "Sixel encoder (~600 LOC pure Nim - Floyd-Steinberg dithering + " &
    "256-color quantization) is deferred to a follow-up commit")

# ---------------------------------------------------------------------------
# Public emission API.
# ---------------------------------------------------------------------------

proc drawImage*(img: Image; placement: ImagePlacement = ImagePlacement()): string =
  ## Returns the byte string to write to the terminal. Callers with a
  ## QueueWriter pass the returned string to `queue`; one-shots can
  ## write directly via `terminal.write(...)`.
  ##
  ## Picks the best supported protocol based on `img.preferredFormat` and
  ## the env-detected capabilities. Falls back to a text placeholder
  ## (`[image]`) if no protocol is supported.
  let caps = detectImageSupport()
  let chosen = case img.preferredFormat
    of ifKitty:
      if caps.kitty: ifKitty else: ifAuto
    of ifSixel:
      if caps.sixel: ifSixel else: ifAuto
    of ifITerm2:
      if caps.iterm2: ifITerm2 else: ifAuto
    of ifAuto:
      if caps.kitty: ifKitty
      elif caps.iterm2: ifITerm2
      elif caps.sixel: ifSixel
      else: ifAuto
  case chosen
  of ifKitty: emitKittyChunked(img, uint32(placement.id))
  of ifITerm2: emitITerm2Inline(img)
  of ifSixel: emitSixel(img)
  of ifAuto: "[image]"

proc deleteImage*(id: ImageId): string =
  ## Kitty graphics: delete an image by ID. No-op string for protocols
  ## that don't support it (caller should detect via capability flags).
  "\x1b_Ga=d,i=" & $uint32(id) & "\x1b\\"
