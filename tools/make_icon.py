#!/usr/bin/env python3
"""Иконка «Ромашки»: рисуем ромашку и собираем .icns через iconutil.

Запуск: python3 tools/make_icon.py app/Resources/Romashka.icns
"""
import math, os, shutil, subprocess, sys, tempfile
from PIL import Image, ImageDraw

S = 1024
BG_TOP = (32, 35, 44)
BG_BOT = (18, 19, 24)
R_OUT, R_CENTER, RINGS = 392, 128, 3
SEGMENTS = [
    # (доля угла, оттенок, глубина) — узнаваемая ромашка из приложения
    (0.34, 0.56, 1), (0.22, 0.69, 1), (0.16, 0.83, 1), (0.11, 0.07, 1), (0.09, 0.42, 1), (0.08, 0.95, 1),
]


def hsv(h, s, v):
    i = int(h * 6) % 6
    f = h * 6 - int(h * 6)
    p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    r, g, b = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    return int(r * 255), int(g * 255), int(b * 255)


def squircle(size, radius_frac=0.2237):
    """Маска скруглённого квадрата в стиле macOS."""
    mask = Image.new("L", (size * 4, size * 4), 0)
    d = ImageDraw.Draw(mask)
    r = int(size * 4 * radius_frac)
    d.rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=r, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def annulus(dr, cx, cy, r_in, r_out, a0, a1, fill, steps=220):
    pts = [(cx + r_out * math.cos(a0 + (a1 - a0) * i / steps),
            cy + r_out * math.sin(a0 + (a1 - a0) * i / steps)) for i in range(steps + 1)]
    pts += [(cx + r_in * math.cos(a0 + (a1 - a0) * i / steps),
             cy + r_in * math.sin(a0 + (a1 - a0) * i / steps)) for i in range(steps, -1, -1)]
    dr.polygon(pts, fill=fill)


def main(out_icns):
    img = Image.new("RGB", (S, S), BG_BOT)
    d = ImageDraw.Draw(img)
    for y in range(S):                                   # мягкий вертикальный градиент
        t = y / S
        d.line([(0, y), (S, y)], fill=tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3)))

    cx = cy = S / 2
    ring_w = (R_OUT - R_CENTER) / RINGS
    a = -math.pi / 2                                      # начинаем сверху
    for frac, hue, depth in SEGMENTS:
        span = frac * 2 * math.pi
        gap = 0.008
        annulus(d, cx, cy, R_CENTER, R_OUT, a + gap, a + span - gap, hsv(hue, 0.42, 0.98))
        # внутренние кольца наследуют оттенок ветки, темнея с глубиной
        for k in range(1, RINGS):
            r_out = R_OUT - ring_w * k
            r_in = max(R_CENTER, r_out - ring_w)
            if r_out <= R_CENTER + 1:
                break
            annulus(d, cx, cy, r_in + 4, r_out - 4,
                    a + gap, a + span - gap, hsv(hue, 0.34 + 0.12 * k, 0.98 - 0.15 * k))
        a += span
    # центр: тёмный круг с тонкими акцентными кольцами (как центр ромашки в приложении)
    d.ellipse([cx - R_CENTER, cy - R_CENTER, cx + R_CENTER, cy + R_CENTER], fill=(15, 16, 20))
    for k in range(3):
        r = R_CENTER - 8 - k * 9
        d.ellipse([cx - r, cy - r, cx + r, cy + r],
                  outline=hsv(0.56, 0.30 + 0.12 * k, 0.42 + 0.16 * k), width=4)
    img.putalpha(squircle(S))

    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "Romashka.iconset")
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        for scale, suffix in ((1, ""), (2, "@2x")):
            px = size * scale
            img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}{suffix}.png"))
    os.makedirs(os.path.dirname(os.path.abspath(out_icns)), exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out_icns], check=True)
    shutil.rmtree(tmp)
    print("иконка:", out_icns, os.path.getsize(out_icns), "байт")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Romashka.icns")
