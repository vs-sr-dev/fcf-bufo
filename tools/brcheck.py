#!/usr/bin/env python3
"""
brcheck.py - verify that every relative branch in a dasm listing really
             lands on the label written in the source.

Why it exists: F8 branches carry a displacement of ONE signed byte
(-128..+127). If the label is farther away, dasm **truncates the value
without emitting any error** and the program jumps somewhere arbitrary.
This actually happened:

    09e5   94 7f   bnz lu_lane      ->  09e6 + 127 = 0a65   (inside edge_run)

-129 was needed. The result was a loop that never iterated plus a band of
random pixels on screen: symptoms that look like bugs in the code.

Usage:
    python brcheck.py build/bufo.lst
Exits with code 1 if it finds at least one wrong branch.
"""
import re
import sys

# F8 relative-branch instructions: opcode + 1 displacement byte
BRANCH = {
    "br", "bp", "bc", "bz", "bt", "bm", "bnc", "bnz", "bno", "bf", "br7",
}

# listing lines: line number, address, hex bytes, source
LINE = re.compile(
    r"^\s*(\d+)\s+([0-9a-f]{4})\s+([0-9a-f ]*?)\s{2,}(.*)$", re.I)


def parse(path):
    """Return (labels, branch instructions)."""
    labels, branches = {}, []
    for raw in open(path, encoding="utf-8", errors="replace"):
        m = LINE.match(raw.rstrip("\n"))
        if not m:
            continue
        lineno, addr, byts, src = m.groups()
        addr = int(addr, 16)
        src = src.split(";")[0].rstrip()
        if not src:
            continue
        # label-only line: no bytes emitted
        if not byts.strip():
            name = src.strip()
            if re.fullmatch(r"[A-Za-z_.][\w.]*", name):
                labels[name] = addr
            continue
        parts = src.split()
        if not parts:
            continue
        mnem, rest = parts[0].lower(), parts[1:]
        if mnem not in BRANCH or not rest:
            continue
        hexb = byts.split()
        if len(hexb) != 2:
            continue
        disp = int(hexb[1], 16)
        if disp > 127:
            disp -= 256
        branches.append((int(lineno), addr, mnem, rest[0], disp))
    return labels, branches


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    labels, branches = parse(sys.argv[1])
    bad = 0
    checked = 0
    for lineno, addr, mnem, target, disp in branches:
        if target not in labels:
            continue                      # non-symbolic operand: skip
        checked += 1
        want = labels[target]
        got = addr + 1 + disp             # confirmed against a correct branch
        if got != want:
            bad += 1
            need = want - (addr + 1)
            print(f"  line {lineno}: {mnem} {target}")
            print(f"    at ${addr:04X}: lands on ${got:04X}, "
                  f"but {target} is at ${want:04X}")
            if -128 <= need <= 127:
                # the right displacement would have fit: this is not a
                # truncation, it is emitted bytes disagreeing with the source
                print(f"    emitted displacement {disp:+d}, "
                      f"needed {need:+d} (in range): INCONSISTENT")
            else:
                print(f"    needed displacement {need:+d} "
                      f"(outside -128..+127): TRUNCATED, "
                      f"split the jump or use jmp")
    print(f"brcheck: {checked} branches verified, {bad} wrong")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
