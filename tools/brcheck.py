#!/usr/bin/env python3
"""
brcheck.py - verifica che ogni branch relativo del listato dasm atterri
             davvero sull'etichetta scritta nel sorgente.

Perche' esiste: i branch della F8 hanno uno spostamento di UN byte con
segno (-128..+127). Se l'etichetta e' piu' lontana, dasm **tronca il
valore senza emettere alcun errore** e il programma salta in un punto
arbitrario. E' successo davvero:

    09e5   94 7f   bnz lu_lane      ->  09e6 + 127 = 0a65   (dentro edge_run)

servivano -129. Il risultato era un loop che non iterava mai e una banda
di pixel casuali sullo schermo: sintomi che sembrano bug del codice.

Uso:
    python brcheck.py build/bufo.lst
Esce con codice 1 se trova almeno un branch sbagliato.
"""
import re
import sys

# istruzioni di salto relativo della F8: opcode + 1 byte di spostamento
BRANCH = {
    "br", "bp", "bc", "bz", "bt", "bm", "bnc", "bnz", "bno", "bf", "br7",
}

# righe del listato: numero, indirizzo, byte esadecimali, sorgente
LINE = re.compile(
    r"^\s*(\d+)\s+([0-9a-f]{4})\s+([0-9a-f ]*?)\s{2,}(.*)$", re.I)


def parse(path):
    """Ritorna (etichette, istruzioni di salto)."""
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
        # riga di sola etichetta: nessun byte emesso
        if not byts.strip():
            name = src.strip()
            if re.fullmatch(r"[A-Za-z_.][\w.]*", name):
                labels[name] = addr
            continue
        parts = src.split()
        if not parts:
            continue
        # il sorgente puo' iniziare con un'etichetta sulla stessa riga
        if len(parts) >= 2 and parts[0].lower() not in BRANCH:
            mnem, rest = parts[0].lower(), parts[1:]
        else:
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
            continue                      # operando non simbolico: salto
        checked += 1
        want = labels[target]
        got = addr + 1 + disp             # verificato su un branch corretto
        if got != want:
            bad += 1
            need = want - (addr + 1)
            print(f"  riga {lineno}: {mnem} {target}")
            print(f"    a ${addr:04X}: atterra a ${got:04X}, "
                  f"ma {target} e' a ${want:04X}")
            if -128 <= need <= 127:
                # lo spostamento giusto ci stava: non e' un troncamento,
                # e' un'incoerenza fra byte emessi e sorgente
                print(f"    spostamento emesso {disp:+d}, "
                      f"necessario {need:+d} (in portata): INCOERENTE")
            else:
                print(f"    spostamento necessario {need:+d} "
                      f"(fuori da -128..+127): TRONCATO, "
                      f"spezzare il salto o usare jmp")
    print(f"brcheck: {checked} branch verificati, {bad} sbagliati")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
