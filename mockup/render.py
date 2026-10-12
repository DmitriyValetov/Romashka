#!/usr/bin/env python3
"""Макет «ромашки» по данным сканирования: render.py [дерево.json] [выход.png].

Две панели: ① домашний каталог, ② провал в самый тяжёлый сегмент.
Все размеры — реальные, снятые прототипом движка (getattrlistbulk + пул потоков).
"""
import json, math, os, sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "home.json")
OUT = os.path.join(HERE, "romashka_mockup.png")

S = 3                       # суперсэмплинг
PW, PH = 1180, 1260         # размер панели в логических точках
CX, CY = PW // 2, 500
R_OUT, R_CENTER, RINGS = 322, 102, 3

BG = (23, 25, 31)
PANEL_BG = (27, 29, 36)
FG = (234, 237, 243)
DIM = (146, 152, 165)
ACCENT = (94, 168, 255)
GREY = (66, 70, 80)
WARN = (255, 158, 96)
TIP_BG = (44, 48, 58)

FONTS = ["/System/Library/Fonts/Supplemental/Arial.ttf",
         "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
         "/System/Library/Fonts/Helvetica.ttc"]


def font(sz, bold=False):
    for p in FONTS:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, max(8, sz))
            except Exception:
                pass
    return ImageFont.load_default()


def hsize(b):
    v = float(b)
    for u in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if v < 1024 or u == "ТБ":
            return (f"{v:.0f} {u}" if v >= 100 else f"{v:.1f} {u}")
        v /= 1024
    return f"{v:.1f} ТБ"


def hsv(h, s, v):
    i = int(h * 6) % 6
    f = h * 6 - int(h * 6)
    p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    r, g, b = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    return int(r * 255), int(g * 255), int(b * 255)


class Tree:
    def __init__(self, nodes, root, root_total=0):
        self.size, self.own, self.denied, self.children = {}, {}, {}, {}
        self.root = root.rstrip("/")
        self.size[self.root] = root_total          # корень в выгрузку не попадает — задаём явно
        for n in nodes:
            p = n["p"].rstrip("/")
            self.size[p] = n["s"]
            self.own[p] = n.get("own", 0)
            self.denied[p] = n.get("den", 0)
            self.children.setdefault(p, [])
        self.children.setdefault(self.root, [])
        for p in self.size:
            if p == self.root:
                continue
            par = os.path.dirname(p)
            while len(par) > 1 and par not in self.size:
                par = os.path.dirname(par)
            if par in self.children:
                self.children[par].append(p)
        for k in self.children:
            self.children[k].sort(key=lambda c: -self.size.get(c, 0))

    def kids(self, path, total):
        ch = [(c, self.size[c]) for c in self.children.get(path.rstrip("/"), []) if self.size.get(c, 0) > 0]
        return ch, max(0, total - sum(v for _, v in ch))


class Panel:
    """Рисование в логических координатах панели с масштабом S."""

    def __init__(self, dr, x0):
        self.dr, self.x0 = dr, x0

    def pt(self, x, y):
        return (self.x0 + x * S, y * S)

    def f(self, sz, bold=False):
        return font(int(sz * S), bold)

    def text(self, x, y, t, sz, fill, bold=False, anchor_right=None):
        fnt = self.f(sz, bold)
        if anchor_right is not None:
            x = anchor_right - self.dr.textlength(t, font=fnt) / S
        self.dr.text(self.pt(x, y), t, font=fnt, fill=fill)

    def rect(self, x0, y0, x1, y1, fill):
        self.dr.rectangle([self.pt(x0, y0), self.pt(x1, y1)], fill=fill)

    def line(self, x0, y0, x1, y1, fill, w=1):
        self.dr.line([self.pt(x0, y0), self.pt(x1, y1)], fill=fill, width=int(w * S))

    def ellipse(self, cx, cy, r, fill=None, outline=None, w=1):
        self.dr.ellipse([self.pt(cx - r, cy - r), self.pt(cx + r, cy + r)],
                        fill=fill, outline=outline, width=int(w * S))

    def poly(self, pts, fill):
        self.dr.polygon([self.pt(x, y) for x, y in pts], fill=fill)

    def tw(self, t, sz, bold=False):
        return self.dr.textlength(t, font=self.f(sz, bold)) / S


def annulus(p, cx, cy, r_in, r_out, a0, a1, fill):
    steps = max(2, int(math.degrees(a1 - a0) / 1.1) + 1)
    pts = [(cx + r_out * math.cos(a0 + (a1 - a0) * i / steps),
            cy + r_out * math.sin(a0 + (a1 - a0) * i / steps)) for i in range(steps + 1)]
    pts += [(cx + r_in * math.cos(a0 + (a1 - a0) * i / steps),
             cy + r_in * math.sin(a0 + (a1 - a0) * i / steps)) for i in range(steps, -1, -1)]
    p.poly(pts, fill)


def breadcrumb(p, y, path, home):
    parts = [x for x in path.replace(home, "~").split("/") if x != ""]
    x = 34
    for i, part in enumerate(parts[:6]):
        last = (i == len(parts) - 1)
        col = FG if last else DIM
        p.text(x, y, part + ("" if last else "  ›"), 19, col, bold=last)
        x += p.tw(part, 19, last) + 26


def render_panel(img, x0, tree, focus, total, title, subtitle, home, tooltip=None):
    p = Panel(ImageDraw.Draw(img), x0)
    p.rect(0, 0, PW, PH, PANEL_BG)
    p.text(34, 26, title, 34, FG, bold=True)
    p.text(34, 74, subtitle, 20, DIM)
    breadcrumb(p, 108, focus, home)

    ring_w = (R_OUT - R_CENTER) / RINGS
    segs = []

    def walk(path, span, r_out, a0, a1, depth, hue):
        kids, rest = tree.kids(path, span)
        items = list(kids) + ([(None, rest)] if rest > span * 0.0015 else [])
        a = a0
        for i, (child, v) in enumerate(items):
            if span <= 0:
                break
            b = a + (a1 - a0) * (v / span)
            if b - a < 0.001:
                a = b
                continue
            r_in = max(R_CENTER, r_out - ring_w)
            # разные оттенки — только у первого кольца; глубже оттенок наследуется от ветки
            chue = (hue + i * (0.137 if depth == 1 else 0.022)) % 1.0
            col = GREY if child is None else hsv(chue, 0.34 + 0.10 * depth, 0.98 - 0.13 * depth)
            segs.append((depth, a, b, r_in, r_out, child, v, col))
            if child is not None and depth < RINGS:
                walk(child, v, r_in, a, b, depth + 1, chue)
            a = b

    walk(focus.rstrip("/"), total, R_OUT, 0, 2 * math.pi, 1, 0.56)
    for depth, a0, a1, r_in, r_out, child, v, col in sorted(segs, key=lambda s: -s[0]):
        annulus(p, CX, CY, r_in, r_out, a0, a1, col)

    # подписи первого кольца
    for depth, a0, a1, r_in, r_out, child, v, col in segs:
        if depth != 1 or child is None:
            continue
        frac = v / total if total else 0
        if frac < 0.055:
            continue
        mid = (a0 + a1) / 2
        rr = (r_in + r_out) / 2 + 3
        px, py = CX + rr * math.cos(mid), CY + rr * math.sin(mid)
        nm = os.path.basename(child) or "/"
        fs = 19 if frac > 0.13 else 15
        p.text(px - p.tw(nm, fs, True) / 2, py - 11, nm, fs, (14, 16, 20), bold=True)
        p.text(px - p.tw(f"{frac*100:.0f}%", fs - 3) / 2, py + 8, f"{frac*100:.0f}%", fs - 3, (32, 36, 42))

    # центр
    nm = os.path.basename(focus.rstrip("/")) or "/"
    if focus.rstrip("/") == home.rstrip("/"):
        nm = "~"
    p.ellipse(CX, CY, R_CENTER, fill=(31, 34, 42), outline=(62, 68, 80), w=3)
    p.text(CX - p.tw(nm, 23, True) / 2, CY - 56, nm, 23, FG, bold=True)
    p.text(CX - p.tw(hsize(total), 30, True) / 2, CY - 24, hsize(total), 30, ACCENT, bold=True)
    p.text(CX - p.tw("на диске", 16) / 2, CY + 16, "на диске", 16, DIM)
    if tree.denied.get(focus.rstrip("/"), 0):
        p.text(CX - p.tw("есть закрытые разделы", 14) / 2, CY + 44, "есть закрытые разделы", 14, WARN)

    # подсказка при наведении
    if tooltip:
        tpath, tsize, tshare = tooltip
        box_w, box_h = 360, 86
        tx, ty = 34, 152
        p.rect(tx, ty, tx + box_w, ty + box_h, TIP_BG)
        p.rect(tx, ty, tx + 4, ty + box_h, ACCENT)
        p.text(tx + 16, ty + 10, tpath, 17, FG, bold=True)
        p.text(tx + 16, ty + 34, f"{hsize(tsize)}   ·   {tshare:.1f}% от родителя", 16, DIM)
        p.text(tx + 16, ty + 58, "наведение подсвечивает ветку и её предков", 15, DIM)

    # список крупнейшего
    first_ring = {c: col for d, _a0, _a1, _ri, _ro, c, _v, col in segs if d == 1 and c}
    ly = 872
    p.text(34, ly, "Крупнейшее здесь", 21, FG, bold=True)
    ly += 34
    kids, rest = tree.kids(focus.rstrip("/"), total)
    tail = kids[6:]
    rest_all = rest + sum(v for _, v in tail)
    rows = kids[:6] + ([(None, rest_all, len(tail))] if rest_all > 0 else [])
    for child, v, *extra in rows:
        if v <= 0:
            continue
        col = GREY if child is None else first_ring.get(child, ACCENT)
        p.rect(34, ly + 6, 52, ly + 24, col)
        name = f"прочее ({extra[0]} шт.)" if child is None else (os.path.basename(child) or "/")
        p.text(64, ly, name, 19, FG, bold=True)
        if child is not None:
            par = os.path.dirname(child).replace(home, "~")
            if len(par) > 58:
                par = "…" + par[-56:]
            p.text(64, ly + 23, par, 14, DIM)
        p.text(0, ly + 4, f"{hsize(v)}     {100.0*v/total:.1f}%", 19, FG, anchor_right=PW - 34)
        ly += 47

    p.line(0, PH - 52, PW, PH - 52, (46, 50, 60), 1)
    p.text(34, PH - 38, "⌘↑ наверх   ·   ⏎ показать в Finder   ·   ⌫ удалить в Finder   ·   ⌘R пересканировать",
           15, DIM)


def main(argv):
    data_path = argv[1] if len(argv) > 1 else DATA
    out_path = argv[2] if len(argv) > 2 else OUT
    data = json.load(open(data_path))
    home = data["roots"][0].rstrip("/")
    tree = Tree(data["nodes"], home, data["alloc"])
    total = tree.size.get(home, data["alloc"])
    kids, _ = tree.kids(home, total)
    deep = kids[0][0] if kids else home
    objs = data.get("files", 0) + data.get("dirs", 0)
    # подсказка при наведении — на самом крупном внуке, путь относительно корня
    top1 = kids[0][0] if kids else home
    gk, _ = tree.kids(top1, tree.size.get(top1, 0))
    tip_path, tip_size = (gk[0][0], gk[0][1]) if gk else (top1, tree.size.get(top1, 0))
    tip_share = 100.0 * tip_size / max(1, tree.size.get(top1, 1))

    img = Image.new("RGB", (PW * 2 * S, PH * S), BG)
    render_panel(img, 0, tree, home, total,
                 "① " + (os.path.basename(home) or "Корень обхода"),
                 f"обход {objs:,} объектов ({hsize(data['alloc'])} на диске) — "
                 f"{data['elapsed']:.1f} с на 4 потоках".replace(",", " "),
                 home,
                 tooltip=(tip_path.replace(home, "~", 1), tip_size, tip_share))
    render_panel(img, PW * S, tree, deep, tree.size.get(deep, 0),
                 f"② Клик в «{os.path.basename(deep)}»",
                 "ромашка перестраивается вокруг выбранного каталога; кольцо — уровень вложенности",
                 home)

    out = img.resize((PW * 2, PH), Image.LANCZOS)
    d = ImageDraw.Draw(out)
    d.line([(PW, 0), (PW, PH)], fill=(52, 56, 66), width=2)
    out.save(out_path)
    print("saved", out_path, out.size, "| ①:", home, hsize(total), "| ②:", deep, hsize(tree.size.get(deep, 0)))


if __name__ == "__main__":
    main(sys.argv)
