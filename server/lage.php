<?php
// Lageuhr – Abgleich zwischen Arbeitsplätzen. Eine Datei, ohne Datenbank, PHP 8.1+.
// Hochladen auf einen Webspace mit HTTPS, die Adresse dieser Datei in der Lageuhr eintragen.
// Protokoll: PROTOKOLL.md. Daten liegen je Lage als JSON in daten/ (Name = SHA-256 des Lage-Codes).
declare(strict_types=1);

const VERSION = 1;
const MAX_FELDER = 60;
const MAX_TEXT = 2000;
const MAX_ANFRAGE = 65536;
const AUFRAEUMEN_TAGE = 60;   // Lagen ohne Zugriff so lange aufheben

$daten = getenv('LAGEUHR_DATEN') ?: __DIR__ . '/daten';
if (is_file(__DIR__ . '/lage.config.php')) include __DIR__ . '/lage.config.php'; // darf $daten setzen

header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function antwort(int $status, array $inhalt): never {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($inhalt, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
function fehler(int $status, string $text): never { antwort($status, ['v' => VERSION, 'fehler' => $text]); }
function jetzt_ms(): int { return (int) floor(microtime(true) * 1000); }

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    header('Content-Type: text/plain; charset=utf-8');
    echo "Lageuhr-Abgleich ist bereit. Diese Adresse in der Lageuhr unter Einstellungen → Abgleich eintragen.\n";
    exit;
}

$roh = file_get_contents('php://input', false, null, 0, MAX_ANFRAGE + 1);
if ($roh === false || strlen($roh) > MAX_ANFRAGE) fehler(413, 'Anfrage zu groß');
$a = json_decode($roh, true);
if (!is_array($a)) fehler(400, 'Anfrage ist kein JSON');

$code = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', (string) ($a['code'] ?? '')));
if (strlen($code) < 12 || strlen($code) > 40) fehler(400, 'Lage-Code ungültig (mindestens 12 Buchstaben/Ziffern)');
$stand = max(0, (int) ($a['stand'] ?? 0));
$platz = mb_substr(trim((string) ($a['arbeitsplatz'] ?? '')), 0, 60);

/** Feld aus der Anfrage prüfen und auf die bekannten Werte beschränken. */
function feld_pruefen(mixed $f, string $platz): ?array {
    if (!is_array($f)) return null;
    $id = (string) ($f['id'] ?? '');
    if (!preg_match('/^[A-Za-z0-9-]{8,64}$/', $id)) return null;
    $art = (string) ($f['art'] ?? '');
    if (!in_array($art, ['text', 'uhr', 'seit', 'termin'], true)) return null;
    $farbe = fn($w) => is_string($w) && preg_match('/^#[0-9A-Fa-f]{6}$/', $w) ? strtoupper($w) : null;
    $zeit = $f['zeit'] ?? null;
    return [
        'id' => $id,
        'art' => $art,
        'titel' => mb_substr((string) ($f['titel'] ?? ''), 0, 200),
        'text' => mb_substr((string) ($f['text'] ?? ''), 0, MAX_TEXT),
        'zeit' => is_numeric($zeit) ? (int) $zeit : null,
        'intervall' => max(0, min(10080, (int) ($f['intervall'] ?? 0))),
        'sekunden' => (bool) ($f['sekunden'] ?? true),
        'schriftfarbe' => $farbe($f['schriftfarbe'] ?? null),
        'hintergrund' => $farbe($f['hintergrund'] ?? null),
        'geaendert' => max(0, (int) ($f['geaendert'] ?? 0)),
        'von' => mb_substr((string) ($f['von'] ?? $platz), 0, 60),
        'geloescht' => (bool) ($f['geloescht'] ?? false),
    ];
}

if (!is_dir($daten) && !@mkdir($daten, 0700, true)) fehler(500, 'Datenordner fehlt');
if (!is_file("$daten/.htaccess")) @file_put_contents("$daten/.htaccess", "Require all denied\nDeny from all\n");

$datei = "$daten/" . hash('sha256', 'lageuhr|' . $code) . '.json';
$h = fopen($datei, 'c+');
if (!$h || !flock($h, LOCK_EX)) fehler(500, 'Lage nicht lesbar');
$inhalt = stream_get_contents($h);
$lage = $inhalt ? json_decode($inhalt, true) : null;
if (!is_array($lage)) $lage = ['rev' => 0, 'felder' => []];

$geaendert = false;
$eingang = is_array($a['felder'] ?? null) ? $a['felder'] : [];
foreach (array_slice($eingang, 0, MAX_FELDER) as $roh_feld) {
    $f = feld_pruefen($roh_feld, $platz);
    if (!$f) continue;
    $alt = $lage['felder'][$f['id']] ?? null;
    if ($alt && $alt['geaendert'] >= $f['geaendert']) continue;   // vorhandener Stand ist neuer: gilt
    if (!$alt && count($lage['felder']) >= MAX_FELDER * 2) continue;
    $f['rev'] = ++$lage['rev'];
    $lage['felder'][$f['id']] = $f;
    $geaendert = true;
}

if ($geaendert) {
    ftruncate($h, 0);
    rewind($h);
    fwrite($h, json_encode($lage, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    fflush($h);
} else {
    @touch($datei); // Zugriff merken (fürs Aufräumen)
}
flock($h, LOCK_UN);
fclose($h);

// Gelegentlich alte Lagen löschen
if (random_int(1, 200) === 1) {
    foreach (glob("$daten/*.json") ?: [] as $d) {
        if (filemtime($d) < time() - AUFRAEUMEN_TAGE * 86400) @unlink($d);
    }
}

// Stand 0 = alles; ist der Stand des Arbeitsplatzes neuer als der Server (Lage neu angelegt), auch alles
$ab = $stand > $lage['rev'] ? 0 : $stand;
$neu = array_values(array_filter($lage['felder'], fn($f) => $f['rev'] > $ab));
usort($neu, fn($x, $y) => $x['rev'] <=> $y['rev']);
antwort(200, ['v' => VERSION, 'rev' => $lage['rev'], 'felder' => $neu, 'serverzeit' => jetzt_ms(), 'voll' => $ab === 0]);
