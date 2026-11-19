using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Lageuhr
{
    public enum FeldArt { Text, Uhr, Seit, Termin }

    /// <summary>Ein Feld im Kasten: Text, aktuelle Zeit, „Seit …“ oder Termin mit Countdown – jedes mit eigenen Farben.</summary>
    public class Feld
    {
        public string Id = Guid.NewGuid().ToString("N");
        public FeldArt Art = FeldArt.Text;
        public string Titel = "";
        public string Text = "";
        public DateTime? Zeit;
        public int Intervall;          // Minuten, nur Termin
        public bool Sekunden = true;   // nur Uhrzeit
        public Color? Schriftfarbe;    // null = wie der Kasten
        public Color? Hintergrund;     // null = kein eigener Hintergrund
        public int Groesse = 100;      // Prozent der Schriftgröße
        public bool Sichtbar = true;

        // Abgleich zwischen Arbeitsplätzen (Größe, sichtbar und Reihenfolge bleiben immer am eigenen Platz)
        public bool Geteilt = true;    // mit anderen Arbeitsplätzen teilen (neu: an außer bei der Uhrzeit)
        public long Geaendert;         // letzte Änderung der geteilten Werte, ms seit 1970 (UTC)
        public string Von;             // Arbeitsplatz der letzten Änderung
        public string Bekannt;         // Signatur der geteilten Werte beim letzten Senden/Empfangen
        internal string Gestempelt;    // nur im Speicher: Signatur, für die Geaendert/Von gesetzt wurden

        public Feld() { }
        public Feld(FeldArt art, string titel = null, string text = "")
        {
            Art = art; Titel = titel ?? StandardTitel(art); Text = text; Geteilt = art != FeldArt.Uhr;
        }

        public static bool IdGueltig(string id) => id != null && Regex.IsMatch(id, "^[A-Za-z0-9-]{8,64}$");

        public Feld Kopie() => (Feld)MemberwiseClone();

        public static string ArtName(FeldArt a) =>
            a == FeldArt.Text ? "Text" : a == FeldArt.Uhr ? "Aktuelle Zeit" : a == FeldArt.Seit ? "Seit … (z. B. Kat-Fall)" : "Termin mit Countdown";

        public static string Kurz(FeldArt a) =>
            a == FeldArt.Text ? "Text" : a == FeldArt.Uhr ? "Uhrzeit" : a == FeldArt.Seit ? "Seit" : "Termin";

        public static string StandardTitel(FeldArt a) =>
            a == FeldArt.Uhr ? "Aktuelle Zeit" : a == FeldArt.Seit ? "Kat-Fall seit" : a == FeldArt.Termin ? "Nächste Lagebesprechung" : "";

        /// <summary>Name in Liste und Menü</summary>
        public string Name
        {
            get
            {
                if (!string.IsNullOrWhiteSpace(Titel)) return Titel;
                if (Art == FeldArt.Text)
                {
                    string z = (Text ?? "").Replace("\r", "").Split('\n').FirstOrDefault(x => x.Trim().Length > 0);
                    if (!string.IsNullOrEmpty(z)) return z.Trim();
                }
                return Kurz(Art);
            }
        }
    }

    /// <summary>Alle Einstellungen. Gespeichert als Lageuhr.ini neben der .exe (sonst unter %APPDATA%\Lageuhr).</summary>
    public class Einstellungen
    {
        public List<Feld> Felder = StandardFelder();
        public bool Nebeneinander = false;
        public float Schriftgroesse = 22f; // Punkt, für die großen Zeiten; alles andere passt sich an
        public int Deckkraft = 90;         // Prozent
        public Color Hintergrund = StandardHintergrund;
        public Color Schriftfarbe = StandardSchrift;
        public int Monatsschreibweise = 0; // 0 = nov, 1 = Nov, 2 = NOV
        public bool Fixiert = false;
        public bool Durchklickbar = false;
        public bool DeckendBeiMaus = true; // unter der Maus voll deckend
        public int Andocken = 0;           // 0 = frei, 1 = links, 2 = rechts, 3 = oben, 4 = unten
        public bool Einklappen = true;     // angedockt: zur Lasche einklappen
        public bool Atomuhr = true;
        public string Zeitserver = Lageuhr.Atomuhr.StandardServer;
        public int VollbildNachMin = 0;    // Vollbild-Lagebild nach so vielen Minuten ohne Eingabe (0 = aus)
        public bool VollbildAlle = true;   // auf allen Bildschirmen
        public bool UpdateSuchen = true;   // beim Start und täglich auf GitHub nach einer neuen Fassung sehen (installiert nie selbst)
        public int? X, Y;

        // Abgleich zwischen Arbeitsplätzen (server/PROTOKOLL.md)
        public bool AbgleichAn = false;
        public string AbgleichServer = "";
        public string LageCode = "";
        public string Arbeitsplatz = Environment.MachineName;
        public long LageStand;             // letzte bekannte rev der Lage (0 = beitreten)
        public List<string> LageIds = new List<string>(); // Ids der geteilten Felder (um Löschen zu erkennen)

        public static readonly Color StandardHintergrund = Color.FromArgb(24, 29, 37);
        public static readonly Color StandardSchrift = Color.White;

        public static List<Feld> StandardFelder() =>
            new List<Feld> { new Feld(FeldArt.Uhr), new Feld(FeldArt.Seit), new Feld(FeldArt.Termin) };

        /// <summary>Farbvorlagen für einzelne Felder: Name, Hintergrund, Schrift (null = wie der Kasten)</summary>
        public static readonly (string Name, Color? Grund, Color? Schrift)[] FeldVorlagen =
        {
            ("Standard", null, null),
            ("Rot", Color.FromArgb(183, 28, 28), Color.White),
            ("Orange", Color.FromArgb(230, 81, 0), Color.White),
            ("Gelb", Color.FromArgb(255, 214, 0), Color.Black),
            ("Grün", Color.FromArgb(46, 125, 50), Color.White),
            ("Blau", Color.FromArgb(21, 101, 192), Color.White),
            ("Grau", Color.FromArgb(69, 90, 100), Color.White),
            ("Weiß", Color.White, Color.Black),
        };

        public string Pfad;

        public Einstellungen Kopie()
        {
            var k = (Einstellungen)MemberwiseClone();
            k.Felder = Felder.Select(f => f.Kopie()).ToList();
            k.LageIds = new List<string>(LageIds);
            return k;
        }

        static string AppDataPfad =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lageuhr", "Lageuhr.ini");

        public static Einstellungen Laden()
        {
            string exeOrdner = AppDomain.CurrentDomain.BaseDirectory;
            string neben = Path.Combine(exeOrdner, "Lageuhr.ini");
            string pfad;
            if (File.Exists(neben)) pfad = neben;
            else if (File.Exists(AppDataPfad)) pfad = AppDataPfad;
            else pfad = Beschreibbar(exeOrdner) ? neben : AppDataPfad;

            var e = new Einstellungen { Pfad = pfad };
            try { if (File.Exists(pfad)) e.Einlesen(File.ReadAllLines(pfad, Encoding.UTF8)); }
            catch { /* kaputte Datei: Standardwerte */ }
            return e;
        }

        static bool Beschreibbar(string ordner)
        {
            try
            {
                string t = Path.Combine(ordner, ".lageuhr-test");
                File.WriteAllText(t, "");
                File.Delete(t);
                return true;
            }
            catch { return false; }
        }

        // ---------- Schreiben ----------

        public void Speichern()
        {
            string text = IniText();
            try { Schreiben(Pfad, text); }
            catch
            {
                if (Pfad == AppDataPfad) return;
                Pfad = AppDataPfad; // Ordner der .exe nicht beschreibbar (z. B. Netzlaufwerk)
                try { Schreiben(Pfad, text); } catch { }
            }
            Lagebild.Schreiben(this); // für den Bildschirmschoner
        }

        /// <summary>Alle Einstellungen als INI-Text.</summary>
        public string IniText()
        {
            var sb = new StringBuilder();
            sb.AppendLine("; Lageuhr – Einstellungen");
            void S(string k, string v) => sb.Append(k).Append('=').AppendLine(Maskieren(v ?? ""));
            void B(string k, bool v) => S(k, v ? "1" : "0");
            void I(string k, int? v) => S(k, v?.ToString(CultureInfo.InvariantCulture) ?? "");
            void L(string k, long v) => S(k, v.ToString(CultureInfo.InvariantCulture));
            void D(string k, DateTime? v) => S(k, v?.ToString(v.Value.Second != 0 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) ?? "");
            void F(string k, Color? v) => S(k, v.HasValue ? Hex(v.Value) : "");

            B("Nebeneinander", Nebeneinander);
            S("Schriftgroesse", Schriftgroesse.ToString("0.#", CultureInfo.InvariantCulture));
            I("Deckkraft", Deckkraft);
            F("Hintergrund", Hintergrund);
            F("Schriftfarbe", Schriftfarbe);
            I("Monatsschreibweise", Monatsschreibweise);
            B("Fixiert", Fixiert); B("Durchklickbar", Durchklickbar);
            B("DeckendBeiMaus", DeckendBeiMaus); I("Andocken", Andocken); B("Einklappen", Einklappen);
            B("Atomuhr", Atomuhr); S("Zeitserver", Zeitserver);
            I("VollbildNachMin", VollbildNachMin); B("VollbildAlle", VollbildAlle);
            B("UpdateSuchen", UpdateSuchen);
            I("X", X); I("Y", Y);
            B("Abgleich", AbgleichAn); S("AbgleichServer", AbgleichServer); S("LageCode", LageCode);
            S("Arbeitsplatz", Arbeitsplatz); L("LageStand", LageStand); S("LageIds", string.Join(",", LageIds));
            I("Felder", Felder.Count);
            for (int i = 0; i < Felder.Count; i++)
            {
                var f = Felder[i];
                string p = "Feld" + (i + 1) + ".";
                S(p + "Art", f.Art.ToString());
                S(p + "Titel", f.Titel); S(p + "Text", f.Text); D(p + "Zeit", f.Zeit);
                I(p + "Intervall", f.Intervall); B(p + "Sekunden", f.Sekunden);
                F(p + "Schriftfarbe", f.Schriftfarbe); F(p + "Hintergrund", f.Hintergrund);
                I(p + "Groesse", f.Groesse); B(p + "Sichtbar", f.Sichtbar);
                S(p + "Id", f.Id); B(p + "Geteilt", f.Geteilt); L(p + "Geaendert", f.Geaendert);
                S(p + "Von", f.Von); S(p + "Bekannt", f.Bekannt);
            }

            return sb.ToString();
        }

        /// <summary>Einstellungen aus INI-Zeilen (z. B. der Ablage für den Bildschirmschoner).</summary>
        public static Einstellungen AusText(string[] zeilen)
        {
            var e = new Einstellungen { Pfad = AppDataPfad };
            e.Einlesen(zeilen);
            return e;
        }

        static void Schreiben(string pfad, string text)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(pfad));
            File.WriteAllText(pfad, text, new UTF8Encoding(false));
        }

        // ---------- Lesen ----------

        void Einlesen(string[] zeilen)
        {
            var werte = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var z in zeilen)
            {
                if (z.StartsWith(";")) continue;
                int i = z.IndexOf('=');
                if (i > 0) werte[z.Substring(0, i).Trim()] = Entmaskieren(z.Substring(i + 1));
            }
            string W(string k) => werte.TryGetValue(k, out var v) ? v : null;
            bool Bo(string k, bool std) => W(k) == null ? std : W(k) == "1";

            Nebeneinander = Bo("Nebeneinander", false);
            if (float.TryParse(W("Schriftgroesse"), NumberStyles.Float, CultureInfo.InvariantCulture, out float g)) Schriftgroesse = Begrenzen(g);
            Deckkraft = Math.Max(30, Math.Min(100, Zahl(W("Deckkraft")) ?? 90));
            Hintergrund = Farbe(W("Hintergrund")) ?? StandardHintergrund;
            Schriftfarbe = Farbe(W("Schriftfarbe")) ?? StandardSchrift;
            Monatsschreibweise = Math.Max(0, Math.Min(2, Zahl(W("Monatsschreibweise")) ?? 0));
            Fixiert = Bo("Fixiert", false);
            Durchklickbar = Bo("Durchklickbar", false);
            DeckendBeiMaus = Bo("DeckendBeiMaus", true);
            Andocken = Math.Max(0, Math.Min(4, Zahl(W("Andocken")) ?? 0));
            Einklappen = Bo("Einklappen", true);
            Atomuhr = Bo("Atomuhr", true);
            Zeitserver = string.IsNullOrWhiteSpace(W("Zeitserver")) ? Lageuhr.Atomuhr.StandardServer : W("Zeitserver");
            VollbildNachMin = Math.Max(0, Math.Min(240, Zahl(W("VollbildNachMin")) ?? 0));
            VollbildAlle = Bo("VollbildAlle", true);
            UpdateSuchen = Bo("UpdateSuchen", true);
            X = Zahl(W("X")); Y = Zahl(W("Y"));
            AbgleichAn = Bo("Abgleich", false);
            AbgleichServer = (W("AbgleichServer") ?? "").Trim();
            LageCode = (W("LageCode") ?? "").Trim();
            Arbeitsplatz = string.IsNullOrWhiteSpace(W("Arbeitsplatz")) ? Environment.MachineName : W("Arbeitsplatz").Trim();
            LageStand = Math.Max(0, Lang(W("LageStand")));
            LageIds = (W("LageIds") ?? "").Split(',').Select(x => x.Trim()).Where(Feld.IdGueltig).Distinct().ToList();

            if (Zahl(W("Felder")) is int n)
            {
                Felder = new List<Feld>();
                var ids = new HashSet<string>();
                for (int i = 1; i <= n; i++)
                {
                    string p = "Feld" + i + ".";
                    if (!Enum.TryParse(W(p + "Art"), true, out FeldArt art)) continue;
                    var f = new Feld
                    {
                        Art = art, Titel = W(p + "Titel") ?? "", Text = W(p + "Text") ?? "", Zeit = Datum(W(p + "Zeit")),
                        Intervall = Math.Max(0, Zahl(W(p + "Intervall")) ?? 0), Sekunden = Bo(p + "Sekunden", true),
                        Schriftfarbe = Farbe(W(p + "Schriftfarbe")), Hintergrund = Farbe(W(p + "Hintergrund")),
                        Groesse = Math.Max(30, Math.Min(300, Zahl(W(p + "Groesse")) ?? 100)), Sichtbar = Bo(p + "Sichtbar", true),
                        Geteilt = Bo(p + "Geteilt", art != FeldArt.Uhr), Geaendert = Math.Max(0, Lang(W(p + "Geaendert"))),
                        Von = string.IsNullOrEmpty(W(p + "Von")) ? null : W(p + "Von"),
                        Bekannt = string.IsNullOrEmpty(W(p + "Bekannt")) ? null : W(p + "Bekannt"),
                    };
                    string id = W(p + "Id");
                    if (Feld.IdGueltig(id) && ids.Add(id)) f.Id = id; // ältere Einstellungen ohne Id: neue Id (Standard)
                    Felder.Add(f);
                }
            }
            else if (W("UhrZeigen") != null)
            {
                // Aufbau von Version 1.0 (feste Zeilen) in Felder umwandeln
                Felder = new List<Feld>();
                if (!string.IsNullOrWhiteSpace(W("TextOben"))) Felder.Add(new Feld(FeldArt.Text, null, W("TextOben")));
                Felder.Add(new Feld(FeldArt.Uhr, W("UhrTitel")) { Sekunden = Bo("UhrSekunden", true), Sichtbar = Bo("UhrZeigen", true) });
                Felder.Add(new Feld(FeldArt.Seit, W("KatTitel")) { Zeit = Datum(W("KatBeginn")), Sichtbar = Bo("KatZeigen", true) });
                Felder.Add(new Feld(FeldArt.Termin, W("LageTitel"))
                {
                    Zeit = Datum(W("LageZeit")), Intervall = Zahl(W("LageIntervall")) ?? 0, Sichtbar = Bo("LageZeigen", true)
                });
                if (!string.IsNullOrWhiteSpace(W("TextUnten"))) Felder.Add(new Feld(FeldArt.Text, null, W("TextUnten")) { Groesse = 80 });
            }
        }

        public static float Begrenzen(float pt) => Math.Max(8f, Math.Min(150f, pt));

        static int? Zahl(string v) =>
            int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out int i) ? i : (int?)null;

        static long Lang(string v) =>
            long.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out long l) ? l : 0;

        static DateTime? Datum(string v) =>
            DateTime.TryParseExact(v, new[] { "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss" }, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
                ? d : (DateTime?)null;

        static Color? Farbe(string v)
        {
            try { return string.IsNullOrWhiteSpace(v) ? (Color?)null : Color.FromArgb(255, ColorTranslator.FromHtml(v)); }
            catch { return null; }
        }

        public static string Hex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

        static string Maskieren(string s) => s.Replace("\\", "\\\\").Replace("\r", "").Replace("\n", "\\n");

        static string Entmaskieren(string s)
        {
            var sb = new StringBuilder();
            for (int i = 0; i < s.Length; i++)
            {
                if (s[i] == '\\' && i + 1 < s.Length)
                {
                    i++;
                    sb.Append(s[i] == 'n' ? "\r\n" : s[i].ToString());
                }
                else sb.Append(s[i]);
            }
            return sb.ToString();
        }
    }
}
