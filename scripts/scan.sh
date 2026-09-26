#!/bin/bash
# Scannt alle Seiten aus dem ADF, bereitet sie mit process.py auf und legt ein PDF im Spool ab.
# Aufruf: scan.sh <sane-device>
#         scan.sh --from-dir <verzeichnis-mit-page-*.pnm> [ausgabe.pdf]
#           verarbeitet vorhandene Rohseiten erneut (zum Einstellen der Aufbereitung)
set -euo pipefail
export LC_ALL=C.UTF-8

CONFIG=/etc/default/documentscanner
# Alle Einstellungen exportieren, process.py liest sie aus der Umgebung
set -a
# shellcheck source=/dev/null
[ -r "${CONFIG}" ] && . "${CONFIG}"
set +a

MODE="${MODE:-Color}"
RESOLUTION="${RESOLUTION:-300}"
SOURCE="${SOURCE:-ADF Duplex}"
PAGE_WIDTH="${PAGE_WIDTH:-210}"
PAGE_HEIGHT="${PAGE_HEIGHT:-297}"
SWCROP="${SWCROP:-no}"
SWDESKEW="${SWDESKEW:-no}"
SWDESPECK="${SWDESPECK:-1}"
KEEP_RAW="${KEEP_RAW:-0}"
RAW_PDF="${RAW_PDF:-1}"
RAW_PDF_SUBDIR="${RAW_PDF_SUBDIR:-raw}"
WORK_DIR="${WORK_DIR:-/var/lib/documentscanner/work}"
FAILED_DIR="${FAILED_DIR:-/var/lib/documentscanner/failed}"
RAW_DIR="${RAW_DIR:-/var/lib/documentscanner/raw}"
SPOOL_DIR="${SPOOL_DIR:-/var/spool/documentscanner/outbox}"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

log() {
    echo "$(date '+%F %T') scan: $*"
}

FROM_DIR=""
OUTPUT=""
if [ "${1:-}" = "--from-dir" ]; then
    FROM_DIR="${2:-}"
    OUTPUT="${3:-}"
    if [ ! -d "${FROM_DIR}" ]; then
        log "Verzeichnis ${FROM_DIR} existiert nicht, Abbruch"
        exit 1
    fi
else
    DEVICE="${1:-}"
    if [ -z "${DEVICE}" ]; then
        log "Bitte SANE-Device angeben, Abbruch"
        exit 1
    fi
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

RC=0
if [ -n "${FROM_DIR}" ]; then
    log "Verarbeite Rohseiten aus ${FROM_DIR}"
    cp "${FROM_DIR}"/page-*.pnm "${SCANDIR}/"
else
    log "Scanne ${DEVICE} (${MODE}, ${RESOLUTION} dpi, ${SOURCE}) nach ${SCANDIR}"
    # Leerseiten werden nicht im Treiber (--swskip) entfernt, sondern in process.py:
    # sonst lassen sich Vorder- und Rückseiten nicht mehr den Blättern zuordnen.
    scanimage -d "${DEVICE}" \
        --batch="${SCANDIR}/page-%04d.pnm" --format=pnm \
        --source "${SOURCE}" --mode "${MODE}" --resolution "${RESOLUTION}" \
        --page-width "${PAGE_WIDTH}" --page-height "${PAGE_HEIGHT}" \
        -x "${PAGE_WIDTH}" -y "${PAGE_HEIGHT}" \
        --swcrop="${SWCROP}" --swdeskew="${SWDESKEW}" --swdespeck "${SWDESPECK}" \
        --df-action Stop --df-thickness=yes --df-length=yes || RC=$?
fi

shopt -s nullglob
PAGES=("${SCANDIR}"/page-*.pnm)

if [ "${#PAGES[@]}" -eq 0 ]; then
    log "Keine Seiten gescannt (scanimage rc=${RC})"
    rm -rf "${SCANDIR}"
    exit 0
fi

# Unbearbeitetes Roh-PDF in einen Unterordner des Shares (auch bei abgebrochenem Scan)
if [ "${RAW_PDF}" = "1" ] && [ -z "${OUTPUT}" ]; then
    RAW_NAME="${NAME}"
    [ "${RC}" -ne 0 ] && RAW_NAME="${NAME}_abgebrochen"
    mkdir -p "${SPOOL_DIR}/${RAW_PDF_SUBDIR}"
    RAW_TARGET="${SPOOL_DIR}/${RAW_PDF_SUBDIR}/${RAW_NAME}.pdf"
    if python3 "${SCRIPT_DIR}/process.py" --raw --output "${RAW_TARGET}.part" "${PAGES[@]}"; then
        mv "${RAW_TARGET}.part" "${RAW_TARGET}"
    else
        rm -f "${RAW_TARGET}.part"
        log "Roh-PDF konnte nicht erzeugt werden"
    fi
fi

# Papierstau / Doppeleinzug: nicht weiterverarbeiten, sondern zur Kontrolle aufheben
if [ "${RC}" -ne 0 ]; then
    fail "Scan abgebrochen (scanimage rc=${RC}) nach ${#PAGES[@]} Seiten"
fi

log "${#PAGES[@]} Seiten gescannt, bereite auf"

# Rohdaten zum Einstellen der Bildaufbereitung aufheben
if [ "${KEEP_RAW}" = "1" ] && [ -z "${FROM_DIR}" ]; then
    mkdir -p "${RAW_DIR}/${NAME}"
    cp "${PAGES[@]}" "${RAW_DIR}/${NAME}/"
fi

DUPLEX=()
[[ "${SOURCE}" == *Duplex* ]] && DUPLEX=(--duplex)

TARGET="${OUTPUT:-${SPOOL_DIR}/${NAME}.pdf}"
PRC=0
python3 "${SCRIPT_DIR}/process.py" "${DUPLEX[@]}" --output "${TARGET}.part" "${PAGES[@]}" || PRC=$?
if [ "${PRC}" -eq 3 ]; then
    log "Alle Seiten leer, kein PDF erzeugt"
    rm -rf "${SCANDIR}"
    exit 0
elif [ "${PRC}" -ne 0 ]; then
    rm -f "${TARGET}.part"
    fail "Aufbereitung fehlgeschlagen (rc=${PRC})"
fi
mv "${TARGET}.part" "${TARGET}"
rm -rf "${SCANDIR}"

log "Fertig: ${TARGET}"

# Direkt zustellen, statt auf den Timer zu warten
if [ -z "${OUTPUT}" ] && [ -x "${SCRIPT_DIR}/deliver.sh" ]; then
    "${SCRIPT_DIR}/deliver.sh" || true
fi
