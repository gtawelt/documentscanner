#!/bin/bash
# Scannt alle Seiten aus dem ADF, bereitet sie auf und legt ein PDF im Spool ab.
# Aufruf: scan.sh <sane-device>
#         scan.sh --from-dir <verzeichnis-mit-page-*.pnm> [ausgabe.pdf]
#           verarbeitet vorhandene Rohseiten erneut (zum Einstellen der Aufbereitung)
set -euo pipefail
# netpbm-Hilfsprogramme (pnmquant) sind Perl-Skripte und warnen sonst über fehlende Locales
export LC_ALL=C

CONFIG=/etc/default/documentscanner
# shellcheck source=/dev/null
[ -r "${CONFIG}" ] && . "${CONFIG}"

MODE="${MODE:-Color}"
RESOLUTION="${RESOLUTION:-300}"
SOURCE="${SOURCE:-ADF Duplex}"
PAGE_WIDTH="${PAGE_WIDTH:-210}"
PAGE_HEIGHT="${PAGE_HEIGHT:-297}"
SWCROP="${SWCROP:-no}"
SWDESKEW="${SWDESKEW:-yes}"
SWDESPECK="${SWDESPECK:-1}"
SKIP_BLANK="${SKIP_BLANK:-1}"
BLANK_THRESHOLD="${BLANK_THRESHOLD:-0.1}"
AUTOROTATE="${AUTOROTATE:-1}"
ROTATE_MIN_CONF="${ROTATE_MIN_CONF:-2}"
PAGE_ROTATE_CONF="${PAGE_ROTATE_CONF:-6}"
DUPLEX_SWAP_ON_180="${DUPLEX_SWAP_ON_180:-1}"
UNPAPER="${UNPAPER:-0}"
UNPAPER_OPTS="${UNPAPER_OPTS:-}"
NORMALIZE="${NORMALIZE:-1}"
NORMALIZE_OPTS="${NORMALIZE_OPTS:--bvalue=60 -wvalue=190}"
IMAGE_FORMAT="${IMAGE_FORMAT:-palette}"
PALETTE_COLORS="${PALETTE_COLORS:-8}"
JPEG_QUALITY="${JPEG_QUALITY:-75}"
KEEP_RAW="${KEEP_RAW:-0}"
WORK_DIR="${WORK_DIR:-/var/lib/documentscanner/work}"
FAILED_DIR="${FAILED_DIR:-/var/lib/documentscanner/failed}"
RAW_DIR="${RAW_DIR:-/var/lib/documentscanner/raw}"
SPOOL_DIR="${SPOOL_DIR:-/var/spool/documentscanner/outbox}"

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
    # Leerseiten werden nicht im Treiber (--swskip) entfernt, sondern erst unten:
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

# Lageerkennung per Tesseract-OSD. Ausgabe: "<Winkel> <Konfidenz>", der Winkel ist
# die Drehung gegen den Uhrzeigersinn (pamflip), die die Seite aufrecht stellt.
orientation() {
    local osd rotate conf
    osd="$(tesseract "$1" - --psm 0 --dpi "${RESOLUTION}" 2>/dev/null)" || { echo "0 0"; return; }
    rotate="$(sed -n 's/^Rotate: //p' <<< "${osd}")"
    conf="$(sed -n 's/^Orientation confidence: //p' <<< "${osd}")"
    # tesseract meldet die Korrektur im Uhrzeigersinn, pamflip dreht dagegen
    echo "$(( (360 - ${rotate:-0}) % 360 )) ${conf:-0}"
}

# Anteil dunkler Pixel in Prozent
dark_ratio() {
    ppmtopgm "$1" 2>/dev/null | pgmhist -machine \
        | awk '{ t += $2; if ($1 < 128) d += $2 } END { printf "%.3f", t ? d * 100 / t : 0 }'
}

# Lage aller Seiten bestimmen; das Dokument wird per Mehrheit (Summe der Konfidenzen)
# gedreht, damit auch Seiten mit wenig Text richtig herum landen
DOC_ANGLE=0
declare -a OSD_ANGLE OSD_CONF
if [ "${AUTOROTATE}" = "1" ]; then
    for i in "${!PAGES[@]}"; do
        read -r "OSD_ANGLE[i]" "OSD_CONF[i]" < <(orientation "${PAGES[i]}")
    done
    DOC_ANGLE="$(for i in "${!PAGES[@]}"; do echo "${OSD_ANGLE[i]} ${OSD_CONF[i]}"; done \
        | awk -v min="${ROTATE_MIN_CONF}" '
            { sum[$1] += $2 }
            END { best = 0; bc = 0
                  for (a in sum) if (sum[a] > bc) { bc = sum[a]; best = a }
                  if (bc < min) best = 0
                  print best }')"
    log "Lage des Dokuments: ${DOC_ANGLE}° (je Seite: $(for i in "${!PAGES[@]}"; do printf '%s/%s ' "${OSD_ANGLE[i]}" "${OSD_CONF[i]}"; done))"
fi

# Pixel pro Meter für die DPI-Angabe im PNG
PPM=$(( (RESOLUTION * 10000 + 127) / 254 ))
declare -a OUT BLANK
for i in "${!PAGES[@]}"; do
    PAGE="${PAGES[i]}"
    BASE="${PAGE%.pnm}"
    SRC="${PAGE}"

    ANGLE="${DOC_ANGLE}"
    # Einzelne Seite nur abweichend drehen, wenn die Erkennung sehr sicher ist (z. B. Querformat)
    if [ "${AUTOROTATE}" = "1" ] && [ "${OSD_ANGLE[i]}" != "${DOC_ANGLE}" ] \
        && awk "BEGIN { exit !(${OSD_CONF[i]} >= ${PAGE_ROTATE_CONF}) }"; then
        ANGLE="${OSD_ANGLE[i]}"
    fi
    if [ "${ANGLE}" != "0" ]; then
        pamflip -r"${ANGLE}" "${SRC}" > "${BASE}-rot.pnm" || fail "Drehen fehlgeschlagen für ${PAGE}"
        SRC="${BASE}-rot.pnm"
    fi

    if [ "${UNPAPER}" = "1" ]; then
        # shellcheck disable=SC2086
        unpaper --overwrite --dpi "${RESOLUTION}" ${UNPAPER_OPTS} "${SRC}" "${BASE}-clean.pnm" \
            || fail "unpaper fehlgeschlagen für ${PAGE}"
        SRC="${BASE}-clean.pnm"
    fi

    # Papierhintergrund und durchscheinende Rückseite auf Weiß ziehen:
    # sauberer und deutlich kleinere Dateien
    if [ "${NORMALIZE}" = "1" ]; then
        # shellcheck disable=SC2086
        pnmnorm ${NORMALIZE_OPTS} "${SRC}" > "${BASE}-norm.pnm" 2>/dev/null \
            || fail "pnmnorm fehlgeschlagen für ${PAGE}"
        SRC="${BASE}-norm.pnm"
    fi

    BLANK[i]=0
    if [ "${SKIP_BLANK}" = "1" ]; then
        RATIO="$(dark_ratio "${SRC}")"
        if awk "BEGIN { exit !(${RATIO} < ${BLANK_THRESHOLD}) }"; then
            log "$(basename "${PAGE}"): leer (${RATIO}% dunkel), wird übersprungen"
            BLANK[i]=1
            continue
        fi
    fi

    if [ "${IMAGE_FORMAT}" = "palette" ]; then
        # Wenige Farben reichen für Dokumente mit weißem Hintergrund und sind sehr klein
        pnmquant -nofloyd "${PALETTE_COLORS}" "${SRC}" 2>/dev/null \
            | pnmtopng -compression 9 -size "${PPM} ${PPM} 1" > "${BASE}.png" \
            || fail "Palette-Konvertierung fehlgeschlagen für ${PAGE}"
        OUT[i]="${BASE}.png"
    elif [ "${IMAGE_FORMAT}" = "png" ]; then
        pnmtopng -size "${PPM} ${PPM} 1" "${SRC}" > "${BASE}.png" \
            || fail "PNG-Konvertierung fehlgeschlagen für ${PAGE}"
        OUT[i]="${BASE}.png"
    else
        pnmtojpeg --quality="${JPEG_QUALITY}" --density="${RESOLUTION}x${RESOLUTION}dpi" "${SRC}" > "${BASE}.jpg" \
            || fail "JPEG-Konvertierung fehlgeschlagen für ${PAGE}"
        OUT[i]="${BASE}.jpg"
    fi
done

# Seitenreihenfolge. Steht das ganze Dokument auf dem Kopf, wurde der Stapel gewendet
# eingelegt: Dann liefert der Scanner je Blatt zuerst die Rückseite.
ORDER=("${!PAGES[@]}")
if [ "${DUPLEX_SWAP_ON_180}" = "1" ] && [ "${DOC_ANGLE}" = "180" ] \
    && [[ "${SOURCE}" == *Duplex* ]] && [ $(( ${#PAGES[@]} % 2 )) -eq 0 ]; then
    log "Stapel war gewendet, tausche Vorder- und Rückseiten"
    ORDER=()
    for (( i = 0; i < ${#PAGES[@]}; i += 2 )); do
        ORDER+=($(( i + 1 )) "${i}")
    done
fi

IMAGES=()
for i in "${ORDER[@]}"; do
    [ "${BLANK[i]}" = "1" ] || IMAGES+=("${OUT[i]}")
done

if [ "${#IMAGES[@]}" -eq 0 ]; then
    log "Alle Seiten leer, kein PDF erzeugt"
    rm -rf "${SCANDIR}"
    exit 0
fi

TARGET="${OUTPUT:-${SPOOL_DIR}/${NAME}.pdf}"
img2pdf --output "${TARGET}.part" "${IMAGES[@]}" \
    || fail "img2pdf fehlgeschlagen"
mv "${TARGET}.part" "${TARGET}"
rm -rf "${SCANDIR}"

log "Fertig: ${TARGET} (${#IMAGES[@]} Seiten, $(( $(stat -c %s "${TARGET}") / 1024 )) KB)"

# Direkt zustellen, statt auf den Timer zu warten
if [ -z "${OUTPUT}" ]; then
    DELIVER="$(dirname "$(readlink -f "$0")")/deliver.sh"
    if [ -x "${DELIVER}" ]; then
        "${DELIVER}" || true
    fi
fi
