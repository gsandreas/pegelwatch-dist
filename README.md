# PegelWatch – Verteilung

Öffentliche Bezugsquelle für **PegelWatch**, die Mess- und Steuerungssoftware
für Wasserpegel- und Pumpenüberwachung auf dem Raspberry Pi
(RIVERWatch · SEPWatch · PUMPWatch).

Dieses Repository enthält **keinen Quellcode**. Die Paketquelle liegt im
Branch `gh-pages` und ist unter **https://gsandreas.github.io/pegelwatch-dist/**
erreichbar; sie wird automatisch veröffentlicht und signiert.

## Installation

Auf einem frisch eingerichteten Raspberry Pi OS (64 bit):

```bash
curl -fsSL https://gsandreas.github.io/pegelwatch-dist/install.sh | sudo sh
```

Testanlage im Kanal *daily*:

```bash
curl -fsSL https://gsandreas.github.io/pegelwatch-dist/install.sh | sudo sh -s -- --channel daily
```

Danach im Browser `http://<IP-des-Pi>:8080/konfiguration` öffnen.

## Kanäle

- **stable** – freigegebene Versionen, für den Produktivbetrieb.
- **daily** – jeder neue Stand, für Test- und Pilotanlagen.

Welchen Kanal eine Anlage bezieht, entscheidet ihr Betreiber in der
Konfiguration der Anlage. Vorgehalten werden die letzten 5 daily- und
3 stable-Versionen.

## Signatur

Die Paketlisten sind mit diesem Schlüssel signiert; apt prüft die Signatur
bei jedem Update:

```
PegelWatch Paketquelle <gsandreas@users.noreply.github.com>
Fingerprint: 811C 0B63 D3FB FEDA 059C 008F 5CFB FAA9 8605 8508
```
