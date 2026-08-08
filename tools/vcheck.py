#!/usr/bin/env python3
"""
vcheck.py - campiona uno snapshot MAME del Channel F in coordinate VRAM.

Lo snapshot MAME contiene l'area visibile del Channel F, cioe' le colonne
4..105 e le righe 4..61 della VRAM, scalate di un fattore intero.
Questo script fa la conversione inversa: dato (x,y) in coordinate VRAM,
dice che colore c'e'.

Uso:
    python vcheck.py shot.png                    # mappa d'insieme
    python vcheck.py shot.png 20,17 40,17 60,17  # campiona punti precisi
"""
import sys
from PIL import Image

# Gli 8 colori fisici del Channel F (da MAME channelf_v.cpp)
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

# area visibile della VRAM
VIS_X0, VIS_Y0, VIS_W, VIS_H = 4, 4, 102, 58


def nearest(rgb):
    """Nome del colore Channel F piu' vicino, piu' la distanza."""
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
        # lo snapshot copre l'area visibile: ricava la scala
        self.sx = w / VIS_W
        self.sy = h / VIS_H
        self.size = (w, h)

    def at(self, vx, vy):
        """Colore alla coordinata VRAM (vx, vy)."""
        px = int((vx - VIS_X0 + 0.5) * self.sx)
        py = int((vy - VIS_Y0 + 0.5) * self.sy)
        px = max(0, min(self.size[0] - 1, px))
        py = max(0, min(self.size[1] - 1, py))
        return self.img.getpixel((px, py))

    def name_at(self, vx, vy):
        return nearest(self.at(vx, vy))[0]


def overview(shot):
    """Stampa il colore dominante di ogni riga VRAM visibile."""
    print(f"snapshot {shot.size[0]}x{shot.size[1]}  "
          f"scala {shot.sx:.2f}x{shot.sy:.2f}")
    print()
    print(" riga | colore prevalente (campionato a x=8,12,...)")
    print("------+------------------------------------------------")
    prev, start = None, VIS_Y0
    for vy in range(VIS_Y0, VIS_Y0 + VIS_H):
        names = [shot.name_at(vx, vy) for vx in range(8, 100, 4)]
        dom = max(set(names), key=names.count)
        if dom != prev:
            if prev is not None:
                print(f" {start:2d}-{vy-1:2d} | {prev}")
            prev, start = dom, vy
    print(f" {start:2d}-{VIS_Y0+VIS_H-1:2d} | {prev}")


# un carattere per colore, per la mappa integrale
GLYPH = {
    "BLACK": ".", "WHITE": "#", "RED": "R", "GREEN": "G",
    "BLUE": "B", "LTGRAY": "g", "LTGREEN": "n", "LTBLUE": "c",
}


def fullmap(shot):
    """Stampa OGNI pixel visibile: niente campionamento, niente scelte mie."""
    print(f"snapshot {shot.size[0]}x{shot.size[1]}  "
          f"scala {shot.sx:.2f}x{shot.sy:.2f}")
    print("legenda: . nero  # bianco  R rosso  G verde  "
          "B blu  g grigioch  n verdech  c azzurro")
    print()
    # righello delle colonne (decine e unita')
    xs = range(VIS_X0, VIS_X0 + VIS_W)
    print("     " + "".join(str(x // 10 % 10) for x in xs))
    print("     " + "".join(str(x % 10) for x in xs))
    for vy in range(VIS_Y0, VIS_Y0 + VIS_H):
        row = "".join(GLYPH.get(shot.name_at(vx, vy), "?") for vx in xs)
        print(f" y{vy:2d} {row}")


def diff(pa, pb):
    """Confronta due snapshot riga per riga: quante colonne sono cambiate
    e di quanto si e' spostato il contenuto (correlazione a scorrimento)."""
    a, b = Shot(pa), Shot(pb)
    xs = list(range(VIS_X0, VIS_X0 + VIS_W))
    print(" riga | cambi | scorrimento stimato (px, + = destra)")
    print("------+-------+-------------------------------------")
    for vy in range(VIS_Y0, VIS_Y0 + VIS_H):
        ra = [a.name_at(vx, vy) for vx in xs]
        rb = [b.name_at(vx, vy) for vx in xs]
        changed = sum(1 for u, v in zip(ra, rb) if u != v)
        best, bestd = 0, -1
        if changed:
            # cerca lo shift che allinea meglio la riga vecchia sulla nuova
            for d in range(-40, 41):
                m = sum(1 for i, v in enumerate(rb)
                        if 0 <= i - d < len(ra) and ra[i - d] == v)
                if m > bestd:
                    best, bestd = d, m
        note = "" if not changed else f"{best:+3d}  (match {bestd}/{len(xs)})"
        print(f" y{vy:2d}  | {changed:5d} | {note}")


def game(paths):
    """Riassume lo stato di gioco leggibile dallo schermo, per ogni shot:
    dove sta il rospo, quante vite, quanto tempo, e se c'e' un oggetto
    sotto la colonna centrale del rospo (cioe' se la morte e' motivata)."""
    LANE_Y0, LANE_H = 12, 5
    print("  shot | corsia  y      x    | vite | tempo | sotto il centro")
    print("-------+---------------------+------+-------+----------------")
    for p in paths:
        s = Shot(p)
        # il rospo e' l'unico verde fuori dalla fascia di status
        pix = [(vx, vy)
               for vy in range(LANE_Y0, VIS_Y0 + VIS_H)
               for vx in range(VIS_X0, VIS_X0 + VIS_W)
               if s.name_at(vx, vy) == "GREEN"]
        if pix:
            y0 = min(v for _, v in pix)
            x0 = min(u for u, _ in pix)
            lane = (y0 - LANE_Y0) // LANE_H
            # Cosa c'e' nella corsia accanto al rospo. Non si puo'
            # leggere direttamente sotto la sua colonna centrale: lo
            # sprite la riempie su tutte e quattro le righe (di
            # proposito, e' la colonna che check_frog esamina) e si
            # leggerebbe il rospo stesso.
            # I due vicini bastano: gli oggetti sono larghi almeno 8 e
            # il rospo 5, quindi se un oggetto copre il centro deborda
            # per forza da almeno un lato.
            under = (f"{s.name_at(x0 - 1, y0 + 1)}|"
                     f"{s.name_at(x0 + 5, y0 + 1)}")
            pos = f"{lane:2d}   {y0:2d}    {x0:3d}"
        else:
            lane, pos, under = -1, " -    -      -", "-"
        lives = sum(1 for vx in range(78, 90)
                    if s.name_at(vx, 6) == "WHITE") // 3
        timer = sum(1 for vx in range(4, 100) if s.name_at(vx, 9) == "WHITE")
        name = p.split("/")[-1].split("\\")[-1]
        print(f" {name:5s} | {pos} | {lives:4d} | {timer:5d} | {under}")


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
