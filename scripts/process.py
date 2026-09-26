#!/usr/bin/env python3
"""Bereitet gescannte Rohseiten auf und schreibt sie als PDF.

Aufruf: process.py --output scan.pdf [--duplex] page-0001.pnm page-0002.pnm ...

Schritte je Dokument:
  1. Lage per Tesseract-OSD bestimmen (Mehrheitsentscheid über alle Seiten)
  2. je Seite: drehen, Weißabgleich + Hintergrund/Durchscheinen auf Weiß,
     Schieflage anhand der Textzeilen korrigieren, Leerseiten erkennen
  3. Duplex-Reihenfolge erkennen (Rückseite zuerst?) und ggf. tauschen
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
# auto: aus Blättern mit einer leeren Seite erkennen, sonst DUPLEX_DEFAULT
# front-first / back-first: fest vorgeben
DUPLEX_ORDER = env("DUPLEX_ORDER", "auto")
# back-first = Stapel liegt mit der Schrift nach oben im Einzug
DUPLEX_DEFAULT = env("DUPLEX_DEFAULT", "front-first")
# Sprache für das Lesen der Seitenzahlen
OCR_LANG = env("OCR_LANG", "deu")
DESKEW = env("DESKEW", "1") == "1"
DESKEW_MAX_ANGLE = env("DESKEW_MAX_ANGLE", 45.0, float)
# Ab dieser Schieflage (Grad) wird gewarnt, dass Ränder außerhalb des Scanbereichs lagen
SKEW_WARN = env("SKEW_WARN", 3.0, float)
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
# Unbearbeitetes Roh-PDF: jpeg (~1–2 MB/Seite) oder png (verlustfrei, ~10 MB/Seite)
RAW_PDF_FORMAT = env("RAW_PDF_FORMAT", "jpeg")
RAW_JPEG_QUALITY = env("RAW_JPEG_QUALITY", 90, int)


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
    # Kante des Scanbereichs (dunkle Linie am Bildrand) entfernen
    border = max(1, RESOLUTION // 25)
    a[:border], a[-border:], a[:, :border], a[:, -border:] = 1.0, 1.0, 1.0, 1.0
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


def straighten(img, angle):
    """Dreht die Seite gerade, ohne Inhalt in den Ecken abzuschneiden, und schneidet
    anschließend wieder auf die Originalgröße zu – mittig um den Inhalt."""
    width, height = img.size
    rotated = img.rotate(angle, resample=Image.BICUBIC, expand=True, fillcolor=(255, 255, 255))
    mask = ink_mask(rotated, 4)
    rows, cols = np.nonzero(mask.any(axis=1))[0], np.nonzero(mask.any(axis=0))[0]
    if rows.size and cols.size:
        cy, cx = (rows[0] + rows[-1]) * 2, (cols[0] + cols[-1]) * 2
    else:
        cy, cx = rotated.height // 2, rotated.width // 2
    left = min(max(cx - width // 2, 0), rotated.width - width)
    top = min(max(cy - height // 2, 0), rotated.height - height)
    return rotated.crop((left, top, left + width, top + height))


def is_blank(img):
    mask = ink_mask(img, 2)
    h, w = mask.shape
    my, mx = int(h * BLANK_MARGIN), int(w * BLANK_MARGIN)
    inner = mask[my:h - my, mx:w - mx].copy()
    # Durchgehende Linien (Papierkante, Knick, Schatten) sind kein Inhalt:
    # Zeilen/Spalten, die über ein Drittel dunkel sind, samt Nachbarn ausblenden
    for axis in (1, 0):
        lines = np.nonzero(inner.mean(axis=axis) > 0.33)[0]
        for i in lines:
            sl = slice(max(i - 3, 0), i + 4)
            if axis == 1:
                inner[sl, :] = False
            else:
                inner[:, sl] = False
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


PAGE_NUMBER_PATTERNS = [
    re.compile(r"Seite\s*(\d{1,3})\b", re.I),
    re.compile(r"\b(\d{1,3})\s*von\s*\d{1,3}\b", re.I),
    re.compile(r"^\s*[-–]\s*(\d{1,3})\s*[-–]\s*$", re.M),
]


def page_number(img):
    """Seitenzahl aus Kopf- und Fußzeile lesen (nur diese Streifen werden per OCR gelesen)."""
    h = img.height
    strip = int(h * 0.12)
    top, bottom = img.crop((0, 0, img.width, strip)), img.crop((0, h - strip, img.width, h))
    both = Image.new("L", (img.width, 2 * strip), 255)
    both.paste(top.convert("L"), (0, 0))
    both.paste(bottom.convert("L"), (0, strip))
    buf = io.BytesIO()
    both.save(buf, "PNG", dpi=(RESOLUTION, RESOLUTION))
    try:
        text = subprocess.run(
            ["tesseract", "stdin", "stdout", "-l", OCR_LANG, "--psm", "6", "--dpi", str(RESOLUTION)],
            input=buf.getvalue(), capture_output=True, timeout=120,
        ).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return None
    for pattern in PAGE_NUMBER_PATTERNS:
        m = pattern.search(text)
        if m and 0 < int(m.group(1)) < 1000:
            return int(m.group(1))
    return None


def sequence_score(numbers):
    """Wie gut die gefundenen Seitenzahlen zu ihren Positionen in dieser Reihenfolge passen:
    +1, wenn der Abstand zweier Seitenzahlen dem Abstand ihrer Positionen entspricht,
    -1, wenn sie rückwärts laufen."""
    found = [(pos, n) for pos, n in enumerate(numbers) if n is not None]
    return sum((nb - na == pb - pa) - (nb < na) for (pa, na), (pb, nb) in zip(found, found[1:]))


def back_first(results, numbers):
    """Ob der Scanner je Blatt zuerst die Rückseite geliefert hat.

    1. Seitenzahlen: die Reihenfolge, in der sie besser aufsteigen, gewinnt.
    2. Blätter mit genau einer leeren Seite: die leere ist fast immer die Rückseite.
    3. sonst DUPLEX_DEFAULT.
    """
    if DUPLEX_ORDER in ("front-first", "back-first"):
        return DUPLEX_ORDER == "back-first"

    swapped = [numbers[j] for i in range(0, len(numbers), 2) for j in (i + 1, i)]
    front, back = sequence_score(numbers), sequence_score(swapped)
    if front != back:
        log(f"Einlegerichtung aus Seitenzahlen {numbers} erkannt: {'Rückseite' if back > front else 'Vorderseite'} zuerst")
        return back > front

    evidence = 0
    for i in range(0, len(results), 2):
        first_blank, second_blank = results[i] is None, results[i + 1] is None
        if first_blank != second_blank:
            evidence += 1 if first_blank else -1
    if evidence:
        log(f"Einlegerichtung aus leeren Rückseiten erkannt: {'Rückseite' if evidence > 0 else 'Vorderseite'} zuerst")
        return evidence > 0
    return DUPLEX_DEFAULT == "back-first"


def write_raw(pages, output):
    """Rohseiten ohne jede Aufbereitung in Scanner-Reihenfolge als PDF schreiben."""
    images = []
    for path in pages:
        img = Image.open(path)
        buf = io.BytesIO()
        if RAW_PDF_FORMAT == "png":
            img.save(buf, "PNG", dpi=(RESOLUTION, RESOLUTION), optimize=True)
        else:
            img.save(buf, "JPEG", quality=RAW_JPEG_QUALITY, dpi=(RESOLUTION, RESOLUTION), optimize=True)
        images.append(buf.getvalue())
    with open(output, "wb") as f:
        f.write(img2pdf.convert(images))
    log(f"Roh-PDF: {len(images)} Seiten, {os.path.getsize(output) // 1024} KB")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--duplex", action="store_true")
    parser.add_argument("--raw", action="store_true", help="Seiten unbearbeitet (nur komprimiert) als PDF schreiben")
    parser.add_argument("pages", nargs="+")
    args = parser.parse_args()

    if args.raw:
        return write_raw(args.pages, args.output)

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
    detect_order = args.duplex and DUPLEX_ORDER == "auto" and len(args.pages) >= 2
    results, numbers = [], []
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
                if abs(skew) >= SKEW_WARN:
                    log(f"{name}: Blatt wurde stark schief eingezogen – Ränder können fehlen, ggf. neu scannen")
                img = straighten(img, skew)

        if SKIP_BLANK:
            blank, ratio = is_blank(img)
            if blank:
                log(f"{name}: leer ({ratio:.3f}% Tinte), wird übersprungen")
                results.append(None)
                numbers.append(None)
                continue

        numbers.append(page_number(img) if detect_order else None)
        results.append(encode(img))

    # 3. Reihenfolge: Liegt der Stapel mit der Schrift nach oben im Einzug, liefert der
    #    Scanner je Blatt zuerst die Rückseite. Ob die Seiten dabei auf dem Kopf stehen,
    #    hängt nur davon ab, welche Kante zuerst eingezogen wurde – das sagt nichts aus.
    order = list(range(len(results)))
    if args.duplex and len(results) % 2 == 0 and back_first(results, numbers):
        log("Rückseiten kamen zuerst, tausche Vorder- und Rückseiten")
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
