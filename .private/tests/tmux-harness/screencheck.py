#!/usr/bin/env python3
"""
Read an ANSI screen dump on stdin (from `tmux capture-pane -p -e`) and check that every
run of text is legible.

Why this exists: students will run the container from whatever terminal they already have,
with whatever color theme it came with. A tab bar styled with, say, bright-white text and
no explicit background looks great on the author's dark theme and is completely invisible
on macOS Terminal.app's default "Basic" light profile. That bug is invisible to a normal
"does the text appear" test, because the text IS there -- it just can't be read.

So each run of same-styled text is resolved to concrete RGB under TWO palettes (a typical
dark theme and a typical light theme) and scored with the WCAG 2.x contrast formula.
A run passes only if it is legible under BOTH.

  --grep TEXT        only analyze rows whose text contains TEXT (repeatable)
  --rows 0,29        only analyze these 0-based row indices
  --min-contrast N   contrast floor, default 4.5 (WCAG AA for normal text)
  --require-explicit fail runs that depend on the theme's own palette (default fg/bg, or
                     ANSI colors 0-15, which every theme redefines). Use this for UI
                     chrome we control, where we want hard-coded, theme-proof colors.
  --json             machine-readable output
"""

import argparse
import json
import re
import sys

# ---------------------------------------------------------------------------
# Palettes
# ---------------------------------------------------------------------------
# ANSI 0-15 are whatever the user's theme says they are, so we evaluate against two
# realistic instantiations. DARK is the xterm/VGA-ish default. LIGHT is modeled on
# macOS Terminal.app "Basic", which is the single most likely profile in a class of
# beginners on Macs.
DARK = {
    "bg": (0x00, 0x00, 0x00), "fg": (0xFF, 0xFF, 0xFF),
    0: (0x00, 0x00, 0x00), 1: (0xCD, 0x00, 0x00), 2: (0x00, 0xCD, 0x00), 3: (0xCD, 0xCD, 0x00),
    4: (0x00, 0x00, 0xEE), 5: (0xCD, 0x00, 0xCD), 6: (0x00, 0xCD, 0xCD), 7: (0xE5, 0xE5, 0xE5),
    8: (0x7F, 0x7F, 0x7F), 9: (0xFF, 0x00, 0x00), 10: (0x00, 0xFF, 0x00), 11: (0xFF, 0xFF, 0x00),
    12: (0x5C, 0x5C, 0xFF), 13: (0xFF, 0x00, 0xFF), 14: (0x00, 0xFF, 0xFF), 15: (0xFF, 0xFF, 0xFF),
}
LIGHT = {
    "bg": (0xFF, 0xFF, 0xFF), "fg": (0x00, 0x00, 0x00),
    0: (0x00, 0x00, 0x00), 1: (0x99, 0x00, 0x00), 2: (0x00, 0xA6, 0x00), 3: (0x99, 0x99, 0x00),
    4: (0x00, 0x00, 0xB2), 5: (0xB2, 0x00, 0xB2), 6: (0x00, 0xA6, 0xB2), 7: (0xBF, 0xBF, 0xBF),
    8: (0x66, 0x66, 0x66), 9: (0xE5, 0x00, 0x00), 10: (0x00, 0xD9, 0x00), 11: (0xE5, 0xE5, 0x00),
    12: (0x00, 0x00, 0xFF), 13: (0xE5, 0x00, 0xE5), 14: (0x00, 0xE5, 0xE5), 15: (0xE5, 0xE5, 0xE5),
}


def cube256(n):
    """xterm 256-color palette entries 16-255 are fixed by spec, so they are theme-proof."""
    if 16 <= n <= 231:
        n -= 16
        levels = (0, 95, 135, 175, 215, 255)
        return (levels[n // 36], levels[(n // 6) % 6], levels[n % 6])
    if 232 <= n <= 255:
        v = 8 + (n - 232) * 10
        return (v, v, v)
    return None


def resolve(color, palette, role):
    """color is None (default), ('idx', n), or ('rgb', r,g,b) -> (r,g,b)."""
    if color is None:
        return palette[role]
    if color[0] == "rgb":
        return tuple(color[1:])
    n = color[1]
    if n < 16:
        return palette[n]
    rgb = cube256(n)
    return rgb if rgb else palette[role]


def theme_dependent(color):
    """True if this color's actual appearance is decided by the user's terminal theme."""
    if color is None:
        return True
    if color[0] == "idx" and color[1] < 16:
        return True
    return False


def luminance(rgb):
    def chan(c):
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (chan(x) for x in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# ---------------------------------------------------------------------------
# ANSI parsing
# ---------------------------------------------------------------------------
CSI_SGR = re.compile(r"\x1b\[([0-9;:]*)m")
OTHER_ESC = re.compile(r"\x1b(?:\][^\x07\x1b]*(?:\x07|\x1b\\)|\[[0-9;:?]*[A-Za-z]|[()][0-9A-Za-z]|[A-Za-z=><])")


class Style:
    __slots__ = ("fg", "bg", "bold", "reverse", "dim")

    def __init__(self):
        self.fg = None
        self.bg = None
        self.bold = False
        self.reverse = False
        self.dim = False

    def copy(self):
        s = Style()
        s.fg, s.bg, s.bold, s.reverse, s.dim = self.fg, self.bg, self.bold, self.reverse, self.dim
        return s

    def key(self):
        return (self.fg, self.bg, self.bold, self.reverse, self.dim)


def apply_sgr(style, params):
    codes = [p for p in params.replace(":", ";").split(";")]
    codes = [int(c) if c.isdigit() else 0 for c in codes] or [0]
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0:
            style.fg = style.bg = None
            style.bold = style.reverse = style.dim = False
        elif c == 1:
            style.bold = True
        elif c == 2:
            style.dim = True
        elif c == 7:
            style.reverse = True
        elif c == 22:
            style.bold = style.dim = False
        elif c == 27:
            style.reverse = False
        elif 30 <= c <= 37:
            style.fg = ("idx", c - 30)
        elif c == 39:
            style.fg = None
        elif 40 <= c <= 47:
            style.bg = ("idx", c - 40)
        elif c == 49:
            style.bg = None
        elif 90 <= c <= 97:
            style.fg = ("idx", c - 90 + 8)
        elif 100 <= c <= 107:
            style.bg = ("idx", c - 100 + 8)
        elif c in (38, 48):
            target = "fg" if c == 38 else "bg"
            if i + 1 < len(codes) and codes[i + 1] == 5:
                setattr(style, target, ("idx", codes[i + 2] if i + 2 < len(codes) else 0))
                i += 2
            elif i + 1 < len(codes) and codes[i + 1] == 2:
                rgb = codes[i + 2:i + 5] + [0, 0, 0]
                setattr(style, target, ("rgb", rgb[0], rgb[1], rgb[2]))
                i += 4
        i += 1
    return style


def parse_rows(text):
    """-> list of rows; each row is a list of (char, Style)."""
    rows = []
    for line in text.split("\n"):
        cells = []
        style = Style()
        pos = 0
        while pos < len(line):
            m = CSI_SGR.match(line, pos)
            if m:
                style = apply_sgr(style.copy(), m.group(1))
                pos = m.end()
                continue
            m = OTHER_ESC.match(line, pos)
            if m:
                pos = m.end()
                continue
            if line[pos] == "\x1b":
                pos += 1
                continue
            cells.append((line[pos], style))
            pos += 1
        rows.append(cells)
    return rows


def runs_of(cells):
    """Group consecutive same-styled cells; skip runs that are only whitespace."""
    out = []
    cur_key = object()
    for idx, (ch, st) in enumerate(cells):
        k = st.key()
        if k != cur_key:
            out.append({"col": idx, "text": ch, "style": st})
            cur_key = k
        else:
            out[-1]["text"] += ch
    return [r for r in out if r["text"].strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grep", action="append", default=[])
    ap.add_argument("--rows", default="")
    ap.add_argument("--min-contrast", type=float, default=4.5)
    ap.add_argument("--require-explicit", action="store_true")
    ap.add_argument("--require-bg", action="store_true",
                    help="every cell in the selected rows must have an explicit background, "
                         "including blank padding. Catches UI chrome whose background falls "
                         "through to the host terminal's own colour.")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--label", default="screen")
    args = ap.parse_args()

    raw = sys.stdin.read()
    rows = parse_rows(raw)

    wanted = set()
    if args.rows:
        wanted |= {int(x) for x in args.rows.split(",") if x.strip()}
    if args.grep:
        for i, cells in enumerate(rows):
            plain = "".join(c for c, _ in cells)
            if any(g in plain for g in args.grep):
                wanted.add(i)
    if not args.rows and not args.grep:
        wanted = {i for i, c in enumerate(rows) if "".join(ch for ch, _ in c).strip()}

    results = []
    failures = 0
    bg_gaps = []
    for i in sorted(wanted):
        if i >= len(rows):
            results.append({"row": i, "error": "row not present in capture"})
            failures += 1
            continue
        # Blank padding is skipped by the contrast check below (there is no text to read), which is
        # exactly where a missing background hides: the row looks styled where the words are and
        # falls through to the host terminal's colour everywhere else.
        if args.require_bg:
            for col, (ch, st) in enumerate(rows[i]):
                bg_spec = st.fg if st.reverse else st.bg
                if theme_dependent(bg_spec):
                    bg_gaps.append({"row": i, "col": col, "char": ch})
                    failures += 1
                    break
        for run in runs_of(rows[i]):
            st = run["style"]
            fg_spec, bg_spec = (st.bg, st.fg) if st.reverse else (st.fg, st.bg)
            scores = {}
            for pname, pal in (("dark", DARK), ("light", LIGHT)):
                fg = resolve(fg_spec, pal, "fg")
                bg = resolve(bg_spec, pal, "bg")
                scores[pname] = round(contrast(fg, bg), 2)
            dep = theme_dependent(fg_spec) or theme_dependent(bg_spec)
            worst = min(scores.values())
            ok = worst >= args.min_contrast and not (args.require_explicit and dep)
            if not ok:
                failures += 1
            results.append({
                "row": i, "col": run["col"], "text": run["text"][:60],
                "fg": fg_spec, "bg": bg_spec, "bold": st.bold, "reverse": st.reverse,
                "contrast_dark": scores["dark"], "contrast_light": scores["light"],
                "theme_dependent": dep, "ok": ok,
            })

    if args.json:
        print(json.dumps({"label": args.label, "failures": failures,
                          "runs": results, "bg_gaps": bg_gaps}, indent=2))
    else:
        print(f"  legibility: {args.label}  (floor {args.min_contrast}:1"
              + (", explicit colors required)" if args.require_explicit else ")"))
        for g in bg_gaps:
            print(f"    FAIL row {g['row']} col {g['col']}: no explicit background "
                  f"(falls through to the host terminal's colour)")
        if not results:
            print("    !! no text runs matched -- nothing was checked")
            failures += 1
        for r in results:
            if "error" in r:
                print(f"    FAIL row {r['row']}: {r['error']}")
                continue
            mark = "ok  " if r["ok"] else "FAIL"
            dep = " theme-dependent" if r["theme_dependent"] else ""
            print(f"    {mark} r{r['row']}c{r['col']:<3} dark={r['contrast_dark']:>5} "
                  f"light={r['contrast_light']:>5}{dep}  {r['text']!r}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
