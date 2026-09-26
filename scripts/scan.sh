#!/bin/bash
# Scannt alle Seiten aus dem ADF, bereitet sie auf und legt ein PDF im Spool ab.
# Aufruf: scan.sh <sane-device>
set -euo pipefail

CONFIG=/etc/default/documentscanner
# shellcheck source=/dev/null
[ -r "${CONFIG}" ] && . "${CONFIG}"

MODE="${MODE:-Color}"
RESOLUTION="${RESOLUTION:-300}"
SOURCE="${SOURCE:-ADF Duplex}"
PAGE_WIDTH="${PAGE_WIDTH:-210}"
PAGE_HEIGHT="${PAGE_HEIGHT:-297}"
SWSKIP="${SWSKIP:-2.5}"
SWCROP="${SWCROP:-yes}"
SWDESKEW="${SWDESKEW:-yes}"
SWDESPECK="${SWDESPECK:-1}"
AUTOROTATE="${AUTOROTATE:-1}"
ROTATE_MIN_CONF="${ROTATE_MIN_CONF:-2}"
UNPAPER="${UNPAPER:-0}"
UNPAPER_OPTS="${UNPAPER_OPTS:-}"
NORMALIZE="${NORMALIZE:-1}"
NORMALIZE_OPTS="${NORMALIZE_OPTS:--keephues -bpercent=0.5 -wpercent=40}"
IMAGE_FORMAT="${IMAGE_FORMAT:-jpeg}"
JPEG_QUALITY="${JPEG_QUALITY:-80}"
KEEP_RAW="${KEEP_RAW:-0}"
WORK_DIR="${WORK_DIR:-/var/lib/documentscanner/work}"
FAILED_DIR="${FAILED_DIR:-/var/lib/documentscanner/failed}"
RAW_DIR="${RAW_DIR:-/var/lib/documentscanner/raw}"
SPOOL_DIR="${SPOOL_DIR:-/var/spool/documentscanner/outbox}"

log() {
    echo "$(date '+%F %T') scan: $*"
}

DEVICE="${1:-}"
if [ -z "${DEVICE}" ]; then
    log "Bitte SANE-Device angeben, Abbruch"
    exit 1
fi

# scanbd nutzt eine eigene SANE-Konfiguration mit nur dem fujitsu-Backend
if [ -z "${SANE_CONFIG_DIR:-}" ] && [ -d /etc/scanbd/sane.d ]; then
    export SANE_CONFIG_DIR=/etc/scanbd/sane.d
fi

mkdir -p "${WORK_DIR}" "${FAILED_DIR}" "${SPOOL_DIR}"

# Nur ein Scan gleichzeitig
exec 9>"${WORK_DIR}/.lock"
if ! flock -n 9; then
    log "Es läuft bereits ein Scan, Abbruch"
    exit 1
fi

NAME="scan_$(date +%Y-%m-%d_%H-%M-%S)"
SCANDIR="${WORK_DIR}/${NAME}"
mkdir "${SCANDIR}"

fail() {
    log "$1 – Seiten liegen in ${FAILED_DIR}/${NAME}"
    mv "${SCANDIR}" "${FAILED_DIR}/${NAME}"
    exit 1
}

log "Scanne ${DEVICE} (${MODE}, ${RESOLUTION} dpi, ${SOURCE}) nach ${SCANDIR}"

RC=0
scanimage -d "${DEVICE}" \
    --batch="${SCANDIR}/page-%04d.pnm" --format=pnm \
    --source "${SOURCE}" --mode "${MODE}" --resolution "${RESOLUTION}" \
    --page-width "${PAGE_WIDTH}" --page-height "${PAGE_HEIGHT}" \
    -x "${PAGE_WIDTH}" -y "${PAGE_HEIGHT}" \
    --swskip "${SWSKIP}" --swcrop="${SWCROP}" --swdeskew="${SWDESKEW}" --swdespeck "${SWDESPECK}" \
    --df-action Stop --df-thickness=yes --df-length=yes || RC=$?

shopt -s nullglob
PAGES=("${SCANDIR}"/page-*.pnm)

if [ "${#PAGES[@]}" -eq 0 ]; then
    log "Keine Seiten gescannt (scanimage rc=${RC})"
    rm -rf "${SCANDIR}"
    exit 0
fi

# Papierstau / Doppeleinzug: nicht weiterverarbeiten, sondern zur Kontrolle aufheben
if [ "${RC}" -ne 0 ]; then
    fail "Scan abgebrochen (scanimage rc=${RC}) nach ${#PAGES[@]} Seiten"
fi

log "${#PAGES[@]} Seiten gescannt, bereite auf"

# Rohdaten zum Einstellen der Bildaufbereitung aufheben
if [ "${KEEP_RAW}" = "1" ]; then
    mkdir -p "${RAW_DIR}/${NAME}"
    cp "${PAGES[@]}" "${RAW_DIR}/${NAME}/"
fi

# Gibt die Drehung (Grad gegen den Uhrzeigersinn) zurück, die die Seite aufrecht stellt
orientation() {
    local osd rotate conf
    osd="$(tesseract "$1" - --psm 0 --dpi "${RESOLUTION}" 2>/dev/null)" || { echo 0; return; }
    rotate="$(sed -n 's/^Rotate: //p' <<< "${osd}")"
    conf="$(sed -n 's/^Orientation confidence: //p' <<< "${osd}")"
    # tesseract meldet die Korrektur im Uhrzeigersinn, pnmflip dreht dagegen
    if [ -n "${rotate}" ] && [ "${rotate}" != "0" ] && awk "BEGIN { exit !(${conf:-0} >= ${ROTATE_MIN_CONF}) }"; then
        echo $(( (360 - rotate) % 360 ))
    else
        echo 0
    fi
}

# Pixel pro Meter für die DPI-Angabe im PNG
PPM=$(( (RESOLUTION * 10000 + 127) / 254 ))
IMAGES=()
for PAGE in "${PAGES[@]}"; do
    BASE="${PAGE%.pnm}"
    SRC="${PAGE}"

    if [ "${AUTOROTATE}" = "1" ]; then
        ANGLE="$(orientation "${SRC}")"
        if [ "${ANGLE}" != "0" ]; then
            log "$(basename "${PAGE}"): drehe um ${ANGLE}°"
            pnmflip -r"${ANGLE}" "${SRC}" > "${BASE}-rot.pnm" || fail "Drehen fehlgeschlagen für ${PAGE}"
            SRC="${BASE}-rot.pnm"
        fi
    fi

    if [ "${UNPAPER}" = "1" ]; then
        # shellcheck disable=SC2086
        unpaper --overwrite --dpi "${RESOLUTION}" ${UNPAPER_OPTS} "${SRC}" "${BASE}-clean.pnm" \
            || fail "unpaper fehlgeschlagen für ${PAGE}"
        SRC="${BASE}-clean.pnm"
    fi

    # Papierhintergrund auf Weiß ziehen: sauberer und deutlich kleinere Dateien
    if [ "${NORMALIZE}" = "1" ]; then
        # shellcheck disable=SC2086
        pnmnorm ${NORMALIZE_OPTS} "${SRC}" > "${BASE}-norm.pnm" 2>/dev/null \
            || fail "pnmnorm fehlgeschlagen für ${PAGE}"
        SRC="${BASE}-norm.pnm"
    fi

    if [ "${IMAGE_FORMAT}" = "png" ]; then
        pnmtopng -size "${PPM} ${PPM} 1" "${SRC}" > "${BASE}.png" \
            || fail "PNG-Konvertierung fehlgeschlagen für ${PAGE}"
        IMAGES+=("${BASE}.png")
    else
        pnmtojpeg --quality="${JPEG_QUALITY}" --density="${RESOLUTION}x${RESOLUTION}dpi" "${SRC}" > "${BASE}.jpg" \
            || fail "JPEG-Konvertierung fehlgeschlagen für ${PAGE}"
        IMAGES+=("${BASE}.jpg")
    fi
done

img2pdf --output "${SPOOL_DIR}/${NAME}.pdf.part" "${IMAGES[@]}" \
    || fail "img2pdf fehlgeschlagen"
mv "${SPOOL_DIR}/${NAME}.pdf.part" "${SPOOL_DIR}/${NAME}.pdf"
rm -rf "${SCANDIR}"

log "Fertig: ${SPOOL_DIR}/${NAME}.pdf"

# Direkt zustellen, statt auf den Timer zu warten
DELIVER="$(dirname "$(readlink -f "$0")")/deliver.sh"
if [ -x "${DELIVER}" ]; then
    "${DELIVER}" || true
fi
