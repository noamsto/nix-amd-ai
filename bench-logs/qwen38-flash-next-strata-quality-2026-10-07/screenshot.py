#!/usr/bin/env python3
"""Render a deterministic 1280x800 editor-and-terminal screenshot from this repo's own source, for the image group.

    screenshot.py <out.png> [repo path ...]      (needs Pillow; STRATA_PY's environment has it)

1280x800 is 1,024,000 pixels, about 1,000 tokens at the Qwen-VL 32x32 pixels per token, so the encoder's 1,024-token cap
is reached without a resize. The picture is synthetic: a dark window with a sidebar, a code pane with line numbers and
syntax colours, and a terminal pane, filled with the first lines of the given files (default: this directory's own
scripts). It stands in for a screenshot of a desktop; it is not one.
"""
import os
import re
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 800
BG, PANEL, BAR, FG, DIM = (30, 31, 38), (24, 25, 31), (40, 42, 54), (220, 223, 228), (110, 115, 130)
KEY, STR, COM, NUM = (198, 120, 221), (152, 195, 121), (92, 99, 112), (209, 154, 102)


def font(size):
    path = subprocess.run(["fc-match", "monospace", "--format", "%{file}"], capture_output=True, text=True).stdout.strip()
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default(size)


def colour(tok):
    if re.fullmatch(r"(def|class|import|from|return|if|else|elif|for|while|in|not|and|or|with|as|try|except|set|case|esac|fi|do|done|then)", tok):
        return KEY
    if tok.startswith(("#", "//")):
        return COM
    if tok[:1] in "\"'":
        return STR
    if tok[:1].isdigit():
        return NUM
    return FG


def draw_code(d, f, lines, x, y, line_h, max_chars, n):
    for i, line in enumerate(lines[:n]):
        d.text((x, y + i * line_h), f"{i + 1:3d}", font=f, fill=DIM)
        cx = x + 44
        for tok in re.findall(r"\s+|#.*|//.*|\"[^\"]*\"|'[^']*'|\w+|.", line.rstrip()[:max_chars]):
            d.text((cx, y + i * line_h), tok, font=f, fill=colour(tok))
            cx += d.textlength(tok, font=f)


def main():
    out, files = sys.argv[1], sys.argv[2:] or [os.path.join(os.path.dirname(os.path.abspath(__file__)), n)
                                              for n in ("kl_strata.py", "soak.py", "rows.sh")]
    if len(files) < 3:
        sys.exit("screenshot.py needs at least three files (editor, terminal, second editor column)")
    src = [open(p, encoding="utf-8").read().splitlines() for p in files]
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    f, small = font(14), font(12)
    d.rectangle((0, 0, W, 28), fill=BAR)
    d.text((12, 6), "  ".join(os.path.basename(p) for p in files), font=small, fill=FG)
    d.rectangle((0, 28, 190, H), fill=PANEL)
    for i, p in enumerate(files + ["README.md", "bench-logs/", "pkgs/strata/", "docs/", "flake.nix"]):
        d.text((14, 44 + i * 22), os.path.basename(p.rstrip("/")) + ("/" if p.endswith("/") else ""), font=small, fill=FG if i == 0 else DIM)
    draw_code(d, f, src[0], 200, 40, 18, 52, 28)
    d.rectangle((200, 548, W, H), fill=PANEL)
    d.line((200, 548, W, 548), fill=BAR, width=2)
    term = ["$ nix build .#strata -o result-strata", "building '/nix/store/...-strata-0-unstable.drv'...",
            "$ bash rows.sh kl 64 def fast"] + [s for s in src[1][:9]] + ["$ _"]
    for i, line in enumerate(term[:13]):
        d.text((212, 556 + i * 18), line[:100], font=f, fill=STR if line.startswith("$") else FG)
    d.rectangle((0, H - 22, W, H), fill=(60, 90, 160))
    d.text((12, H - 18), "main  0 errors  1 warning        Ln 14, Col 8     UTF-8     Python", font=small, fill=FG)
    # a second, narrower code column so the pixels carry text the way a split editor does
    draw_code(d, f, src[2], 780, 40, 18, 49, 28)
    im.save(out, optimize=True)
    print(f"{out}: {os.path.getsize(out)} bytes, {W}x{H}")


if __name__ == "__main__":
    main()
