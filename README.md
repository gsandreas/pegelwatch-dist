# PegelWatch – Verteilung

Öffentliche Bezugsquelle für **PegelWatch**, die Mess- und Steuerungssoftware
für Wasserpegel- und Pumpenüberwachung auf dem Raspberry Pi
(RIVERWatch · SEPWatch · PUMPWatch).

Dieses Repository enthält **keinen Quellcode**, sondern nur, was zum
Installieren und Aktualisieren einer Anlage nötig ist:

| Inhalt | Zweck |
|---|---|
| apt-Paketquelle (signiert) | Installation und Updates über `apt`, Kanäle **stable** und **daily** |
| Installationsskript | richtet einen frischen Raspberry Pi mit einem Befehl ein |
| Images (später) | vorbereitetes Raspberry-Pi-Image für die Ersteinrichtung |

> **Status:** im Aufbau. Paketquelle und Installationsskript folgen.

## Kanäle

- **stable** – freigegebene Versionen, für den Produktivbetrieb.
- **daily** – jeder neue Stand, für Test- und Pilotanlagen.

Welchen Kanal eine Anlage bezieht, entscheidet ihr Betreiber in der
Konfiguration der Anlage.
