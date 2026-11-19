# Abgleich zwischen Arbeitsplätzen

Alle Lageuhren mit demselben **Lage-Code** und derselben **Server-Adresse** zeigen dieselben geteilten Felder.
Der Server ist eine einzelne PHP-Datei (`lage.php`, PHP 8.1+, ohne Datenbank) auf einem Webspace mit HTTPS.

## Server einrichten

1. `lage.php` auf den Webspace hochladen (z. B. in einen eigenen Ordner `lageuhr/`).
2. Die Adresse im Browser öffnen: Es erscheint „Lageuhr-Abgleich ist bereit“.
3. Diese Adresse in der Lageuhr unter Einstellungen → Abgleich eintragen.

Die Daten liegen in `daten/` neben der Datei (legt sie selbst an, mit `.htaccess` gesperrt). Anderer Ort:
`lage.config.php` daneben mit `<?php $daten = '/pfad/ausserhalb/des/webs';`. Lagen ohne Zugriff werden nach 60 Tagen gelöscht.
Der Dateiname ist der SHA-256 des Lage-Codes – wer den Code nicht kennt, findet die Lage nicht.

## Schnittstelle

`POST <adresse>` mit JSON (höchstens 64 KB):

```json
{"v":1, "code":"K7P3-QX9M-2DFH", "stand":12, "arbeitsplatz":"Stab-PC1", "felder":[ <Feld>, … ]}
```

- `code`: Lage-Code; der Server nimmt nur Buchstaben und Ziffern (Groß-/Kleinschreibung egal), mindestens 12.
- `stand`: letzte `rev`, die der Arbeitsplatz kennt (0 = noch nichts).
- `felder`: geänderte geteilte Felder dieses Arbeitsplatzes (auch gelöschte), sonst leer.

Feld:

```json
{"id":"…", "art":"text|uhr|seit|termin", "titel":"…", "text":"…", "zeit":1763300000000,
 "intervall":0, "sekunden":true, "schriftfarbe":"#RRGGBB", "hintergrund":null,
 "geaendert":1763300000000, "von":"Stab-PC1", "geloescht":false}
```

- `id`: 8–64 Zeichen `A-Za-z0-9-` (die Feld-Id der Lageuhr).
- `zeit`, `geaendert`: Millisekunden seit 1970 (UTC). `geaendert` nach der Uhr mit Atomuhr-Abgleich.
- `schriftfarbe`/`hintergrund`: `#RRGGBB` oder `null`.

Der Server übernimmt ein Feld nur, wenn sein `geaendert` neuer ist als der gespeicherte Stand (die letzte Änderung gewinnt),
und gibt ihm die nächste `rev`. Gelöschte Felder bleiben als `"geloescht":true` stehen.

Antwort `200`:

```json
{"v":1, "rev":15, "felder":[ <Feld mit "rev">, … ], "serverzeit":1763300000000, "voll":false}
```

- `felder`: alle Felder mit `rev` > `stand`, aufsteigend (auch die eben gesendeten).
- `voll: true`: Die Antwort enthält die ganze Lage (bei `stand` 0, oder wenn `stand` größer ist als der Server kennt –
  dann ist die Lage auf dem Server neu, z. B. nach dem Aufräumen).

Fehler: `400`/`413`/`500` mit `{"v":1,"fehler":"…"}`. `GET` zeigt nur einen Bereitschaftstext.

## Verhalten der Lageuhr (Windows und Mac gleich)

**Einstellungen:** Abgleich an/aus, Server-Adresse (ohne `https://` davor wird es ergänzt; `http://` nur für
`127.0.0.1`/`localhost`), Lage-Code (Knopf *Neue Lage* erzeugt `XXXX-XXXX-XXXX` aus `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`
und kopiert ihn), Name des Arbeitsplatzes (vorbelegt mit dem Rechnernamen).

**Je Feld:** *Mit anderen Arbeitsplätzen teilen* (neu: an für Text/Seit/Termin, aus für die Uhrzeit). Geteilt werden
Art, Titel, Text, Zeit, Wiederholung, Sekunden, Schrift- und Hintergrundfarbe. **Nur am eigenen Platz:** Größe,
sichtbar, Reihenfolge, alles am ganzen Kasten (Schrift, Deckkraft, Andocken …).

Gemerkt wird je Feld: `geteilt`, `geaendert`, `von`, `bekannt` (Signatur der geteilten Werte beim letzten Senden/Empfangen);
für die Lage: `stand` und die Ids der geteilten Felder (um Löschen zu erkennen).

**Ablauf** (alle 3 s; nach einer eigenen Änderung nach 0,3 s; nie zwei Anfragen gleichzeitig; 10 s Zeitüberschreitung):

1. **Beitreten** (`stand` = 0, z. B. neuer Code): erst ohne Felder fragen. Hat die Lage Felder (nicht gelöscht), werden
   eigene geteilte Felder, die dort nicht vorkommen, auf *nicht geteilt* und *ausgeblendet* gesetzt (bleiben in den
   Einstellungen, nichts doppelt). Ist die Lage leer, gehen die eigenen geteilten Felder in der nächsten Runde hinaus
   (so legt man eine Lage an).
2. **Senden:** Geteiltes Feld, dessen Signatur von `bekannt` abweicht → `geaendert` = jetzt, `von` = Arbeitsplatz,
   `bekannt` = Signatur, senden. Fehlt eine früher geteilte Id in der Feldliste → als gelöscht senden.
   Teilen ausschalten löscht nicht bei den anderen. Was nicht ankam (Fehler), geht in der nächsten Runde noch einmal.
3. **Empfangen:** Für jedes Feld der Antwort: Gibt es die Id, und ist das Empfangene neuer als der eigene `geaendert`,
   werden die geteilten Werte übernommen (`bekannt` = neue Signatur); gelöscht → Feld entfernen. Unbekannte Id →
   Feld hinten anfügen (geteilt, sichtbar, Größe 100). Danach `stand` = `rev`. Bei `voll` mit eigenem `stand` > 0
   (Lage auf dem Server neu) gehen alle eigenen geteilten Felder noch einmal hinaus.
4. **Wiederkehrende Termine** schaltet jeder Platz selbst weiter; das gilt nicht als Änderung (`bekannt` mitziehen).

**Anzeige:** Menü zeigt den Zustand („Abgleich: verbunden · Lage K7P3-…“ bzw. „getrennt seit 1432“) und *Jetzt abgleichen*.
Ist der Abgleich an und länger als 30 s keine Verbindung, steht unten im Kasten klein in Warnfarbe
„Abgleich getrennt seit 1432“. In den Einstellungen steht beim Feld „zuletzt geändert von PC2 um 161432nov26“.
Der Bildschirmschoner zeigt einfach die Felder wie bisher.
