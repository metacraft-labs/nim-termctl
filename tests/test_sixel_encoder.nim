## test_sixel_encoder.nim - the Sixel encoder, read back by a decoder written
## here from the DEC format (VT330/VT340 Programmer Reference, "Sixel
## Graphics"), not by the encoder's own code: a picture is encoded, the escape
## is parsed into pixels, and the pixels are compared with the source.
##
## No mocks: the encoder is called on real pixel buffers and its whole output
## is parsed.

import std/[strutils, unittest]

import nim_termctl/sixel
import nim_termctl/image

type Decoded = object
  width, height: int
  declaredW, declaredH: int
  pixels: seq[array[3, int]]
  registers: int

proc decode(s: string): Decoded =
  ## Parse a complete `DCS q ... ST` into pixels.
  doAssert s.startsWith("\x1bPq"), "no Sixel introducer"
  doAssert s.endsWith("\x1b\\"), "no string terminator"
  let body = s[3 ..< s.len - 2]
  var palette: seq[array[3, int]] = @[]
  var i = 0
  proc num(): int =
    result = 0
    while i < body.len and body[i] in {'0' .. '9'}:
      result = result * 10 + ord(body[i]) - ord('0')
      inc i
  if body[i] == '"':
    inc i
    discard num(); inc i
    discard num(); inc i
    result.declaredW = num(); inc i
    result.declaredH = num()
  result.width = result.declaredW
  result.height = result.declaredH
  result.pixels = newSeq[array[3, int]](result.width * result.height)
  var color = 0
  var x = 0
  var band = 0
  while i < body.len:
    let c = body[i]
    case c
    of '#':
      inc i
      let n = num()
      if i < body.len and body[i] == ';':
        inc i
        doAssert num() == 2, "only RGB registers are written"
        inc i
        let r = num(); inc i
        let g = num(); inc i
        let b = num()
        while palette.len <= n: palette.add [0, 0, 0]
        palette[n] = [(r * 255 + 50) div 100, (g * 255 + 50) div 100,
                      (b * 255 + 50) div 100]
      else:
        color = n
    of '$':
      x = 0; inc i
    of '-':
      x = 0; inc band; inc i
    of '!':
      inc i
      let n = num()
      let bits = ord(body[i]) - 63
      for k in 0 ..< n:
        for dy in 0 ..< 6:
          if (bits and (1 shl dy)) != 0:
            let y = band * 6 + dy
            if y < result.height and x + k < result.width:
              result.pixels[y * result.width + x + k] = palette[color]
      x += n
      inc i
    else:
      let bits = ord(c) - 63
      doAssert bits >= 0 and bits < 64, "not a sixel character: " & $ord(c)
      for dy in 0 ..< 6:
        if (bits and (1 shl dy)) != 0:
          let y = band * 6 + dy
          if y < result.height and x < result.width:
            result.pixels[y * result.width + x] = palette[color]
      inc x
      inc i
  result.registers = palette.len

proc picture(w, h: int; f: proc (x, y: int): array[3, int]): seq[byte] =
  result = newSeq[byte](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let c = f(x, y)
      let i = (y * w + x) * 4
      result[i] = byte(c[0]); result[i + 1] = byte(c[1])
      result[i + 2] = byte(c[2]); result[i + 3] = 255

suite "Sixel: the encoder, read back":

  test "a few colours come back exactly, band by band, the last band short":
    # 7 wide, 13 tall: two full bands and a one-row third, which is where an
    # encoder that assumed whole bands would write outside the picture.
    let colours = [[255, 0, 0], [0, 128, 255], [20, 200, 40], [250, 250, 250]]
    let src = picture(7, 13, proc (x, y: int): array[3, int] =
      colours[(x * 3 + y * 5) mod 4])
    let s = encodeSixel(src, 7, 13)
    check s.contains("\"1;1;7;13")
    let d = decode(s)
    check d.registers == 4
    var exact = 0
    for y in 0 ..< 13:
      for x in 0 ..< 7:
        let want = colours[(x * 3 + y * 5) mod 4]
        let got = d.pixels[y * 7 + x]
        # Registers are percentages: within one percent step of the source.
        if abs(got[0] - want[0]) <= 2 and abs(got[1] - want[1]) <= 2 and
           abs(got[2] - want[2]) <= 2:
          inc exact
    check exact == 7 * 13

  test "a long run is one repeat introducer, and the escape is shorter for it":
    let src = picture(100, 6, proc (x, y: int): array[3, int] = [10, 20, 30])
    let s = encodeSixel(src, 100, 6)
    check s.contains("!100~")
    check s.len < 100
    let d = decode(s)
    check d.pixels[99] == [10, 20, 31]   # 30 -> 12 percent -> 31

  test "more colours than registers: a median-cut palette, dithered":
    # 64x64 with 4096 distinct colours. 256 registers cannot hold them, so
    # each 8x8 block's MEAN must survive: that is what dithering is for.
    let src = picture(64, 64, proc (x, y: int): array[3, int] =
      [x * 4, y * 4, (x + y) * 2])
    let pal = paletteFor(src, 64, 64)
    check pal.reduced
    check pal.colors.len <= DefaultMaxColors
    check pal.colors.len > 200
    let d = decode(encodeSixel(src, 64, 64))
    var worst = 0.0
    for by in 0 ..< 8:
      for bx in 0 ..< 8:
        var s = [0, 0, 0]
        var g = [0, 0, 0]
        for y in by * 8 ..< by * 8 + 8:
          for x in bx * 8 ..< bx * 8 + 8:
            let want = [x * 4, y * 4, (x + y) * 2]
            for k in 0 .. 2:
              s[k] += want[k]
              g[k] += d.pixels[y * 64 + x][k]
        for k in 0 .. 2:
          worst = max(worst, abs(float(s[k] - g[k]) / 64.0))
    checkpoint("worst block-mean error " & $worst)
    check worst < 4.0
    # THE TWIN: a palette that kept every colour is not reduced.
    check not paletteFor(picture(4, 4, proc (x, y: int): array[3, int] =
      [x * 50, y * 50, 0]), 4, 4).reduced

  test "a picture with no extent, or a short buffer, is refused by name":
    var refused = 0
    try:
      discard encodeSixel(newSeq[byte](0), 0, 4)
    except SixelError as e:
      check e.msg.contains("positive extent")
      inc refused
    try:
      discard encodeSixel(newSeq[byte](10), 2, 2)
    except SixelError as e:
      check e.msg.contains("needs 16 bytes")
      inc refused
    check refused == 2

  test "emitSixel draws RGBA and refuses an encoded source":
    let src = picture(3, 3, proc (x, y: int): array[3, int] = [x * 80, y * 80, 7])
    check emitSixel(Image(bytes: src, format: sfRgba, width: 3, height: 3)) ==
      encodeSixel(src, 3, 3)
    var refused = false
    try:
      discard emitSixel(Image(bytes: @[1'u8, 2, 3], format: sfPng))
    except ImageError as e:
      refused = e.msg.contains("decode")
    check refused
