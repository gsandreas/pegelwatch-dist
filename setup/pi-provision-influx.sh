#!/usr/bin/env bash
# pi-provision-influx.sh — macht einen frisch aufgesetzten Pi MESSBEREIT, indem
# es die InfluxDB fertig einrichtet und pegelwatch/Grafana damit verdrahtet:
#
#   1. Datenbank "pegelwatch" anlegen (falls nicht vorhanden)
#   2. Admin-Token erzeugen (falls noch keiner in secrets.toml steht)
#   3. Token in /etc/pegelwatch/secrets.toml unter [influx.local] eintragen
#   4. Grafana-Datasource (UID pegelwatch-influx) mit dem Token provisionieren
#   5. pegelwatch neu starten, damit es sofort in die InfluxDB schreibt
#
# Wird von deploy.ps1 bei der Ersteinrichtung (oder -BaseSetup) NACH der
# pegelwatch-Installation aufgerufen. Idempotent und bewusst NICHT-fatal: was
# nicht geht (z.B. InfluxDB laeuft wegen fehlendem 4-KB-Kernel noch nicht), wird
# nur gewarnt — der Rest des Deploys bleibt gueltig.
#
# Aufruf:  sudo ./pi-provision-influx.sh
set -uo pipefail

INFLUX_HOST="http://localhost:8086"
DB="pegelwatch"
SECRETS="/etc/pegelwatch/secrets.toml"
GRAFANA_DS="/etc/grafana/provisioning/datasources/pegelwatch.yaml"
RUN_USER="${SUDO_USER:-$(id -un)}"

c_blue=$'\e[36m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_off=$'\e[0m'
step() { printf '\n%s[>>] %s%s\n' "$c_blue" "$1" "$c_off"; }
ok()   { printf '%s[OK]%s   %s\n' "$c_green" "$c_off" "$1"; }
warn() { printf '%s[WARN]%s %s\n' "$c_yellow" "$c_off" "$1"; }

[ "$(id -u)" -eq 0 ] || { warn "Bitte mit sudo ausfuehren."; exit 0; }

# ── 0. Voraussetzungen ────────────────────────────────────────────────────────
if ! command -v influxdb3 >/dev/null 2>&1; then
    warn "influxdb3 nicht installiert — Provisionierung uebersprungen (pi-base-setup zuerst)."
    exit 0
fi
if ! systemctl is-active --quiet influxdb3; then
    warn "influxdb3 laeuft nicht (evtl. 4-KB-Kernel noetig: 'kernel=kernel8.img' + reboot)."
    warn "DB/Token uebersprungen — nach dem Fix erneut deployen (oder -BaseSetup)."
    exit 0
fi
# Auf HTTP-Bereitschaft warten (Dienst kann kurz nach systemctl noch hochfahren).
ready=""
for _ in $(seq 1 20); do
    if curl -sf "$INFLUX_HOST/health" >/dev/null 2>&1; then ready=yes; break; fi
    sleep 1
done
[ -n "$ready" ] || warn "InfluxDB-HTTP ($INFLUX_HOST) nicht bereit — versuche es trotzdem."

# ── Helfer: Token aus [influx.local] lesen / schreiben ────────────────────────
read_influx_token() {
    [ -f "$SECRETS" ] || return 0
    awk '
        /^[[:space:]]*\[/ { s=$0; gsub(/[[:space:]]/,"",s); insec=(s=="[influx.local]") }
        insec && /^[[:space:]]*token[[:space:]]*=/ {
            v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); gsub(/^"|"$/,"",v); gsub(/[[:space:]]+$/,"",v); print v; exit
        }
    ' "$SECRETS" 2>/dev/null
}

set_influx_token() {
    local tok="$1"
    [ -f "$SECRETS" ] || { printf '[influx.local]\ntoken = "%s"\n' "$tok" > "$SECRETS"; return; }
    if grep -qE '^[[:space:]]*\[influx\.local\][[:space:]]*$' "$SECRETS"; then
        awk -v tok="$tok" '
            /^[[:space:]]*\[/ {
                if (insec && !set) { print "token = \"" tok "\""; set=1 }
                s=$0; gsub(/[[:space:]]/,"",s); insec=(s=="[influx.local]"); if (insec) set=0
            }
            {
                if (insec && $0 ~ /^[[:space:]]*token[[:space:]]*=/) { print "token = \"" tok "\""; set=1; next }
                print
            }
            END { if (insec && !set) print "token = \"" tok "\"" }
        ' "$SECRETS" > "$SECRETS.tmp" && mv "$SECRETS.tmp" "$SECRETS"
    else
        printf '\n[influx.local]\ntoken = "%s"\n' "$tok" >> "$SECRETS"
    fi
}

# ── 1./2. Token bestimmen (vorhandenen nutzen, sonst Admin-Token erzeugen) ─────
step "InfluxDB-Token einrichten"
token="$(read_influx_token)"
if [ -n "$token" ]; then
    ok "Token bereits in secrets.toml hinterlegt — kein neuer noetig."
else
    out="$(influxdb3 create token --admin --host "$INFLUX_HOST" 2>&1)" || true
    token="$(printf '%s' "$out" | grep -oE 'apiv3_[A-Za-z0-9_=-]+' | head -1 || true)"
    if [ -z "$token" ]; then
        warn "Konnte keinen Admin-Token erzeugen (evtl. existiert bereits einer, der nicht bekannt ist)."
        warn "Ausgabe: $(printf '%s' "$out" | head -3)"
        warn "Token manuell anlegen und in $SECRETS unter [influx.local] eintragen."
        exit 0
    fi
    set_influx_token "$token"
    chown "$RUN_USER:$RUN_USER" "$SECRETS" 2>/dev/null || true
    chmod 600 "$SECRETS" 2>/dev/null || true
    ok "Neuer Admin-Token erzeugt und in secrets.toml eingetragen."
fi

# ── 3. Datenbank anlegen (idempotent) ─────────────────────────────────────────
step "InfluxDB-Datenbank '$DB' sicherstellen"
if influxdb3 show databases --host "$INFLUX_HOST" --token "$token" 2>/dev/null | grep -qx "$DB"; then
    ok "Datenbank '$DB' existiert bereits."
else
    if influxdb3 create database "$DB" --host "$INFLUX_HOST" --token "$token" >/dev/null 2>&1; then
        ok "Datenbank '$DB' angelegt."
    else
        warn "Datenbank '$DB' konnte nicht angelegt werden (wird beim ersten Schreiben ggf. automatisch erzeugt)."
    fi
fi

# ── 4. Grafana-Datasource provisionieren (mit Token) ──────────────────────────
if command -v grafana-server >/dev/null 2>&1; then
    step "Grafana-Datasource (pegelwatch-influx) provisionieren"
    if [ -f "$GRAFANA_DS" ]; then
        ok "Datasource bereits provisioniert — unveraendert gelassen."
    else
        install -d -m0755 /etc/grafana/provisioning/datasources
        cat > "$GRAFANA_DS" <<EOF
apiVersion: 1
datasources:
  - name: PegelWatch InfluxDB
    uid: pegelwatch-influx
    type: influxdb
    access: proxy
    url: $INFLUX_HOST
    isDefault: true
    jsonData:
      dbName: $DB
      httpMode: GET
      httpHeaderName1: Authorization
    secureJsonData:
      httpHeaderValue1: Bearer $token
EOF
        chown grafana:grafana "$GRAFANA_DS" 2>/dev/null || true
        chmod 640 "$GRAFANA_DS"
        systemctl restart grafana-server 2>/dev/null || warn "Grafana-Neustart fehlgeschlagen."
        ok "Datasource provisioniert (Grafana neu gestartet)."
    fi
fi

# ── 5. pegelwatch neu starten (uebernimmt den neuen Token) ─────────────────────
if systemctl list-unit-files pegelwatch.service >/dev/null 2>&1; then
    systemctl restart pegelwatch 2>/dev/null || warn "pegelwatch-Neustart fehlgeschlagen."
    ok "pegelwatch neu gestartet — schreibt jetzt in die InfluxDB."
fi

step "InfluxDB-Provisionierung abgeschlossen"
