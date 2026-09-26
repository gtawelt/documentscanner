#!/bin/bash
# Verschiebt fertige PDFs aus dem lokalen Spool auf den SMB-Share.
# Ist der Share nicht erreichbar, bleiben die PDFs im Spool und werden beim
# nächsten Lauf (systemd-Timer) zugestellt.
set -euo pipefail

CONFIG=/etc/default/documentscanner
# shellcheck source=/dev/null
[ -r "${CONFIG}" ] && . "${CONFIG}"

SPOOL_DIR="${SPOOL_DIR:-/var/spool/documentscanner/outbox}"
TARGET_DIR="${TARGET_DIR:-/mnt/scan}"

log() {
    echo "$(date '+%F %T') deliver: $*"
}

shopt -s nullglob
FILES=("${SPOOL_DIR}"/*.pdf)
[ "${#FILES[@]}" -eq 0 ] && exit 0

# Share bei Bedarf (neu) mounten – systemd-Automount funktioniert im LXC nicht
if ! findmnt -n -t cifs "${TARGET_DIR}" > /dev/null; then
    mount "${TARGET_DIR}" 2>&1 || true
fi
if ! findmnt -n -t cifs "${TARGET_DIR}" > /dev/null || ! ls "${TARGET_DIR}" > /dev/null 2>&1; then
    log "${TARGET_DIR} nicht gemountet, ${#FILES[@]} PDF(s) bleiben im Spool"
    exit 1
fi

# Parallel laufende Zustellungen (Timer + scan.sh) vermeiden
exec 9>"${SPOOL_DIR}/.deliver.lock"
flock 9

RC=0
for FILE in "${FILES[@]}"; do
    [ -f "${FILE}" ] || continue
    NAME="$(basename "${FILE}")"
    # Erst unter .tmp kopieren, damit Paperless nie eine halbe Datei sieht
    if cp "${FILE}" "${TARGET_DIR}/${NAME}.tmp" && mv "${TARGET_DIR}/${NAME}.tmp" "${TARGET_DIR}/${NAME}"; then
        rm -f "${FILE}"
        log "Zugestellt: ${TARGET_DIR}/${NAME}"
    else
        rm -f "${TARGET_DIR}/${NAME}.tmp" || true
        log "Zustellung fehlgeschlagen: ${NAME}"
        RC=1
    fi
done

exit "${RC}"
