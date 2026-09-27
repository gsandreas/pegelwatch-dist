#!/usr/bin/env bash
# influxdb3-heal.sh <datadir> — vor jedem influxdb3-Start aufgerufen
# (ExecStartPre in influxdb3.service).
#
# Verschiebt Katalog-/WAL-Dateien, die nur aus Nullbytes bestehen (auch 0 Byte
# lang), nach <datadir>/.recovered/<zeitstempel>/. Solche Dateien hinterlaesst
# ein unsauberer Shutdown (Stromverlust): das Dateisystem hat die Groesse schon
# festgeschrieben, die Daten aber nicht mehr. influxdb3 ueberspringt sie beim
# Replay ("Invalid wal file identifier"), will beim naechsten Schreiben aber
# genau diese Dateinummer neu anlegen ("another process has written to the WAL
# ahead of this one") und beendet sich — Start-Endlosschleife, bis systemd
# aufgibt. Nur Nullbytes = nie geschriebener Inhalt, also kein Datenverlust.
#
# Installiert von deploy.ps1 (bei jedem Deploy) und deploy/pi-base-setup.sh.
set -u
base="${1:-/var/lib/influxdb3}"
quar="$base/.recovered/$(date +%Y%m%d-%H%M%S)"
n=0
while IFS= read -r -d '' f; do
	size="$(stat -c %s "$f" 2>/dev/null)" || continue
	# cmp -n 0 ist immer gleich -> 0-Byte-Dateien werden mit erfasst.
	cmp -s -n "$size" "$f" /dev/zero || continue
	mkdir -p "$quar"
	if mv -f "$f" "$quar/"; then n=$((n + 1)); fi
done < <(find "$base" -path "$base/.recovered" -prune -o -type f \( -name '*.catalog' -o -name '*.wal' \) -print0 2>/dev/null)
if [ "$n" -gt 0 ]; then
	echo "influxdb3-heal: $n leere/genullte Katalog-/WAL-Datei(en) nach $quar beiseitegeraeumt"
fi
exit 0
