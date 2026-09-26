#!/bin/bash
# Installiert documentscanner in einem Debian-13-LXC. Als root im Container ausführen:
#   ./deploy/install.sh
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PREFIX=/opt/documentscanner

log() {
    echo "==> $*"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte als root ausführen" >&2
    exit 1
fi

log "Pakete installieren"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    sane-utils libsane1 scanbd tesseract-ocr tesseract-ocr-osd tesseract-ocr-deu \
    python3 python3-numpy python3-pil python3-img2pdf cifs-utils util-linux usbutils

log "Skripte nach ${PREFIX} installieren"
install -d "${PREFIX}/scripts"
install -m 0755 "${REPO}/scripts/scan.sh" "${REPO}/scripts/process.py" "${REPO}/scripts/deliver.sh" "${PREFIX}/scripts/"

if [ ! -f /etc/default/documentscanner ]; then
    install -m 0644 "${REPO}/deploy/documentscanner.default" /etc/default/documentscanner
else
    log "/etc/default/documentscanner existiert bereits, wird nicht überschrieben"
fi

install -d /var/lib/documentscanner/work /var/lib/documentscanner/failed /var/spool/documentscanner/outbox

log "scanbd konfigurieren"
# Eigene SANE-Konfiguration für scanbd, nur mit dem fujitsu-Backend
install -d /etc/scanbd/sane.d
cp -a /etc/sane.d/. /etc/scanbd/sane.d/
rm -rf /etc/scanbd/sane.d/dll.d
echo "fujitsu" > /etc/scanbd/sane.d/dll.conf

SCANBD_CONF=/etc/scanbd/scanbd.conf
SCRIPT_DIR="$(sed -nE 's/^\s*scriptdir\s*=\s*(\S+).*/\1/p' "${SCANBD_CONF}" | head -n 1)"
SCRIPT_DIR="${SCRIPT_DIR:-/etc/scanbd/scripts}"
install -d "${SCRIPT_DIR}"
install -m 0755 "${REPO}/scanbd/scan.script" "${SCRIPT_DIR}/scan.script"

# Alle Aktionen auf unser Skript umbiegen; scan.script ignoriert alles außer "scan"
sed -i -E 's/"test\.script"/"scan.script"/g' "${SCANBD_CONF}"
# Scripts als root ausführen (Zugriff auf USB-Gerät, Spool, Share)
sed -i -E 's/^(\s*user\s*=\s*).*/\1root/' "${SCANBD_CONF}"

install -d /etc/systemd/system/scanbd.service.d
cat > /etc/systemd/system/scanbd.service.d/documentscanner.conf <<'EOF'
[Service]
Environment=SANE_CONFIG_DIR=/etc/scanbd/sane.d
EOF

log "SMB-Share einrichten"
install -d /mnt/scan
install -d -m 0700 /etc/documentscanner
if [ ! -f /etc/documentscanner/smb.cred ]; then
    install -m 0600 "${REPO}/deploy/smb.cred.example" /etc/documentscanner/smb.cred
    log "Bitte Zugangsdaten in /etc/documentscanner/smb.cred eintragen"
fi
if ! grep -qE '\s/mnt/scan\s' /etc/fstab; then
    cat "${REPO}/deploy/fstab.example" >> /etc/fstab
fi

log "systemd-Units installieren"
install -m 0644 "${REPO}/deploy/documentscanner-deliver.service" "${REPO}/deploy/documentscanner-deliver.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl restart remote-fs.target || true
systemctl enable --now documentscanner-deliver.timer
systemctl enable scanbd
# saned/scanbm wird nicht gebraucht ("enable scanbd" aktiviert es per Also= mit)
systemctl disable --now scanbm.socket 2>/dev/null || true
systemctl restart scanbd

log "Fertig. Prüfen mit:"
echo "    lsusb | grep -i fujitsu"
echo "    systemctl stop scanbd; SANE_CONFIG_DIR=/etc/scanbd/sane.d scanimage -L; systemctl start scanbd"
echo "    journalctl -u scanbd -f"
