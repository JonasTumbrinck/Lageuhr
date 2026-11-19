using System;
using System.Collections.Generic;
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
    /// <summary>Angaben aus lageuhr-version.txt (Release-Datei auf GitHub).</summary>
    public class UpdateInfo
    {
        public Version Version;
        public readonly Dictionary<string, string> Pruefsummen = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); // Datei → SHA-256 (hex, klein)
        public readonly List<string> Neu = new List<string>();
        public string VersionText => Aktualisierung.Text(Version);
    }

    /// <summary>Fehler beim Suchen oder Installieren, mit Text für die Kolleginnen und Kollegen.</summary>
    public class UpdateFehler : Exception
    {
        public bool Schreibgeschuetzt { get; }
        public UpdateFehler(string text, bool schreibgeschuetzt = false, Exception innen = null) : base(text, innen) { Schreibgeschuetzt = schreibgeschuetzt; }
    }

    /// <summary>
    /// Update über GitHub-Releases: Versionsdatei lesen, neue .exe laden, Prüfsumme prüfen, laufende .exe ersetzen.
    /// Ohne WinForms (testbar); Pfade und Quelle lassen sich für Tests setzen. Installiert wird nur auf Wunsch.
    /// </summary>
    public class Aktualisierung
    {
        public const string Repo = "https://github.com/JonasTumbrinck/Lageuhr";
        public const string DownloadSeite = Repo + "/releases/latest";
        public const string Dateiname = "Lageuhr.exe";
        public const string VersionsDatei = "lageuhr-version.txt";
        const int ZeitlimitMs = 15000, DownloadZeitlimitMs = 120000;
        const int MaxVersionsDatei = 64 * 1024, MaxDatei = 64 * 1024 * 1024;

        /// <summary>Basisadresse; LAGEUHR_UPDATE_QUELLE nur zum Testen.</summary>
        public string Quelle = (Environment.GetEnvironmentVariable("LAGEUHR_UPDATE_QUELLE") ?? Repo).TrimEnd('/');
        public Version EigeneVersion = Normal(typeof(Aktualisierung).Assembly.GetName().Version);
        /// <summary>Pfad der laufenden .exe.</summary>
        public string ExePfad;
        /// <summary>Wo eine eingerichtete Lageuhr.scr liegen kann; nur vorhandene werden ersetzt.</summary>
        public List<string> SchonerPfade = new List<string>();

        // Zustand (geschrieben im Hintergrund, gelesen nach dem Rückruf)
        public UpdateInfo Verfuegbar { get; private set; }
        public string Fehler { get; private set; }
        public bool Schreibgeschuetzt { get; private set; }
        public bool Gesucht { get; private set; }
        public bool Installiert { get; private set; }
        public string Taetigkeit { get; private set; } // „suche …“, „lade herunter …“ oder null

        int laeuft;
        public bool Laeuft => Volatile.Read(ref laeuft) != 0;

        public Aktualisierung(string exePfad)
        {
            ExePfad = exePfad;
            string ordner = Path.GetDirectoryName(exePfad) ?? "";
            SchonerPfade.Add(Path.Combine(ordner, "Lageuhr.scr"));
            SchonerPfade.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lageuhr", "Lageuhr.scr"));
        }

        public string AltPfad => ExePfad + ".alt";
        public string NeuPfad => ExePfad + ".neu";
        public string VersionsAdresse => Quelle + "/releases/latest/download/" + VersionsDatei;
        public string DateiAdresse(Version v) => Quelle + "/releases/download/v" + Text(v) + "/" + Dateiname;

        // ---------- Versionen ----------

        public static Version Normal(Version v) => v == null ? new Version(0, 0, 0) : new Version(v.Major, v.Minor, Math.Max(0, v.Build));

        public static string Text(Version v) => v == null ? "?" : v.Major + "." + v.Minor + "." + Math.Max(0, v.Build);

        /// <summary>„1.5.1“, „v1.5.1“ oder „1.5“ → Version (Major.Minor.Build); sonst null.</summary>
        public static Version VersionLesen(string s)
        {
            var m = Regex.Match((s ?? "").Trim(), @"^[vV]?(\d{1,5})\.(\d{1,5})(?:\.(\d{1,5}))?$");
            if (!m.Success) return null;
            int T(int i) => m.Groups[i].Success ? int.Parse(m.Groups[i].Value, CultureInfo.InvariantCulture) : 0;
            return new Version(T(1), T(2), T(3));
        }

        public static bool IstNeuer(Version verfuegbar, Version eigen) => verfuegbar != null && Normal(verfuegbar) > Normal(eigen);

        // ---------- Versionsdatei ----------

        /// <summary>Zeilen „version …“, „sha256 &lt;datei&gt; &lt;hex&gt;“, „neu …“; Unbekanntes wird übergangen.</summary>
        public static UpdateInfo Parsen(string text)
        {
            var info = new UpdateInfo();
            foreach (var roh in (text ?? "").Replace("﻿", "").Replace("\r", "").Split('\n'))
            {
                string z = roh.Trim();
                if (z.Length == 0 || z.StartsWith("#")) continue;
                int i = z.IndexOfAny(new[] { ' ', '\t' });
                string schluessel = (i < 0 ? z : z.Substring(0, i)).ToLowerInvariant();
                string rest = i < 0 ? "" : z.Substring(i + 1).Trim();
                switch (schluessel)
                {
                    case "version":
                        info.Version = VersionLesen(rest) ?? info.Version;
                        break;
                    case "sha256":
                        var t = rest.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                        if (t.Length == 2 && Regex.IsMatch(t[1], "^[0-9a-fA-F]{64}$")) info.Pruefsummen[t[0]] = t[1].ToLowerInvariant();
                        break;
                    case "neu":
                        if (rest.Length > 0) info.Neu.Add(rest);
                        break;
                }
            }
            return info;
        }

        // ---------- Suchen ----------

        /// <summary>Versionsdatei lesen; gibt die Angaben zurück, wenn es eine neuere Version gibt, sonst null. Wirft UpdateFehler.</summary>
        public UpdateInfo Suchen()
        {
            string text;
            try { text = Encoding.UTF8.GetString(Laden(VersionsAdresse, ZeitlimitMs, MaxVersionsDatei, null)); }
            catch (Exception ex) { throw new UpdateFehler(FehlerText(ex), false, ex); }
            var info = Parsen(text);
            if (info.Version == null) throw new UpdateFehler("Versionsangabe auf GitHub ist unlesbar");
            if (!IstNeuer(info.Version, EigeneVersion)) return null;
            if (!info.Pruefsummen.ContainsKey(Dateiname))
                throw new UpdateFehler("Version " + info.VersionText + " hat noch keine Windows-Datei");
            return info;
        }

        /// <summary>Im Hintergrund suchen (nie zwei gleichzeitig). <paramref name="fertig"/> läuft im Hintergrund-Thread. false = läuft schon.</summary>
        public bool SucheStarten(Action fertig)
        {
            if (Interlocked.CompareExchange(ref laeuft, 1, 0) != 0) return false;
            Taetigkeit = "suche …";
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    try
                    {
                        Verfuegbar = Suchen();
                        Fehler = null;
                    }
                    catch (Exception ex) { Fehler = ex is UpdateFehler ? ex.Message : FehlerText(ex); }
                    Gesucht = true;
                }
                finally { Taetigkeit = null; Volatile.Write(ref laeuft, 0); }
                fertig?.Invoke();
            });
            return true;
        }

        // ---------- Installieren ----------

        /// <summary>
        /// Lädt die neue .exe nach &lt;exe&gt;.neu, prüft die Prüfsumme und tauscht sie gegen die laufende .exe (die alte wird &lt;exe&gt;.alt).
        /// Danach auch eine eingerichtete Lageuhr.scr ersetzen. Rückgabe: Hinweise (z. B. Bildschirmschoner nicht ersetzt). Wirft UpdateFehler.
        /// </summary>
        public List<string> Installieren(UpdateInfo info)
        {
            var hinweise = new List<string>();
            if (info?.Version == null || !info.Pruefsummen.TryGetValue(Dateiname, out string soll))
                throw new UpdateFehler("Keine Prüfsumme für " + Dateiname);
            string ordner = Path.GetDirectoryName(ExePfad);
            if (!OrdnerBeschreibbar(ordner))
                throw new UpdateFehler("Ordner ist schreibgeschützt (" + ordner + ")", true);

            string neu = NeuPfad, alt = AltPfad;
            Loeschen(neu);
            try
            {
                Laden(DateiAdresse(info.Version), DownloadZeitlimitMs, MaxDatei, neu);
            }
            catch (Exception ex) { Loeschen(neu); throw new UpdateFehler("Herunterladen hat nicht geklappt: " + FehlerText(ex), false, ex); }

            string ist;
            try { ist = Pruefsumme(neu); }
            catch (Exception ex) { Loeschen(neu); throw new UpdateFehler("Heruntergeladene Datei nicht lesbar: " + ex.Message, false, ex); }
            if (ist != soll)
            {
                Loeschen(neu);
                throw new UpdateFehler("Prüfsumme stimmt nicht – Datei verworfen, nichts geändert");
            }

            if (File.Exists(alt))
            {
                try { File.Delete(alt); }
                catch (Exception ex) { Loeschen(neu); throw new UpdateFehler("Alte Fassung (" + Path.GetFileName(alt) + ") lässt sich nicht löschen: " + ex.Message, false, ex); }
            }
            try { File.Move(ExePfad, alt); } // geht unter Windows auch bei laufender .exe
            catch (Exception ex)
            {
                Loeschen(neu);
                throw new UpdateFehler("Lageuhr lässt sich nicht ersetzen: " + ex.Message, ex is UnauthorizedAccessException, ex);
            }
            try { File.Move(neu, ExePfad); }
            catch (Exception ex)
            {
                try { File.Move(alt, ExePfad); } catch { }
                Loeschen(neu);
                throw new UpdateFehler("Lageuhr lässt sich nicht ersetzen: " + ex.Message, ex is UnauthorizedAccessException, ex);
            }
            Installiert = true;

            // eingerichteter Bildschirmschoner: gleiche Fassung
            var gesehen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var scr in SchonerPfade)
            {
                if (string.IsNullOrWhiteSpace(scr)) continue;
                string voll;
                try { voll = Path.GetFullPath(scr); } catch { continue; }
                if (!gesehen.Add(voll) || !File.Exists(voll)) continue;
                try { File.Copy(ExePfad, voll, true); }
                catch (Exception ex) { hinweise.Add("Bildschirmschoner " + voll + " nicht ersetzt: " + ex.Message); }
            }
            return hinweise;
        }

        /// <summary>Im Hintergrund installieren. <paramref name="fertig"/> (Hinweise, Fehler) läuft im Hintergrund-Thread. false = läuft schon.</summary>
        public bool InstallationStarten(UpdateInfo info, Action<List<string>, UpdateFehler> fertig)
        {
            if (Interlocked.CompareExchange(ref laeuft, 1, 0) != 0) return false;
            Taetigkeit = "lade " + info?.VersionText + " herunter …";
            ThreadPool.QueueUserWorkItem(_ =>
            {
                List<string> hinweise = null;
                UpdateFehler fehler = null;
                try
                {
                    try { hinweise = Installieren(info); Schreibgeschuetzt = false; }
                    catch (UpdateFehler ex) { fehler = ex; Schreibgeschuetzt = ex.Schreibgeschuetzt; }
                    catch (Exception ex) { fehler = new UpdateFehler(ex.Message, false, ex); }
                }
                finally { Taetigkeit = null; Volatile.Write(ref laeuft, 0); }
                fertig?.Invoke(hinweise, fehler);
            });
            return true;
        }

        /// <summary>Beim Start: &lt;exe&gt;.alt vom letzten Update still löschen (gelingt erst, wenn die alte Fassung beendet ist).</summary>
        public void Aufraeumen()
        {
            try { if (File.Exists(AltPfad)) File.Delete(AltPfad); } catch { }
            if (!Laeuft) try { if (File.Exists(NeuPfad)) File.Delete(NeuPfad); } catch { }
        }

        // ---------- Anzeige ----------

        /// <summary>Statuszeile für die Einstellungen.</summary>
        public string Status()
        {
            string eigen = "Version " + Text(EigeneVersion);
            if (Installiert) return "Update installiert – startet neu …";
            if (Taetigkeit != null) return eigen + " – " + Taetigkeit;
            if (Schreibgeschuetzt) return "Update " + Verfuegbar?.VersionText + " verfügbar, aber der Ordner ist schreibgeschützt – neue Fassung über die Download-Seite holen.";
            if (Verfuegbar != null) return "Update " + Verfuegbar.VersionText + " verfügbar (installiert: " + Text(EigeneVersion) + ")";
            if (Fehler != null) return eigen + " – Update-Suche: " + Fehler;
            return Gesucht ? eigen + " – aktuell" : eigen;
        }

        // ---------- Netz und Dateien ----------

        /// <summary>GET; mit <paramref name="ziel"/> in die Datei, sonst als Bytes. Folgt Umleitungen (GitHub → Speicher).</summary>
        byte[] Laden(string adresse, int zeitlimitMs, int maxBytes, string ziel)
        {
            var p = ServicePointManager.SecurityProtocol;
            if (p != SecurityProtocolType.SystemDefault && (p & SecurityProtocolType.Tls12) == 0)
                ServicePointManager.SecurityProtocol = p | SecurityProtocolType.Tls12;
#pragma warning disable SYSLIB0014 // nur für den Test unter neuerem .NET; .NET Framework 4.8 kennt nur diesen Weg
            var r = (HttpWebRequest)WebRequest.Create(adresse);
#pragma warning restore SYSLIB0014
            r.Method = "GET";
            r.UserAgent = "Lageuhr/" + Text(EigeneVersion);
            r.Timeout = zeitlimitMs;
            r.ReadWriteTimeout = ZeitlimitMs * 2;
            r.AllowAutoRedirect = true;
            r.MaximumAutomaticRedirections = 5;
            r.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);
            using (var a = (HttpWebResponse)r.GetResponse())
            using (var s = a.GetResponseStream())
            {
                if ((int)a.StatusCode != 200) throw new UpdateFehler("Server antwortet mit " + (int)a.StatusCode);
                if (a.ContentLength > maxBytes) throw new UpdateFehler("Datei ist zu groß");
                using (var aus = ziel != null ? (Stream)new FileStream(ziel, FileMode.Create, FileAccess.Write, FileShare.None) : new MemoryStream())
                {
                    var puffer = new byte[81920];
                    long gesamt = 0;
                    int n;
                    while ((n = s.Read(puffer, 0, puffer.Length)) > 0)
                    {
                        gesamt += n;
                        if (gesamt > maxBytes) throw new UpdateFehler("Datei ist zu groß");
                        aus.Write(puffer, 0, n);
                    }
                    return ziel == null ? ((MemoryStream)aus).ToArray() : null;
                }
            }
        }

        public static string Pruefsumme(string datei)
        {
            using (var sha = SHA256.Create())
            using (var f = File.OpenRead(datei))
                return string.Concat(sha.ComputeHash(f).Select(b => b.ToString("x2")));
        }

        static bool OrdnerBeschreibbar(string ordner)
        {
            try
            {
                string t = Path.Combine(ordner, ".lageuhr-update-test");
                File.WriteAllText(t, "");
                File.Delete(t);
                return true;
            }
            catch { return false; }
        }

        static void Loeschen(string pfad)
        {
            try { if (File.Exists(pfad)) File.Delete(pfad); } catch { }
        }

        static string FehlerText(Exception ex)
        {
            if (ex is UpdateFehler) return ex.Message;
            if (ex is WebException w)
            {
                if (w.Response is HttpWebResponse a)
                {
                    int code = (int)a.StatusCode;
                    try { a.Close(); } catch { }
                    return code == 404 ? "auf GitHub nicht gefunden (404)" : "Server antwortet mit " + code;
                }
                switch (w.Status)
                {
                    case WebExceptionStatus.Timeout: return "keine Antwort (Zeitüberschreitung)";
                    case WebExceptionStatus.NameResolutionFailure: return "keine Internetverbindung (GitHub nicht gefunden)";
                    case WebExceptionStatus.ConnectFailure: return "keine Verbindung zu GitHub";
                    case WebExceptionStatus.TrustFailure:
                    case WebExceptionStatus.SecureChannelFailure: return "sichere Verbindung (HTTPS) nicht möglich";
                }
                return "keine Verbindung zu GitHub (" + w.Message + ")";
            }
            return ex.Message;
        }
    }
}
