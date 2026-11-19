using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace Lageuhr
{
    /// <summary>Der Kasten auf dem Bildschirm.</summary>
    public class Overlay : Form
    {
        Einstellungen einst;
        readonly Timer takt;
        readonly NotifyIcon tray;
        readonly ContextMenuStrip menue = new ContextMenuStrip();
        EinstellungenFenster dialog;

        List<Block> bloecke = new List<Block>();
        readonly Anordnung anordnung = new Anordnung();
        string letzteSignatur = "";
        int topmostZaehler;
        bool mausDrin;

        // Größe mit dem Griff unten rechts ziehen
        bool skaliert; Point skalStart; int skalBreite; float skalPunkt;


        // Andocken und Einklappen
        bool eingeklappt;
        Size boxGroesse = new Size(200, 100);
        string laschenZeit = "--:--";
        int warnstufe;            // 0 = nichts, 1 = Termin in ≤ 10 min, 2 = Termin JETZT
        DateTime? rausSeit;
        bool Angedockt => einst.Andocken != 0;
        bool Klappbar => Angedockt && einst.Einklappen && !einst.Durchklickbar;

        // Vollbild-Lagebild
        readonly List<VollbildFenster> vollbild = new List<VollbildFenster>();
        bool VollbildAktiv => vollbild.Count > 0;
        bool schonerAusgesetzt, wachGehalten;

        // Atomuhr
        string zeitStatus = "Noch nicht abgeglichen";
        bool abgleichLaeuft;
        DateTime naechsterAbgleich = DateTime.MinValue;
        DateTime? letzterAbgleich;

        // Abgleich zwischen Arbeitsplätzen
        readonly Abgleich abgleich = new Abgleich();
        Einstellungen dialogBasis; // Stand beim Öffnen der Einstellungen (zum Zusammenführen)

        // Update über GitHub (sucht nur; installiert wird nur auf Wunsch)
        readonly Aktualisierung update = new Aktualisierung(Application.ExecutablePath);
        DateTime naechsteUpdateSuche = DateTime.Now.AddSeconds(30);
        bool updateMelden;          // Ergebnis der laufenden Suche als Meldung zeigen (Menü „Nach Update suchen“)
        readonly bool nachUpdate;   // gerade nach einem Update gestartet

        const int NachlaufMinuten = 5;
        const TextFormatFlags TF = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix;

        public Overlay(Einstellungen e, bool nachUpdate = false)
        {
            einst = e;
            this.nachUpdate = nachUpdate;
            FormBorderStyle = FormBorderStyle.None;
            MaximizeBox = false;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            DoubleBuffered = true;
            Text = "Lageuhr";
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            menue.Opening += (s, a) => { MenueFuellen(); a.Cancel = false; };
            menue.Items.Add("…"); // damit sich das Menü öffnet; der Inhalt entsteht beim Öffnen
            ContextMenuStrip = menue;
            tray = new NotifyIcon { Icon = Icon ?? SystemIcons.Application, Text = "Lageuhr", ContextMenuStrip = menue, Visible = true };
            tray.MouseClick += (s, a) => { if (a.Button == MouseButtons.Left) Einblenden(); };
            tray.MouseDoubleClick += (s, a) => { if (a.Button == MouseButtons.Left) EinstellungenOeffnen(); };

            Opacity = 0; // blendet in OnShown sanft ein
            BackColor = einst.Hintergrund;
            Takt();
            PositionSetzen();

            takt = new Timer { Interval = 100 };
            takt.Tick += (s, a) => Takt();
            takt.Start();
            Microsoft.Win32.SystemEvents.PowerModeChanged += Energiemodus;
        }

        // nach dem Ruhezustand neu mit der Atomuhr abgleichen
        void Energiemodus(object s, Microsoft.Win32.PowerModeChangedEventArgs a)
        {
            if (a.Mode == Microsoft.Win32.PowerModes.Resume) naechsterAbgleich = DateTime.MinValue;
        }

        // ---------- Atomuhr ----------

        void ZeitAbgleichen(string server = null, Action<string> fertig = null)
        {
            if (abgleichLaeuft) return;
            abgleichLaeuft = true;
            zeitStatus = "Gleiche ab …";
            bool vonHand = server != null;
            Atomuhr.Abgleichen(server ?? einst.Zeitserver, (v, quelle) =>
            {
                if (IsDisposed) return;
                BeginInvoke((Action)(() =>
                {
                    abgleichLaeuft = false;
                    if (v.HasValue && (einst.Atomuhr || vonHand))
                    {
                        Zeit.Versatz = v.Value;
                        letzterAbgleich = DateTime.Now;
                        zeitStatus = "Atomuhr: abgeglichen um " + Zeit.Jetzt.ToString("HH:mm:ss") + " mit " + quelle + " – " + Zeit.AbweichungText(v.Value);
                        naechsterAbgleich = DateTime.Now.AddMinutes(30);
                    }
                    else
                    {
                        zeitStatus = "Atomuhr nicht erreichbar – " + (letzterAbgleich.HasValue ? "letzter Abgleich gilt weiter" : "es gilt die Rechnerzeit");
                        naechsterAbgleich = DateTime.Now.AddMinutes(2);
                    }
                    letzteSignatur = "";
                    Lagebild.Schreiben(einst); // Abweichung auch für den Bildschirmschoner
                    fertig?.Invoke(zeitStatus);
                }));
            });
        }

        // ---------- Abgleich zwischen Arbeitsplätzen ----------

        void AbgleichStarten()
        {
            abgleich.Starten(einst, a => { if (!IsDisposed && IsHandleCreated) BeginInvoke(a); else throw new ObjectDisposedException("Overlay"); },
                () => einst, folge =>
                {
                    if (IsDisposed) return;
                    if (folge != AbgleichFolge.Nichts) einst.Speichern();
                    if (folge == AbgleichFolge.Neuzeichnen) letzteSignatur = "";
                    if (dialog != null && !dialog.IsDisposed) dialog.AbgleichStatusZeigen(abgleich.StatusLang(einst));
                });
        }

        // ---------- Maus, Andocken, Einklappen ----------

        bool MausDrueber => Bounds.Contains(Cursor.Position);

        double ZielDeckkraft =>
            eingeklappt || (einst.DeckendBeiMaus && !einst.Durchklickbar && MausDrueber) ? 1.0 : einst.Deckkraft / 100.0;

        void DeckkraftSetzen()
        {
            if (animiert) return;
            OpacitySetzen(ZielDeckkraft);
        }

        void OpacitySetzen(double wert)
        {
            if (Math.Abs(Opacity - wert) < 0.001) return;
            Opacity = wert;
            DurchklickSetzen(einst.Durchklickbar); // Opacity setzt die Fensterart zurück
        }

        // ---------- Animation ----------

        readonly Timer animTakt = new Timer { Interval = 15 };
        bool animiert;
        DateTime animStart;
        Rectangle animVon, animNach;
        double deckVon, deckNach;
        int animMs;
        bool animEaseIn;
        Action animFertig;

        /// <summary>Fenster gleiten lassen und dabei ein- oder ausblenden.</summary>
        void Animieren(Rectangle von, Rectangle nach, double deckkraftVon, double deckkraftNach, int ms, bool easeIn, Action fertig = null)
        {
            animVon = von; animNach = nach; deckVon = deckkraftVon; deckNach = deckkraftNach;
            animMs = ms; animEaseIn = easeIn; animFertig = fertig;
            animStart = DateTime.Now;
            animiert = true;
            SetBounds(von.X, von.Y, von.Width, von.Height);
            OpacitySetzen(deckkraftVon);
            if (animTakt.Tag == null) { animTakt.Tick += (s, a) => AnimSchritt(); animTakt.Tag = true; }
            animTakt.Start();
        }

        void AnimSchritt()
        {
            double t = Math.Min(1.0, (DateTime.Now - animStart).TotalMilliseconds / animMs);
            double k = animEaseIn ? t * t * t : 1 - Math.Pow(1 - t, 3);
            int L(int a, int b) => (int)Math.Round(a + (b - a) * k);
            SetBounds(L(animVon.X, animNach.X), L(animVon.Y, animNach.Y), L(animVon.Width, animNach.Width), L(animVon.Height, animNach.Height));
            OpacitySetzen(deckVon + (deckNach - deckVon) * k);
            if (t < 1.0) return;
            animTakt.Stop();
            animiert = false;
            var f = animFertig; animFertig = null;
            f?.Invoke();
        }

        /// <summary>Rechteck zur angedockten Kante hin verschoben (Anteil der Größe; 1 = ganz hinaus).</summary>
        Rectangle ZurKante(Rectangle r, double anteil)
        {
            int dx = (int)(r.Width * anteil), dy = (int)(r.Height * anteil);
            switch (einst.Andocken)
            {
                case 1: r.Offset(-dx, 0); break;
                case 2: r.Offset(dx, 0); break;
                case 3: r.Offset(0, -dy); break;
                case 4: r.Offset(0, dy); break;
            }
            return r;
        }

        void Ausklappen()
        {
            if (!eingeklappt || animiert) return;
            eingeklappt = false;
            rausSeit = null;
            letzteSignatur = "";
            Takt();                       // setzt den Rahmen auf den ganzen Kasten
            var ziel = Bounds;
            Animieren(ZurKante(ziel, 0.35), ziel, 0.15, ZielDeckkraft, 180, false, () => { letzteSignatur = ""; Takt(); });
        }

        void Einklappen()
        {
            if (!Klappbar || eingeklappt || animiert) return;
            var von = Bounds;
            Animieren(von, ZurKante(von, 0.35), Opacity, 0.0, 150, true, () =>
            {
                if (von.Contains(Cursor.Position)) // Maus inzwischen zurück: wieder hereingleiten
                {
                    Animieren(Bounds, von, Opacity, ZielDeckkraft, 120, false);
                    return;
                }
                eingeklappt = true;
                letzteSignatur = "";
                Takt();                   // setzt den Rahmen auf die Lasche
                var ziel = Bounds;
                Animieren(ZurKante(ziel, 1.0), ziel, 0.3, 1.0, 120, false);
            });
        }

        /// <summary>Einblenden (Start, Menü „Einblenden“).</summary>
        void Einblenden()
        {
            if (!Visible) { OpacitySetzen(0); Show(); }
            NachVorne();
            if (!animiert) Animieren(Bounds, Bounds, Opacity, ZielDeckkraft, 200, false);
        }

        /// <summary>Ausblenden (Menü „Ausblenden“); erreichbar bleibt die Lageuhr über das Uhr-Symbol.</summary>
        void Ausblenden()
        {
            if (animiert) return;
            Animieren(Bounds, Bounds, Opacity, 0.0, 180, true, () => { Hide(); OpacitySetzen(ZielDeckkraft); });
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Animieren(Bounds, Bounds, 0.0, ZielDeckkraft, 200, false); // sanft einblenden beim Start
            if (nachUpdate)
            {
                var t = new Timer { Interval = 1500 };
                t.Tick += (s, a) =>
                {
                    t.Stop(); t.Dispose();
                    try { tray.ShowBalloonTip(8000, "Lageuhr", "Lageuhr auf " + Aktualisierung.Text(update.EigeneVersion) + " aktualisiert", ToolTipIcon.Info); } catch { }
                };
                t.Start();
            }
        }

        /// <summary>Prüft im Takt, ob die Maus den ausgeklappten Kasten verlassen hat (1 s Nachlauf wie beim Mac-Dock).</summary>
        void EinklappenPruefen()
        {
            if (animiert) return;
            if (!Klappbar) { if (eingeklappt) Ausklappen(); return; }
            if (eingeklappt) { if (MausDrueber) Ausklappen(); return; }
            var drin = Rectangle.Inflate(Bounds, Px(4), Px(4)).Contains(Cursor.Position);
            if (drin || menue.Visible || (dialog != null && !dialog.IsDisposed) || skaliert || MouseButtons != MouseButtons.None)
                rausSeit = null;
            else if (rausSeit is DateTime r) { if ((DateTime.Now - r).TotalSeconds > 1.0) Einklappen(); }
            else rausSeit = DateTime.Now;
        }

        Rectangle DockBereich() =>
            Screen.FromPoint(new Point((einst.X ?? Left) + 1, (einst.Y ?? Top) + 1)).WorkingArea;

        void DockRahmenSetzen()
        {
            var b = DockBereich();
            int seite = einst.Andocken;
            var box = boxGroesse;
            var s = eingeklappt ? LaschenGroesse(seite) : box;
            int x, y;
            if (seite == 1 || seite == 2)
            {
                int oben = Math.Max(b.Top, Math.Min(b.Bottom - box.Height, einst.Y ?? b.Top));
                x = seite == 1 ? b.Left : b.Right - s.Width;
                y = eingeklappt ? oben + box.Height / 2 - s.Height / 2 : oben;
            }
            else
            {
                int links = Math.Max(b.Left, Math.Min(b.Right - box.Width, einst.X ?? b.Left));
                y = seite == 3 ? b.Top : b.Bottom - s.Height;
                x = eingeklappt ? links + box.Width / 2 - s.Width / 2 : links;
            }
            if (!animiert && Bounds != new Rectangle(x, y, s.Width, s.Height)) SetBounds(x, y, s.Width, s.Height); // während einer Animation nicht dazwischenfunken
            Invalidate();
        }

        /// <summary>Nach dem Verschieben: nah an einer Bildschirmkante andocken, sonst frei schweben.</summary>
        void NachVerschieben()
        {
            var b = Screen.FromControl(this).WorkingArea;
            var abstaende = new[] { (1, Left - b.Left), (2, b.Right - Right), (3, Top - b.Top), (4, b.Bottom - Bottom) };
            var naechste = abstaende.OrderBy(a => a.Item2).First();
            einst.X = Left; einst.Y = Top;
            einst.Andocken = naechste.Item2 <= Px(12) ? naechste.Item1 : 0;
            Geaendert();
        }

        void AndockenSetzen(int seite)
        {
            einst.X = Left; einst.Y = Top;
            einst.Andocken = seite;
            eingeklappt = false;
            rausSeit = null;
            Geaendert();
        }

        Font LaschenSchrift => anordnung.Schrift("Segoe UI", 10f, FontStyle.Bold);
        string LaschenText(int seite) => seite == 1 || seite == 2 ? laschenZeit.Replace(":", "\n") : laschenZeit;

        Size LaschenGroesse(int seite)
        {
            var t = Anordnung.Messen(LaschenText(seite), LaschenSchrift);
            return seite == 1 || seite == 2 ? new Size(t.Width + Px(16), t.Height + Px(30)) : new Size(t.Width + Px(38), t.Height + Px(12));
        }

        void LascheZeichnen(Graphics g)
        {
            int seite = einst.Andocken;
            bool blinkAn = Zeit.Jetzt.Millisecond < 500;
            Color grund = einst.Hintergrund, schrift = einst.Schriftfarbe;
            if (warnstufe == 2 && blinkAn) { grund = Color.FromArgb(211, 47, 47); schrift = Color.White; }
            if (warnstufe == 1) { grund = Color.FromArgb(255, 193, 7); schrift = Color.Black; }
            g.Clear(grund);
            var r = new Rectangle(0, 0, Width - 1, Height - 1); // Rand nur zur Bildschirmmitte hin
            using (var p = new Pen(Farben.Mischen(schrift, grund, 0.25)))
            {
                if (seite != 1) g.DrawLine(p, r.Left, r.Top, r.Left, r.Bottom);
                if (seite != 2) g.DrawLine(p, r.Right, r.Top, r.Right, r.Bottom);
                if (seite != 3) g.DrawLine(p, r.Left, r.Top, r.Right, r.Top);
                if (seite != 4) g.DrawLine(p, r.Left, r.Bottom, r.Right, r.Bottom);
            }
            string text = LaschenText(seite);
            var ts = Anordnung.Messen(text, LaschenSchrift);
            string pfeil = new[] { "", "›", "‹", "˅", "˄" }[Math.Max(0, Math.Min(4, seite))];
            var pf = anordnung.Schrift("Segoe UI", 12f, FontStyle.Bold);
            var ps = Anordnung.Messen(pfeil, pf);
            Color pfFarbe = Farben.Mischen(schrift, grund, 0.7);
            const TextFormatFlags mitte = TF | TextFormatFlags.HorizontalCenter;
            if (seite == 1 || seite == 2)
            {
                TextRenderer.DrawText(g, text, LaschenSchrift, new Rectangle(0, Px(7), Width, ts.Height), schrift, grund, mitte);
                TextRenderer.DrawText(g, pfeil, pf, new Rectangle(0, Height - ps.Height - Px(5), Width, ps.Height), pfFarbe, grund, mitte);
            }
            else
            {
                TextRenderer.DrawText(g, text, LaschenSchrift, new Point(Px(8), (Height - ts.Height) / 2), schrift, grund, TF);
                TextRenderer.DrawText(g, pfeil, pf, new Point(Width - ps.Width - Px(9), (Height - ps.Height) / 2), pfFarbe, grund, TF);
            }
        }

        // ---------- Fensterart ----------

        protected override bool ShowWithoutActivation => true;

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_TOPMOST; // nicht in Alt+Tab
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try { int rund = 2; DwmSetWindowAttribute(Handle, 33, ref rund, 4); } catch { } // runde Ecken unter Windows 11
            DurchklickSetzen(einst.Durchklickbar);
        }

        void DurchklickSetzen(bool an)
        {
            if (!IsHandleCreated) return;
            int ex = GetWindowLong(Handle, GWL_EXSTYLE);
            if (an)
            {
                SetWindowLong(Handle, GWL_EXSTYLE, ex | WS_EX_TRANSPARENT | WS_EX_LAYERED);
                SetLayeredWindowAttributes(Handle, 0, (byte)Math.Round(einst.Deckkraft * 2.55), LWA_ALPHA);
            }
            else if ((ex & WS_EX_TRANSPARENT) != 0)
            {
                SetWindowLong(Handle, GWL_EXSTYLE, ex & ~WS_EX_TRANSPARENT);
                if ((ex & WS_EX_LAYERED) != 0)
                    SetLayeredWindowAttributes(Handle, 0, (byte)Math.Round(einst.Deckkraft * 2.55), LWA_ALPHA);
            }
        }

        void NachVorne()
        {
            if (!Visible || menue.Visible || skaliert) return;
            SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        }

        // ---------- Menü ----------

        void MenueFuellen()
        {
            menue.Items.Clear();
            if (update.Verfuegbar != null && !update.Installiert)
            {
                var mUpdate = update.Laeuft
                    ? new ToolStripMenuItem("Update " + update.Verfuegbar.VersionText + ": " + update.Taetigkeit) { Enabled = false }
                    : new ToolStripMenuItem("Update auf " + update.Verfuegbar.VersionText + " installieren …", null, (s, a) => UpdateInstallieren());
                mUpdate.Font = new Font(mUpdate.Font, FontStyle.Bold);
                if (mUpdate.Enabled) mUpdate.ForeColor = Color.FromArgb(47, 122, 48);
                menue.Items.Add(mUpdate);
                menue.Items.Add(new ToolStripSeparator());
            }
            var mEinst = new ToolStripMenuItem("Einstellungen …", null, (s, a) => EinstellungenOeffnen());
            mEinst.Font = new Font(mEinst.Font, FontStyle.Bold);
            menue.Items.Add(mEinst);

            var seit = einst.Felder.Where(f => f.Art == FeldArt.Seit).ToList();
            var termine = einst.Felder.Where(f => f.Art == FeldArt.Termin).ToList();
            if (seit.Count + termine.Count > 0) menue.Items.Add(new ToolStripSeparator());
            foreach (var f in seit)
            {
                string id = f.Id;
                menue.Items.Add(f.Name + ": beginnt jetzt", null, (s, a) => SeitJetzt(id));
            }
            foreach (var f in termine)
            {
                string id = f.Id;
                var m = new ToolStripMenuItem(f.Name);
                foreach (int min in new[] { 15, 30, 45, 60, 90, 120, 180, 240 })
                {
                    string t = min < 60 ? min + " min" : min % 60 == 0 ? min / 60 + " h" : $"{min / 60}:{min % 60:00} h";
                    m.DropDownItems.Add("in " + t, null, (s, a) => FeldSetzen(id, x => { x.Zeit = Zeit.Runden5(Zeit.Jetzt.AddMinutes(min)); x.Sichtbar = true; }));
                }
                m.DropDownItems.Add(new ToolStripSeparator());
                m.DropDownItems.Add("Andere Zeit …", null, (s, a) => EinstellungenOeffnen(id));
                m.DropDownItems.Add("Keine", null, (s, a) => FeldSetzen(id, x => x.Zeit = null));
                menue.Items.Add(m);
            }
            menue.Items.Add(new ToolStripSeparator());

            menue.Items.Add("Schrift größer", null, (s, a) => SchriftAendern(+2));
            menue.Items.Add("Schrift kleiner", null, (s, a) => SchriftAendern(-2));
            menue.Items.Add(new ToolStripMenuItem("Position fixieren", null, (s, a) =>
            {
                einst.Fixiert = !einst.Fixiert; einst.Speichern(); Invalidate();
            }) { Checked = einst.Fixiert });
            menue.Items.Add(new ToolStripMenuItem("Durchklickbar (dann nur über das Uhr-Symbol unten rechts bedienbar)", null, (s, a) =>
            {
                einst.Durchklickbar = !einst.Durchklickbar; DurchklickSetzen(einst.Durchklickbar); einst.Speichern(); Invalidate();
            }) { Checked = einst.Durchklickbar });
            menue.Items.Add(Visible ? "Ausblenden" : "Einblenden", null, (s, a) => { if (Visible) Ausblenden(); else Einblenden(); });

            menue.Items.Add(new ToolStripSeparator());
            var dock = new ToolStripMenuItem("Andocken");
            string[] seiten = { "Nicht angedockt (frei)", "Links", "Rechts", "Oben", "Unten" };
            for (int i = 0; i < seiten.Length; i++)
            {
                int seite = i;
                dock.DropDownItems.Add(new ToolStripMenuItem(seiten[i], null, (s, a) => AndockenSetzen(seite)) { Checked = einst.Andocken == i });
            }
            menue.Items.Add(dock);
            menue.Items.Add(new ToolStripMenuItem("Angedockt automatisch einklappen", null, (s, a) =>
            {
                einst.Einklappen = !einst.Einklappen; Geaendert();
            }) { Checked = einst.Einklappen });
            menue.Items.Add(new ToolStripMenuItem("Unter der Maus voll deckend", null, (s, a) =>
            {
                einst.DeckendBeiMaus = !einst.DeckendBeiMaus; Geaendert();
            }) { Checked = einst.DeckendBeiMaus });

            menue.Items.Add(new ToolStripSeparator());
            menue.Items.Add("Vollbild-Lagebild jetzt (Taste oder Maus beendet)", null, (s, a) => VollbildZeigen());
            menue.Items.Add("Als Bildschirmschoner einrichten …", null, (s, a) => BildschirmschonerEinrichten());
            menue.Items.Add(new ToolStripSeparator());
            menue.Items.Add("Zeit jetzt mit Atomuhr abgleichen", null, (s, a) => ZeitAbgleichen(einst.Zeitserver));
            menue.Items.Add(new ToolStripMenuItem(zeitStatus) { Enabled = false });
            if (Abgleich.Eingerichtet(einst))
            {
                menue.Items.Add(new ToolStripSeparator());
                menue.Items.Add("Jetzt abgleichen", null, (s, a) => abgleich.Sofort());
                menue.Items.Add(new ToolStripMenuItem(abgleich.Status(einst)) { Enabled = false });
            }
            if (update.Verfuegbar == null && !update.Installiert)
            {
                menue.Items.Add(new ToolStripSeparator());
                if (update.Laeuft) menue.Items.Add(new ToolStripMenuItem("Suche nach Update …") { Enabled = false });
                else menue.Items.Add("Nach Update suchen", null, (s, a) => UpdateSuchen(true));
            }

            menue.Items.Add(new ToolStripSeparator());
            menue.Items.Add("Beenden", null, (s, a) => Close());
        }

        void FeldSetzen(string id, Action<Feld> aendern)
        {
            var f = einst.Felder.FirstOrDefault(x => x.Id == id);
            if (f == null) return;
            aendern(f);
            Geaendert();
        }

        void SeitJetzt(string id)
        {
            var f = einst.Felder.FirstOrDefault(x => x.Id == id);
            if (f == null) return;
            if (f.Zeit.HasValue)
            {
                var r = MessageBox.Show(this,
                    "„" + f.Name + "“ auf jetzt setzen?\n\nBisher: " + Zeit.Taktisch(f.Zeit.Value, einst.Monatsschreibweise),
                    "Lageuhr", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (r != DialogResult.Yes) return;
            }
            FeldSetzen(id, x => { x.Zeit = Zeit.Minute(Zeit.Jetzt); x.Sichtbar = true; });
        }

        void SchriftAendern(float delta)
        {
            einst.Schriftgroesse = Einstellungen.Begrenzen((float)Math.Round(einst.Schriftgroesse + delta));
            Geaendert();
        }

        void EinstellungenOeffnen(string feldId = null)
        {
            if (dialog == null || dialog.IsDisposed)
            {
                dialogBasis = einst.Kopie();
                dialog = new EinstellungenFenster(einst.Kopie(), Uebernehmen);
                dialog.FormClosed += (s, a) => { dialog = null; dialogBasis = null; };
                dialog.Abgleichen = (server, fertig) => ZeitAbgleichen(server, fertig);
                dialog.ZeitStatusZeigen(zeitStatus);
                dialog.AbgleichStatusZeigen(abgleich.StatusLang(einst));
                dialog.SchonerEinrichten = BildschirmschonerEinrichten;
                dialog.UpdateAktion = UpdateKnopf;
                dialog.Show();
                UpdateStatusZeigen();
            }
            if (feldId != null) dialog.Auswaehlen(feldId);
            dialog.Activate();
        }

        void Uebernehmen(Einstellungen neu)
        {
            var n = Abgleich.Zusammenfuehren(einst, dialogBasis, neu); // was inzwischen kam, bleibt erhalten
            n.X = einst.X; n.Y = einst.Y; n.Pfad = einst.Pfad;
            n.Fixiert = einst.Fixiert; n.Durchklickbar = einst.Durchklickbar;
            einst = n;
            BackColor = einst.Hintergrund;
            Geaendert();
            if (dialog != null && !dialog.IsDisposed) dialog.AbgleichStatusZeigen(abgleich.StatusLang(einst));
        }

        void Geaendert()
        {
            einst.Speichern();
            abgleich.Bald(); // eigene Änderung: nach 0,3 s an die anderen Arbeitsplätze
            if (!Klappbar) eingeklappt = false;
            letzteSignatur = "";
            Takt();
            DeckkraftSetzen();
        }

        // ---------- Takt und Inhalt ----------

        void Takt()
        {
            var jetzt = Zeit.Jetzt;

            // Atomuhr: beim Start, dann alle 30 Minuten (bei Fehler nach 2 Minuten erneut)
            if (einst.Atomuhr && !abgleichLaeuft && DateTime.Now >= naechsterAbgleich) ZeitAbgleichen();
            if (!einst.Atomuhr && Zeit.Versatz != 0) { Zeit.Versatz = 0; zeitStatus = "Atomuhr-Abgleich ist aus – es gilt die Rechnerzeit"; }

            // Lasche: Uhrzeit und Warnung bei bevorstehendem Termin
            laschenZeit = jetzt.ToString("HH:mm");
            warnstufe = 0;
            foreach (var f in einst.Felder.Where(x => x.Art == FeldArt.Termin && x.Sichtbar && x.Zeit.HasValue))
            {
                var rest = f.Zeit.Value - jetzt;
                if (rest.Ticks <= 0 && -rest.TotalMinutes < NachlaufMinuten) warnstufe = 2;
                else if (rest.Ticks > 0 && rest.TotalMinutes <= 10) warnstufe = Math.Max(warnstufe, 1);
            }
            if (IsHandleCreated) EinklappenPruefen();
            if (eingeklappt && warnstufe == 2) Invalidate(); // Lasche blinkt
            if (IsHandleCreated && einst.DeckendBeiMaus) DeckkraftSetzen();
            if (IsHandleCreated) VollbildPruefen(jetzt);

            // Wiederkehrende Termine: 5 Minuten nach Beginn auf den nächsten springen
            bool weiter = Lagebild.TermineWeiterschalten(einst, jetzt); // zieht die bekannte Signatur mit (keine Änderung)
            if (weiter) einst.Speichern();

            // Update: 30 s nach dem Start, dann täglich (nur suchen)
            if (einst.UpdateSuchen && IsHandleCreated && !update.Laeuft && !update.Installiert && DateTime.Now >= naechsteUpdateSuche) UpdateSuchen(false);

            // Abgleich: alle 3 s, nach eigener Änderung nach 0,3 s
            if (IsHandleCreated && abgleich.Faellig(einst)) AbgleichStarten();

            var neu = Lagebild.BloeckeBauen(einst, jetzt);
            if (abgleich.Warnung(einst) is string warnung) neu.Add(Lagebild.HinweisBlock(einst, warnung));
            string sig = Signatur(neu);
            if (sig != letzteSignatur)
            {
                letzteSignatur = sig;
                bloecke = neu;
                Anordnen();
                Invalidate();
            }

            if (++topmostZaehler >= 8) { topmostZaehler = 0; NachVorne(); }
        }

        string Signatur(List<Block> l)
        {
            var sb = new StringBuilder();
            sb.Append(einst.Schriftgroesse).Append(einst.Nebeneinander).Append(einst.Schriftfarbe.ToArgb()).Append(einst.Hintergrund.ToArgb())
              .Append('|').Append(einst.Andocken).Append(eingeklappt).Append(eingeklappt ? laschenZeit : "").Append(warnstufe);
            sb.Append(Lagebild.Signatur(l));
            return sb.ToString();
        }

        // ---------- Anordnung ----------

        static float dpiFaktor = -1;
        static int Px(double px)
        {
            if (dpiFaktor < 0)
                using (var g = Graphics.FromHwnd(IntPtr.Zero)) dpiFaktor = g.DpiX / 96f;
            return (int)Math.Round(px * dpiFaktor);
        }

        void Anordnen()
        {
            anordnung.Berechnen(bloecke, einst.Schriftgroesse, einst.Nebeneinander, einst.Hintergrund, einst.Schriftfarbe,
                "Keine Felder – Doppelklick für Einstellungen");
            GroesseSetzen(anordnung.Groesse);
        }

        void GroesseSetzen(Size neu)
        {
            boxGroesse = neu;
            if (Angedockt) { DockRahmenSetzen(); return; }
            if (neu == Size) return;
            if (!IsHandleCreated || skaliert) { Size = neu; return; } // beim Ziehen bleibt die Ecke oben links stehen
            var wa = Screen.FromControl(this).WorkingArea;
            bool rechts = Left + Width / 2 > wa.Left + wa.Width / 2;
            bool unten = Top + Height / 2 > wa.Top + wa.Height / 2;
            int x = rechts ? Right - neu.Width : Left;
            int y = unten ? Bottom - neu.Height : Top;
            SetBounds(x, y, neu.Width, neu.Height);
        }

        void PositionSetzen()
        {
            if (Angedockt) { DockRahmenSetzen(); return; }
            if (einst.X is int x && einst.Y is int y)
            {
                var r = new Rectangle(x, y, Width, Height);
                bool sichtbar = Screen.AllScreens.Any(s =>
                {
                    var i = Rectangle.Intersect(s.WorkingArea, r);
                    return i.Width >= Px(40) && i.Height >= Px(30);
                });
                if (sichtbar) { Location = new Point(x, y); return; }
            }
            var wa = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(wa.Right - Width - Px(20), wa.Top + Px(20));
        }

        // ---------- Zeichnen ----------

        int GriffGroesse => Px(16);
        Rectangle GriffVerschieben => new Rectangle(0, 0, GriffGroesse + Px(4), GriffGroesse + Px(4));
        Rectangle GriffGroesseAendern => new Rectangle(Width - GriffGroesse - Px(4), Height - GriffGroesse - Px(4), GriffGroesse + Px(4), GriffGroesse + Px(4));
        bool GriffeZeigen => !einst.Fixiert && (mausDrin || skaliert);

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            if (eingeklappt) { LascheZeichnen(g); return; }
            g.Clear(einst.Hintergrund);
            Color linie = Farben.Mischen(einst.Schriftfarbe, einst.Hintergrund, 0.22);
            using (var p = new Pen(linie)) g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);

            anordnung.Zeichnen(g, Point.Empty, linie, Px(6));

            if (GriffeZeigen)
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (var br = new SolidBrush(Farben.Mischen(einst.Schriftfarbe, einst.Hintergrund, 0.55)))
                {
                    int d = Math.Max(2, Px(3)), a = Px(5), o = Px(4);
                    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) // oben links: verschieben
                        g.FillEllipse(br, o + i * a, o + j * a, d, d);
                    int bx = Width - o - d, by = Height - o - d;              // unten rechts: Größe
                    for (int i = 0; i < 3; i++) for (int j = 0; j <= i; j++)
                        g.FillEllipse(br, bx - (i - j) * a, by - j * a, d, d);
                }
            }
        }

        // ---------- Maus ----------

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (eingeklappt) { Cursor = Cursors.Hand; return; }
            if (!mausDrin) { mausDrin = true; Invalidate(); }
            if (skaliert)
            {
                int dx = Cursor.Position.X - skalStart.X;
                float pt = Einstellungen.Begrenzen((float)Math.Round(skalPunkt * (skalBreite + dx) / (float)skalBreite * 2) / 2f);
                if (pt != einst.Schriftgroesse) { einst.Schriftgroesse = pt; letzteSignatur = ""; Takt(); }
                return;
            }
            if (einst.Fixiert) Cursor = Cursors.Default;
            else if (GriffVerschieben.Contains(e.Location)) Cursor = Cursors.SizeAll;
            else if (GriffGroesseAendern.Contains(e.Location)) Cursor = Cursors.SizeNWSE;
            else Cursor = Cursors.Default;
        }

        protected override void OnMouseEnter(EventArgs e)
        {
            base.OnMouseEnter(e);
            rausSeit = null;
            if (eingeklappt) Ausklappen();
            DeckkraftSetzen();
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (!skaliert && !ClientRectangle.Contains(PointToClient(Cursor.Position))) { mausDrin = false; Invalidate(); }
            DeckkraftSetzen();
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (eingeklappt) { Ausklappen(); return; }
            if (e.Button != MouseButtons.Left || einst.Fixiert) return;
            if (GriffVerschieben.Contains(e.Location))
            {
                ReleaseCapture();
                SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero); // Windows schiebt das Fenster
            }
            else if (GriffGroesseAendern.Contains(e.Location))
            {
                skaliert = true; skalStart = Cursor.Position; skalBreite = Width; skalPunkt = einst.Schriftgroesse;
                Capture = true;
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (skaliert) { skaliert = false; Capture = false; einst.Speichern(); Invalidate(); }
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e)
        {
            base.OnMouseDoubleClick(e);
            if (e.Button == MouseButtons.Left) EinstellungenOeffnen();
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            if (!eingeklappt) SchriftAendern(e.Delta > 0 ? 1 : -1);
        }

        protected override void OnResizeEnd(EventArgs e) // nach dem Verschieben am Griff
        {
            base.OnResizeEnd(e);
            NachVerschieben();
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_NCLBUTTONDBLCLK) { EinstellungenOeffnen(); return; } // Doppelklick auf den Griff
            base.WndProc(ref m);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!Angedockt) { einst.X = Left; einst.Y = Top; } // angedockt bleibt die gemerkte Stelle an der Kante
            einst.Speichern();
            Microsoft.Win32.SystemEvents.PowerModeChanged -= Energiemodus;
            VollbildBeenden();
            if (wachGehalten) SetThreadExecutionState(ES_CONTINUOUS);
            takt.Stop();
            tray.Visible = false;
            tray.Dispose();
            base.OnFormClosing(e);
        }

        // ---------- Vollbild-Lagebild ----------

        /// <summary>Sekunden seit der letzten Eingabe (Maus, Tastatur) im ganzen System.</summary>
        static double Leerlauf
        {
            get
            {
                var i = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
                return GetLastInputInfo(ref i) ? unchecked((uint)Environment.TickCount - i.dwTime) / 1000.0 : 0;
            }
        }

        /// <summary>Im Takt: Vollbild nach Leerlauf zeigen oder laufendes Vollbild aktualisieren.</summary>
        void VollbildPruefen(DateTime jetzt)
        {
            bool halten = einst.VollbildNachMin > 0; // solange an: Bildschirm bleibt an
            if (halten != wachGehalten && !VollbildAktiv)
            {
                SetThreadExecutionState(halten ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED : ES_CONTINUOUS);
                wachGehalten = halten;
            }
            if (VollbildAktiv) { foreach (var v in vollbild) v.Aktualisieren(einst, jetzt); return; }
            if (!halten || (dialog != null && !dialog.IsDisposed) || menue.Visible) return;
            double grenze = einst.VollbildNachMin * 60.0;
            // vor dem Windows-Bildschirmschoner da sein, sonst würde er zuerst starten
            int aktiv = 0, warten = 0;
            if (SystemParametersInfo(SPI_GETSCREENSAVEACTIVE, 0, ref aktiv, 0) && aktiv != 0 &&
                SystemParametersInfo(SPI_GETSCREENSAVETIMEOUT, 0, ref warten, 0) && warten > 20)
                grenze = Math.Min(grenze, warten - 10);
            if (Leerlauf >= grenze) VollbildZeigen();
        }

        void VollbildZeigen()
        {
            if (VollbildAktiv) return;
            var schirme = einst.VollbildAlle ? Screen.AllScreens : new[] { Screen.FromControl(this) };
            foreach (var sc in schirme)
            {
                var v = new VollbildFenster(sc, einst) { Opacity = 0 };
                v.Beenden += () => BeginInvoke((Action)VollbildBeenden);
                v.Show();
                v.Aktualisieren(einst, Zeit.Jetzt);
                vollbild.Add(v);
            }
            vollbild[0].Activate();
            Cursor.Hide();
            // Windows-Bildschirmschoner solange aussetzen (nur in dieser Sitzung, nichts wird gespeichert)
            int aktiv = 0;
            if (SystemParametersInfo(SPI_GETSCREENSAVEACTIVE, 0, ref aktiv, 0) && aktiv != 0)
            {
                SystemParametersInfoSetzen(SPI_SETSCREENSAVEACTIVE, 0, IntPtr.Zero, 0);
                schonerAusgesetzt = true;
            }
            SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
            // sanft einblenden
            var start = DateTime.Now;
            var t = new Timer { Interval = 15 };
            t.Tick += (s, a) =>
            {
                double k = Math.Min(1, (DateTime.Now - start).TotalMilliseconds / 400);
                foreach (var v in vollbild) v.Opacity = k;
                if (k >= 1 || !VollbildAktiv) { t.Stop(); t.Dispose(); }
            };
            t.Start();
        }

        void VollbildBeenden()
        {
            if (!VollbildAktiv) return;
            var liste = vollbild.ToList();
            vollbild.Clear();
            foreach (var v in liste) { v.Close(); v.Dispose(); }
            Cursor.Show();
            if (schonerAusgesetzt) { SystemParametersInfoSetzen(SPI_SETSCREENSAVEACTIVE, 1, IntPtr.Zero, 0); schonerAusgesetzt = false; }
            SetThreadExecutionState(einst.VollbildNachMin > 0 ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED : ES_CONTINUOUS);
            wachGehalten = einst.VollbildNachMin > 0;
        }

        // ---------- Update ----------

        IWin32Window Besitzer => dialog != null && !dialog.IsDisposed ? (IWin32Window)dialog : this;

        void NachUi(Action a)
        {
            try { if (!IsDisposed && IsHandleCreated) BeginInvoke(a); } catch { }
        }

        /// <summary>Im Hintergrund suchen; <paramref name="melden"/>: Ergebnis als Meldung (sonst nur Status im Menü und in den Einstellungen).</summary>
        void UpdateSuchen(bool melden)
        {
            if (update.Installiert) return;
            if (melden) updateMelden = true;
            update.SucheStarten(() => NachUi(() =>
            {
                naechsteUpdateSuche = DateTime.Now.Add(update.Fehler != null ? TimeSpan.FromHours(2) : TimeSpan.FromHours(24));
                UpdateStatusZeigen();
                if (!updateMelden) return;
                updateMelden = false;
                if (update.Verfuegbar != null) UpdateInstallieren();
                else if (update.Fehler != null)
                    MessageBox.Show(Besitzer, "Nach Update suchen hat nicht geklappt:\n" + update.Fehler, "Lageuhr", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                else
                    MessageBox.Show(Besitzer, "Die Lageuhr ist aktuell (" + Aktualisierung.Text(update.EigeneVersion) + ").", "Lageuhr", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }));
            UpdateStatusZeigen();
        }

        /// <summary>Nachfragen, installieren, neu starten. <paramref name="vorher"/> läuft vor dem Neustart (Einstellungsfenster: übernehmen).</summary>
        void UpdateInstallieren(Action vorher = null)
        {
            var info = update.Verfuegbar;
            if (info == null || update.Laeuft || update.Installiert) return;
            if (update.Schreibgeschuetzt) { SchreibgeschuetztMelden(); return; }
            var sb = new StringBuilder("Lageuhr " + info.VersionText + " ist da.");
            if (info.Neu.Count > 0)
            {
                sb.Append("\n\nNeu:");
                foreach (var n in info.Neu.Take(15)) sb.Append("\n• ").Append(n);
            }
            sb.Append("\n\nJetzt installieren? Die Lageuhr startet danach neu; Felder und Einstellungen bleiben.");
            if (MessageBox.Show(Besitzer, sb.ToString(), "Lageuhr – Update", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;

            // als Bildschirmschoner eingerichtet (auch an anderer Stelle): mit ersetzen
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop"))
                    if (k?.GetValue("SCRNSAVE.EXE") is string scr &&
                        string.Equals(Path.GetFileName(scr), "Lageuhr.scr", StringComparison.OrdinalIgnoreCase) && !update.SchonerPfade.Contains(scr))
                        update.SchonerPfade.Add(scr);
            }
            catch { }

            update.InstallationStarten(info, (hinweise, fehler) => NachUi(() =>
            {
                UpdateStatusZeigen();
                if (fehler != null)
                {
                    if (fehler.Schreibgeschuetzt) SchreibgeschuetztMelden();
                    else MessageBox.Show(Besitzer, "Das Update hat nicht geklappt:\n" + fehler.Message + "\n\nDie Lageuhr läuft unverändert weiter.",
                        "Lageuhr – Update", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                if (hinweise != null && hinweise.Count > 0)
                    MessageBox.Show(Besitzer, "Update installiert. Hinweis:\n" + string.Join("\n", hinweise), "Lageuhr – Update", MessageBoxButtons.OK, MessageBoxIcon.Information);
                try { vorher?.Invoke(); } catch { }
                Neustarten();
            }));
            UpdateStatusZeigen();
        }

        void SchreibgeschuetztMelden()
        {
            var r = MessageBox.Show(Besitzer, "Die Lageuhr liegt in einem schreibgeschützten Ordner und kann sich nicht selbst aktualisieren:\n" +
                Path.GetDirectoryName(update.ExePfad) + "\n\nDie neue Fassung gibt es auf der Download-Seite; die Lageuhr.exe dort ersetzen " +
                "(oder die IT bitten).\n\nDownload-Seite jetzt öffnen?", "Lageuhr – Update", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (r == DialogResult.Yes) DownloadSeiteOeffnen();
        }

        void DownloadSeiteOeffnen()
        {
            try { Process.Start(new ProcessStartInfo(Aktualisierung.DownloadSeite) { UseShellExecute = true }); }
            catch (Exception ex) { MessageBox.Show(Besitzer, "Browser lässt sich nicht öffnen:\n" + ex.Message + "\n\n" + Aktualisierung.DownloadSeite, "Lageuhr"); }
        }

        /// <summary>Knopf im Einstellungsfenster: suchen, installieren oder Download-Seite – je nach Stand.</summary>
        void UpdateKnopf(Action vorher)
        {
            if (update.Laeuft || update.Installiert) return;
            if (update.Verfuegbar != null && update.Schreibgeschuetzt) DownloadSeiteOeffnen();
            else if (update.Verfuegbar != null) UpdateInstallieren(vorher);
            else UpdateSuchen(false);
        }

        void UpdateStatusZeigen()
        {
            if (dialog == null || dialog.IsDisposed) return;
            string knopf = update.Verfuegbar != null && update.Schreibgeschuetzt ? "Download-Seite …"
                : update.Verfuegbar != null ? "Installieren …" : "Jetzt suchen";
            dialog.UpdateStatusZeigen(update.Status(), knopf, !update.Laeuft && !update.Installiert);
        }

        /// <summary>Neue Fassung mit --nach-update starten und sich beenden (sie wartet, bis diese beendet ist).</summary>
        void Neustarten()
        {
            if (!Angedockt) { einst.X = Left; einst.Y = Top; }
            einst.Speichern();
            try
            {
                Process.Start(new ProcessStartInfo(update.ExePfad, "--nach-update")
                {
                    UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(update.ExePfad)
                });
            }
            catch (Exception ex)
            {
                MessageBox.Show(Besitzer, "Das Update ist installiert, aber die Lageuhr startet nicht von selbst neu:\n" + ex.Message +
                    "\n\nBitte die Lageuhr neu starten.", "Lageuhr – Update", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            if (dialog != null && !dialog.IsDisposed) dialog.Close();
            Close();
        }

        // ---------- Bildschirmschoner einrichten ----------

        /// <summary>Kopiert sich als Lageuhr.scr und richtet sie als Bildschirmschoner dieses Kontos ein (keine Adminrechte nötig).</summary>
        void BildschirmschonerEinrichten()
        {
            using (var pol = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Policies\Microsoft\Windows\Control Panel\Desktop"))
            {
                if (pol?.GetValue("SCRNSAVE.EXE") != null)
                {
                    MessageBox.Show("Der Bildschirmschoner ist auf diesem Rechner von der IT fest vorgegeben und lässt sich nicht ändern.\n\n" +
                        "Stattdessen kann die Lageuhr selbst nach einer Wartezeit das Vollbild-Lagebild zeigen (Einstellungen → Vollbild).",
                        "Lageuhr", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
            }
            string exe = Application.ExecutablePath;
            string ziel = Path.Combine(Path.GetDirectoryName(exe), "Lageuhr.scr");
            try { File.Copy(exe, ziel, true); }
            catch
            {
                ziel = Path.Combine(Path.GetDirectoryName(Lagebild.DatenPfad), "Lageuhr.scr");
                try { Directory.CreateDirectory(Path.GetDirectoryName(ziel)); File.Copy(exe, ziel, true); }
                catch (Exception ex) { MessageBox.Show("Einrichten hat nicht geklappt:\n" + ex.Message, "Lageuhr"); return; }
            }
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop", true))
                {
                    k.SetValue("SCRNSAVE.EXE", ziel);
                    k.SetValue("ScreenSaveActive", "1");
                }
                SystemParametersInfoSetzen(SPI_SETSCREENSAVEACTIVE, 1, IntPtr.Zero, SPIF_SENDCHANGE);
            }
            catch (Exception ex) { MessageBox.Show("Einrichten hat nicht geklappt:\n" + ex.Message, "Lageuhr"); return; }
            Lagebild.Schreiben(einst);
            var r = MessageBox.Show("Die Lageuhr ist jetzt Ihr Bildschirmschoner. Sie zeigt die Felder groß auf dem Bildschirm; " +
                "die Bildschirmsperre bleibt wie eingestellt (nach Maus oder Taste kommt die Anmeldung).\n\n" +
                "Wartezeit und „Anmeldeseite bei Reaktivierung“ jetzt in den Bildschirmschoner-Einstellungen prüfen?",
                "Lageuhr", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (r == DialogResult.Yes)
                try { System.Diagnostics.Process.Start("control.exe", "desk.cpl,,@screensaver"); } catch { }
        }

        // ---------- Windows ----------

        [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO i);
        [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
        [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint aktion, uint p, ref int wert, uint w);
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfo")] static extern bool SystemParametersInfoSetzen(uint aktion, uint p, IntPtr wert, uint w);
        const uint SPI_GETSCREENSAVETIMEOUT = 0x0E, SPI_GETSCREENSAVEACTIVE = 0x10, SPI_SETSCREENSAVEACTIVE = 0x11, SPIF_SENDCHANGE = 0x2;
        const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x1, ES_DISPLAY_REQUIRED = 0x2;

        const int GWL_EXSTYLE = -20;
        const int WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_TOPMOST = 0x8, WS_EX_LAYERED = 0x80000;
        const uint LWA_ALPHA = 0x2;
        const int WM_NCLBUTTONDOWN = 0xA1, WM_NCLBUTTONDBLCLK = 0xA3, HTCAPTION = 2;
        static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_NOOWNERZORDER = 0x200;

        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
        [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    }
}
