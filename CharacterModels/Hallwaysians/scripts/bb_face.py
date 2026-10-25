"""Face sprites for the Black Box preview -- mirrors BlackBoxFace.sprite()
in BlackBox.swift (shape + soft glow, warm phosphor on transparent)."""
from PIL import Image, ImageDraw, ImageFilter
import os

AMBER = (255, 214, 150)
BLUSH = (255, 120, 120)


def sprite(kind, px=128, color=AMBER):
    big = px * 4
    w, h = (px, px)
    if kind == 'eye':
        size = (int(px * 0.62), int(px * 0.90))
    elif kind == 'brow':
        size = (px, int(px * 0.25))
    elif kind in ('smile', 'happy'):
        size = (px, int(px * 0.55))
    elif kind == 'mouth':
        size = (px, int(px * 0.75))
    elif kind == 'blush':
        size = (px, int(px * 0.6))
    elif kind == 'ring':
        size = (px * 2, px * 2)
    else:
        size = (px, px)
    W, H = size
    S = 4
    shape = Image.new('L', (W * S, H * S), 0)
    d = ImageDraw.Draw(shape)
    pad = int(min(W, H) * 0.22) * S
    if kind == 'eye':
        r = (W * S - 2 * pad) // 2
        d.rounded_rectangle((pad, pad, W * S - pad, H * S - pad), radius=r, fill=255)
    elif kind == 'brow':
        p = int(H * S * 0.3)
        d.rounded_rectangle((p, p, W * S - p, H * S - p), radius=(H * S - 2 * p) // 2, fill=255)
    elif kind == 'smile':
        # a lower arc (U), thick stroke
        p = int(W * S * 0.16)
        d.arc((p, -H * S + p * 2, W * S - p, H * S - p), 25, 155, fill=255, width=int(W * S * 0.085))
    elif kind == 'happy':
        # an upper arc (n): a smiling closed eye
        p = int(W * S * 0.16)
        d.arc((p, p, W * S - p, H * S * 2 - p * 2), 205, 335, fill=255, width=int(W * S * 0.11))
    elif kind == 'mouth':
        p = int(W * S * 0.22)
        d.rounded_rectangle((p, p, W * S - p, H * S - p), radius=int((H * S - 2 * p) * 0.48), fill=255)
    elif kind == 'blush':
        p = int(W * S * 0.18)
        d.ellipse((p, p, W * S - p, H * S - p), fill=255)
    elif kind == 'ring':
        c = W * S / 2
        for rr, wd in ((0.90, 0.035), (0.62, 0.03), (0.34, 0.03)):
            R = c * rr
            d.ellipse((c - R, c - R, c + R, c + R), outline=255, width=int(c * wd))
    shape = shape.resize((W, H), Image.LANCZOS)
    blur = shape.filter(ImageFilter.GaussianBlur(radius=max(2, min(W, H) * (0.10 if kind != 'blush' else 0.16))))
    if kind == 'blush':
        alpha = blur.point(lambda v: int(v * 0.85))
    else:
        alpha = Image.eval(Image.merge('L', [shape]), lambda v: v)
        alpha = Image.composite(shape, blur.point(lambda v: int(min(255, v * 0.9))), shape)
    rgb = Image.new('RGB', (W, H), color)
    # hot core: whiter where the shape is solid
    core = Image.new('RGB', (W, H), tuple(min(255, int(c * 0.35 + 255 * 0.65)) for c in color))
    rgb = Image.composite(core, rgb, shape.point(lambda v: int(v * 0.8)))
    out = rgb.copy()
    out.putalpha(alpha)
    return out


if __name__ == '__main__':
    os.makedirs('/tmp/claude-0/hw/out_bb/face', exist_ok=True)
    for k in ('eye', 'brow', 'smile', 'happy', 'mouth', 'blush', 'ring'):
        sprite(k, color=BLUSH if k == 'blush' else AMBER).save(f'/tmp/claude-0/hw/out_bb/face/{k}.png')
