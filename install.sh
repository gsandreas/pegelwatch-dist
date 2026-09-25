#!/bin/sh
# PegelWatch — Installation auf einem Raspberry Pi (Raspberry Pi OS 64 bit).
#
#   curl -fsSL https://gsandreas.github.io/pegelwatch-dist/install.sh | sudo sh
#
# Optionen (hinter "sudo sh -s --"):
#   --channel daily   Kanal daily statt stable (jeder neue Stand, fuer Testanlagen)
#   --user NAME       Dienstbenutzer (Standard: der Aufrufer von sudo — noetig,
#                     wenn PegelWatch den Kiosk in dessen Desktop-Sitzung zeigt)
#   --no-base         Grafana/InfluxDB nicht installieren (nur PegelWatch)
#
# Was passiert:
#   1. Grafana + InfluxDB 3 Core (pi-base-setup.sh)
#   2. PegelWatch-Paketquelle (signiert) einrichten, Paket installieren und
#      von allgemeinen Upgrades ausnehmen (Updates kommen ueber den Kanal)
#   3. I²C/SPI aktivieren, InfluxDB-Datenbank + Token + Grafana-Datenquelle
# Danach: Konfiguration im Browser unter http://<IP-des-Pi>:8080/konfiguration
set -eu

BASE="https://gsandreas.github.io/pegelwatch-dist"
KEYRING=/usr/share/keyrings/pegelwatch-archive-keyring.gpg
# Fingerprint des Signaturschluessels — prueft, dass die Paketquelle echt ist.
FPR="811C0B63D3FBFEDA059C008F5CFBFAA986058508"

CHANNEL=stable
RUN_USER="${SUDO_USER:-}"
BASE_SETUP=1
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --user)    RUN_USER="$2"; shift 2 ;;
        --no-base) BASE_SETUP=0; shift ;;
        *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
    esac
done
case "$CHANNEL" in stable|daily) ;; *) echo "Kanal muss stable oder daily sein" >&2; exit 2 ;; esac

say() { printf '\n\033[36m[>>] %s\033[0m\n' "$1"; }
die() { printf '\033[31m[FEHLER]\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Bitte mit sudo ausfuehren: curl -fsSL $BASE/install.sh | sudo sh"
case "$(uname -m)" in aarch64|arm64) ;; *) die "Nur fuer Raspberry Pi mit 64-bit-System (arm64)." ;; esac
if [ -n "$RUN_USER" ] && ! getent passwd "$RUN_USER" >/dev/null; then die "Benutzer '$RUN_USER' gibt es nicht."; fi

export DEBIAN_FRONTEND=noninteractive
say "Grundpakete"
apt-get update -q
apt-get install -y -q ca-certificates curl gpg

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ "$BASE_SETUP" = 1 ]; then
    say "Grafana und InfluxDB 3 einrichten"
    curl -fsSL "$BASE/setup/pi-base-setup.sh" -o "$TMP/pi-base-setup.sh"
    curl -fsSL "$BASE/setup/influxdb3-heal.sh" -o "$TMP/influxdb3-heal.sh"
    SUDO_USER="${RUN_USER:-root}" bash "$TMP/pi-base-setup.sh"
fi

say "PegelWatch-Paketquelle einrichten (Kanal $CHANNEL)"
curl -fsSL "$BASE/pegelwatch-archive-keyring.gpg" -o "$TMP/keyring.gpg"
got=$(gpg --show-keys --with-colons "$TMP/keyring.gpg" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
[ "$got" = "$FPR" ] || die "Signaturschluessel der Paketquelle stimmt nicht (erwartet $FPR, erhalten ${got:-nichts})."
install -D -m 0644 "$TMP/keyring.gpg" "$KEYRING"
cat > /etc/apt/sources.list.d/pegelwatch.list <<LIST
# PegelWatch-Paketquelle (signiert). Beide Kanaele sind eingetragen, damit ein
# Rollback auf eine freigegebene Version moeglich ist; welcher Stand installiert
# wird, entscheidet der Kanal in der PegelWatch-Konfiguration.
deb [arch=arm64 signed-by=$KEYRING] $BASE stable main
deb [arch=arm64 signed-by=$KEYRING] $BASE daily main
LIST

say "PegelWatch installieren"
if [ -n "$RUN_USER" ] && [ "$RUN_USER" != root ]; then
    install -d -m 0755 /etc/pegelwatch
    echo "$RUN_USER" > /etc/pegelwatch/install-user
fi
apt-get update -q
apt-get install -y -q --allow-change-held-packages -t "$CHANNEL" pegelwatch
apt-mark hold pegelwatch >/dev/null
if [ "$CHANNEL" = daily ] && [ -f /etc/pegelwatch/config.toml ]; then
    sed -i 's/^\(channel[[:space:]]*=[[:space:]]*\)"stable"/\1"daily"/' /etc/pegelwatch/config.toml
fi

if command -v raspi-config >/dev/null 2>&1; then
    say "I²C und SPI aktivieren"
    raspi-config nonint do_i2c 0 || true
    raspi-config nonint do_spi 0 || true
fi

if [ "$BASE_SETUP" = 1 ]; then
    say "InfluxDB-Datenbank, Token und Grafana-Datenquelle"
    curl -fsSL "$BASE/setup/pi-provision-influx.sh" -o "$TMP/pi-provision-influx.sh"
    SUDO_USER="${RUN_USER:-root}" bash "$TMP/pi-provision-influx.sh" || true
fi

IP=$(hostname -I 2>/dev/null | cut -d' ' -f1)
say "Fertig"
echo "  PegelWatch $(dpkg-query -W -f='${Version}' pegelwatch) laeuft (Kanal $CHANNEL)."
echo "  Konfiguration: http://${IP:-<IP-des-Pi>}:8080/konfiguration"
echo "  Grafana:       http://${IP:-<IP-des-Pi>}:3000"
echo "  Ein Neustart aktiviert I²C/SPI, falls sie eben erst eingeschaltet wurden."
