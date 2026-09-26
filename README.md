# documentscanner

Macht aus einem Fujitsu **ScanSnap S510** einen „Knopf drücken → PDF in Paperless“-Scanner.
Läuft in einem LXC-Container auf dem Proxmox-Host `pve-len`, an dem der Scanner per USB hängt.

```
[S510 Knopf] → scanbd → scan.sh
                 scanimage (ADF Duplex, Farbe, 300 dpi, Deskew/Despeck im Treiber)
             → process.py (Python, Pillow + numpy)
                 Tesseract-Lageerkennung (kopfstehende Seiten drehen, kein OCR)
                 Weißabgleich: Papierton + Durchscheinendes → weiß, farbige Tinte bleibt
                 Schieflage anhand der Textzeilen korrigieren, Leerseiten entfernen
                 PNG mit 8-Farben-Palette (~150–250 KB/Seite)
                 img2pdf → lokaler Spool
             → deliver.sh (sofort + alle 60 s per Timer)
                 → \\192.168.0.10\DATA\dokumente\scan → Paperless-ngx (OCR)
```

**Warum kein OCR im Container?** Paperless-ngx führt beim Import ohnehin OCRmyPDF/Tesseract aus.
Vorheriges OCR wäre doppelte Arbeit bzw. Paperless würde die (schlechtere) vorhandene Textschicht übernehmen.

Ursprünglich basiert das Projekt auf [BastianPoe/documentscanner](https://github.com/BastianPoe/documentscanner).

## Einrichtung

### 1. Container auf pve-len anlegen
Privilegierter Debian-13-Container, z. B.:

```bash
pct create 120 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst --hostname scanner --unprivileged 0 --cores 2 --memory 1024 --rootfs local-lvm:8 --net0 name=eth0,bridge=vmbr0,ip=dhcp --onboot 1
```

(Template-Name mit `pveam available | grep debian-13` prüfen.)

Dann die Zeilen aus [deploy/lxc.conf.example](deploy/lxc.conf.example) an `/etc/pve/lxc/120.conf` anhängen
und den Container starten. Auf dem Host darf **kein** scanbd/saned laufen, das den Scanner belegt.

### 2. Im Container installieren

```bash
apt-get install -y git && git clone <dieses-repo> /root/documentscanner
/root/documentscanner/deploy/install.sh
```

Danach Zugangsdaten für den Share in `/etc/documentscanner/smb.cred` eintragen und `mount /mnt/scan` testen.

### 3. Paperless-ngx
- Consume-Verzeichnis von Paperless auf `\\192.168.0.10\DATA\dokumente\scan` legen.
- `PAPERLESS_CONSUMER_POLLING=10` setzen – auf SMB-Freigaben funktioniert inotify nicht.
- Dateien werden erst als `*.pdf.tmp` geschrieben und dann umbenannt, Paperless sieht nie halbe Dateien.

## Konfiguration
Alle Einstellungen stehen in `/etc/default/documentscanner` (Vorlage: [deploy/documentscanner.default](deploy/documentscanner.default)):
- **Ausgabeformat:** `IMAGE_FORMAT=palette` (Standard) speichert jede Seite als PNG mit 8 Farben – scharf und
  ~150–250 KB/Seite. Für Fotos/farbige Grafiken `IMAGE_FORMAT=jpeg`.
- **Hintergrund & Tinte:** Weißabgleich auf den Papierton, danach wird alles Helle und Farblose
  (getöntes Papier, durchscheinende Rückseiten) weiß. Farbige Tinte bleibt erhalten und wird nachgedunkelt.
  Stellschrauben: `WHITE_POINT` (kleiner = aggressiver), `INK_GAMMA`, `COLOR_BOOST`.
- **Schieflage:** Der Treiber korrigiert nur bei klarer Papierkante (`SWDESKEW`); zusätzlich richtet
  `process.py` die Seite an den Textzeilen aus (`DESKEW`).
- **Drehung:** Die Lage wird per Tesseract-OSD für das ganze Dokument per Mehrheit bestimmt.
- **Duplex-Reihenfolge:** Liegt der Stapel mit der Schrift nach oben im Einzug, liefert der Scanner je Blatt
  zuerst die Rückseite. `DUPLEX_ORDER=auto` erkennt das aus den Seitenzahlen in Kopf-/Fußzeile
  („Seite 3“, „2 von 4“) bzw. aus Blättern mit leerer Rückseite; sonst gilt `DUPLEX_DEFAULT`
  (Standard: Vorderseite zuerst = Schrift nach unten einlegen).
- **Schieflage** bis ±45° wird korrigiert. Ab 3° steht eine Warnung im Log: Bei so schief eingezogenen
  Blättern können Ränder außerhalb des Scanbereichs gelegen haben.
- **Leerseiten** entfernt `process.py` (`BLANK_THRESHOLD`, Rand wird ignoriert), nicht der Treiber – sonst verrutschen die
  Vorder-/Rückseiten-Paare.
- **Zuschnitt** im Treiber (`SWCROP`) ist aus, weil er bei dünnem Papier in den Inhalt schneidet.

**Einstellen an echten Scans:** `KEEP_RAW=1` setzen, dann landen die unbearbeiteten Seiten in
`/var/lib/documentscanner/raw/` (~25 MB/Seite!). Mit
`/opt/documentscanner/scripts/scan.sh --from-dir /var/lib/documentscanner/raw/<scan> /tmp/test.pdf`
lassen sie sich mit geänderten Einstellungen erneut verarbeiten, ohne neu zu scannen.

## Fehlersuche
- Scanner auf Host und im Container sichtbar? `lsusb | grep -i fujitsu`
- SANE findet ihn? scanbd belegt den Scanner, daher vorher stoppen:
  `systemctl stop scanbd; SANE_CONFIG_DIR=/etc/scanbd/sane.d scanimage -L; systemctl start scanbd`
- Knopfdruck/Scan-Log: `journalctl -u scanbd -f`
- Zustellung: `journalctl -u documentscanner-deliver -f`, Rückstau in `/var/spool/documentscanner/outbox`
- Abgebrochene Scans (Papierstau, Doppeleinzug) landen **nicht** in Paperless, sondern in
  `/var/lib/documentscanner/failed/` – regelmäßig kontrollieren und aufräumen.
