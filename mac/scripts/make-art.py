#!/usr/bin/env python3
"""Draws the ClockOffice artwork from the Clockwork dial (30 ticks, 5 batons, one hand, one hub).

    python3 mac/scripts/make-art.py mac/Resources

Writes icon-clock.png (the app icon) and menu-glyph.svg (one colour, tinted by macOS). Needs Pillow.
The dials inside the app are drawn in code (Sources/ClockOfficeUI/DialView.swift) from the same proportions.

Proportions are measured from the Clockwork listing icon (1024 px, centre 512): ticks from radius 356 to 400 and
12 wide, batons from 280 to 400 and 34 wide, hand 26 wide from 75 behind the centre to 250 in front, hub radius 34.
"""
import math
import os
import sys
from PIL import Image, ImageDraw

INK = (17, 18, 20, 255)
TICK = (180, 184, 189, 255)
PAPER = (243, 243, 239, 255)
ORANGE = (242, 122, 26, 255)     # "needs you", the one colour that asks for attention (DialView.Palette)
BATONS = [0, 72, 144, 216, 288]   # degrees clockwise from 12 o'clock
ACCENT = {72, 288}                # the two batons that carry the accent on the app icon
REST = 66                         # where the hand rests, as on the Clockwork dial
SS = 4                            # every image is drawn four times larger, then reduced


def bar(d, c, r0, r1, w, deg, fill):
    """A straight bar along a radius, from r0 to r1 from the centre c, w wide, at deg clockwise from 12."""
    a = math.radians(deg)
    ux, uy = math.sin(a), -math.cos(a)
    px, py = -uy, ux
    h = w / 2
    d.polygon([(c + ux * r0 + px * h, c + uy * r0 + py * h), (c + ux * r1 + px * h, c + uy * r1 + py * h),
               (c + ux * r1 - px * h, c + uy * r1 - py * h), (c + ux * r0 - px * h, c + uy * r0 - py * h)], fill=fill)


def dial(px, hand, outer, face=None, accent=None, weight=1.0, ticks=True):
    """One dial, px wide. outer = the ticks' outer radius as a share of half the width."""
    n = px * SS
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = n / 2
    k = (outer * n / 2) / 400.0  # icon units to pixels
    if face:
        d.ellipse([0, 0, n - 1, n - 1], fill=face)
        # A hairline rim just inside the circle the app crops to (the image is shown 10% larger than that circle),
        # so a white dial keeps its edge on a near-white panel.
        v = c / 1.1
        d.ellipse([c - v, c - v, c + v, c + v], outline=(17, 18, 20, 60), width=round(n / 64))
    if ticks:
        for deg in range(0, 360, 12):
            if deg not in BATONS:
                bar(d, c, 356 * k, 400 * k, 12 * weight * k, deg, TICK)
    for deg in BATONS:
        bar(d, c, 280 * k, 400 * k, 34 * weight * k, deg, accent if (accent and deg in ACCENT) else INK)
    bar(d, c, -75 * k, 250 * k, 26 * weight * k, hand, INK)
    r = 34 * weight * k
    d.ellipse([c - r, c - r, c + r, c + r], fill=INK)
    return im.resize((px, px), Image.LANCZOS)


def rounded_tile(px, inset, radius, fill, edge):
    n = px * SS
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    box = [inset * SS, inset * SS, n - inset * SS - 1, n - inset * SS - 1]
    d.rounded_rectangle(box, radius=radius * SS, fill=edge)
    e = 2 * SS
    d.rounded_rectangle([box[0] + e, box[1] + e, box[2] - e, box[3] - e], radius=radius * SS - e, fill=fill)
    return im.resize((px, px), Image.LANCZOS)


def menu_glyph():
    """One colour: a rim, the five batons, the hand and the hub. No small ticks: at 20 points they would only be
    grey fog. The rim is what makes it read as a clock at that size; without it the batons look like an asterisk."""
    c = 500
    parts = [f'<circle cx="{c}" cy="{c}" r="415" fill="none" stroke="#000" stroke-width="70"/>']
    for deg in BATONS:
        parts.append(f'<rect x="{c - 35}" y="{c - 330}" width="70" height="80" transform="rotate({deg} {c} {c})"/>')
    parts.append(f'<rect x="{c - 35}" y="{c - 215}" width="70" height="285" transform="rotate({REST} {c} {c})"/>')
    parts.append(f'<circle cx="{c}" cy="{c}" r="70"/>')
    body = "\n    ".join(parts)
    return (f'<svg viewBox="0 0 1000 1000" xmlns="http://www.w3.org/2000/svg" width="1000" height="1000">\n'
            f'  <title>Clock dial</title>\n  <g fill="#000">\n    {body}\n  </g>\n</svg>\n')


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)

    # App icon: the same tile shape as before (830 px tile on a 1024 canvas), paper, the dial with two orange batons.
    icon = rounded_tile(1024, 97, 186, PAPER, (0, 0, 0, 34))
    face = dial(1024, REST, outer=0.60, accent=ORANGE)
    icon.alpha_composite(face)
    icon.save(os.path.join(out, "icon-clock.png"))

    with open(os.path.join(out, "menu-glyph.svg"), "w") as f:
        f.write(menu_glyph())
    print("wrote icon-clock.png, menu-glyph.svg to", out)


if __name__ == "__main__":
    main()
