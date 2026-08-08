#!/usr/bin/env python3
"""
vcheck.py - sample a MAME Channel F snapshot in VRAM coordinates.

A MAME snapshot holds the Channel F's visible area, i.e. VRAM columns
4..105 and rows 4..61, scaled by an integer factor. This script does the
inverse conversion: given (x,y) in VRAM coordinates, it tells you which
colour is there.

Usage:
    python vcheck.py shot.png                    # per-row overview
    python vcheck.py shot.png --map              # every visible pixel, as ASCII
    python vcheck.py --diff a.png b.png          # what moved between two shots
    python vcheck.py --game a.png b.png ...      # game state, per snapshot
    python vcheck.py shot.png 20,17 40,17        # sample exact points
"""
import sys
from PIL import Image

# the 8 physical colours of the Channel F (from MAME channelf_v.cpp)
PALETTE = {
    (0x10, 0x10, 0x10): "BLACK",
    (0xfd, 0xfd, 0xfd): "WHITE",
    (0xff, 0x31, 0x53): "RED",
    (0x02, 0xcc, 0x5d): "GREEN",
    (0x4b, 0x3f, 0xf3): "BLUE",
    (0xe0, 0xe0, 0xe0): "LTGRAY",
    (0x91, 0xff, 0xa6): "LTGREEN",
    (0xce, 0xd0, 0xff): "LTBLUE",
}

# the visible area of VRAM
VIS_X0, VIS_Y0, VIS_W, VIS_H = 4, 4, 102, 58


def nearest(rgb):
    """Name of the closest Channel F colour, plus the distance."""
    best, bestd = None, 1 << 30
    for ref, name in PALETTE.items():
        d = sum((a - b) ** 2 for a, b in zip(rgb, ref))
        if d < bestd:
            best, bestd = name, d
    return best, bestd


class Shot:
    def __init__(self, path):
        self.img = Image.open(path).convert("RGB")
        w, h = self.img.size
        # the snapshot covers the visible area: derive the scale from it
        self.sx = w / VIS_W
        self.sy = h / VIS_H
        self.size = (w, h)

    def at(self, vx, vy):
        """Colour at VRAM coordinate (vx, vy)."""
        px = int((vx - VIS_X0 + 0.5) * self.sx)
        py = int((vy - VIS_Y0 + 0.5) * self.sy)
        px = max(0, min(self.size[0] - 1, px))
        py = max(0, min(self.size[1] - 1, py))
        return self.img.getpixel((px, py))

    def name_at(self, vx, vy):
        return nearest(self.at(vx, vy))[0]


def overview(shot):
    """Print the dominant colour of every visible VRAM row."""
    print(f"snapshot {shot.size[0]}x{shot.size[1]}  "
          f"scale {shot.sx:.2f}x{shot.sy:.2f}")
    print()
    print(" row   | dominant colour (sampled at x=8,12,...)")
    print("-------+------------------------------------------------")
    prev, start = None, VIS_Y0
    for vy in range(VIS_Y0, VIS_Y0 + VIS_H):
        names = [shot.name_at(vx, vy) for vx in range(8, 100, 4)]
        dom = max(set(names), key=names.count)
        if dom != prev:
            if prev is not None:
                print(f" {start:2d}-{vy-1:2d} | {prev}")
            prev, start = dom, vy
    print(f" {start:2d}-{VIS_Y0+VIS_H-1:2d} | {prev}")


# one character per colour, for the full map
GLYPH = {
    "BLACK": ".", "WHITE": "#", "RED": "R", "GREEN": "G",
    "BLUE": "B", "LTGRAY": "g", "LTGREEN": "n", "LTBLUE": "c",
}


def fullmap(shot):
    """Print EVERY visible pixel: no sampling, no choices of mine."""
    print(f"snapshot {shot.size[0]}x{shot.size[1]}  "
          f"scale {shot.sx:.2f}x{shot.sy:.2f}")
    print("key: . black  # white  R red  G green  "
          "B blue  g ltgray  n ltgreen  c ltblue")
    print()
    # column ruler (tens and units)
    xs = range(VIS_X0, VIS_X0 + VIS_W)
    print("     " + "".join(str(x // 10 % 10) for x in xs))
    print("     " + "".join(str(x % 10) for x in xs))
    for vy in range(VIS_Y0, VIS_Y0 + VIS_H):
        row = "".join(GLYPH.get(shot.name_at(vx, vy), "?") for vx in xs)
        print(f" y{vy:2d} {row}")


def diff(pa, pb):
    """Compare two snapshots row by row: how many columns changed, and how
    far the content shifted (by sliding correlation)."""
    a, b = Shot(pa), Shot(pb)
    xs = list(range(VIS_X0, VIS_X0 + VIS_W))
    print(" row  | chgd  | estimated shift (px, + = right)")
    print("------+-------+-------------------------------------")
    for vy in range(VIS_Y0, VIS_Y0 + VIS_H):
        ra = [a.name_at(vx, vy) for vx in xs]
        rb = [b.name_at(vx, vy) for vx in xs]
        changed = sum(1 for u, v in zip(ra, rb) if u != v)
        best, bestd = 0, -1
        if changed:
            # find the shift that best aligns the old row onto the new one
            for d in range(-40, 41):
                m = sum(1 for i, v in enumerate(rb)
                        if 0 <= i - d < len(ra) and ra[i - d] == v)
                if m > bestd:
                    best, bestd = d, m
        note = "" if not changed else f"{best:+3d}  (match {bestd}/{len(xs)})"
        print(f" y{vy:2d}  | {changed:5d} | {note}")
    print()
    print("NOTE: the lane patterns are periodic, so the shift is only")
    print("determined modulo the lane's period (+12 can be -20 at period 32).")
    print("Always compare against the period before calling a direction wrong.")


def game(paths):
    """Summarise the game state readable off the screen, per snapshot: where
    the toad is, lives, time left, and what sits next to it."""
    LANE_Y0, LANE_H = 12, 5
    print("  shot | lane    y      x    | lives | time  | beside the toad")
    print("-------+---------------------+-------+-------+----------------")
    for p in paths:
        s = Shot(p)
        # the toad is the only green thing outside the status band
        pix = [(vx, vy)
               for vy in range(LANE_Y0, VIS_Y0 + VIS_H)
               for vx in range(VIS_X0, VIS_X0 + VIS_W)
               if s.name_at(vx, vy) == "GREEN"]
        if pix:
            y0 = min(v for _, v in pix)
            x0 = min(u for u, _ in pix)
            lane = (y0 - LANE_Y0) // LANE_H
            # What the lane holds next to the toad. It cannot be read
            # directly under its centre column: the sprite fills that
            # column on all four rows (deliberately - it is the column
            # check_frog examines), so you would read the toad itself.
            # The two neighbours are enough: objects are at least 8 wide
            # and the toad is 5, so anything covering the centre has to
            # stick out on at least one side.
            under = (f"{s.name_at(x0 - 1, y0 + 1)}|"
                     f"{s.name_at(x0 + 5, y0 + 1)}")
            pos = f"{lane:2d}   {y0:2d}    {x0:3d}"
        else:
            lane, pos, under = -1, " -    -      -", "-"
        lives = sum(1 for vx in range(78, 90)
                    if s.name_at(vx, 6) == "WHITE") // 3
        timer = sum(1 for vx in range(4, 100) if s.name_at(vx, 9) == "WHITE")
        name = p.split("/")[-1].split("\\")[-1]
        print(f" {name:5s} | {pos} | {lives:5d} | {timer:5d} | {under}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    if sys.argv[1] == "--game":
        game(sys.argv[2:])
        return 0
    if sys.argv[1] == "--diff":
        diff(sys.argv[2], sys.argv[3])
        return 0
    shot = Shot(sys.argv[1])
    pts = sys.argv[2:]
    if pts and pts[0] == "--map":
        fullmap(shot)
        return 0
    if not pts:
        overview(shot)
        return 0
    for p in pts:
        vx, vy = (int(v) for v in p.split(","))
        rgb = shot.at(vx, vy)
        name, dist = nearest(rgb)
        flag = "" if dist == 0 else f"  (approx, d={dist})"
        print(f"({vx:3d},{vy:2d}) rgb={rgb}  ->  {name}{flag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
