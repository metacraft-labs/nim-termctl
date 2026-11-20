## nim_termctl/sixel.nim - a Sixel encoder for RGBA pixels.
##
## Sixel (DEC VT340, xterm `-ti vt340`, mlterm, foot, WezTerm, Windows
## Terminal, ...) draws a picture from a palette of at most a few hundred
## colour registers, six pixel rows ("a band") at a time. This module turns
## an RGBA8888 buffer into the complete escape - `DCS q`, the raster
## attributes, the palette, the bands, `ST` - in four steps:
##
##   1. **Palette.** A picture with at most `maxColors` distinct colours keeps
##      every one of them. One with more is reduced by MEDIAN CUT: the colour
##      box with the widest channel range is split at the median of that
##      channel until there are `maxColors` boxes, and each box's mean is a
##      register.
##   2. **Registers are percentages.** Sixel's `#n;2;r;g;b` takes 0-100 per
##      channel, so a register cannot hold every 8-bit value. The palette is
##      rounded to what the terminal will SHOW (`showable`) before any pixel is
##      mapped to it, so the error that is diffused is the error on screen.
##   3. **Dithering.** With a reduced palette each pixel is mapped to its
##      nearest register and the difference is spread Floyd-Steinberg
##      (7/16 right, 3/16 below-left, 5/16 below, 1/16 below-right). A picture
##      that kept every colour is not dithered: its only error is the
##      percentage rounding, which is below one step of any register.
##   4. **Bands.** For each band, each register used in it is written as a
##      row of sixel characters (`?` + the six-bit column mask) with `!n`
##      run-length compression, `$` back to the band's start, and `-` to the
##      next band.
##
## Pure Nim over values: no I/O, no `std/os`, so a caller compiled for the
## JavaScript backend can use it too.

import std/[algorithm, math, sequtils, tables]

type
  SixelError* = object of CatchableError

  SixelPalette* = object
    ## The colour registers, as the 8-bit colours the terminal shows for them.
    colors*: seq[array[3, uint8]]
    reduced*: bool
      ## Whether the picture had more colours than registers (median cut and
      ## dithering applied).

const
  DefaultMaxColors* = 256
    ## xterm's and most emulators' register count.
  SixelIntroducer* = "\x1bPq"
  SixelTerminator* = "\x1b\\"

func toPercent(v: uint8): int = (int(v) * 100 + 127) div 255
func fromPercent(p: int): uint8 = uint8((p * 255 + 50) div 100)

func showable*(c: array[3, uint8]): array[3, uint8] =
  ## The colour a register defined from `c` shows: each channel through the
  ## 0-100 percentage Sixel registers are written in.
  [fromPercent(toPercent(c[0])), fromPercent(toPercent(c[1])),
   fromPercent(toPercent(c[2]))]

func pixel(rgba: openArray[byte]; i: int): array[3, uint8] =
  [uint8(rgba[i * 4]), uint8(rgba[i * 4 + 1]), uint8(rgba[i * 4 + 2])]

func key(c: array[3, uint8]): int = int(c[0]) shl 16 or int(c[1]) shl 8 or int(c[2])

proc medianCut(colors: seq[array[3, uint8]]; counts: seq[int];
               maxColors: int): seq[array[3, uint8]] =
  ## Split the box with the widest channel range at that channel's weighted
  ## median until there are `maxColors` boxes; each box's weighted mean is a
  ## register.
  type Box = seq[int]   # indices into `colors`
  var boxes: seq[Box] = @[toSeq(0 ..< colors.len)]
  proc spread(b: Box): (int, int) =
    var best = -1
    var bestCh = 0
    for ch in 0 .. 2:
      var lo = 255
      var hi = 0
      for i in b:
        lo = min(lo, int(colors[i][ch]))
        hi = max(hi, int(colors[i][ch]))
      if hi - lo > best:
        best = hi - lo
        bestCh = ch
    (best, bestCh)
  while boxes.len < maxColors:
    var pick = -1
    var pickSpread = 0
    var pickCh = 0
    for bi, b in boxes:
      if b.len < 2: continue
      let (s, ch) = spread(b)
      if s > pickSpread:
        pickSpread = s
        pick = bi
        pickCh = ch
    if pick < 0:
      break
    var b = boxes[pick]
    let ch = pickCh
    b.sort(proc (x, y: int): int = cmp(colors[x][ch], colors[y][ch]))
    var total = 0
    for i in b: total += counts[i]
    var acc = 0
    var cut = 1
    for j, i in b:
      acc += counts[i]
      if acc * 2 >= total:
        cut = max(1, min(b.len - 1, j + 1))
        break
    boxes[pick] = b[0 ..< cut]
    boxes.add b[cut .. ^1]
  for b in boxes:
    var s = [0, 0, 0]
    var n = 0
    for i in b:
      for ch in 0 .. 2:
        s[ch] += int(colors[i][ch]) * counts[i]
      n += counts[i]
    result.add [uint8(s[0] div n), uint8(s[1] div n), uint8(s[2] div n)]

proc paletteFor*(rgba: openArray[byte]; width, height: int;
                 maxColors = DefaultMaxColors): SixelPalette =
  ## The registers for a picture: every distinct colour when there are at
  ## most `maxColors`, else a median cut. Rounded to what is shown.
  if maxColors < 1 or maxColors > 1024:
    raise newException(SixelError, "sixel: maxColors must be 1..1024, got " &
      $maxColors)
  var index = initTable[int, int]()
  var colors: seq[array[3, uint8]] = @[]
  var counts: seq[int] = @[]
  for i in 0 ..< width * height:
    let c = pixel(rgba, i)
    let k = key(c)
    let at = index.getOrDefault(k, -1)
    if at < 0:
      index[k] = colors.len
      colors.add c
      counts.add 1
    else:
      inc counts[at]
  var chosen =
    if colors.len <= maxColors: colors
    else: medianCut(colors, counts, maxColors)
  result.reduced = colors.len > maxColors
  var seen = initTable[int, bool]()
  for c in chosen:
    let s = showable(c)
    if not seen.hasKey(key(s)):
      seen[key(s)] = true
      result.colors.add s

func nearest(p: SixelPalette; r, g, b: float): int =
  var best = Inf
  for i, c in p.colors:
    let dr = r - float(c[0])
    let dg = g - float(c[1])
    let db = b - float(c[2])
    let d = dr * dr + dg * dg + db * db
    if d < best:
      best = d
      result = i

proc indexed*(rgba: openArray[byte]; width, height: int;
              palette: SixelPalette): seq[int] =
  ## Each pixel's register. Floyd-Steinberg diffused when the palette was
  ## reduced; the nearest register otherwise.
  result = newSeq[int](width * height)
  if not palette.reduced:
    var memo = initTable[int, int]()
    for i in 0 ..< width * height:
      let c = pixel(rgba, i)
      let k = key(c)
      var at = memo.getOrDefault(k, -1)
      if at < 0:
        at = nearest(palette, float(c[0]), float(c[1]), float(c[2]))
        memo[k] = at
      result[i] = at
    return
  var err = newSeq[array[3, float]](width * height)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let i = y * width + x
      let c = pixel(rgba, i)
      let r = clamp(float(c[0]) + err[i][0], 0.0, 255.0)
      let g = clamp(float(c[1]) + err[i][1], 0.0, 255.0)
      let b = clamp(float(c[2]) + err[i][2], 0.0, 255.0)
      let at = nearest(palette, r, g, b)
      result[i] = at
      let shown = palette.colors[at]
      let e = [r - float(shown[0]), g - float(shown[1]), b - float(shown[2])]
      for (dx, dy, w) in [(1, 0, 7.0 / 16.0), (-1, 1, 3.0 / 16.0),
                          (0, 1, 5.0 / 16.0), (1, 1, 1.0 / 16.0)]:
        let tx = x + dx
        let ty = y + dy
        if tx < 0 or tx >= width or ty >= height:
          continue
        let j = ty * width + tx
        for k in 0 .. 2:
          err[j][k] += e[k] * w

proc addRun(s: var string; ch: char; n: int) =
  if n <= 0: return
  if n >= 4:
    s.add '!'
    s.add $n
    s.add ch
  else:
    for _ in 0 ..< n: s.add ch

proc encodeSixel*(rgba: openArray[byte]; width, height: int;
                  maxColors = DefaultMaxColors): string =
  ## The complete Sixel escape for an RGBA8888 picture, row-major with no
  ## padding. Alpha is ignored: every pixel is painted.
  if width <= 0 or height <= 0:
    raise newException(SixelError, "sixel: a picture needs a positive extent, got " &
      $width & "x" & $height)
  if rgba.len != width * height * 4:
    raise newException(SixelError, "sixel: " & $width & "x" & $height &
      " needs " & $(width * height * 4) & " bytes, got " & $rgba.len)
  let palette = paletteFor(rgba, width, height, maxColors)
  let reg = indexed(rgba, width, height, palette)
  result = SixelIntroducer
  result.add "\"1;1;" & $width & ";" & $height
  for i, c in palette.colors:
    result.add "#" & $i & ";2;" & $toPercent(c[0]) & ";" & $toPercent(c[1]) &
               ";" & $toPercent(c[2])
  var used = newSeq[bool](palette.colors.len)
  var bits = newSeq[int](width)
  let bands = (height + 5) div 6
  for band in 0 ..< bands:
    let y0 = band * 6
    for i in 0 ..< used.len: used[i] = false
    for y in y0 ..< min(height, y0 + 6):
      for x in 0 ..< width:
        used[reg[y * width + x]] = true
    var first = true
    for color in 0 ..< used.len:
      if not used[color]: continue
      for x in 0 ..< width:
        var m = 0
        for dy in 0 ..< 6:
          let y = y0 + dy
          if y < height and reg[y * width + x] == color:
            m = m or (1 shl dy)
        bits[x] = m
      if not first:
        result.add '$'
      first = false
      result.add "#" & $color
      var x = 0
      # Trailing empty columns are not written: `$` returns to the band's
      # start whatever was drawn.
      var last = width - 1
      while last >= 0 and bits[last] == 0: dec last
      while x <= last:
        var n = 1
        while x + n <= last and bits[x + n] == bits[x]: inc n
        result.addRun(char(63 + bits[x]), n)
        x += n
    if band < bands - 1:
      result.add '-'
  result.add SixelTerminator
