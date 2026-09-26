#!/usr/bin/env python3
"""Bereitet gescannte Rohseiten auf und schreibt sie als PDF.

Aufruf: process.py --output scan.pdf [--duplex] page-0001.pnm page-0002.pnm ...

Schritte je Dokument:
  1. Lage per Tesseract-OSD bestimmen (Mehrheitsentscheid über alle Seiten)
  2. je Seite: drehen, Weißabgleich + Hintergrund/Durchscheinen auf Weiß,
     Schieflage anhand der Textzeilen korrigieren, Leerseiten erkennen
  3. bei gewendetem Duplex-Stapel Vorder-/Rückseiten tauschen
  4. als PNG mit Farbpalette (oder JPEG) in ein PDF schreiben

Einstellungen kommen aus Umgebungsvariablen (siehe /etc/default/documentscanner).
"""

import argparse
import io
import os
import re
import subprocess
import sys
from datetime import datetime

import img2pdf
import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None


def env(name, default, cast=str):
    value = os.environ.get(name, "")
    return cast(value) if value != "" else default


RESOLUTION = env("RESOLUTION", 300, int)
AUTOROTATE = env("AUTOROTATE", "1") == "1"
ROTATE_MIN_CONF = env("ROTATE_MIN_CONF", 2.0, float)
PAGE_ROTATE_CONF = env("PAGE_ROTATE_CONF", 6.0, float)
DUPLEX_SWAP_ON_180 = env("DUPLEX_SWAP_ON_180", "1") == "1"
DESKEW = env("DESKEW", "1") == "1"
DESKEW_MAX_ANGLE = env("DESKEW_MAX_ANGLE", 10.0, float)
CLEAN = env("CLEAN", "1") == "1"
# Anteil der Hintergrundhelligkeit, ab dem ein Farbkanal weiß wird
WHITE_POINT = env("WHITE_POINT", 0.85, float)
BLACK_POINT = env("BLACK_POINT", 60, int)
# > 1 dunkelt blasse Schrift nach
INK_GAMMA = env("INK_GAMMA", 2.0, float)
# 0..1: dunkelt farbige Tinte zusätzlich nach Sättigung ab
COLOR_BOOST = env("COLOR_BOOST", 0.7, float)
# Pixel, die in allen Kanälen mindestens so hell sind, werden reinweiß
WHITE_SNAP = env("WHITE_SNAP", 0.8, float)
SKIP_BLANK = env("SKIP_BLANK", "1") == "1"
# Prozent Tinten-Pixel (ohne Rand), unter denen eine Seite als leer gilt
BLANK_THRESHOLD = env("BLANK_THRESHOLD", 0.05, float)
BLANK_MARGIN = env("BLANK_MARGIN", 0.06, float)
IMAGE_FORMAT = env("IMAGE_FORMAT", "palette")
PALETTE_COLORS = env("PALETTE_COLORS", 8, int)
JPEG_QUALITY = env("JPEG_QUALITY", 75, int)


def log(msg):
    print(f"{datetime.now():%Y-%m-%d %H:%M:%S} process: {msg}", flush=True)


def orientation(path):
    """Drehung gegen den Uhrzeigersinn (0/90/180/270), die die Seite aufrecht stellt, und Konfidenz."""
    try:
        out = subprocess.run(
            ["tesseract", path, "-", "--psm", "0", "--dpi", str(RESOLUTION)],
            capture_output=True, text=True, timeout=120,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return 0, 0.0
    rotate = re.search(r"^Rotate: (\d+)", out, re.M)
    conf = re.search(r"^Orientation confidence: ([\d.]+)", out, re.M)
    if not rotate or not conf:
        return 0, 0.0
    # tesseract meldet die Korrektur im Uhrzeigersinn
    return (360 - int(rotate.group(1))) % 360, float(conf.group(1))


def clean(img):
    """Weißabgleich auf den Papierhintergrund, dann Tonwertkorrektur je Kanal.

    Getöntes Papier und durchscheinende Rückseiten sind nahezu farblos und hell:
    sie liegen in allen Kanälen über dem Weißpunkt und werden weiß. Farbige Tinte
    ist in mindestens einem Kanal dunkel und bleibt daher erhalten.
    """
    a = np.asarray(img.convert("RGB"), dtype=np.float32)
    sample = a[::8, ::8].reshape(-1, 3)
    # Hintergrund = typische Helligkeit der hellen Mehrheit der Pixel
    background = np.maximum(np.percentile(sample, 75, axis=0), 1.0)
    a *= 255.0 / background
    white = 255.0 * WHITE_POINT
    a = np.clip((a - BLACK_POINT) / (white - BLACK_POINT), 0.0, 1.0)
    a = a ** INK_GAMMA
    if COLOR_BOOST > 0:
        # Farbige Tinte (Kugelschreiber, Stempel) je nach Sättigung abdunkeln;
        # Schwarz, Grau und Weiß haben keine Sättigung und bleiben unverändert
        chroma = a.max(axis=2, keepdims=True) - a.min(axis=2, keepdims=True)
        a *= 1.0 - COLOR_BOOST * chroma
    # Fast weiße Pixel (Papierrauschen) auf reines Weiß setzen: sauberer und viel kleiner
    a[a.min(axis=2) >= WHITE_SNAP] = 1.0
    return Image.fromarray((a * 255.0 + 0.5).astype(np.uint8), "RGB")


def ink_mask(img, scale):
    """Binärmaske 'Tinte' einer verkleinerten Graustufenkopie."""
    small = img.convert("L")
    small = small.resize((max(1, small.width // scale), max(1, small.height // scale)), Image.BOX)
    return np.asarray(small) < 160


def skew_angle(img):
    """Schieflage in Grad (gegen den Uhrzeigersinn) anhand der Textzeilen (Projektionsprofil)."""
    small = img.convert("L")
    small = small.resize((small.width // 4, small.height // 4), Image.BOX)
    ink = Image.fromarray(((np.asarray(small) < 160) * 255).astype(np.uint8))
    if np.count_nonzero(np.asarray(ink)) < 500:
        return 0.0

    def score(angle):
        rows = np.asarray(ink.rotate(angle, resample=Image.NEAREST, fillcolor=0), dtype=np.float32).sum(axis=1)
        return float(np.sum(np.diff(rows) ** 2))

    best, step = 0.0, 1.0
    candidates = np.arange(-DESKEW_MAX_ANGLE, DESKEW_MAX_ANGLE + step, step)
    while step >= 0.05:
        best = max(candidates, key=score)
        step /= 4
        candidates = np.arange(best - 4 * step, best + 4 * step + step / 2, step)
    return float(best)


def is_blank(img):
    mask = ink_mask(img, 2)
    h, w = mask.shape
    my, mx = int(h * BLANK_MARGIN), int(w * BLANK_MARGIN)
    inner = mask[my:h - my, mx:w - mx]
    ratio = 100.0 * np.count_nonzero(inner) / inner.size
    return ratio < BLANK_THRESHOLD, ratio


def encode(img):
    buf = io.BytesIO()
    if IMAGE_FORMAT == "jpeg":
        img.save(buf, "JPEG", quality=JPEG_QUALITY, dpi=(RESOLUTION, RESOLUTION), optimize=True)
    elif IMAGE_FORMAT == "png":
        img.save(buf, "PNG", dpi=(RESOLUTION, RESOLUTION), optimize=True)
    else:
        # Wenige Farben reichen für Dokumente mit weißem Hintergrund und sind sehr klein
        pal = img.quantize(colors=PALETTE_COLORS, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
        pal.save(buf, "PNG", dpi=(RESOLUTION, RESOLUTION), optimize=True)
    return buf.getvalue()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--duplex", action="store_true")
    parser.add_argument("pages", nargs="+")
    args = parser.parse_args()

    # 1. Lage des Dokuments
    osd = [orientation(p) if AUTOROTATE else (0, 0.0) for p in args.pages]
    votes = {}
    for angle, conf in osd:
        votes[angle] = votes.get(angle, 0.0) + conf
    doc_angle = max(votes, key=votes.get) if votes else 0
    if votes.get(doc_angle, 0.0) < ROTATE_MIN_CONF:
        doc_angle = 0
    if AUTOROTATE:
        log(f"Lage des Dokuments: {doc_angle}° (je Seite: {' '.join(f'{a}/{c:.1f}' for a, c in osd)})")

    # 2. Seiten aufbereiten
    results = []
    for i, path in enumerate(args.pages):
        name = os.path.basename(path)
        img = Image.open(path)
        img.load()

        angle = doc_angle
        # Einzelne Seite nur abweichend drehen, wenn die Erkennung sehr sicher ist (z. B. Querformat)
        if osd[i][0] != doc_angle and osd[i][1] >= PAGE_ROTATE_CONF:
            angle = osd[i][0]
        if angle:
            img = img.rotate(angle, expand=True)

        if CLEAN:
            img = clean(img)

        if DESKEW:
            skew = skew_angle(img)
            if abs(skew) >= 0.2:
                log(f"{name}: Schieflage {skew:+.2f}° korrigiert")
                img = img.rotate(skew, resample=Image.BICUBIC, fillcolor=(255, 255, 255))

        if SKIP_BLANK:
            blank, ratio = is_blank(img)
            if blank:
                log(f"{name}: leer ({ratio:.3f}% Tinte), wird übersprungen")
                results.append(None)
                continue

        results.append(encode(img))

    # 3. Reihenfolge: Steht das Dokument auf dem Kopf, wurde der Stapel gewendet
    #    eingelegt und der Scanner liefert je Blatt zuerst die Rückseite.
    order = list(range(len(results)))
    if args.duplex and DUPLEX_SWAP_ON_180 and doc_angle == 180 and len(results) % 2 == 0:
        log("Stapel war gewendet, tausche Vorder- und Rückseiten")
        order = [j for i in range(0, len(results), 2) for j in (i + 1, i)]

    images = [results[i] for i in order if results[i] is not None]
    if not images:
        log("Alle Seiten leer, kein PDF erzeugt")
        return 3

    with open(args.output, "wb") as f:
        f.write(img2pdf.convert(images))
    log(f"{len(images)} Seiten, {os.path.getsize(args.output) // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
