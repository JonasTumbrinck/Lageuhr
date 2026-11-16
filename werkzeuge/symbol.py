#!/usr/bin/env python3
"""Erzeugt das Programmsymbol (Uhr auf dunklem Grund) als lageuhr.ico und lageuhr.png – nur Standardbibliothek."""
import math, struct, sys, zlib, os

GRUND = (24, 29, 37)
WEISS = (255, 255, 255)
ROT = (230, 57, 70)


def pixel(x, y):
    """x, y in 0..1; liefert (r, g, b, a)."""
    # abgerundetes Quadrat
    r = 0.2
    dx = max(abs(x - 0.5) - (0.5 - r), 0)
    dy = max(abs(y - 0.5) - (0.5 - r), 0)
    if math.hypot(dx, dy) > r:
        return (0, 0, 0, 0)
    cx, cy = x - 0.5, y - 0.5
    d = math.hypot(cx, cy)
    # Ring
    if 0.30 <= d <= 0.37:
        return WEISS + (255,)
    # Markierung bei 12 Uhr
    if abs(cx) < 0.03 and -0.30 < cy < -0.22:
        return ROT + (255,)
    # Zeiger: Stunde Richtung 10 Uhr, Minute Richtung 12 Uhr (wie ein Lagebesprechungs-Termin)
    def zeiger(winkel, laenge, dicke):
        wx, wy = math.sin(winkel), -math.cos(winkel)
        t = cx * wx + cy * wy
        if t < -0.02 or t > laenge:
            return False
        return abs(cx * wy - cy * wx) < dicke
    if zeiger(math.radians(-60), 0.17, 0.035) or zeiger(math.radians(0), 0.24, 0.028):
        return WEISS + (255,)
    if d < 0.045:
        return WEISS + (255,)
    return GRUND + (255,)


def bild(n, ss=4):
    zeilen = []
    for py in range(n):
        zeile = bytearray([0])
        for px in range(n):
            acc = [0, 0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    r, g, b, a = pixel((px + (sx + 0.5) / ss) / n, (py + (sy + 0.5) / ss) / n)
                    acc[0] += r * a; acc[1] += g * a; acc[2] += b * a; acc[3] += a
            a = acc[3]
            if a:
                zeile += bytes([round(acc[0] / a), round(acc[1] / a), round(acc[2] / a), round(a / ss / ss)])
            else:
                zeile += b"\0\0\0\0"
        zeilen.append(bytes(zeile))
    return zeilen


def png(n):
    roh = b"".join(bild(n))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(roh, 9)) + chunk(b"IEND", b""))


def main(ziel):
    groessen = [16, 24, 32, 48, 64, 256]
    pngs = [png(n) for n in groessen]
    kopf = struct.pack("<HHH", 0, 1, len(pngs))
    eintraege, daten = b"", b""
    ofs = 6 + 16 * len(pngs)
    for n, p in zip(groessen, pngs):
        eintraege += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(p), ofs)
        daten += p
        ofs += len(p)
    with open(os.path.join(ziel, "lageuhr.ico"), "wb") as f:
        f.write(kopf + eintraege + daten)
    with open(os.path.join(ziel, "lageuhr.png"), "wb") as f:
        f.write(png(1024 if "--gross" in sys.argv else 512))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else ".")
