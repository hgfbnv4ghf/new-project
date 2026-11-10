#!/usr/bin/env python3
"""Draws the 1024px app icon (a prompt chevron and cursor) without third-party packages."""
import struct
import sys
import zlib

SIZE = 1024
BG = (13, 14, 17)
ACCENT = (217, 130, 95)
TEXT = (228, 228, 231)


def distance_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return ((px - ax - t * dx) ** 2 + (py - ay - t * dy) ** 2) ** 0.5


def pixel(x, y):
    # Chevron: two strokes meeting at the right.
    if min(distance_to_segment(x, y, 250, 330, 470, 512),
           distance_to_segment(x, y, 470, 512, 250, 694)) <= 46:
        return ACCENT
    # Block cursor.
    if 560 <= x <= 790 and 610 <= y <= 700:
        return TEXT
    return BG


def main(path):
    rows = bytearray()
    for y in range(SIZE):
        rows.append(0)
        for x in range(SIZE):
            rows.extend(pixel(x, y))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


if __name__ == "__main__":
    main(sys.argv[1])
