using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

namespace Lageuhr
{
    static class Programm
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            // Als Bildschirmschoner (Lageuhr.scr): Windows ruft mit /s (zeigen), /p (Vorschau) oder /c (Einstellungen) auf
            string a = args.Length > 0 ? args[0].Trim().ToLowerInvariant() : "";
            bool alsScr = string.Equals(Path.GetExtension(Application.ExecutablePath), ".scr", StringComparison.OrdinalIgnoreCase);
            if (a.StartsWith("/s") || a.StartsWith("-s")) { Bildschirmschoner(); return; }
            if (a.StartsWith("/p") || a.StartsWith("-p")) return; // kleine Vorschau in den Windows-Einstellungen: bleibt leer
            if (a.StartsWith("/c") || a.StartsWith("-c") || (alsScr && a.Length == 0))
            {
                MessageBox.Show("Felder, Farben und Zeiten des Bildschirmschoners stellen Sie in der Lageuhr ein " +
                    "(Rechtsklick auf den Kasten → Einstellungen). Der Bildschirmschoner zeigt immer den aktuellen Stand der Lageuhr.",
                    "Lageuhr – Bildschirmschoner", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            var einst = Einstellungen.Laden();
            string name = "Lageuhr_" + ((uint)einst.Pfad.ToLowerInvariant().GetHashCode()).ToString("x8");
            using (new Mutex(true, name, out bool neu))
            {
                if (!neu)
                {
                    MessageBox.Show("Die Lageuhr läuft bereits.\n\nSie ist über das Uhr-Symbol unten rechts in der Taskleiste erreichbar.",
                        "Lageuhr", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                Application.Run(new Overlay(einst));
            }
        }

        /// <summary>Bildschirmschoner: Lagebild auf allen Bildschirmen, bis Maus oder Taste.</summary>
        static void Bildschirmschoner()
        {
            var e = Lagebild.Lesen();
            var fenster = Screen.AllScreens.Select(s => new VollbildFenster(s, e)).ToList();
            foreach (var f in fenster) f.Beenden += Application.Exit;
            DateTime gelesen = DateTime.Now;
            var takt = new System.Windows.Forms.Timer { Interval = 100 };
            takt.Tick += (s, x) =>
            {
                if ((DateTime.Now - gelesen).TotalSeconds > 10) { e = Lagebild.Lesen(); gelesen = DateTime.Now; } // Änderungen der Lageuhr übernehmen
                Lagebild.TermineWeiterschalten(e, Zeit.Jetzt);
                foreach (var f in fenster) f.Aktualisieren(e, Zeit.Jetzt);
            };
            foreach (var f in fenster) { f.Show(); f.Aktualisieren(e, Zeit.Jetzt); }
            fenster[0].Activate();
            Cursor.Hide();
            takt.Start();
            Application.Run();
        }
    }
}
