# Lageuhr

Kleiner Kasten, der immer im Vordergrund auf dem Bildschirm liegt – für Beamer und Lagebildschirm.
Er besteht aus beliebig vielen **Feldern** (anlegen, kopieren, sortieren, ausblenden), vier Arten:

- **Text** – z. B. Lage, Einsatzabschnitt, Funkkanal; mit kleiner Beschriftung darüber, mehrzeilig
- **Aktuelle Zeit** als taktische Zeit (`161432nov26`), auf Wunsch zusätzlich mit Sekunden
- **Seit …** (z. B. Kat-Fall, Einsatzbeginn) – Beginn als taktische Zeit und laufende Dauer
- **Termin mit Countdown** (z. B. nächste Lagebesprechung) – ab 10 min gelb, zur Zeit „JETZT“ rot blinkend,
  danach „überfällig“; auf Wunsch wiederkehrend (z. B. alle 120 min)

Jedes Feld hat eigene **Farben** (Schrift und Hintergrund, Vorlagen Rot/Orange/Gelb/Grün/Blau/Grau/Weiß) und eine
eigene **Größe**; ein Feld mit eigenem Hintergrund erscheint als farbige Kachel. Für den ganzen Kasten: Schriftgröße,
Farben, Deckkraft, untereinander oder als Leiste nebeneinander (Text-Felder am Anfang und Ende gehen dann über die
ganze Breite), Monatsschreibweise `nov`/`Nov`/`NOV`. Warnfarben passen sich dem Hintergrund an, damit sie lesbar bleiben.

**Andocken:** am Griff an eine Bildschirmkante ziehen (oder Menü → *Andocken*). Angedockt klappt der Kasten wie das
Mac-Dock zu einer schmalen **Lasche** mit der Uhrzeit ein; Maus darauf klappt ihn aus, 1 s nach dem Verlassen klappt er
wieder ein – beides mit einer kurzen Gleit- und Blendanimation (auch beim Start und bei *Ausblenden*/*Einblenden*).
Die Lasche wird gelb, wenn ein Termin in ≤ 10 min ansteht, und blinkt rot bei „JETZT“.
Unter der Maus ist der Kasten **voll deckend**, sonst gilt die eingestellte Deckkraft.

**Atomuhr:** Die angezeigte Zeit wird beim Start, alle 30 Minuten und nach dem Ruhezustand mit der Atomuhr der PTB
(Braunschweig, gesetzliche Zeit) abgeglichen – per NTP (`ptbtime1–3.ptb.de`, auf Millisekunden genau). Sperrt das Netz
NTP (UDP 123, z. B. in vielen Behörden-WLANs), nimmt die Lageuhr die Zeit aus den Antworten des PTB-Webservers
(mehrere Anfragen, etwa ±0,2 s). Die Rechneruhr wird dabei nicht verstellt (keine Adminrechte nötig); die Lageuhr rechnet
nur die Abweichung heraus. Ohne Internet gilt die Rechnerzeit. Stand und Abweichung: Menü bzw. Einstellungen.

**Lagebild statt Bildschirmschoner** – zwei Wege, gleiche Darstellung (alle sichtbaren Felder groß und mittig, verschiebt
sich jede Minute leicht gegen Einbrennen; immer dunkler Grund mit heller Schrift, farbige Felder behalten ihre Farben):

- **Vollbild-Lagebild:** Menü → *Vollbild-Lagebild jetzt*, oder automatisch nach 2–60 min ohne Eingabe
  (Einstellungen → *Vollbild*; startet rechtzeitig vor dem System-Bildschirmschoner). Maus, Taste oder Klick beendet es.
  **Solange das automatische Vollbild an ist, startet kein Bildschirmschoner und der Rechner sperrt sich nicht von selbst**
  (Bildschirm bleibt an) – für den Lagebildschirm gedacht.
- **Echter Bildschirmschoner:** Menü → *Als Bildschirmschoner einrichten …* – die Sperre bleibt wie eingestellt
  (nach Maus/Taste kommt die Anmeldung). Windows: legt `Lageuhr.scr` neben die `.exe` (sonst `%APPDATA%\Lageuhr`) und
  richtet ihn für das eigene Konto ein; geht nicht, wenn die IT den Bildschirmschoner per Richtlinie festlegt.
  Mac: kopiert `Lageuhr.saver` nach `~/Library/Screen Savers`, danach in den Systemeinstellungen auswählen.
  Der Bildschirmschoner zeigt immer den aktuellen Stand der laufenden Lageuhr (Änderungen nach spätestens 10 s).
  Windows liest ihn aus `%APPDATA%\Lageuhr\lagebild.ini`. Mac: Der Schoner läuft abgeschottet, die App darf nicht in seine
  Ablage schreiben – er fragt die Lageuhr per systemweiter Nachricht nach dem Stand und merkt sich den letzten.
  Ohne Lageuhr (und ohne gemerkten Stand) zeigt er die Uhrzeit.

**Abgleich zwischen Arbeitsplätzen:** Alle Lageuhren mit demselben **Lage-Code** zeigen dieselben Felder – wer an
einem Platz die nächste Lagebesprechung oder den Kat-Fall-Beginn ändert, ändert ihn überall (nach wenigen Sekunden).
Dafür braucht es einmal die kleine Server-Datei `server/lage.php` auf einem Webspace mit HTTPS (Anleitung und Schnittstelle:
`server/PROTOKOLL.md`). In den Einstellungen → *Abgleich*: Server-Adresse eintragen, an einem Platz *Neue Lage* (erzeugt
den Code, z. B. `K7P3-QX9M-2DFH`), an den anderen Plätzen denselben Code eintragen. Je Feld lässt sich wählen, ob es
geteilt wird; Größe, Position und Aussehen des Kastens bleiben je Platz. Bei gleichzeitigen Änderungen gilt die letzte.
Ohne Verbindung läuft alles mit dem letzten Stand weiter, unten im Kasten steht dann „Abgleich getrennt seit …“.

**Updates:** Die Lageuhr schaut beim Start und einmal am Tag auf GitHub nach einer neuen Version (abschaltbar) und zeigt
sie im Menü und in den Einstellungen an. Installiert wird **nur auf Klick** – nie mitten im Einsatz von selbst. Die Lageuhr
ersetzt sich dann an Ort und Stelle (auch auf dem USB-Stick) und startet neu; Felder und Einstellungen bleiben.
Geladen wird nur über HTTPS mit Prüfsumme (Mac zusätzlich Signaturprüfung). Liegt sie in einem schreibgeschützten
Ordner (oder am Mac noch im Download-Ordner), kommt ein Hinweis mit Link zum Herunterladen.

Keine Installation, keine Adminrechte; Internet nur für Atomuhr, Abgleich und Update-Suche (alles abschaltbar).

## Starten

Fertige Dateien: GitHub → *Releases* (`Lageuhr.exe`, `Lageuhr-mac.zip`), oder selbst bauen (siehe unten).

| | Datei | Start |
|---|---|---|
| Windows 10/11 | `dist/windows/Lageuhr.exe` (ca. 100 KB) | Doppelklick. Beim ersten Mal ggf. „Windows hat den PC geschützt“ → *Weitere Informationen* → *Trotzdem ausführen*. |
| macOS 13+ | `dist/mac/Lageuhr-mac.zip` → `Lageuhr.app` | Entpacken, Doppelklick. Auf anderen Macs beim ersten Mal: Rechtsklick → *Öffnen* (bzw. *Systemeinstellungen → Datenschutz & Sicherheit → Dennoch öffnen*). |

Die Einstellungen bleiben erhalten (auch der Kat-Fall-Beginn):
Windows in `Lageuhr.ini` neben der `.exe` (z. B. auf dem USB-Stick; ist der Ordner schreibgeschützt, unter `%APPDATA%\Lageuhr`),
Mac in den Benutzereinstellungen (`local.lageuhr`).

## Bedienung

- **Verschieben:** Maus auf den Kasten → oben links erscheint ein Punktegriff, daran ziehen.
  Woanders auf dem Kasten verschiebt sich nichts versehentlich.
- **Größe:** am Griff unten rechts ziehen, Mausrad/Scrollen über dem Kasten oder in den Einstellungen.
- **Einstellungen:** Doppelklick auf den Kasten.
- **Menü:** Rechtsklick auf den Kasten oder das Uhr-Symbol (Windows: Taskleiste unten rechts, Mac: Menüleiste oben).
  Dort auch schnell für jedes Feld: *… beginnt jetzt* (Seit-Felder), *in 15 min … 4 h* (Termin-Felder), *Position fixieren*,
  *Durchklickbar* (Kasten reagiert nicht mehr auf die Maus, Bedienung dann nur über das Uhr-Symbol), *Ausblenden*, *Beenden*.

## Bauen

```sh
./bauen.sh
```

Braucht das .NET-SDK (baut die Windows-`.exe` für .NET Framework 4.8, das auf jedem Windows 10/11 vorhanden ist),
die Xcode-Befehlszeilenwerkzeuge (Mac-App für Apple Silicon und Intel) und `python3` (Programmsymbol).

- `src/` – Windows (C#, WinForms): `Overlay.cs` Kasten (mit Andocken/Lasche), `Atomuhr.cs` (NTP + Web-Ersatz), `Lagebild.cs` (Layout, Vollbild, Ablage für `Lageuhr.scr`), `EinstellungenFenster.cs`, `Einstellungen.cs` (Felder, INI; liest auch den Aufbau von 1.0), `Zeit.cs`
- `src/Abgleich.cs`, `mac/Abgleich.swift` – Abgleich zwischen Arbeitsplätzen
- `mac/` – Mac (AppKit): `Gemeinsam.swift` (Zeit, Felder, Layout, Vollbild-Ansicht, Ablage), `Lageuhr.swift` (App), `Schoner.swift` (Bildschirmschoner)
- `server/` – `lage.php` (Abgleich-Server, PHP 8.1+, ohne Datenbank) und `PROTOKOLL.md`; Test: `LAGEUHR_DATEN=/tmp/x php -S 127.0.0.1:8471` in `server/`
- Animation in Zeitlupe: `LAGEUHR_ZEITLUPE=10 … --beispiel --dock 2 --animationstest`
- Testbilder vom Mac-Kasten: `Lageuhr.app/Contents/MacOS/Lageuhr --bild bild.png [hell] [leiste] [jetzt]`;
  Atomuhr prüfen: `… --atomuhr [server]` (auch `host:port`, z. B. gegen einen simulierten Zeitserver)

**Neue Version veröffentlichen:** Version in `bauen.sh` und `src/Lageuhr.csproj` erhöhen, in `neu.txt` stichwortartig
schreiben, was neu ist, `./bauen.sh`, dann ein GitHub-Release `v<version>` mit den drei Dateien `dist/windows/Lageuhr.exe`,
`dist/mac/Lageuhr-mac.zip` und `dist/lageuhr-version.txt`. Die Lageuhren lesen
`…/releases/latest/download/lageuhr-version.txt` (Version, SHA-256 der Dateien, `neu …`-Zeilen).
Testen gegen ein simuliertes GitHub: `LAGEUHR_UPDATE_QUELLE=http://127.0.0.1:<port>` (Ordner mit
`releases/latest/download/…` und `releases/download/v<version>/…`, bedient mit `php -S`).

Version: 1.5.0 (in `src/Lageuhr.csproj` und `bauen.sh`).
