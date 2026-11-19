using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace Lageuhr
{
    /// <summary>Was nach einer Abgleich-Runde zu tun ist.</summary>
    public enum AbgleichFolge { Nichts, Speichern, Neuzeichnen }

    /// <summary>
    /// Abgleich der geteilten Felder zwischen Arbeitsplätzen über lage.php (Protokoll: server/PROTOKOLL.md).
    /// Ohne WinForms: Vorbereiten und Anwenden laufen auf dem UI-Thread, nur die Übertragung im Hintergrund.
    /// </summary>
    public class Abgleich
    {
        public const int TaktMs = 3000, BaldMs = 300, ZeitlimitMs = 10000, WarnungNachMs = 30000;
        const int MaxFelderJeAnfrage = 50, MaxBytes = 60000;
        const string CodeZeichen = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";

        /// <summary>Uhr für „geaendert“: Millisekunden seit 1970 (UTC), mit Atomuhr-Abgleich. Zum Testen austauschbar.</summary>
        public Func<long> UhrMs = () => DateTimeOffset.UtcNow.AddSeconds(Zeit.Versatz).ToUnixTimeMilliseconds();

        /// <summary>Netzzugriff: Adresse und JSON hin, JSON zurück; wirft bei Fehlern. Zum Testen austauschbar.</summary>
        public Func<string, string, string> Senden = Uebertragen;

        public bool Laeuft { get; private set; }
        public bool Verbunden { get; private set; }
        public string Fehler { get; private set; }
        /// <summary>Anzahl der Felder (auch gelöschte) in der letzten Anfrage – für Tests und Fehlersuche.</summary>
        public int LetzteAnzahl { get; private set; }

        long? getrenntSeit, letzterErfolg;
        DateTime naechsterLauf = DateTime.MinValue;
        bool baldNachLauf;
        string statusSchluessel;   // Lage, auf die sich der Zustand bezieht
        string beigetreten;        // Lage, der dieser Platz in dieser Sitzung beigetreten ist
        readonly Dictionary<string, long> loeschStempel = new Dictionary<string, long>();

        /// <summary>Eine Anfrage mit allem, was zum Anwenden der Antwort nötig ist.</summary>
        public class Anfrage
        {
            public string Adresse, Schluessel, Json;
            public long Stand, Zeit;
            public bool Beitreten, Mehr;
            public readonly Dictionary<string, string> Gesendet = new Dictionary<string, string>(); // Id → Signatur
            public readonly List<string> Geloescht = new List<string>();
        }

        class Empfangen
        {
            public string Id, Titel, Text, Von;
            public FeldArt Art;
            public DateTime? Zeit;
            public int Intervall;
            public bool Sekunden, Geloescht;
            public Color? Schriftfarbe, Hintergrund;
            public long Geaendert;
        }

        // ---------- Einstellungen prüfen ----------

        /// <summary>Server-Adresse mit https:// (ergänzt, wenn es fehlt); http:// nur für den eigenen Rechner. Sonst null.</summary>
        public static string AdresseNormal(string a)
        {
            if (string.IsNullOrWhiteSpace(a)) return null;
            a = a.Trim();
            if (a.IndexOf("://", StringComparison.Ordinal) < 0) a = "https://" + a;
            if (!Uri.TryCreate(a, UriKind.Absolute, out var u) || string.IsNullOrEmpty(u.Host)) return null;
            if (u.Scheme == Uri.UriSchemeHttps) return u.AbsoluteUri;
            if (u.Scheme == Uri.UriSchemeHttp && (u.Host == "127.0.0.1" || u.Host == "localhost" || u.Host == "[::1]")) return u.AbsoluteUri;
            return null;
        }

        /// <summary>Lage-Code wie der Server ihn sieht: nur Buchstaben und Ziffern, groß.</summary>
        public static string CodeSchluessel(string code) =>
            new string((code ?? "").Where(c => c < 128 && char.IsLetterOrDigit(c)).ToArray()).ToUpperInvariant();

        public static bool CodeGueltig(string code)
        {
            int n = CodeSchluessel(code).Length;
            return n >= 12 && n <= 40;
        }

        public static bool Eingerichtet(Einstellungen e) =>
            e.AbgleichAn && AdresseNormal(e.AbgleichServer) != null && CodeGueltig(e.LageCode);

        /// <summary>Kennzeichen der Lage (Adresse und Code) – ändert es sich, beginnt der Platz neu (Stand 0).</summary>
        public static string Schluessel(Einstellungen e) => AdresseNormal(e.AbgleichServer) + "|" + CodeSchluessel(e.LageCode);

        /// <summary>Neuer Lage-Code XXXX-XXXX-XXXX mit kryptografischem Zufall.</summary>
        public static string NeuerCode()
        {
            var b = new byte[12];
            using (var r = RandomNumberGenerator.Create()) r.GetBytes(b);
            var sb = new StringBuilder();
            for (int i = 0; i < b.Length; i++)
            {
                if (i > 0 && i % 4 == 0) sb.Append('-');
                sb.Append(CodeZeichen[b[i] & 31]); // 256 ist durch 32 teilbar: gleich verteilt
            }
            return sb.ToString();
        }

        static string Platz(Einstellungen e)
        {
            string p = string.IsNullOrWhiteSpace(e.Arbeitsplatz) ? Environment.MachineName : e.Arbeitsplatz.Trim();
            return p.Length > 60 ? p.Substring(0, 60) : p;
        }

        static string CodeKurz(string code)
        {
            string k = CodeSchluessel(code);
            return (k.Length > 4 ? k.Substring(0, 4) : k) + "-…";
        }

        // ---------- Werte eines Feldes ----------

        static readonly DateTime Epoche = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        /// <summary>Lokale Zeit (wie in den Einstellungen) → Millisekunden seit 1970 (UTC).</summary>
        public static long? ZeitMs(DateTime? z) =>
            z is DateTime d ? (long)Math.Round((DateTime.SpecifyKind(d, DateTimeKind.Local).ToUniversalTime() - Epoche).TotalMilliseconds) : (long?)null;

        /// <summary>Millisekunden seit 1970 (UTC) → lokale Zeit, auf ganze Sekunden.</summary>
        public static DateTime? ZeitAusMs(long? ms)
        {
            if (!(ms is long m)) return null;
            var d = Epoche.AddMilliseconds(m).ToLocalTime();
            return new DateTime(d.Ticks - d.Ticks % TimeSpan.TicksPerSecond, DateTimeKind.Unspecified);
        }

        static string Art(FeldArt a) => a == FeldArt.Uhr ? "uhr" : a == FeldArt.Seit ? "seit" : a == FeldArt.Termin ? "termin" : "text";

        static FeldArt? ArtAus(string s) =>
            s == "text" ? FeldArt.Text : s == "uhr" ? FeldArt.Uhr : s == "seit" ? FeldArt.Seit : s == "termin" ? FeldArt.Termin : (FeldArt?)null;

        static string Hex(Color? c) => c.HasValue ? Einstellungen.Hex(c.Value) : null;

        static Color? FarbeAus(string s)
        {
            if (s == null || !Regex.IsMatch(s, "^#[0-9A-Fa-f]{6}$")) return null;
            int v = int.Parse(s.Substring(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            return Color.FromArgb(255, (v >> 16) & 255, (v >> 8) & 255, v & 255);
        }

        static string Zeilen(string t) => (t ?? "").Replace("\r\n", "\n").Replace("\r", "\n");

        /// <summary>Signatur der geteilten Werte (Art, Titel, Text, Zeit, Wiederholung, Sekunden, Farben).</summary>
        public static string Signatur(Feld f)
        {
            string s = string.Join("\u001f", Art(f.Art), f.Titel ?? "", Zeilen(f.Text),
                ZeitMs(f.Zeit)?.ToString(CultureInfo.InvariantCulture) ?? "-", f.Intervall.ToString(CultureInfo.InvariantCulture),
                f.Sekunden ? "1" : "0", Hex(f.Schriftfarbe) ?? "-", Hex(f.Hintergrund) ?? "-");
            using (var h = SHA256.Create())
            {
                var b = h.ComputeHash(Encoding.UTF8.GetBytes(s));
                var sb = new StringBuilder();
                for (int i = 0; i < 16; i++) sb.Append(b[i].ToString("x2"));
                return sb.ToString();
            }
        }

        static void WerteUebernehmen(Feld f, Empfangen r)
        {
            f.Art = r.Art; f.Titel = r.Titel; f.Text = Zeilen(r.Text).Replace("\n", "\r\n"); f.Zeit = r.Zeit;
            f.Intervall = r.Intervall; f.Sekunden = r.Sekunden; f.Schriftfarbe = r.Schriftfarbe; f.Hintergrund = r.Hintergrund;
        }

        static void WerteUebernehmen(Feld f, Feld von)
        {
            f.Art = von.Art; f.Titel = von.Titel; f.Text = von.Text; f.Zeit = von.Zeit;
            f.Intervall = von.Intervall; f.Sekunden = von.Sekunden; f.Schriftfarbe = von.Schriftfarbe; f.Hintergrund = von.Hintergrund;
        }

        static string Kuerzen(string s, int n) => s == null ? "" : s.Length > n ? s.Substring(0, n) : s;

        static string FeldJson(Feld f)
        {
            var j = new JsonSchreiber();
            j.Wert("id", f.Id).Wert("art", Art(f.Art)).Wert("titel", Kuerzen(f.Titel, 200)).Wert("text", Kuerzen(Zeilen(f.Text), 2000))
             .Zahl("zeit", ZeitMs(f.Zeit)).Zahl("intervall", Math.Max(0, Math.Min(10080, f.Intervall))).Wahr("sekunden", f.Sekunden)
             .Wert("schriftfarbe", Hex(f.Schriftfarbe)).Wert("hintergrund", Hex(f.Hintergrund))
             .Zahl("geaendert", f.Geaendert).Wert("von", f.Von).Wahr("geloescht", false);
            return j.Ende();
        }

        static string LoeschJson(string id, long geaendert, string von)
        {
            var j = new JsonSchreiber();
            j.Wert("id", id).Wert("art", "text").Wert("titel", "").Wert("text", "").Zahl("zeit", null).Zahl("intervall", 0)
             .Wahr("sekunden", true).Wert("schriftfarbe", null).Wert("hintergrund", null)
             .Zahl("geaendert", geaendert).Wert("von", von).Wahr("geloescht", true);
            return j.Ende();
        }

        // ---------- Ablauf ----------

        /// <summary>Im Takt fragen: Ist eine Runde fällig?</summary>
        public bool Faellig(Einstellungen e)
        {
            if (!Eingerichtet(e)) { if (statusSchluessel != null) StatusZuruecksetzen(null); return false; }
            return !Laeuft && DateTime.UtcNow >= naechsterLauf;
        }

        /// <summary>Nach einer eigenen Änderung: bald abgleichen (0,3 s).</summary>
        public void Bald()
        {
            if (Laeuft) { baldNachLauf = true; return; }
            var t = DateTime.UtcNow.AddMilliseconds(BaldMs);
            if (t < naechsterLauf) naechsterLauf = t;
        }

        /// <summary>„Jetzt abgleichen“: im nächsten Takt.</summary>
        public void Sofort()
        {
            if (Laeuft) baldNachLauf = true; else naechsterLauf = DateTime.MinValue;
        }

        void StatusZuruecksetzen(string schluessel)
        {
            statusSchluessel = schluessel;
            Verbunden = false; Fehler = null; getrenntSeit = null; letzterErfolg = null;
            loeschStempel.Clear();
        }

        /// <summary>Eine Runde vorbereiten: geänderte geteilte Felder stempeln und die Anfrage bauen (null = nichts zu tun).</summary>
        public Anfrage Vorbereiten(Einstellungen e)
        {
            if (!Eingerichtet(e)) { StatusZuruecksetzen(null); return null; }
            string schluessel = Schluessel(e);
            if (schluessel != statusSchluessel) StatusZuruecksetzen(schluessel);
            long jetzt = UhrMs();
            if (getrenntSeit == null && !Verbunden) getrenntSeit = jetzt;

            var a = new Anfrage
            {
                Adresse = AdresseNormal(e.AbgleichServer), Schluessel = schluessel, Stand = e.LageStand, Zeit = jetzt,
                Beitreten = e.LageStand == 0 && beigetreten != schluessel,
            };
            string platz = Platz(e);
            var felder = new List<string>();
            int bytes = 300;
            if (!a.Beitreten) // beim Beitreten erst nur fragen
            {
                foreach (var f in e.Felder.Where(x => x.Geteilt))
                {
                    string sig = Signatur(f);
                    if (sig == f.Bekannt || a.Gesendet.ContainsKey(f.Id)) continue;
                    if (felder.Count >= MaxFelderJeAnfrage) { a.Mehr = true; break; }
                    if (f.Gestempelt != sig) // neue Änderung: Zeit und Platz merken (bei Wiederholung bleibt der Stempel)
                    {
                        f.Geaendert = Math.Max(jetzt, f.Geaendert + 1);
                        f.Von = platz;
                        f.Gestempelt = sig;
                    }
                    string j = FeldJson(f);
                    int n = Encoding.UTF8.GetByteCount(j) + 1;
                    if (bytes + n > MaxBytes && felder.Count > 0) { a.Mehr = true; break; }
                    bytes += n;
                    felder.Add(j);
                    a.Gesendet[f.Id] = sig;
                }
                var vorhanden = new HashSet<string>(e.Felder.Select(f => f.Id));
                foreach (var id in e.LageIds.Where(i => !vorhanden.Contains(i)).Distinct().ToList())
                {
                    if (felder.Count >= MaxFelderJeAnfrage) { a.Mehr = true; break; }
                    if (!loeschStempel.TryGetValue(id, out long t)) loeschStempel[id] = t = jetzt;
                    felder.Add(LoeschJson(id, t, platz));
                    a.Geloescht.Add(id);
                }
            }
            LetzteAnzahl = felder.Count;
            var w = new JsonSchreiber();
            w.Zahl("v", 1).Wert("code", e.LageCode.Trim()).Zahl("stand", a.Stand).Wert("arbeitsplatz", platz).Roh("felder", "[" + string.Join(",", felder) + "]");
            a.Json = w.Ende();
            return a;
        }

        /// <summary>Eine Runde ohne Hintergrund-Thread (für Tests).</summary>
        public AbgleichFolge Runde(Einstellungen e)
        {
            var a = Vorbereiten(e);
            if (a == null) return AbgleichFolge.Nichts;
            Laeuft = true;
            string antwort = null; Exception fehler = null;
            try { antwort = Senden(a.Adresse, a.Json); } catch (Exception ex) { fehler = ex; }
            return Abschliessen(e, a, antwort, fehler);
        }

        /// <summary>
        /// Eine Runde im Hintergrund. <paramref name="aufUi"/> bringt das Ergebnis auf den UI-Thread; dort wird es auf
        /// <paramref name="aktuell"/>() angewendet (die Einstellungen können inzwischen ersetzt sein).
        /// </summary>
        public bool Starten(Einstellungen e, Action<Action> aufUi, Func<Einstellungen> aktuell, Action<AbgleichFolge> fertig)
        {
            var a = Vorbereiten(e);
            if (a == null) return false;
            Laeuft = true;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                string antwort = null; Exception fehler = null;
                try { antwort = Senden(a.Adresse, a.Json); } catch (Exception ex) { fehler = ex; }
                try { aufUi(() => fertig(Abschliessen(aktuell(), a, antwort, fehler))); }
                catch { Laeuft = false; } // Fenster schon zu
            });
            return true;
        }

        AbgleichFolge Abschliessen(Einstellungen e, Anfrage a, string antwort, Exception fehler)
        {
            Laeuft = false;
            var folge = AbgleichFolge.Nichts;
            bool bald = baldNachLauf || a.Mehr;
            baldNachLauf = false;
            if (Schluessel(e) != a.Schluessel || e.LageStand != a.Stand)
                bald = true; // inzwischen andere Lage eingestellt: Antwort verwerfen
            else if (fehler == null)
            {
                try
                {
                    folge = Anwenden(e, a, antwort, out bool nochmal);
                    bald |= nochmal;
                }
                catch (Exception ex) { fehler = ex; }
            }
            if (fehler != null && Schluessel(e) == a.Schluessel)
            {
                Verbunden = false;
                Fehler = FehlerText(fehler);
                if (getrenntSeit == null) getrenntSeit = a.Zeit;
            }
            naechsterLauf = DateTime.UtcNow.AddMilliseconds(bald ? BaldMs : TaktMs);
            return folge;
        }

        AbgleichFolge Anwenden(Einstellungen e, Anfrage a, string antwort, out bool nochmal)
        {
            nochmal = false;
            // erst alles lesen, dann ändern (eine unverständliche Antwort ändert nichts)
            var o = JsonLeser.Lesen(antwort) as Dictionary<string, object>;
            if (o == null) throw new FormatException("Antwort des Servers ist unverständlich");
            if (o.TryGetValue("fehler", out var fe) && fe is string ft) throw new InvalidOperationException("Server meldet: " + ft);
            if (!o.TryGetValue("rev", out var rv) || !(rv is long rev)) throw new FormatException("Antwort des Servers ist unverständlich");
            bool voll = o.TryGetValue("voll", out var vo) && vo is bool vb && vb;
            var empfangen = new List<Empfangen>();
            if (o.TryGetValue("felder", out var fl) && fl is List<object> liste)
                foreach (var x in liste)
                    if (x is Dictionary<string, object> d && Lesen(d) is Empfangen r) empfangen.Add(r);

            bool felderGeaendert = false, speichern = a.Gesendet.Count > 0 || a.Geloescht.Count > 0 || e.LageStand != rev;
            var nachId = new Dictionary<string, Feld>();
            foreach (var f in e.Felder) if (!nachId.ContainsKey(f.Id)) nachId[f.Id] = f;

            if (a.Beitreten)
            {
                beigetreten = a.Schluessel;
                e.LageIds.Clear();
                var dort = new HashSet<string>(empfangen.Where(r => !r.Geloescht).Select(r => r.Id));
                if (dort.Count > 0)
                {
                    // Lage hat schon Felder: eigene geteilte, die dort fehlen, nur noch hier und ausgeblendet
                    foreach (var f in e.Felder.Where(f => f.Geteilt && !dort.Contains(f.Id)))
                    {
                        f.Geteilt = false; f.Sichtbar = false; f.Bekannt = null; f.Gestempelt = null;
                        felderGeaendert = true;
                    }
                }
                else
                {
                    // Lage ist leer: eigene geteilte Felder gehen in der nächsten Runde hinaus (so legt man eine Lage an)
                    foreach (var f in e.Felder.Where(f => f.Geteilt)) { f.Bekannt = null; f.Gestempelt = null; }
                    nochmal = true;
                }
            }

            var ausstehendGeloescht = new HashSet<string>(e.LageIds.Where(i => !nachId.ContainsKey(i)).Except(a.Geloescht));
            foreach (var r in empfangen)
            {
                nachId.TryGetValue(r.Id, out var f);
                if (r.Geloescht)
                {
                    if (f != null && f.Geteilt && r.Geaendert > f.Geaendert)
                    {
                        e.Felder.Remove(f);
                        nachId.Remove(r.Id);
                        felderGeaendert = true;
                    }
                    if (f == null || !f.Geteilt || r.Geaendert > f.Geaendert) e.LageIds.Remove(r.Id);
                    continue;
                }
                if (f == null)
                {
                    if (ausstehendGeloescht.Contains(r.Id)) continue; // hier gelöscht, geht gleich hinaus
                    f = new Feld { Id = r.Id, Geteilt = true, Sichtbar = true, Groesse = 100 };
                    WerteUebernehmen(f, r);
                    f.Geaendert = r.Geaendert; f.Von = r.Von; f.Bekannt = Signatur(f);
                    e.Felder.Add(f);
                    nachId[f.Id] = f;
                    felderGeaendert = true;
                }
                else if (f.Geteilt && r.Geaendert > f.Geaendert)
                {
                    string vorher = Signatur(f);
                    WerteUebernehmen(f, r);
                    f.Geaendert = r.Geaendert; f.Von = r.Von;
                    f.Bekannt = Signatur(f); f.Gestempelt = null;
                    if (f.Bekannt != vorher) felderGeaendert = true;
                }
            }

            // Gesendetes gilt als bekannt, solange es inzwischen nicht anders geändert wurde
            foreach (var g in a.Gesendet)
                if (nachId.TryGetValue(g.Key, out var f) && f.Geteilt && Signatur(f) == g.Value)
                {
                    f.Bekannt = g.Value; f.Gestempelt = null;
                }
            foreach (var id in a.Geloescht)
                if (!nachId.ContainsKey(id)) { e.LageIds.Remove(id); loeschStempel.Remove(id); }

            if (voll && a.Stand > 0)
            {
                // Lage auf dem Server neu (z. B. aufgeräumt): alle eigenen geteilten Felder noch einmal hinaus
                foreach (var f in e.Felder.Where(f => f.Geteilt)) { f.Bekannt = null; f.Gestempelt = null; }
                nochmal = true;
            }

            // Ids der geteilten Felder merken (um Löschen zu erkennen); nicht mehr geteilte fallen heraus, ohne zu löschen
            var ids = new List<string>(e.LageIds.Where(i => !nachId.ContainsKey(i)));
            ids.AddRange(e.Felder.Where(f => f.Geteilt && f.Bekannt != null).Select(f => f.Id));
            e.LageIds = ids.Distinct().ToList();
            e.LageStand = rev;

            Verbunden = true; Fehler = null; getrenntSeit = null; letzterErfolg = UhrMs();
            return felderGeaendert ? AbgleichFolge.Neuzeichnen : speichern ? AbgleichFolge.Speichern : AbgleichFolge.Nichts;
        }

        static Empfangen Lesen(Dictionary<string, object> d)
        {
            string S(string k) => d.TryGetValue(k, out var v) && v is string s ? s : null;
            long? L(string k) => d.TryGetValue(k, out var v) ? v is long l ? l : v is double x ? (long)x : (long?)null : null;
            bool B(string k, bool std) => d.TryGetValue(k, out var v) && v is bool b ? b : std;
            string id = S("id");
            if (id == null || !Feld.IdGueltig(id)) return null;
            bool geloescht = B("geloescht", false);
            var art = ArtAus(S("art"));
            if (art == null && !geloescht) return null;
            return new Empfangen
            {
                Id = id, Art = art ?? FeldArt.Text, Titel = S("titel") ?? "", Text = S("text") ?? "", Zeit = ZeitAusMs(L("zeit")),
                Intervall = (int)Math.Max(0, Math.Min(10080, L("intervall") ?? 0)), Sekunden = B("sekunden", true),
                Schriftfarbe = FarbeAus(S("schriftfarbe")), Hintergrund = FarbeAus(S("hintergrund")),
                Geaendert = L("geaendert") ?? 0, Von = S("von") ?? "", Geloescht = geloescht,
            };
        }

        // ---------- Wiederkehrende Termine ----------

        public const int NachlaufMinuten = 5;

        /// <summary>
        /// Wiederkehrende Termine 5 Minuten nach Beginn auf den nächsten springen lassen. Das macht jeder Platz selbst;
        /// es gilt nicht als Änderung, darum wird die bekannte Signatur mitgezogen.
        /// </summary>
        public static bool TermineWeiterschalten(Einstellungen e, DateTime jetzt)
        {
            bool weiter = false;
            foreach (var f in e.Felder)
            {
                if (f.Art != FeldArt.Termin || f.Intervall <= 0 || !(f.Zeit is DateTime t) || jetzt < t.AddMinutes(NachlaufMinuten)) continue;
                bool abgeglichen = f.Bekannt != null && f.Bekannt == Signatur(f);
                while (jetzt >= t.AddMinutes(NachlaufMinuten)) t = t.AddMinutes(f.Intervall);
                f.Zeit = t;
                if (abgeglichen) f.Bekannt = Signatur(f);
                weiter = true;
            }
            return weiter;
        }

        // ---------- Einstellungen-Fenster übernehmen ----------

        /// <summary>
        /// Ergebnis des Einstellungen-Fensters mit dem zusammenführen, was inzwischen kam (Abgleich, Menü).
        /// <paramref name="basis"/> ist der Stand beim Öffnen: Was im Fenster nicht geändert wurde, kommt aus <paramref name="aktuell"/>.
        /// </summary>
        public static Einstellungen Zusammenfuehren(Einstellungen aktuell, Einstellungen basis, Einstellungen neu)
        {
            var n = neu.Kopie();
            if (basis == null) return n;
            var akt = new Dictionary<string, Feld>();
            foreach (var f in aktuell.Felder) if (!akt.ContainsKey(f.Id)) akt[f.Id] = f;
            var bas = new Dictionary<string, Feld>();
            foreach (var f in basis.Felder) if (!bas.ContainsKey(f.Id)) bas[f.Id] = f;

            var felder = new List<Feld>();
            foreach (var f in n.Felder)
            {
                if (!bas.TryGetValue(f.Id, out var b)) { felder.Add(f); continue; } // im Fenster neu angelegt
                bool unveraendert = Signatur(f) == Signatur(b);
                if (!akt.TryGetValue(f.Id, out var a))
                {
                    if (!unveraendert) felder.Add(f); // inzwischen anderswo gelöscht; hier geändert: bleibt
                    continue;
                }
                if (unveraendert) WerteUebernehmen(f, a);
                f.Geaendert = a.Geaendert; f.Von = a.Von; f.Bekannt = a.Bekannt; f.Gestempelt = a.Gestempelt;
                bool geteiltNeu = f.Geteilt && !b.Geteilt;
                if (f.Geteilt == b.Geteilt) f.Geteilt = a.Geteilt;
                if (f.Sichtbar == b.Sichtbar) f.Sichtbar = a.Sichtbar;
                if (f.Groesse == b.Groesse) f.Groesse = a.Groesse;
                if (geteiltNeu) { f.Bekannt = null; f.Gestempelt = null; } // wieder geteilt: noch einmal hinaus
                felder.Add(f);
            }
            var ids = new HashSet<string>(felder.Select(f => f.Id));
            foreach (var a in aktuell.Felder)
                if (!bas.ContainsKey(a.Id) && !ids.Contains(a.Id)) felder.Add(a.Kopie()); // inzwischen angekommen
            n.Felder = felder;

            if (Schluessel(n) == Schluessel(aktuell))
            {
                n.LageStand = aktuell.LageStand;
                n.LageIds = new List<string>(aktuell.LageIds);
            }
            else
            {
                n.LageStand = 0; // andere Lage: neu beitreten
                n.LageIds = new List<string>();
            }
            return n;
        }

        // ---------- Anzeige ----------

        string Uhrzeit(long ms, string format) =>
            Epoche.AddMilliseconds(ms).ToLocalTime().ToString(format, CultureInfo.InvariantCulture);

        /// <summary>Kurz für Menü: „Abgleich: verbunden · Lage K7P3-…“ bzw. „Abgleich: getrennt seit 1432“.</summary>
        public string Status(Einstellungen e)
        {
            if (!e.AbgleichAn) return "Abgleich ist aus";
            if (AdresseNormal(e.AbgleichServer) == null)
                return string.IsNullOrWhiteSpace(e.AbgleichServer) ? "Abgleich: Server-Adresse fehlt" : "Abgleich: Server-Adresse ungültig (https:// nötig)";
            if (!CodeGueltig(e.LageCode)) return "Abgleich: Lage-Code fehlt";
            if (Schluessel(e) != statusSchluessel) return "Abgleich: verbinde …";
            if (Verbunden) return "Abgleich: verbunden · Lage " + CodeKurz(e.LageCode);
            if (Fehler == null || getrenntSeit == null) return "Abgleich: verbinde …";
            return "Abgleich: getrennt seit " + Uhrzeit(getrenntSeit.Value, "HHmm");
        }

        /// <summary>Ausführlich für das Einstellungen-Fenster (mit Fehler bzw. letzter Verbindung).</summary>
        public string StatusLang(Einstellungen e)
        {
            string s = Status(e);
            if (!Eingerichtet(e) || Schluessel(e) != statusSchluessel) return s;
            if (Verbunden && letzterErfolg is long l) return s + " · zuletzt " + Uhrzeit(l, "HH:mm:ss");
            if (Fehler != null) return s + " – " + Fehler;
            return s;
        }

        /// <summary>Hinweis für den Kasten, wenn der Abgleich an ist und länger als 30 s keine Verbindung besteht; sonst null.</summary>
        public string Warnung(Einstellungen e)
        {
            if (!Eingerichtet(e) || Schluessel(e) != statusSchluessel || Verbunden || !(getrenntSeit is long g)) return null;
            if (UhrMs() - g <= WarnungNachMs) return null;
            return "Abgleich getrennt seit " + Uhrzeit(g, "HHmm");
        }

        static string FehlerText(Exception ex)
        {
            if (ex is WebException w)
            {
                switch (w.Status)
                {
                    case WebExceptionStatus.Timeout: return "keine Antwort vom Server (Zeitüberschreitung)";
                    case WebExceptionStatus.NameResolutionFailure: return "Server nicht gefunden";
                    case WebExceptionStatus.ConnectFailure: return "keine Verbindung zum Server";
                    case WebExceptionStatus.TrustFailure:
                    case WebExceptionStatus.SecureChannelFailure: return "sichere Verbindung (HTTPS) nicht möglich";
                }
            }
            return ex.Message;
        }

        // ---------- Netz ----------

        /// <summary>POST mit JSON, Antwort als Text. Wirft bei Netz- oder Serverfehlern (mit dem Fehlertext des Servers).</summary>
        public static string Uebertragen(string adresse, string json)
        {
            var p = ServicePointManager.SecurityProtocol;
            if (p != SecurityProtocolType.SystemDefault && (p & SecurityProtocolType.Tls12) == 0)
                ServicePointManager.SecurityProtocol = p | SecurityProtocolType.Tls12;
            var r = (HttpWebRequest)WebRequest.Create(adresse);
            r.Method = "POST";
            r.ContentType = "application/json; charset=utf-8";
            r.Accept = "application/json";
            r.UserAgent = "Lageuhr";
            r.Timeout = ZeitlimitMs;
            r.ReadWriteTimeout = ZeitlimitMs;
            r.AllowAutoRedirect = false;
            r.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);
            try { r.ServicePoint.Expect100Continue = false; } catch { }
            var daten = new UTF8Encoding(false).GetBytes(json);
            r.ContentLength = daten.Length;
            try
            {
                using (var s = r.GetRequestStream()) s.Write(daten, 0, daten.Length);
                using (var a = (HttpWebResponse)r.GetResponse())
                using (var l = new StreamReader(a.GetResponseStream(), Encoding.UTF8))
                {
                    if ((int)a.StatusCode != 200) throw new InvalidOperationException("Server antwortet mit " + (int)a.StatusCode);
                    return l.ReadToEnd();
                }
            }
            catch (WebException ex) when (ex.Response is HttpWebResponse fa)
            {
                string text = null;
                try
                {
                    using (var l = new StreamReader(fa.GetResponseStream(), Encoding.UTF8))
                        if (JsonLeser.Lesen(l.ReadToEnd()) is Dictionary<string, object> d && d.TryGetValue("fehler", out var f)) text = f as string;
                }
                catch { }
                finally { fa.Close(); }
                throw new InvalidOperationException(text != null ? "Server meldet: " + text : "Server antwortet mit " + (int)fa.StatusCode, ex);
            }
        }
    }

    /// <summary>Schreibt ein JSON-Objekt (nur was der Abgleich braucht).</summary>
    class JsonSchreiber
    {
        readonly StringBuilder sb = new StringBuilder("{");

        JsonSchreiber Name(string k)
        {
            if (sb.Length > 1) sb.Append(',');
            Text(sb, k);
            sb.Append(':');
            return this;
        }

        public JsonSchreiber Wert(string k, string v) { Name(k); if (v == null) sb.Append("null"); else Text(sb, v); return this; }
        public JsonSchreiber Zahl(string k, long? v) { Name(k); sb.Append(v.HasValue ? v.Value.ToString(CultureInfo.InvariantCulture) : "null"); return this; }
        public JsonSchreiber Wahr(string k, bool v) { Name(k); sb.Append(v ? "true" : "false"); return this; }
        public JsonSchreiber Roh(string k, string json) { Name(k); sb.Append(json); return this; }
        public string Ende() => sb.ToString() + "}";

        public static void Text(StringBuilder sb, string s)
        {
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20 || c == (char)0x2028 || c == (char)0x2029) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }
    }

    /// <summary>Liest JSON: Objekt → Dictionary, Liste → List, Zahl → long (ganz) oder double, Text, bool, null.</summary>
    static class JsonLeser
    {
        public static object Lesen(string s)
        {
            if (s == null) throw new FormatException("Leere Antwort");
            int i = 0;
            var w = Wert(s, ref i);
            Leer(s, ref i);
            if (i != s.Length) throw new FormatException("JSON: Zeichen nach dem Ende");
            return w;
        }

        static void Leer(string s, ref int i) { while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == (char)0xFEFF)) i++; }

        static FormatException F(int i) => new FormatException("JSON: unerwartetes Zeichen an Stelle " + i);

        static object Wert(string s, ref int i)
        {
            Leer(s, ref i);
            if (i >= s.Length) throw F(i);
            char c = s[i];
            if (c == '{')
            {
                var d = new Dictionary<string, object>();
                i++; Leer(s, ref i);
                if (i < s.Length && s[i] == '}') { i++; return d; }
                while (true)
                {
                    Leer(s, ref i);
                    if (i >= s.Length || s[i] != '"') throw F(i);
                    string k = Text(s, ref i);
                    Leer(s, ref i);
                    if (i >= s.Length || s[i] != ':') throw F(i);
                    i++;
                    d[k] = Wert(s, ref i);
                    Leer(s, ref i);
                    if (i < s.Length && s[i] == ',') { i++; continue; }
                    if (i < s.Length && s[i] == '}') { i++; return d; }
                    throw F(i);
                }
            }
            if (c == '[')
            {
                var l = new List<object>();
                i++; Leer(s, ref i);
                if (i < s.Length && s[i] == ']') { i++; return l; }
                while (true)
                {
                    l.Add(Wert(s, ref i));
                    Leer(s, ref i);
                    if (i < s.Length && s[i] == ',') { i++; continue; }
                    if (i < s.Length && s[i] == ']') { i++; return l; }
                    throw F(i);
                }
            }
            if (c == '"') return Text(s, ref i);
            if (Wort(s, ref i, "true")) return true;
            if (Wort(s, ref i, "false")) return false;
            if (Wort(s, ref i, "null")) return null;
            int start = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            string z = s.Substring(start, i - start);
            if (z.Length == 0) throw F(start);
            if (long.TryParse(z, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long ganz)) return ganz;
            if (double.TryParse(z, NumberStyles.Float, CultureInfo.InvariantCulture, out double d2)) return d2;
            throw F(start);
        }

        static bool Wort(string s, ref int i, string w)
        {
            if (string.CompareOrdinal(s, i, w, 0, w.Length) != 0) return false;
            i += w.Length;
            return true;
        }

        static string Text(string s, ref int i)
        {
            var sb = new StringBuilder();
            i++; // "
            while (i < s.Length)
            {
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c != '\\') { sb.Append(c); continue; }
                if (i >= s.Length) break;
                char e = s[i++];
                switch (e)
                {
                    case '"': sb.Append('"'); break;
                    case '\\': sb.Append('\\'); break;
                    case '/': sb.Append('/'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'n': sb.Append('\n'); break;
                    case 'r': sb.Append('\r'); break;
                    case 't': sb.Append('\t'); break;
                    case 'u':
                        if (i + 4 > s.Length) throw F(i);
                        sb.Append((char)int.Parse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture)); // Ersatzpaare ergeben sich von selbst
                        i += 4;
                        break;
                    default: throw F(i - 1);
                }
            }
            throw new FormatException("JSON: Text ohne Ende");
        }
    }
}
