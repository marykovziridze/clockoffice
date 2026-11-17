#!/usr/bin/env python3
"""Records docs/demo.gif: about seven seconds, cropped to the top of the dropdown, with a pointer.

Two questions wait. The pointer clicks a suggested answer on the first; then a reply is typed into the other and
sent. The count beside the menu-bar icon goes 2, 1, 0. Everything on screen is the app's own test rig (--rig):
real screens, made-up sessions, nothing is sent anywhere. The pointer is drawn onto the pictures afterwards.

  scripts/demo-gif.py [path to the app's program]      default: the release build in .build
Needs ffmpeg and the Python package Pillow.
"""
import json, os, subprocess, sys, tempfile, time, urllib.parse, urllib.request
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
import shutil, socket

def free_port():
    """A port nothing else listens on: a fixed one would drive whatever happened to be there."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

PORT = free_port()
FPS = 15
CROP_PT = (0, 0, 410, 366)        # the menu-bar strip and the two question cards, in points
OUT_W = 620                        # width of the GIF in pixels

def program():
    if len(sys.argv) > 1: return sys.argv[1]
    out = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    return os.path.join(out, "ClockOffice")

def ask(path):
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/{path}", timeout=30) as r:
        return json.load(r)

def middle(screen, words):
    for t in screen["texts"]:
        if words in t["says"]:
            return (t["x"] + t["w"] / 2, t["y"] + t["h"] / 2)
    sys.exit("not on screen: " + words)

def picture(screen):
    im = Image.open(screen["picture"]).convert("RGB")
    box = tuple(int(v * 2) for v in CROP_PT)
    canvas = Image.new("RGB", (box[2] - box[0], box[3] - box[1]), (38, 36, 38))
    canvas.paste(im.crop((box[0], box[1], min(box[2], im.width), min(box[3], im.height))), (0, 0))
    return canvas

def pointer(im, at, press=0.0):
    """The arrow pointer at a place given in points; `press` from 0 to 1 draws the ring of a click."""
    im = im.copy()
    d = ImageDraw.Draw(im, "RGBA")
    x, y = at[0] * 2, at[1] * 2
    if press > 0:
        r = 14 + 26 * press
        d.ellipse((x - r, y - r, x + r, y + r), outline=(255, 255, 255, int(200 * (1 - press))), width=4)
    arrow = [(0, 0), (0, 34), (9, 26), (16, 42), (22, 39), (15, 24), (27, 24)]
    d.polygon([(x + px, y + py) for px, py in arrow], fill=(20, 20, 20, 255), outline=(255, 255, 255, 255))
    d.line([(x + px, y + py) for px, py in arrow + [arrow[0]]], fill=(255, 255, 255, 255), width=3)
    return im

def ease(t): return t * t * (3 - 2 * t)

class Film:
    def __init__(self): self.frames = []; self.at = (330.0, 400.0)
    def hold(self, im, seconds, press=0.0):
        for _ in range(max(1, round(seconds * FPS))): self.frames.append(pointer(im, self.at, press))
    def travel(self, im, to, seconds):
        start, n = self.at, max(2, round(seconds * FPS))
        for i in range(1, n + 1):
            k = ease(i / n)
            self.at = (start[0] + (to[0] - start[0]) * k, start[1] + (to[1] - start[1]) * k)
            self.frames.append(pointer(im, self.at))
    def click(self, im):
        for p in (0.25, 0.6, 1.0): self.frames.append(pointer(im, self.at, p))

def main():
    work = tempfile.mkdtemp()
    rig = subprocess.Popen([program(), "--rig", os.path.join(work, "shots"), "--port", str(PORT)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(4)
        film = Film()
        s = ask("open?surface=dropdown")
        first = picture(s)
        film.hold(first, 0.7)

        # One click on a suggested answer.
        yes = middle(s, "yes")
        film.travel(first, yes, 0.55)
        film.click(first)
        s = ask(f"click?x={yes[0]}&y={yes[1]}")
        film.hold(picture(s), 1.0)                       # "Sending "yes"… Undo"
        time.sleep(3.6)
        s = ask("look")
        answered = picture(s)
        film.hold(answered, 0.6)                         # that question is gone; the count says 1

        # A reply typed into the other question.
        box = middle(s, "Type a reply")
        film.travel(answered, box, 0.45)
        film.click(answered)
        s = ask(f"click?x={box[0]}&y={box[1]}")
        typed = picture(s)
        film.hold(typed, 0.2)
        text = "At the top, in bold"
        for i in range(0, len(text), 3):
            s = ask("type?text=" + urllib.parse.quote(text[i:i + 3]))
            typed = picture(s)
            film.hold(typed, 0.13)
        film.hold(typed, 0.3)
        arrow = (370.0, box[1])                          # the round send arrow at the right end of the box
        film.travel(typed, arrow, 0.4)
        film.click(typed)
        s = ask(f"click?x={arrow[0]}&y={arrow[1]}")
        time.sleep(1.5)
        s = ask("look")
        film.hold(picture(s), 1.6)                       # both answered; the count is gone
    except BaseException:
        rig.terminate(); shutil.rmtree(work, ignore_errors=True)
        raise
    rig.terminate()

    frames = os.path.join(work, "frames"); os.makedirs(frames)
    h = round(film.frames[0].height * OUT_W / film.frames[0].width)
    for i, im in enumerate(film.frames):
        im.resize((OUT_W, h), Image.LANCZOS).save(os.path.join(frames, f"f{i:04d}.png"))
    out = os.path.join(ROOT, "docs", "demo.gif")
    pal = os.path.join(work, "pal.png")
    src = ["-framerate", str(FPS), "-i", os.path.join(frames, "f%04d.png")]
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *src, "-vf", "palettegen=max_colors=96", "-frames:v", "1", "-update", "1", pal], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *src, "-i", pal, "-lavfi", "paletteuse=dither=none", out], check=True)
    shutil.rmtree(work, ignore_errors=True)
    print(f"wrote docs/demo.gif: {len(film.frames)} frames, {len(film.frames) / FPS:.1f} s, {OUT_W}x{h}, {os.path.getsize(out)} bytes")

main()
