using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;

namespace Lageuhr
{
    // Gemeinsamer Teil für Kasten, Vollbild-Lagebild und Bildschirmschoner (Lageuhr.scr).

    public class Block
    {
        public FeldArt Art;
        public string Titel, Wert, Zusatz;
        public Color TitelFarbe, WertFarbe, ZusatzFarbe;
        public Color? Hintergrund;
        public float Faktor;
    }

    public class Zeichnung
    {
        public string Text; public Font Schrift; public Color Farbe; public Color Grund; public Point Ort;
    }

    public class Kachel { public Rectangle Rect; public Color? Farbe; }

    public static class Farben
    {
        public static Color Mischen(Color a, Color b, double t) => Color.FromArgb(
            (int)Math.Round(a.R * t + b.R * (1 - t)),
            (int)Math.Round(a.G * t + b.G * (1 - t)),
            (int)Math.Round(a.B * t + b.B * (1 - t)));

        static double Leuchtdichte(Color c)
        {
            double K(int x) { double v = x / 255.0; return v <= 0.03928 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4); }
            return 0.2126 * K(c.R) + 0.7152 * K(c.G) + 0.0722 * K(c.B);
        }

        public static double Kontrast(Color a, Color b)
        {
            double l1 = Leuchtdichte(a), l2 = Leuchtdichte(b);
            return (Math.Max(l1, l2) + 0.05) / (Math.Min(l1, l2) + 0.05);
        }

        /// <summary>Warnfarbe, die auf dem Grund lesbar ist; sonst die Schriftfarbe.</summary>
        public static Color Warnfarbe(Color grund, Color schrift, params Color[] kandidaten)
        {
            foreach (var k in kandidaten) if (Kontrast(k, grund) >= 4.5) return k;
            return schrift;
        }
    }

    public static class Lagebild
    {
        public const int NachlaufMinuten = 5;

        static float dpiFaktor = -1;
        public static int Px(double px)
        {
            if (dpiFaktor < 0)
                using (var g = Graphics.FromHwnd(IntPtr.Zero)) dpiFaktor = g.DpiX / 96f;
            return (int)Math.Round(px * dpiFaktor);
        }

        public static GraphicsPath Abgerundet(Rectangle r, int radius)
        {
            var p = new GraphicsPath();
            int d = Math.Max(1, Math.Min(2 * radius, Math.Min(r.Width, r.Height)));
            p.AddArc(r.Left, r.Top, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        /// <summary>Wiederkehrende Termine 5 Minuten nach Beginn auf den nächsten springen lassen.</summary>
        public static bool TermineWeiterschalten(Einstellungen e, DateTime jetzt)
        {
            bool weiter = false;
            foreach (var f in e.Felder)
            {
                if (f.Art != FeldArt.Termin || f.Intervall <= 0 || !(f.Zeit is DateTime t) || jetzt < t.AddMinutes(NachlaufMinuten)) continue;
                while (jetzt >= t.AddMinutes(NachlaufMinuten)) t = t.AddMinutes(f.Intervall);
                f.Zeit = t;
                weiter = true;
            }
            return weiter;
        }

        /// <summary>Baut aus den sichtbaren Feldern die anzuzeigenden Blöcke (Texte und Farben).</summary>
        public static List<Block> BloeckeBauen(Einstellungen e, DateTime jetzt)
        {
            var l = new List<Block>();
            int sw = e.Monatsschreibweise;
            bool blinkAn = jetzt.Millisecond < 500;

            foreach (var f in e.Felder.Where(x => x.Sichtbar))
            {
                Color grund = f.Hintergrund ?? e.Hintergrund;
                Color schrift = f.Schriftfarbe ?? e.Schriftfarbe;
                Color zusatz = Farben.Mischen(schrift, grund, 0.85), blass = Farben.Mischen(schrift, grund, 0.62);
                Color gelb = Farben.Warnfarbe(grund, schrift, Color.FromArgb(255, 193, 7), Color.FromArgb(178, 106, 0));
                Color rot = Farben.Warnfarbe(grund, schrift, Color.FromArgb(255, 82, 82), Color.FromArgb(198, 40, 40), Color.White);

                var b = new Block
                {
                    Art = f.Art, Titel = string.IsNullOrWhiteSpace(f.Titel) ? null : f.Titel,
                    TitelFarbe = blass, WertFarbe = schrift, ZusatzFarbe = zusatz,
                    Hintergrund = f.Hintergrund, Faktor = f.Groesse / 100f
                };
                switch (f.Art)
                {
                    case FeldArt.Text:
                        b.Wert = (f.Text ?? "").Trim();
                        if (b.Wert.Length == 0 && b.Titel == null) { b.Wert = "(leerer Text)"; b.WertFarbe = blass; }
                        break;
                    case FeldArt.Uhr:
                        b.Wert = Zeit.Taktisch(jetzt, sw);
                        b.Zusatz = f.Sekunden ? jetzt.ToString("HH:mm:ss") : null;
                        break;
                    case FeldArt.Seit:
                        if (f.Zeit is DateTime k)
                        {
                            var d = jetzt - k;
                            b.Wert = Zeit.Taktisch(k, sw);
                            b.Zusatz = d.Ticks >= 0 ? "Dauer " + Zeit.Laufzeit(d) : "beginnt in " + Zeit.Rest(-d);
                        }
                        else { b.Wert = "—"; b.Zusatz = "nicht festgelegt"; b.ZusatzFarbe = blass; }
                        break;
                    case FeldArt.Termin:
                        if (f.Zeit is DateTime t)
                        {
                            var rest = t - jetzt;
                            b.Wert = Zeit.Taktisch(t, sw);
                            if (rest.Ticks > 0)
                            {
                                b.Zusatz = "in " + Zeit.Rest(rest);
                                if (rest.TotalMinutes <= 10) b.ZusatzFarbe = gelb;
                            }
                            else if (-rest.TotalMinutes < NachlaufMinuten)
                            {
                                b.Zusatz = "JETZT"; b.ZusatzFarbe = blinkAn ? rot : blass; b.WertFarbe = rot;
                            }
                            else { b.Zusatz = "überfällig seit " + Zeit.Vergangen(-rest); b.ZusatzFarbe = rot; }
                        }
                        else { b.Wert = "—"; b.Zusatz = "nicht festgelegt"; b.ZusatzFarbe = blass; }
                        break;
                }
                l.Add(b);
            }
            return l;
        }

        public static readonly Color LagebildGrund = Color.FromArgb(11, 13, 18);

        /// <summary>Für Vollbild und Bildschirmschoner: dunkler Grund, helle Schrift. Farbige Felder bleiben;
        /// eine eigene Schriftfarbe ohne eigenen Hintergrund, die auf Dunkel nicht lesbar wäre, wird hell.</summary>
        public static Einstellungen Dunkel(Einstellungen e)
        {
            var d = e.Kopie();
            d.Hintergrund = LagebildGrund;
            d.Schriftfarbe = Color.White;
            foreach (var f in d.Felder)
                if (!f.Hintergrund.HasValue && f.Schriftfarbe.HasValue && Farben.Kontrast(f.Schriftfarbe.Value, LagebildGrund) < 3)
                    f.Schriftfarbe = null;
            return d;
        }

        public static string Signatur(List<Block> l)
        {
            var sb = new StringBuilder();
            foreach (var b in l)
                sb.Append('|').Append(b.Art).Append(b.Titel).Append('#').Append(b.Wert).Append('#').Append(b.Zusatz).Append('#')
                  .Append(b.TitelFarbe.ToArgb()).Append(b.WertFarbe.ToArgb()).Append(b.ZusatzFarbe.ToArgb())
                  .Append(b.Hintergrund?.ToArgb()).Append('#').Append(b.Faktor);
            return sb.ToString();
        }

        // ---------- Datenaustausch mit dem Bildschirmschoner ----------

        /// <summary>Ablage für den Bildschirmschoner: immer unter %APPDATA%, egal wo die Lageuhr liegt.</summary>
        public static string DatenPfad =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lageuhr", "lagebild.ini");

        public static void Schreiben(Einstellungen e)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(DatenPfad));
                string text = e.IniText() + "Versatz=" + Zeit.Versatz.ToString("R", CultureInfo.InvariantCulture) + "\r\n";
                File.WriteAllText(DatenPfad, text, new UTF8Encoding(false));
            }
            catch { }
        }

        /// <summary>Für den Bildschirmschoner: zuerst die Ablage der laufenden Lageuhr, sonst deren Einstellungen.</summary>
        public static Einstellungen Lesen()
        {
            try
            {
                if (File.Exists(DatenPfad))
                {
                    var zeilen = File.ReadAllLines(DatenPfad, Encoding.UTF8);
                    var e = Einstellungen.AusText(zeilen);
                    var v = zeilen.FirstOrDefault(z => z.StartsWith("Versatz="));
                    if (v != null && double.TryParse(v.Substring(8), NumberStyles.Float, CultureInfo.InvariantCulture, out double d)) Zeit.Versatz = d;
                    return e;
                }
            }
            catch { }
            return Einstellungen.Laden();
        }
    }

    /// <summary>Ordnet die Blöcke an – mit Rand, Kacheln und Trennlinien – und zeichnet sie.</summary>
    public class Anordnung
    {
        public const TextFormatFlags TF = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix;

        public readonly List<Zeichnung> Zeichnungen = new List<Zeichnung>();
        public readonly List<Kachel> Kacheln = new List<Kachel>();
        public readonly List<Rectangle> Trenner = new List<Rectangle>();
        public Size Groesse;
        readonly Dictionary<string, Font> schriften = new Dictionary<string, Font>();

        public Font Schrift(string familie, float pt, FontStyle stil = FontStyle.Regular)
        {
            pt = (float)Math.Round(Math.Max(6f, pt), 1);
            string k = familie + "|" + pt + "|" + stil;
            if (!schriften.TryGetValue(k, out var f)) schriften[k] = f = new Font(familie, pt, stil);
            return f;
        }

        public static Size Messen(string t, Font f) =>
            string.IsNullOrEmpty(t) ? Size.Empty : TextRenderer.MeasureText(t, f, new Size(int.MaxValue, int.MaxValue), TF);

        class Gemessen { public Block Block; public List<(string Text, Font Schrift, Color Farbe, int Y)> Zeilen = new List<(string, Font, Color, int)>(); public Size Groesse; }

        Gemessen Vermessen(Block b, float schriftgroesse)
        {
            float g = schriftgroesse * b.Faktor;
            var m = new Gemessen { Block = b };
            int y = 0, w = 0;
            void Zeile(string t, Font f, Color c)
            {
                var s = Messen(t, f);
                if (s.IsEmpty) return;
                m.Zeilen.Add((t, f, c, y));
                y += s.Height;
                w = Math.Max(w, s.Width);
            }
            Zeile(b.Titel, Schrift("Segoe UI", g * 0.43f), b.TitelFarbe);
            if (b.Art == FeldArt.Text) Zeile(b.Wert, Schrift("Segoe UI Semibold", g * 0.6f), b.WertFarbe);
            else Zeile(b.Wert, Schrift("Segoe UI", g, FontStyle.Bold), b.WertFarbe);
            Zeile(b.Zusatz, Schrift("Segoe UI", g * 0.5f), b.ZusatzFarbe);
            m.Groesse = new Size(w, y);
            return m;
        }

        public void Berechnen(List<Block> bloecke, float schriftgroesse, bool nebeneinander, Color hintergrund, Color schriftfarbe, string leerHinweis)
        {
            int Px(double p) => Lagebild.Px(p);
            if (schriften.Count > 200) { foreach (var f in schriften.Values) f.Dispose(); schriften.Clear(); }
            Zeichnungen.Clear(); Kacheln.Clear(); Trenner.Clear();
            float fk = schriftgroesse / 22f;
            int rand = Math.Max(Px(8), (int)(Px(8) * fk));
            int innen = Math.Max(Px(8), (int)(Px(9) * fk));
            int abstand = Math.Max(Px(4), (int)(Px(5) * fk));
            int linie = Math.Max(1, (int)Math.Round(Px(1) * Math.Max(1, fk / 2)));
            var alle = bloecke.Select(b => Vermessen(b, schriftgroesse)).ToList();

            void Setzen(Gemessen m, Rectangle r)
            {
                Kacheln.Add(new Kachel { Rect = r, Farbe = m.Block.Hintergrund });
                Color grund = m.Block.Hintergrund ?? hintergrund;
                foreach (var z in m.Zeilen)
                    Zeichnungen.Add(new Zeichnung { Text = z.Text, Schrift = z.Schrift, Farbe = z.Farbe, Grund = grund, Ort = new Point(r.Left + innen, r.Top + innen + z.Y) });
            }
            bool Trennen(Gemessen a, Gemessen b) => a != null && a.Block.Hintergrund == null && b.Block.Hintergrund == null;

            int breite = Px(130), y = rand;
            if (!nebeneinander)
            {
                breite = Math.Max(breite, (alle.Count > 0 ? alle.Max(m => m.Groesse.Width) : 0) + 2 * innen);
                Gemessen vorher = null;
                foreach (var m in alle)
                {
                    if (vorher != null)
                    {
                        if (Trennen(vorher, m)) Trenner.Add(new Rectangle(rand + innen, y + abstand / 2, breite - 2 * innen, linie));
                        y += abstand;
                    }
                    Setzen(m, new Rectangle(rand, y, breite, m.Groesse.Height + 2 * innen));
                    y += m.Groesse.Height + 2 * innen;
                    vorher = m;
                }
            }
            else
            {
                // Text-Felder am Anfang und Ende gehen über die ganze Breite, der Rest steht nebeneinander
                var mitte = new List<Gemessen>(alle);
                var kopf = new List<Gemessen>();
                var fuss = new List<Gemessen>();
                while (mitte.Count > 0 && mitte[0].Block.Art == FeldArt.Text) { kopf.Add(mitte[0]); mitte.RemoveAt(0); }
                while (mitte.Count > 0 && mitte[mitte.Count - 1].Block.Art == FeldArt.Text) { fuss.Insert(0, mitte[mitte.Count - 1]); mitte.RemoveAt(mitte.Count - 1); }
                int hoehe = (mitte.Count > 0 ? mitte.Max(m => m.Groesse.Height) : 0) + 2 * innen;
                int reihe = mitte.Sum(m => m.Groesse.Width + 2 * innen) + Math.Max(0, mitte.Count - 1) * abstand;
                breite = Math.Max(Math.Max(breite, reihe), (kopf.Concat(fuss).Select(m => m.Groesse.Width).DefaultIfEmpty(0).Max()) + 2 * innen);

                Gemessen vorher = null;
                bool vorherFarbig = false;
                void Ganz(Gemessen m)
                {
                    if (vorher != null || vorherFarbig)
                    {
                        if (!vorherFarbig && Trennen(vorher, m)) Trenner.Add(new Rectangle(rand + innen, y + abstand / 2, breite - 2 * innen, linie));
                        y += abstand;
                    }
                    Setzen(m, new Rectangle(rand, y, breite, m.Groesse.Height + 2 * innen));
                    y += m.Groesse.Height + 2 * innen;
                    vorher = m; vorherFarbig = false;
                }
                kopf.ForEach(Ganz);
                if (mitte.Count > 0)
                {
                    bool reiheFarbig = mitte.Any(m => m.Block.Hintergrund != null);
                    if (vorher != null)
                    {
                        if (vorher.Block.Hintergrund == null && !reiheFarbig) Trenner.Add(new Rectangle(rand + innen, y + abstand / 2, breite - 2 * innen, linie));
                        y += abstand;
                    }
                    int x = rand;
                    Gemessen links = null;
                    foreach (var m in mitte)
                    {
                        if (links != null)
                        {
                            if (Trennen(links, m)) Trenner.Add(new Rectangle(x + abstand / 2, y + innen, linie, hoehe - 2 * innen));
                            x += abstand;
                        }
                        Setzen(m, new Rectangle(x, y, m.Groesse.Width + 2 * innen, hoehe));
                        x += m.Groesse.Width + 2 * innen;
                        links = m;
                    }
                    y += hoehe;
                    vorher = reiheFarbig ? null : mitte[mitte.Count - 1];
                    vorherFarbig = reiheFarbig;
                }
                fuss.ForEach(Ganz);
            }
            if (alle.Count == 0)
            {
                var f = Schrift("Segoe UI", Math.Max(10f, 10f * fk));
                var s = Messen(leerHinweis, f);
                Zeichnungen.Add(new Zeichnung { Text = leerHinweis, Schrift = f, Farbe = schriftfarbe, Grund = hintergrund, Ort = new Point(rand + innen, rand + innen) });
                breite = Math.Max(breite, s.Width + 2 * innen);
                y += s.Height + 2 * innen;
            }
            Groesse = new Size(breite + 2 * rand, y + rand);
        }

        /// <summary>Kacheln, Trennlinien und Texte zeichnen, verschoben um <paramref name="v"/>.</summary>
        public void Zeichnen(Graphics g, Point v, Color trennfarbe, int eckradius)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            foreach (var k in Kacheln.Where(x => x.Farbe.HasValue))
            {
                var r = k.Rect; r.Offset(v);
                using (var br = new SolidBrush(k.Farbe.Value))
                using (var pfad = Lagebild.Abgerundet(r, eckradius))
                    g.FillPath(br, pfad);
            }
            g.SmoothingMode = SmoothingMode.None;
            using (var br = new SolidBrush(trennfarbe))
                foreach (var t in Trenner) { var r = t; r.Offset(v); g.FillRectangle(br, r); }
            foreach (var z in Zeichnungen)
                TextRenderer.DrawText(g, z.Text, z.Schrift, new Point(z.Ort.X + v.X, z.Ort.Y + v.Y), z.Farbe, z.Grund, TF);
        }
    }

    /// <summary>Ein Bildschirm voll Lagebild – für das Vollbild-Lagebild und den Bildschirmschoner.</summary>
    public class VollbildFenster : Form
    {
        readonly Anordnung anordnung = new Anordnung();
        Einstellungen e;
        string letzte = "", aufbau = "";
        Size groesseFuer;
        float schriftgroesse = 40;
        Point versatz;
        DateTime naechsteDrift = DateTime.MinValue;
        Point? mausStart;
        readonly DateTime seit = DateTime.Now;
        static readonly Random zufall = new Random();

        /// <summary>Maus, Taste oder Klick: beenden.</summary>
        public event Action Beenden;

        public VollbildFenster(Screen bildschirm, Einstellungen e)
        {
            this.e = Lagebild.Dunkel(e);
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            Bounds = bildschirm.Bounds;
            TopMost = true;
            ShowInTaskbar = false;
            KeyPreview = true;
            DoubleBuffered = true;
            BackColor = Lagebild.LagebildGrund;
            Text = "Lageuhr – Lagebild";
        }

        public void Aktualisieren(Einstellungen neu, DateTime jetzt)
        {
            e = Lagebild.Dunkel(neu); // Vollbild und Bildschirmschoner immer dunkel
            BackColor = e.Hintergrund;
            var b = Lagebild.BloeckeBauen(e, jetzt);
            // Schriftgröße nur neu bestimmen, wenn sich Bildschirm oder Feldaufbau ändern (sonst „pumpt“ das Bild)
            string neuerAufbau = string.Join("|", b.Select(x => x.Art + (x.Titel ?? "") + x.Faktor + x.Hintergrund?.ToArgb())) + e.Nebeneinander;
            if (groesseFuer != ClientSize || neuerAufbau != aufbau)
            {
                var probe = new Anordnung();
                probe.Berechnen(b, 40, e.Nebeneinander, e.Hintergrund, e.Schriftfarbe, "Keine Felder");
                double k = Math.Min(ClientSize.Width * 0.82 / Math.Max(1, probe.Groesse.Width), ClientSize.Height * 0.78 / Math.Max(1, probe.Groesse.Height));
                schriftgroesse = (float)Math.Max(12, Math.Min(400, 40 * k));
                groesseFuer = ClientSize; aufbau = neuerAufbau;
                naechsteDrift = DateTime.MinValue;
            }
            string sig = Lagebild.Signatur(b) + e.Hintergrund.ToArgb() + e.Schriftfarbe.ToArgb();
            if (sig == letzte && DateTime.Now < naechsteDrift) return;
            letzte = sig;
            anordnung.Berechnen(b, schriftgroesse, e.Nebeneinander, e.Hintergrund, e.Schriftfarbe, "Keine Felder");
            if (DateTime.Now >= naechsteDrift) // jede Minute leicht verschieben (gegen Einbrennen)
            {
                int fw = Math.Max(0, ClientSize.Width - anordnung.Groesse.Width), fh = Math.Max(0, ClientSize.Height - anordnung.Groesse.Height);
                versatz = new Point(fw / 2 + (int)((zufall.NextDouble() - 0.5) * 0.3 * fw), fh / 2 + (int)((zufall.NextDouble() - 0.5) * 0.3 * fh));
                naechsteDrift = DateTime.Now.AddMinutes(1);
            }
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs a)
        {
            a.Graphics.Clear(e.Hintergrund);
            anordnung.Zeichnen(a.Graphics, versatz, Farben.Mischen(e.Schriftfarbe, e.Hintergrund, 0.22), Lagebild.Px(14));
        }

        void Ende() => Beenden?.Invoke();

        protected override void OnMouseMove(MouseEventArgs a)
        {
            base.OnMouseMove(a);
            var p = Cursor.Position;
            if (mausStart == null || (DateTime.Now - seit).TotalMilliseconds < 800) { mausStart = p; return; }
            if (Math.Abs(p.X - mausStart.Value.X) + Math.Abs(p.Y - mausStart.Value.Y) > 8) Ende();
        }
        protected override void OnMouseDown(MouseEventArgs a) { base.OnMouseDown(a); Ende(); }
        protected override void OnKeyDown(KeyEventArgs a) { base.OnKeyDown(a); Ende(); }

        protected override void WndProc(ref Message m)
        {
            const int WM_SYSCOMMAND = 0x112, SC_SCREENSAVE = 0xF140, SC_MONITORPOWER = 0xF170;
            if (m.Msg == WM_SYSCOMMAND)
            {
                int c = m.WParam.ToInt32() & 0xFFF0;
                if (c == SC_SCREENSAVE || c == SC_MONITORPOWER) { m.Result = IntPtr.Zero; return; } // kein Bildschirmschoner über dem Lagebild
            }
            base.WndProc(ref m);
        }
    }
}
