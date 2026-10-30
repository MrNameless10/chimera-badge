import sys

HEADS = [
    [".BB......BB.", ".BAB....BAB.", ".BBBBBBBBBB.", "BBWPBBBBWPBB", "BBWWBBBBWWBB", "BBBBBAABBBBB", ".BBBBBBBBBB."],
    ["..BB....BB..", "..BA....AB..", "..BA....AB..", ".BBBBBBBBBB.", "BBWPBBBBWPBB", "BBBBBAABBBBB", ".BBBBBBBBBB."],
    [".B........B.", ".BB......BB.", ".BBBBBBBBBB.", "BWWWBBBBWWWB", "BWPWBBBBWPWB", "BBBBBAABBBBB", ".BBBBAABBBB."],
    [".BBB....BBB.", "BWWPB..BWWPB", "BBBBBBBBBBBB", "BBBBBBBBBBBB", "BAAAAAAAAAAB", ".BBBBBBBBBB.", "............"],
    ["A..........A", ".A........A.", ".BBBBBBBBBB.", "BBWPBBBBWPBB", "BBBBBBBBBBBB", "BBBBAAAABBBB", ".BBBBBBBBBB."],
    [".....BB.....", "....BBBB....", "..BBBBBBBB..", ".BBWPBBWPBB.", "BBBBBBBBBBBB", "BBBBBAABBBBB", "BBBBBBBBBBBB"],
    ["..A......A..", "...A....A...", "..BBBBBBBB..", ".BBWPBBWPBB.", "BBBBBBBBBBBB", "BBBBBBBBBBBB", ".BA.BBBB.AB."],
    [".BB......BB.", "BBAB....BABB", "BBBBBBBBBBBB", "BBWPBBBBWPBB", "BBBBBBBBBBBB", ".BBLLPPLLBB.", "..BBLLLLBB.."],
]
BODIES = [
    ["..BBBBBBBB..", ".BBLLLLLLBB.", "BBBLLLLLLBBB", ".BBLLLLLLBB.", "..BBBBBBBB..", "..BB....BB.."],
    ["A.BBBBBBBB.A", "AABLLLLLLBAA", "AABLLLLLLBAA", ".ABLLLLLLBA.", "..BBBBBBBB..", "...B....B..."],
    ["..BBBBBBBB..", ".BBLLLLLLBB.", ".BBLLLLLLBBA", ".BBBBBBBBBAA", "..BB...BBAA.", "..BB...BB..."],
    ["..BBBBBBBB..", ".BBLLLLLLBBA", "BBBLLLLLLBAA", ".BBLLLLLLBBA", "..BBBBBBBB..", "............"],
    ["..AAAAAAAA..", ".AAAAAAAAAA.", ".ABBBBBBBBA.", ".AAAAAAAAAA.", "..AAAAAAAA..", "..BB....BB.."],
    ["B.BBBBBBBB.B", ".BBLLLLLLBB.", "BBBLLLLLLBBB", ".BBLLLLLLBB.", "B.BBBBBBBB.B", ".B........B."],
    ["BBBBBBBBBBBB", "BBBLLLLLLBBB", "BBBLLLLLLBBB", "BBBBBBBBBBBB", "BBB.BBBB.BBB", ".B...BB...B."],
    ["..AAAAAAAA..", "..BBBBBBBB..", ".ABLLAALLBA.", "..BBBBBBBB..", "..AAAAAAAA..", "..BB....BB.."],
]
FEET = ["..BB....BB.."]
COLOUR = {"B": 1, "L": 2, "A": 3, "W": 4, "P": 5}
ROWS = 13


def sprite(head, body, stage):
    if stage == 0:
        return ["." * 12] * (ROWS - 8) + HEADS[head] + FEET
    if stage == 1:
        return HEADS[head] + [r.replace("A", ".") for r in BODIES[body]]
    return HEADS[head] + BODIES[body]


def combat(grid):
    top = ROWS - 8 if grid[0] == "." * 12 else 0
    out = []
    for y, r in enumerate(grid):
        head = y < top + 7
        out.append("".join("B" if c in ("LWA" if head else "LW") else c for c in r))
    return out


def scan(grid):
    h, w = len(grid), len(grid[0])
    used = [[False] * w for _ in range(h)]
    out = []
    for y in range(h):
        for x in range(w):
            c = grid[y][x]
            if c == "." or used[y][x]:
                continue
            x2 = x
            while x2 + 1 < w and grid[y][x2 + 1] == c and not used[y][x2 + 1]:
                x2 += 1
            y2 = y
            while y2 + 1 < h and all(grid[y2 + 1][i] == c and not used[y2 + 1][i] for i in range(x, x2 + 1)):
                y2 += 1
            for yy in range(y, y2 + 1):
                for xx in range(x, x2 + 1):
                    used[yy][xx] = True
            out.append((x, y, x2 - x + 1, y2 - y + 1, c))
    return out


def largest(grid):
    h, w = len(grid), len(grid[0])
    left = [[c != "." for c in r] for r in grid]
    out = []
    while True:
        best = None
        for y in range(h):
            for x in range(w):
                if not left[y][x]:
                    continue
                c, ww = grid[y][x], 0
                while x + ww < w and left[y][x + ww] and grid[y][x + ww] == c:
                    ww += 1
                hh = 0
                while y + hh < h:
                    k = 0
                    while k < ww and left[y + hh][x + k] and grid[y + hh][x + k] == c:
                        k += 1
                    if not k:
                        break
                    ww, hh = k, hh + 1
                    if best is None or ww * hh > best[2] * best[3]:
                        best = (x, y, ww, hh, c)
        if best is None:
            return out
        x, y, ww, hh, _ = best
        for yy in range(y, y + hh):
            for xx in range(x, x + ww):
                left[yy][xx] = False
        out.append(best)


def cover(grid):
    t = ["".join(r[x] for r in grid) for x in range(len(grid[0]))]
    flip = [(y, x, h, w, c) for x, y, w, h, c in scan(t)]
    return min((scan(grid), flip, largest(grid)), key=len)


def build():
    records = []
    for stage in range(3):
        for lod in range(2):
            for head in range(8):
                for body in range(8):
                    g = sprite(head, body, stage)
                    rs = cover(combat(g) if lod else g)
                    data = bytearray([len(rs)])
                    for x, y, w, h, c in rs:
                        data += bytes([x << 4 | y, (w - 1) << 4 | (h - 1), COLOUR[c]])
                    records.append(bytes(data))
    index_size = 2 * len(records)
    index, blob, offset = bytearray(), bytearray(), index_size
    for r in records:
        index += bytes([offset >> 8, offset & 255])
        blob += r
        offset += len(r)
    return bytes(index + blob), records


if __name__ == "__main__":
    data, records = build()
    open(sys.argv[1], "wb").write(data)
    counts = [r[0] for r in records]
    print(len(data), "bytes,", len(records), "sprites, max rects full", max(counts[i] for i in range(len(counts)) if (i // 64) % 2 == 0),
          "combat", max(counts[i] for i in range(len(counts)) if (i // 64) % 2 == 1))
