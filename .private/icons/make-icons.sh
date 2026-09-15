#!/usr/bin/env bash
# Regenerate cs193v.icns and cs193v.ico from the two masters in src/  (#134)
#
# DEVELOPER-ONLY, AND NEVER RUN ON A STUDENT'S MACHINE. .gitattributes' `/.private/**
# export-ignore` keeps this file and src/ out of the branch tarball; only the two artifacts it
# emits are un-ignored. That is deliberate: iconutil is macOS-only and install-cs193v-windows.cmd
# cannot build an .ico at all, so both outputs are committed rather than generated on demand.
#
# TWO MASTERS, NOT ONE SCALED. Anything before Tahoe renders .icns artwork literally -- no mask --
# so the 1024 has to carry the squircle and its 100px gutter itself, and Tahoe then clips to the
# squircle and demotes artwork that does not already fit it into a grey rounded box. Windows
# neither masks nor insets, so that same gutter would leave a ~13px glyph in a 16px Start Menu
# row. src/cs193v-824.png is the artwork with the gutter already off.
#
# THE GEOMETRY IS CHECKED HERE AND NOT IN 10-static.sh, because proving it needs a full PNG decode
# -- zlib plus per-line unfiltering over a megapixel -- and that tier's whole point is
# milliseconds. This runs by hand, where a second is free. The static tier reads the IHDR instead,
# which catches a swapped master; this catches a re-exported one.
set -eu

HERE="$(cd -- "$(dirname -- "$0")" && pwd -P)"
SRC="$HERE/src"
M1024="$SRC/cs193v-1024.png"
M824="$SRC/cs193v-824.png"

# THE MACOS-ONLY DOOR, stated once and early. sips and iconutil both ship with the OS and neither
# has a Linux equivalent in this repo's dependency set, so a Linux developer gets told what is
# wrong rather than two tool-not-found errors from inside a pipeline.
[ "$(uname -s)" = Darwin ] || {
    printf 'make-icons.sh needs macOS: sips and iconutil have no Linux equivalent here.\n' >&2
    printf 'The two artifacts are committed, so this only needs running when a master changes.\n' >&2
    exit 1
}
for t in sips iconutil python3; do
    command -v "$t" >/dev/null || { printf 'missing: %s\n' "$t" >&2; exit 1; }
done
for f in "$M1024" "$M824"; do
    [ -f "$f" ] || { printf 'missing master: %s\n' "$f" >&2; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cs193v-icons.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ─── 1. refuse a master that is not what the two platforms were promised ───────
# BOTH MASTERS, AND THE GUTTER IS THE POINT. A 1024 exported full-bleed has the right IHDR and
# the wrong picture: it is the case Tahoe puts in a grey box, and nothing downstream of here can
# tell. The 824 is checked the other way -- any gutter on it means the Start Menu glyph shrinks.
python3 - "$M1024" "$M824" <<'PY'
import sys, zlib, struct

def rgba(path):
    d = open(path, 'rb').read()
    if d[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit(f'{path}: not a PNG')
    pos, idat, ihdr = 8, bytearray(), None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        if typ == b'IHDR':
            ihdr = struct.unpack('>IIBBBBB', d[pos + 8:pos + 8 + ln])
        elif typ == b'IDAT':
            idat += d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    if ihdr is None:
        raise SystemExit(f'{path}: no IHDR')
    w, h, depth, ctype, _, _, inter = ihdr
    if (depth, ctype, inter) != (8, 6, 0):
        raise SystemExit(f'{path}: need 8-bit RGBA non-interlaced, '
                         f'got depth={depth} colour-type={ctype} interlace={inter}')
    raw = zlib.decompress(bytes(idat))
    stride, bpp = w * 4, 4
    out, prev, p = bytearray(), bytearray(stride), 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc
                                      else b if pb <= pc else c)) & 255
        elif f != 0:
            raise SystemExit(f'{path}: unknown PNG filter {f}')
        out += line
        prev = line
    return w, h, out

def gutters(w, h, px):
    x0, y0, x1, y1 = w, h, -1, -1
    for y in range(h):
        row = px[y * w * 4:(y + 1) * w * 4]
        for x in range(w):
            if row[x * 4 + 3]:
                x0, x1 = min(x0, x), max(x1, x)
                y0, y1 = min(y0, y), max(y1, y)
    if x1 < 0:
        raise SystemExit('fully transparent master')
    return x0, w - 1 - x1, y0, h - 1 - y1

big, small = sys.argv[1], sys.argv[2]

w, h, px = rgba(big)
if (w, h) != (1024, 1024):
    raise SystemExit(f'{big}: expected 1024x1024, got {w}x{h}')
g = gutters(w, h, px)
if g != (100, 100, 100, 100):
    raise SystemExit(f'{big}: expected a 100px gutter on all four sides (824 artwork on a '
                     f'1024 canvas), measured L{g[0]} R{g[1]} T{g[2]} B{g[3]}.\n'
                     f'  Artwork drawn to the full canvas is what Tahoe demotes into a grey box.')

w, h, px = rgba(small)
if (w, h) != (824, 824):
    raise SystemExit(f'{small}: expected 824x824, got {w}x{h}')
g = gutters(w, h, px)
if g != (0, 0, 0, 0):
    raise SystemExit(f'{small}: expected full-bleed artwork with no gutter, measured '
                     f'L{g[0]} R{g[1]} T{g[2]} B{g[3]}.\n'
                     f'  A gutter here shrinks the glyph in a 16px Start Menu row.')

print('masters: 1024 canvas with a 100px gutter, 824 full-bleed -- both as documented')
PY

# ─── 2. the .icns, from the 1024 canvas ────────────────────────────────────────
# THE @2x RUNGS ARE WHAT MAKE 64 AND 1024 APPEAR. iconutil derives the chunk type from the
# filename, so the set of names here IS the set of sizes 10-static.sh asserts on.
SET="$TMP/cs193v.iconset"
mkdir -p "$SET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x \
            128:128x128 256:128x128@2x 256:256x256 512:256x256@2x \
            512:512x512 1024:512x512@2x; do
    px="${spec%%:*}"
    name="${spec#*:}"
    sips -z "$px" "$px" "$M1024" --out "$SET/icon_$name.png" >/dev/null
done
iconutil -c icns "$SET" -o "$HERE/cs193v.icns"

# ─── 3. the .ico, from the 824 artwork ─────────────────────────────────────────
# BMP BELOW 256 AND PNG AT 256, which is the conservative split and what ImageMagick emits.
# Windows has read PNG-compressed entries at every size since Vista, so all-PNG would very
# probably work -- but this repo has no way to TEST a Windows shell from here (27-installer-*
# drives the .cmd under wine, which renders nothing), and an icon that is wrong on somebody
# else's machine is exactly the failure a manual check finds last. Cheap to be conservative.
for px in 16 20 24 32 48 64 256; do
    sips -z "$px" "$px" "$M824" --out "$TMP/$px.png" >/dev/null
done
python3 - "$HERE/cs193v.ico" "$TMP" 16 20 24 32 48 64 256 <<'PY'
import sys, zlib, struct

def rgba(path):
    d = open(path, 'rb').read()
    pos, idat, ihdr = 8, bytearray(), None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        if typ == b'IHDR':
            ihdr = struct.unpack('>IIBBBBB', d[pos + 8:pos + 8 + ln])
        elif typ == b'IDAT':
            idat += d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    w, h, depth, ctype, _, _, inter = ihdr
    if (depth, ctype, inter) != (8, 6, 0):
        raise SystemExit(f'{path}: sips produced depth={depth} colour-type={ctype} '
                         f'interlace={inter}; this packer needs 8-bit RGBA non-interlaced')
    raw = zlib.decompress(bytes(idat))
    stride, bpp = w * 4, 4
    out, prev, p = bytearray(), bytearray(stride), 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc
                                      else b if pb <= pc else c)) & 255
        elif f != 0:
            raise SystemExit(f'{path}: unknown PNG filter {f}')
        out += line
        prev = line
    return w, h, out

def dib(w, h, px):
    # BITMAPINFOHEADER with biHeight DOUBLED: an icon entry carries the colour bitmap and an AND
    # mask stacked in one image. 32bpp makes the mask redundant -- Windows uses the alpha -- but
    # a reader that trusts biHeight still walks off the end if it is not there.
    hdr = struct.pack('<IiiHHIIiiII', 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    rows = bytearray()
    for y in range(h - 1, -1, -1):                       # DIBs are bottom-up
        row = px[y * w * 4:(y + 1) * w * 4]
        for x in range(w):
            r, g, b, a = row[x * 4:x * 4 + 4]
            rows += bytes((b, g, r, a))                  # BGRA
    mask = bytearray(((w + 31) // 32) * 4 * h)           # all zero: every pixel shown
    return bytes(hdr) + bytes(rows) + bytes(mask)

out, tmp, sizes = sys.argv[1], sys.argv[2], [int(s) for s in sys.argv[3:]]
images = []
for px in sizes:
    path = f'{tmp}/{px}.png'
    if px >= 256:
        images.append((px, open(path, 'rb').read()))      # PNG-compressed entry
    else:
        w, h, raw = rgba(path)
        if (w, h) != (px, px):
            raise SystemExit(f'{path}: sips produced {w}x{h}, expected {px}x{px}')
        images.append((px, dib(w, h, raw)))

offset = 6 + 16 * len(images)
blob, directory = bytearray(), bytearray()
for px, data in images:
    directory += struct.pack('<BBBBHHII',
                             0 if px >= 256 else px,      # 0 means 256
                             0 if px >= 256 else px,
                             0, 0, 1, 32, len(data), offset)
    blob += data
    offset += len(data)
with open(out, 'wb') as f:
    f.write(struct.pack('<HHH', 0, 1, len(images)))
    f.write(bytes(directory))
    f.write(bytes(blob))
print(f'ico: {len(images)} entries, sizes {" ".join(str(s) for s in sizes)}')
PY

printf 'wrote %s\n' "$HERE/cs193v.icns" "$HERE/cs193v.ico"
