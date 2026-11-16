using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;

namespace Lageuhr
{
    /// <summary>Fenster „Einstellungen“: links die Felder und der ganze Kasten, rechts das ausgewählte Feld.</summary>
    public class EinstellungenFenster : Form
    {
        readonly Einstellungen e;
        readonly Action<Einstellungen> uebernehmen;
        bool laedt;

        // Felderliste
        ListBox liste;
        Button btNeu, btKopie, btEntfernen, btHoch, btRunter;
        ContextMenuStrip neuMenue;

        // ausgewähltes Feld
        GroupBox gbFeld;
        TableLayoutPanel tFeld;
        Label lbArt, lbTaktisch;
        TextBox tbTitel, tbText;
        CheckBox cbSichtbar, cbSek, cbEigeneSchrift, cbEigenerGrund;
        DateTimePicker dtZeit;
        NumericUpDown nIntervall, nGroesse;
        Button btFeldSchrift, btFeldGrund, btJetzt;
        FlowLayoutPanel reiheSchnell;
        Color feldSchrift = Color.White, feldGrund = Color.FromArgb(183, 28, 28);
        readonly Dictionary<string, Control[]> zeilen = new Dictionary<string, Control[]>();

        // ganzer Kasten
        NumericUpDown nSchrift, nDeckkraft;
        ComboBox cbAnordnung, cbMonat;
        Button btHintergrund, btSchriftfarbe;
        Color hintergrund, schriftfarbe;
        CheckBox cbDeckend;

        // Andocken und Atomuhr
        ComboBox cbAndocken;
        CheckBox cbEinklappen, cbAtomuhr;
        TextBox tbServer;
        Label lbZeitStatus;
        /// <summary>Abgleich auslösen: Server, Rückmeldung mit dem Ergebnis.</summary>
        public Action<string, Action<string>> Abgleichen;
        /// <summary>Lageuhr als Windows-Bildschirmschoner einrichten.</summary>
        public Action SchonerEinrichten;
        ComboBox cbVollbild;
        CheckBox cbVollbildAlle;
        static readonly int[] VollbildMinuten = { 0, 2, 5, 10, 15, 20, 30, 45, 60 };
        public void ZeitStatusZeigen(string t) { if (lbZeitStatus != null) lbZeitStatus.Text = t; }

        static int Px(double px)
        {
            using (var g = Graphics.FromHwnd(IntPtr.Zero)) return (int)Math.Round(px * g.DpiX / 96f);
        }

        public EinstellungenFenster(Einstellungen e, Action<Einstellungen> uebernehmen)
        {
            this.e = e;
            this.uebernehmen = uebernehmen;
            hintergrund = e.Hintergrund;
            schriftfarbe = e.Schriftfarbe;

            Text = "Lageuhr – Einstellungen";
            Font = SystemFonts.MessageBoxFont;
            AutoScaleMode = AutoScaleMode.None;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            var haupt = new TableLayoutPanel { ColumnCount = 2, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(Px(10)) };
            Controls.Add(haupt);
            var links = Spalte(haupt);
            var rechts = Spalte(haupt);

            // ---------- Felder ----------
            var g = Gruppe(links, "Felder (von oben nach unten)");
            liste = new ListBox
            {
                DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = Px(24), Width = Px(300), Height = Px(24) * 9 + Px(4),
                IntegralHeight = false
            };
            liste.DrawItem += ListeZeichnen;
            liste.SelectedIndexChanged += (s, a) => FeldZeigen();
            Ganz(g, liste);

            neuMenue = new ContextMenuStrip();
            foreach (FeldArt art in Enum.GetValues(typeof(FeldArt)))
            {
                var a2 = art;
                neuMenue.Items.Add(Feld.ArtName(art), null, (s, a) => NeuesFeld(a2));
            }
            btNeu = Knopf("Neues Feld ▾", (s, a) => neuMenue.Show(btNeu, new Point(0, btNeu.Height)));
            btKopie = Knopf("Kopieren", (s, a) => Kopieren());
            btEntfernen = Knopf("Entfernen", (s, a) => Entfernen());
            btHoch = Knopf("▲", (s, a) => Verschieben(-1));
            btRunter = Knopf("▼", (s, a) => Verschieben(1));
            Ganz(g, Reihe(btNeu, btKopie, btEntfernen, btHoch, btRunter));

            // ---------- ganzer Kasten ----------
            g = Gruppe(links, "Ganzer Kasten");
            nSchrift = Zahl(8, 150, (decimal)e.Schriftgroesse, 1);
            nSchrift.DecimalPlaces = 1;
            Zeile(g, "Schriftgröße", Reihe(nSchrift, Hinweis("pt  (auch: Mausrad)")));
            btSchriftfarbe = Knopf("", (s, a) => { if (FarbeWaehlen(ref schriftfarbe)) FarbknopfZeigen(btSchriftfarbe, schriftfarbe, "Schrift"); });
            btHintergrund = Knopf("", (s, a) => { if (FarbeWaehlen(ref hintergrund)) FarbknopfZeigen(btHintergrund, hintergrund, "Hintergrund"); liste.Invalidate(); });
            Zeile(g, "Farben", Reihe(btSchriftfarbe, btHintergrund));
            Zeile(g, "", Reihe(
                Knopf("Dunkel", (s, a) => KastenVorlage(Einstellungen.StandardHintergrund, Color.White)),
                Knopf("Hell", (s, a) => KastenVorlage(Color.White, Color.FromArgb(30, 30, 30)))));
            nDeckkraft = Zahl(30, 100, e.Deckkraft, 5);
            Zeile(g, "Deckkraft", Reihe(nDeckkraft, Hinweis("%")));
            cbAnordnung = Auswahl(new[] { "untereinander", "nebeneinander (Leiste)" }, e.Nebeneinander ? 1 : 0);
            Zeile(g, "Anordnung", cbAnordnung);
            var bsp = new DateTime(2026, 11, 16, 14, 32, 0);
            cbMonat = Auswahl(new[] { Zeit.Taktisch(bsp, 0), Zeit.Taktisch(bsp, 1), Zeit.Taktisch(bsp, 2) }, e.Monatsschreibweise);
            cbMonat.SelectedIndexChanged += (s, a) => Hinweise();
            Zeile(g, "Taktische Zeit", cbMonat);
            cbDeckend = Haken("unter der Maus voll deckend");
            cbDeckend.Checked = e.DeckendBeiMaus;
            Ganz(g, cbDeckend);
            FarbknopfZeigen(btSchriftfarbe, schriftfarbe, "Schrift");
            FarbknopfZeigen(btHintergrund, hintergrund, "Hintergrund");

            // ---------- ausgewähltes Feld ----------
            tFeld = Gruppe(rechts, "Ausgewähltes Feld");
            gbFeld = (GroupBox)tFeld.Parent;
            gbFeld.MinimumSize = new Size(Px(470), Px(400));

            lbArt = new Label { AutoSize = true, Font = new Font(Font, FontStyle.Bold), Margin = new Padding(0, Px(4), 0, Px(4)) };
            FeldZeile("art", "Art", lbArt);
            tbTitel = new TextBox { Width = Px(220) };
            cbSichtbar = Haken("anzeigen");
            FeldZeile("titel", "Beschriftung", Reihe(tbTitel, cbSichtbar));
            tbText = new TextBox { Multiline = true, AcceptsReturn = true, ScrollBars = ScrollBars.Vertical, Width = Px(300), Height = Px(56) };
            FeldZeile("text", "Text", tbText);
            dtZeit = new DateTimePicker { Format = DateTimePickerFormat.Custom, CustomFormat = "dd.MM.yyyy   HH:mm", ShowCheckBox = true, Width = Px(190) };
            FeldZeile("zeit", "Zeitpunkt", dtZeit);
            btJetzt = Knopf("Jetzt", (s, a) => Schnell(0));
            reiheSchnell = Reihe(btJetzt, Knopf("in 30 min", (s, a) => Schnell(30)), Knopf("in 1 h", (s, a) => Schnell(60)), Knopf("in 2 h", (s, a) => Schnell(120)));
            FeldZeile("schnell", "", reiheSchnell);
            lbTaktisch = Hinweis();
            FeldZeile("taktisch", "", lbTaktisch);
            nIntervall = Zahl(0, 1440, 0, 15);
            FeldZeile("intervall", "Wiederholen alle", Reihe(nIntervall, Hinweis("Minuten (0 = einmalig)")));
            cbSek = Haken("zusätzlich mit Sekunden (14:32:07)");
            FeldZeile("sekunden", "", cbSek);
            nGroesse = Zahl(30, 300, 100, 10);
            FeldZeile("groesse", "Größe", Reihe(nGroesse, Hinweis("% der Schriftgröße")));
            cbEigeneSchrift = Haken("eigene");
            btFeldSchrift = Knopf("", (s, a) => { if (FarbeWaehlen(ref feldSchrift)) { cbEigeneSchrift.Checked = true; FeldFarbenZeigen(); FeldLesen(); } });
            FeldZeile("schrift", "Schriftfarbe", Reihe(cbEigeneSchrift, btFeldSchrift));
            cbEigenerGrund = Haken("eigener");
            btFeldGrund = Knopf("", (s, a) => { if (FarbeWaehlen(ref feldGrund)) { cbEigenerGrund.Checked = true; FeldFarbenZeigen(); FeldLesen(); } });
            FeldZeile("grund", "Hintergrund", Reihe(cbEigenerGrund, btFeldGrund));
            var vorlagen = new FlowLayoutPanel { AutoSize = true, MaximumSize = new Size(Px(330), 0), Margin = new Padding(0) };
            for (int i = 0; i < Einstellungen.FeldVorlagen.Length; i++)
            {
                var v = Einstellungen.FeldVorlagen[i];
                var b = Knopf(v.Name, (s, a) => FeldVorlage(v.Grund, v.Schrift));
                b.MinimumSize = new Size(Px(74), 0);
                if (v.Grund.HasValue)
                {
                    b.UseVisualStyleBackColor = false;
                    b.FlatStyle = FlatStyle.Flat;
                    b.BackColor = v.Grund.Value;
                    b.ForeColor = v.Schrift ?? Color.White;
                    b.FlatAppearance.BorderColor = SystemColors.ControlDark;
                }
                vorlagen.Controls.Add(b);
            }
            FeldZeile("vorlagen", "Farbvorlage", vorlagen);

            foreach (var c in new Control[] { cbSichtbar, cbSek, cbEigeneSchrift, cbEigenerGrund })
                ((CheckBox)c).CheckedChanged += (s, a) => { FeldFarbenZeigen(); FeldLesen(); };
            tbTitel.TextChanged += (s, a) => FeldLesen();
            tbText.TextChanged += (s, a) => FeldLesen();
            dtZeit.ValueChanged += (s, a) => FeldLesen();
            nIntervall.ValueChanged += (s, a) => FeldLesen();
            nGroesse.ValueChanged += (s, a) => FeldLesen();

            // ---------- Andocken und Atomuhr ----------
            g = Gruppe(rechts, "Andocken, Atomuhr, Vollbild");
            cbAndocken = Auswahl(new[] { "nicht angedockt (frei)", "links", "rechts", "oben", "unten" }, e.Andocken);
            cbAndocken.Width = Px(160);
            cbEinklappen = Haken("automatisch einklappen");
            cbEinklappen.Checked = e.Einklappen;
            Zeile(g, "Andocken", Reihe(cbAndocken, cbEinklappen));
            Zeile(g, "", Hinweis("Oder am Griff an eine Bildschirmkante ziehen; wegziehen löst ihn.", Px(340)));
            cbAtomuhr = Haken("Zeit mit Atomuhr abgleichen (Start, alle 30 min)");
            cbAtomuhr.Checked = e.Atomuhr;
            var btAbgleichen = Knopf("Jetzt abgleichen", (s, a) =>
            {
                lbZeitStatus.Text = "Gleiche ab …";
                string sv = string.IsNullOrWhiteSpace(tbServer.Text) ? Atomuhr.StandardServer : tbServer.Text.Trim();
                Abgleichen?.Invoke(sv, t => { if (!IsDisposed) lbZeitStatus.Text = t; });
            });
            Zeile(g, "Atomuhr", Reihe(cbAtomuhr, btAbgleichen));
            tbServer = new TextBox { Text = e.Zeitserver, Width = Px(330) };
            Zeile(g, "Zeitserver", tbServer);
            lbZeitStatus = Hinweis("", Px(340));
            Zeile(g, "", lbZeitStatus);
            cbVollbild = Auswahl(VollbildMinuten.Select(m => m == 0 ? "aus" : "nach " + m + " min ohne Eingabe").ToArray(),
                Math.Max(0, Array.IndexOf(VollbildMinuten, e.VollbildNachMin)));
            cbVollbildAlle = Haken("auf allen Bildschirmen");
            cbVollbildAlle.Checked = e.VollbildAlle;
            Zeile(g, "Vollbild", Reihe(cbVollbild, cbVollbildAlle));
            Zeile(g, "", Hinweis("Statt Bildschirmschoner: Lagebild groß nach dieser Zeit ohne Eingabe. Solange an, startet kein " +
                "Bildschirmschoner und der Rechner sperrt sich nicht von selbst.", Px(340)));
            Zeile(g, "Bildschirmschoner", Reihe(Knopf("Als Bildschirmschoner einrichten …", (s, a) => SchonerEinrichten?.Invoke()),
                Hinweis("Sperre bleibt aktiv")));

            g = Gruppe(rechts, "Bedienung");
            Ganz(g, Hinweis(
                "Verschieben: am Griff oben links ziehen · Größe: am Griff unten rechts ziehen oder Mausrad · " +
                "Menü: Rechtsklick auf den Kasten oder das Uhr-Symbol unten rechts in der Taskleiste · Einstellungen: Doppelklick.\n" +
                "Gespeichert in: " + e.Pfad, Px(450)));

            // ---------- Knöpfe ----------
            var knoepfe = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, Px(6), 0, 0) };
            var btAbbrechen = Knopf("Abbrechen", (s, a) => Close());
            var btUebernehmen = Knopf("Übernehmen", (s, a) => Anwenden());
            var btOk = Knopf("OK", (s, a) => { Anwenden(); Close(); });
            foreach (var b in new[] { btAbbrechen, btUebernehmen, btOk }) { b.MinimumSize = new Size(Px(90), 0); knoepfe.Controls.Add(b); }
            haupt.Controls.Add(knoepfe);
            haupt.SetColumnSpan(knoepfe, 2);
            CancelButton = btAbbrechen;

            ListeFuellen();
            if (e.Felder.Count > 0) liste.SelectedIndex = 0; else FeldZeigen();
        }

        // ---------- Liste ----------

        void ListeFuellen()
        {
            liste.BeginUpdate();
            liste.Items.Clear();
            foreach (var f in e.Felder) liste.Items.Add(f);
            liste.EndUpdate();
        }

        void ListeZeichnen(object sender, DrawItemEventArgs a)
        {
            a.DrawBackground();
            if (a.Index < 0 || a.Index >= e.Felder.Count) return;
            var f = e.Felder[a.Index];
            bool gewaehlt = (a.State & DrawItemState.Selected) != 0;
            var g = a.Graphics;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            int d = Px(12), x = a.Bounds.Left + Px(6), y = a.Bounds.Top + (a.Bounds.Height - d) / 2;
            // gefüllter Punkt = eigener Hintergrund, hohler Kreis = wie der Kasten
            if (f.Hintergrund.HasValue)
            {
                using (var br = new SolidBrush(f.Hintergrund.Value)) g.FillEllipse(br, x, y, d, d);
                using (var p = new Pen(SystemColors.ControlDark)) g.DrawEllipse(p, x, y, d, d);
            }
            else using (var p = new Pen(gewaehlt ? SystemColors.HighlightText : SystemColors.GrayText, Px(1.5))) g.DrawEllipse(p, x, y, d, d);

            Color farbe = gewaehlt ? SystemColors.HighlightText : f.Sichtbar ? SystemColors.ControlText : SystemColors.GrayText;
            string name = f.Name.Replace("\r", "").Replace("\n", " ");
            var rName = new Rectangle(x + d + Px(8), a.Bounds.Top, a.Bounds.Width - d - Px(90), a.Bounds.Height);
            TextRenderer.DrawText(g, name, Font, rName, farbe, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            string art = Feld.Kurz(f.Art) + (f.Sichtbar ? "" : " · aus");
            var rArt = new Rectangle(a.Bounds.Right - Px(80), a.Bounds.Top, Px(76), a.Bounds.Height);
            TextRenderer.DrawText(g, art, Font, rArt, gewaehlt ? SystemColors.HighlightText : SystemColors.GrayText,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Right | TextFormatFlags.NoPrefix);
            a.DrawFocusRectangle();
        }

        int Aktuell => liste.SelectedIndex >= 0 && liste.SelectedIndex < e.Felder.Count ? liste.SelectedIndex : -1;

        public void Auswaehlen(string id)
        {
            int i = e.Felder.FindIndex(f => f.Id == id);
            if (i >= 0) liste.SelectedIndex = i;
        }

        void NeuesFeld(FeldArt art)
        {
            var f = new Feld(art);
            if (art == FeldArt.Text) f.Text = "Neuer Text";
            if (art == FeldArt.Seit) f.Titel = "Seit";
            if (art == FeldArt.Termin) f.Titel = "Termin";
            int i = Aktuell >= 0 ? Aktuell + 1 : e.Felder.Count;
            e.Felder.Insert(i, f);
            ListeFuellen();
            liste.SelectedIndex = i;
            (art == FeldArt.Text ? tbText : tbTitel).Focus();
        }

        void Kopieren()
        {
            int i = Aktuell;
            if (i < 0) return;
            var f = e.Felder[i].Kopie();
            f.Id = Guid.NewGuid().ToString("N");
            e.Felder.Insert(i + 1, f);
            ListeFuellen();
            liste.SelectedIndex = i + 1;
        }

        void Entfernen()
        {
            int i = Aktuell;
            if (i < 0) return;
            e.Felder.RemoveAt(i);
            ListeFuellen();
            if (e.Felder.Count > 0) liste.SelectedIndex = Math.Min(i, e.Felder.Count - 1); else FeldZeigen();
        }

        void Verschieben(int richtung)
        {
            int i = Aktuell, j = i + richtung;
            if (i < 0 || j < 0 || j >= e.Felder.Count) return;
            var f = e.Felder[i]; e.Felder[i] = e.Felder[j]; e.Felder[j] = f;
            ListeFuellen();
            liste.SelectedIndex = j;
        }

        // ---------- ausgewähltes Feld ----------

        void FeldZeile(string name, string beschriftung, Control c)
        {
            var l = new Label { Text = beschriftung, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, Px(5), Px(8), Px(3)) };
            tFeld.Controls.Add(l);
            tFeld.Controls.Add(c);
            zeilen[name] = new[] { l, c };
        }

        void ZeileZeigen(string name, bool sichtbar)
        {
            foreach (var c in zeilen[name]) c.Visible = sichtbar;
        }

        void FeldZeigen()
        {
            int i = Aktuell;
            btKopie.Enabled = btEntfernen.Enabled = i >= 0;
            btHoch.Enabled = i > 0;
            btRunter.Enabled = i >= 0 && i < e.Felder.Count - 1;
            tFeld.Visible = i >= 0;
            if (i < 0) return;

            laedt = true;
            var f = e.Felder[i];
            lbArt.Text = Feld.ArtName(f.Art);
            tbTitel.Text = f.Titel;
            cbSichtbar.Checked = f.Sichtbar;
            tbText.Text = f.Text;
            dtZeit.Value = f.Zeit ?? Zeit.Runden5(Zeit.Jetzt.AddMinutes(f.Art == FeldArt.Termin ? 60 : 0));
            dtZeit.Checked = f.Zeit.HasValue;
            nIntervall.Value = Math.Max(0, Math.Min(1440, f.Intervall));
            cbSek.Checked = f.Sekunden;
            nGroesse.Value = Math.Max(30, Math.Min(300, f.Groesse));
            cbEigeneSchrift.Checked = f.Schriftfarbe.HasValue;
            cbEigenerGrund.Checked = f.Hintergrund.HasValue;
            feldSchrift = f.Schriftfarbe ?? schriftfarbe;
            feldGrund = f.Hintergrund ?? Color.FromArgb(183, 28, 28);
            FeldFarbenZeigen();

            bool zeitlich = f.Art == FeldArt.Seit || f.Art == FeldArt.Termin;
            SuspendLayout();
            ZeileZeigen("text", f.Art == FeldArt.Text);
            ZeileZeigen("zeit", zeitlich);
            ZeileZeigen("schnell", zeitlich);
            ZeileZeigen("taktisch", zeitlich);
            ZeileZeigen("intervall", f.Art == FeldArt.Termin);
            ZeileZeigen("sekunden", f.Art == FeldArt.Uhr);
            btJetzt.Visible = f.Art == FeldArt.Seit;
            for (int k = 1; k < reiheSchnell.Controls.Count; k++) reiheSchnell.Controls[k].Visible = f.Art == FeldArt.Termin;
            ResumeLayout();
            laedt = false;
            Hinweise();
        }

        void FeldFarbenZeigen()
        {
            FarbknopfZeigen(btFeldSchrift, feldSchrift, null);
            FarbknopfZeigen(btFeldGrund, feldGrund, null);
            btFeldSchrift.Enabled = cbEigeneSchrift.Checked;
            btFeldGrund.Enabled = cbEigenerGrund.Checked;
        }

        void Hinweise()
        {
            lbTaktisch.Text = dtZeit.Checked
                ? "taktisch: " + Zeit.Taktisch(dtZeit.Value, Math.Max(0, cbMonat.SelectedIndex))
                : "nicht festgelegt (Haken im Datumsfeld setzen)";
        }

        void FeldLesen()
        {
            if (laedt) return;
            Hinweise();
            int i = Aktuell;
            if (i < 0) return;
            var f = e.Felder[i];
            f.Titel = tbTitel.Text;
            f.Sichtbar = cbSichtbar.Checked;
            f.Text = tbText.Text;
            f.Zeit = dtZeit.Checked ? Zeit.Minute(dtZeit.Value) : (DateTime?)null;
            f.Intervall = (int)nIntervall.Value;
            f.Sekunden = cbSek.Checked;
            f.Groesse = (int)nGroesse.Value;
            f.Schriftfarbe = cbEigeneSchrift.Checked ? feldSchrift : (Color?)null;
            f.Hintergrund = cbEigenerGrund.Checked ? feldGrund : (Color?)null;
            liste.Invalidate(liste.GetItemRectangle(i));
        }

        void Schnell(int minuten)
        {
            dtZeit.Value = minuten == 0 ? Zeit.Minute(Zeit.Jetzt) : Zeit.Runden5(Zeit.Jetzt.AddMinutes(minuten));
            dtZeit.Checked = true;
            FeldLesen();
        }

        void FeldVorlage(Color? grund, Color? schrift)
        {
            laedt = true;
            cbEigenerGrund.Checked = grund.HasValue;
            cbEigeneSchrift.Checked = schrift.HasValue;
            if (grund.HasValue) feldGrund = grund.Value;
            if (schrift.HasValue) feldSchrift = schrift.Value;
            laedt = false;
            FeldFarbenZeigen();
            FeldLesen();
        }

        // ---------- ganzer Kasten ----------

        void KastenVorlage(Color grund, Color schrift)
        {
            hintergrund = grund; schriftfarbe = schrift;
            FarbknopfZeigen(btHintergrund, grund, "Hintergrund");
            FarbknopfZeigen(btSchriftfarbe, schrift, "Schrift");
        }

        bool FarbeWaehlen(ref Color farbe)
        {
            using (var d = new ColorDialog { Color = farbe, FullOpen = true, AnyColor = true })
            {
                if (d.ShowDialog(this) != DialogResult.OK) return false;
                farbe = Color.FromArgb(255, d.Color);
                return true;
            }
        }

        static void FarbknopfZeigen(Button b, Color c, string name)
        {
            b.UseVisualStyleBackColor = false;
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderColor = SystemColors.ControlDark;
            b.BackColor = c;
            b.ForeColor = c.GetBrightness() > 0.55f ? Color.Black : Color.White;
            b.Text = (name != null ? name + "  " : "") + Einstellungen.Hex(c);
            b.MinimumSize = new Size(Px(name != null ? 130 : 100), 0);
        }

        void Anwenden()
        {
            FeldLesen();
            e.Schriftgroesse = Einstellungen.Begrenzen((float)nSchrift.Value);
            e.Deckkraft = (int)nDeckkraft.Value;
            e.Hintergrund = hintergrund;
            e.Schriftfarbe = schriftfarbe;
            e.Nebeneinander = cbAnordnung.SelectedIndex == 1;
            e.Monatsschreibweise = Math.Max(0, cbMonat.SelectedIndex);
            e.DeckendBeiMaus = cbDeckend.Checked;
            e.Andocken = Math.Max(0, cbAndocken.SelectedIndex);
            e.Einklappen = cbEinklappen.Checked;
            e.Atomuhr = cbAtomuhr.Checked;
            e.Zeitserver = string.IsNullOrWhiteSpace(tbServer.Text) ? Atomuhr.StandardServer : tbServer.Text.Trim();
            e.VollbildNachMin = VollbildMinuten[Math.Max(0, cbVollbild.SelectedIndex)];
            e.VollbildAlle = cbVollbildAlle.Checked;
            uebernehmen(e);
        }

        // ---------- Bausteine ----------

        static TableLayoutPanel Spalte(TableLayoutPanel haupt)
        {
            var t = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Top, Margin = new Padding(0, 0, Px(8), 0) };
            haupt.Controls.Add(t);
            return t;
        }

        static TableLayoutPanel Gruppe(TableLayoutPanel spalte, string titel)
        {
            var gb = new GroupBox { Text = titel, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Fill, Padding = new Padding(Px(8), Px(4), Px(8), Px(6)), Margin = new Padding(0, 0, 0, Px(8)) };
            var t = new TableLayoutPanel { ColumnCount = 2, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Fill };
            t.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            t.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            gb.Controls.Add(t);
            spalte.Controls.Add(gb);
            return t;
        }

        static void Zeile(TableLayoutPanel t, string beschriftung, Control c)
        {
            t.Controls.Add(new Label { Text = beschriftung, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, Px(3), Px(8), Px(3)) });
            t.Controls.Add(c);
        }

        static void Ganz(TableLayoutPanel t, Control c)
        {
            t.Controls.Add(c);
            t.SetColumnSpan(c, 2);
        }

        static FlowLayoutPanel Reihe(params Control[] cs)
        {
            var f = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false, Margin = new Padding(0) };
            foreach (var c in cs) f.Controls.Add(c);
            return f;
        }

        static CheckBox Haken(string text) => new CheckBox { Text = text, AutoSize = true, Margin = new Padding(Px(3), Px(5), Px(3), Px(3)) };

        static Label Hinweis(string text = "", int maxBreite = 0)
        {
            var l = new Label { Text = text, AutoSize = true, ForeColor = SystemColors.GrayText, Anchor = AnchorStyles.Left, Margin = new Padding(Px(3), Px(5), 0, Px(3)) };
            if (maxBreite > 0) l.MaximumSize = new Size(maxBreite, 0);
            return l;
        }

        static Button Knopf(string text, EventHandler klick)
        {
            var b = new Button { Text = text, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, UseVisualStyleBackColor = true };
            b.Click += klick;
            return b;
        }

        static NumericUpDown Zahl(decimal min, decimal max, decimal wert, decimal schritt) => new NumericUpDown
        {
            Minimum = min, Maximum = max, Value = Math.Max(min, Math.Min(max, wert)), Increment = schritt, Width = Px(70)
        };

        static ComboBox Auswahl(string[] eintraege, int index)
        {
            var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = Px(200) };
            c.Items.AddRange(eintraege);
            c.SelectedIndex = Math.Max(0, Math.Min(eintraege.Length - 1, index));
            return c;
        }
    }
}
