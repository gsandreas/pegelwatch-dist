#!/usr/bin/env bash
# pi-base-setup.sh — Basis-Installation fuer einen frisch aufgesetzten Raspberry Pi,
# BEVOR pegelwatch per deploy.ps1 darauf aufgesetzt wird.
#
# Richtet die beiden Fremddienste ein, auf denen pegelwatch aufbaut:
#   1. Basis-System aktualisieren        (apt update + full-upgrade)
#   2. Grafana                           — offizielles apt-Repo (apt-verwaltet,
#                                            folgt kuenftig einfach `apt upgrade`)
#   3. InfluxDB 3 Core                   — GEPINNTE Version als Binary (nicht in
#                                            apt verfuegbar) + gehaertete systemd-Unit
#
# Danach auf dem Windows-Rechner:  .\deploy.ps1 -PiHost <ip>   (installiert pegelwatch)
#
# Eigenschaften:
#   * idempotent — mehrfach ausfuehrbar, ueberspringt bereits erledigte Schritte
#   * greift NICHT in pegelwatch/config.toml/secrets.toml/state.db ein
#   * legt KEIN InfluxDB-Token/keine DB an (bewusst manuell, siehe Schluss-Hinweis)
#
# Aufruf direkt auf dem Pi:   sudo ./pi-base-setup.sh
# oder von Windows aus:       .\pi-base-setup.ps1 -PiHost <ip>   (Wrapper: scp + ssh)

set -euo pipefail

# ── Gepinnte Versionen / Konfiguration ───────────────────────────────────────
# Neue InfluxDB-Version einspielen: VERSION anheben und die zugehoerige SHA256
# aus  https://dl.influxdata.com/influxdb/releases/<tarball>.sha256  uebernehmen.
INFLUXDB3_VERSION="3.10.0"
INFLUXDB3_SHA256="07302213ff25a7f09e3dedf5f658c999ba8cfac710fb3f17db3b9d5ebf1fa178"
INFLUXDB3_NODE_ID="pumpwatch1"
INFLUX_DATA_DIR="/var/lib/influxdb3"
INFLUX_HTTP_BIND="0.0.0.0:8086"   # 8086 (nicht influxdb3-Default 8181), damit
                                   # pegelwatch/Grafana die gewohnte Adresse nutzen

# Dienst-Benutzer: der Aufrufer hinter sudo (nicht root — analog pegelwatch, damit
# Datenverzeichnis und spaeteres Token-Handling demselben Benutzer gehoeren).
RUN_USER="${SUDO_USER:-$(id -un)}"

# ── Ausgabe-Helfer ───────────────────────────────────────────────────────────
c_blue=$'\e[36m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_red=$'\e[31m'; c_off=$'\e[0m'
step() { printf '\n%s[>>] %s%s\n' "$c_blue" "$1" "$c_off"; }
ok()   { printf '%s[OK]%s   %s\n' "$c_green" "$c_off" "$1"; }
warn() { printf '%s[WARN]%s %s\n' "$c_yellow" "$c_off" "$1"; }
die()  { printf '%s[FEHLER]%s %s\n' "$c_red" "$c_off" "$1" >&2; exit 1; }

# ── 0. Vorbedingungen ────────────────────────────────────────────────────────
step "Vorbedingungen pruefen"
[ "$(id -u)" -eq 0 ] || die "Bitte mit sudo ausfuehren:  sudo ./pi-base-setup.sh"

arch="$(uname -m)"
[ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ] || \
	die "Nicht-arm64-Architektur ($arch) — dieses Skript ist fuer den Raspberry Pi (64-bit) gedacht."
ok "Architektur: $arch, Dienst-Benutzer: $RUN_USER"

# InfluxDB 3 Core stuerzt auf 16-KB-Kerneln (u.a. Pi 5) ab — 4-KB-Seiten sind Pflicht.
pagesize="$(getconf PAGE_SIZE 2>/dev/null || echo '?')"
if [ "$pagesize" != "4096" ]; then
	warn "Speicherseitengroesse = $pagesize (nicht 4096!)."
	warn "InfluxDB 3 Core braucht einen 4-KB-Kernel, sonst crasht es beim Start:"
	warn "    echo 'kernel=kernel8.img' | sudo tee -a /boot/firmware/config.txt && sudo reboot"
	warn "Installation laeuft weiter — InfluxDB startet aber erst nach dieser Umstellung sauber."
else
	ok "Speicherseitengroesse: 4096 (InfluxDB-3-tauglich)"
fi

export DEBIAN_FRONTEND=noninteractive

# ── 1. Basis-System aktualisieren ────────────────────────────────────────────
step "Basis-System aktualisieren (apt update + full-upgrade)"
apt-get update
apt-get -y full-upgrade
apt-get -y install ca-certificates wget curl gpg apt-transport-https
ok "Basis aktuell, Grundpakete vorhanden"

# ── 2. Grafana aus offiziellem apt-Repo ──────────────────────────────────────
step "Grafana (offizielles apt-Repo) installieren/aktualisieren"
install -d -m 0755 /usr/share/keyrings
# Schluessel immer neu holen (idempotent, deckt Schluesselrotation ab).
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/grafana.gpg
echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
	> /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get -y install grafana
systemctl enable --now grafana-server
ok "Grafana installiert und aktiviert (kuenftige Updates via 'apt upgrade')"

# ── 3. InfluxDB 3 Core (gepinnte Version) ────────────────────────────────────
step "InfluxDB 3 Core $INFLUXDB3_VERSION installieren (gepinnt, mit Checksumme)"
current=""
if [ -x /usr/local/bin/influxdb3 ]; then
	current="$(/usr/local/bin/influxdb3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi
if [ "$current" = "$INFLUXDB3_VERSION" ]; then
	ok "influxdb3 $INFLUXDB3_VERSION bereits installiert — Download uebersprungen"
else
	tarball="influxdb3-core-${INFLUXDB3_VERSION}_linux_arm64.tar.gz"
	url="https://dl.influxdata.com/influxdb/releases/${tarball}"
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	echo "  Lade $url"
	wget -q -O "$tmp/$tarball" "$url" || die "Download fehlgeschlagen: $url"
	echo "  Pruefe SHA256 ..."
	echo "${INFLUXDB3_SHA256}  $tmp/$tarball" | sha256sum -c - \
		|| die "SHA256 stimmt NICHT — Download verworfen (falsche Version oder manipuliert)."
	tar xzf "$tmp/$tarball" -C "$tmp"
	bin="$(find "$tmp" -type f -name influxdb3 -perm -u+x | head -1)"
	[ -n "$bin" ] || die "influxdb3-Binary im Tarball nicht gefunden"
	install -m 0755 "$bin" /usr/local/bin/influxdb3
	ok "influxdb3 $INFLUXDB3_VERSION nach /usr/local/bin installiert"
fi

# Datenverzeichnis (gehoert dem Dienst-Benutzer, nicht root).
install -d -o "$RUN_USER" -g "$RUN_USER" "$INFLUX_DATA_DIR"

# Selbstheilungs-Skript: raeumt leere/genullte Katalog-/WAL-Dateien beiseite, die
# ein unsauberer Shutdown (Stromverlust) hinterlaesst — sonst crasht influxdb3
# beim Start endlos ("catalog buffer too short" bzw. WAL "AlreadyExists"). Nur
# Nullbytes = nie geschriebener Inhalt, also kein Datenverlust. Laeuft als
# ExecStartPre. Quelle ist deploy/influxdb3-heal.sh: es muss neben diesem Skript
# liegen (deploy.ps1 kopiert beide und installiert es zusaetzlich bei jedem Deploy).
step "InfluxDB-Selbstheilung + systemd-Unit einrichten"
heal_src="$(dirname "$0")/influxdb3-heal.sh"
[ -f "$heal_src" ] || die "influxdb3-heal.sh nicht neben pi-base-setup.sh gefunden ($heal_src) — beide Dateien auf den Pi kopieren"
sed 's/\r$//' "$heal_src" > /usr/local/bin/influxdb3-heal.sh
chmod 0755 /usr/local/bin/influxdb3-heal.sh
ok "Heal-Skript: /usr/local/bin/influxdb3-heal.sh"

cat > /etc/systemd/system/influxdb3.service <<UNIT
[Unit]
Description=InfluxDB 3 Core (PegelWatch)
After=network.target
Wants=network.target
# Nicht endlos in denselben Startfehler loopen (SD-Kartenschonung): nach 5
# Fehlstarts in 300s gibt systemd auf -> failed. Wiederanlauf danach:
#   sudo systemctl reset-failed influxdb3 && sudo systemctl start influxdb3
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$RUN_USER
# Vor dem Start leere Katalog/WAL-Dateien nach unsauberem Shutdown wegraeumen.
ExecStartPre=/usr/local/bin/influxdb3-heal.sh $INFLUX_DATA_DIR
ExecStart=/usr/local/bin/influxdb3 serve --node-id $INFLUXDB3_NODE_ID --object-store file --data-dir $INFLUX_DATA_DIR --http-bind $INFLUX_HTTP_BIND --disable-telemetry-upload
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable influxdb3
systemctl reset-failed influxdb3 2>/dev/null || true
systemctl restart influxdb3
ok "influxdb3.service eingerichtet, aktiviert und gestartet"

# ── Abschluss / naechste Schritte ────────────────────────────────────────────
step "Basis-Setup abgeschlossen"
inflx_state="$(systemctl is-active influxdb3 2>/dev/null || true)"
graf_state="$(systemctl is-active grafana-server 2>/dev/null || true)"
echo "  InfluxDB 3 Core : $inflx_state  (Port ${INFLUX_HTTP_BIND##*:})"
echo "  Grafana         : $graf_state  (Port 3000)"
cat <<NEXT

Naechste Schritte (bewusst manuell — schreiben Zugangsdaten):

  1. InfluxDB-Admin-Token + Datenbank anlegen (Token notieren!):
       influxdb3 create token --admin --host http://localhost:8086
       influxdb3 create database pegelwatch --token "apiv3_..." --host http://localhost:8086

  2. pegelwatch vom Windows-Rechner deployen:
       .\\deploy.ps1 -PiHost <ip-dieses-pi>

  3. Token in der Konfigurations-UI eintragen (InfluxDB -> Token -> speichern,
     danach Dienst neu starten) oder direkt in /etc/pegelwatch/secrets.toml.

  4. Grafana: Datasource (UID pegelwatch-influx, InfluxQL, http://localhost:8086,
     Bearer <token>) + die Dashboards aus grafana/ provisionieren — siehe
     docs/03-grafana.md.
NEXT
ok "Fertig."
