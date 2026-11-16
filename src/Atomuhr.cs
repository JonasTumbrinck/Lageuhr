using System;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace Lageuhr
{
    /// <summary>
    /// Abgleich mit der Atomuhr: Zeitserver per NTP (UDP 123), Standard PTB Braunschweig (gesetzliche Zeit).
    /// Ist NTP gesperrt (häufig in Firmen- und Behördennetzen), Ersatzweg über den Kopf „Date“ des PTB-Webservers (±0,5 s).
    /// </summary>
    public static class Atomuhr
    {
        public const string StandardServer = "ptbtime1.ptb.de ptbtime2.ptb.de ptbtime3.ptb.de";
        const string WebAdresse = "https://www.ptb.de/cms/";

        /// <summary>Im Hintergrund abgleichen; <paramref name="fertig"/> bekommt Abweichung (Sekunden) und Quelle, oder null.</summary>
        public static void Abgleichen(string liste, Action<double?, string> fertig)
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                foreach (var s in (liste ?? "").Split(new[] { ' ', ',', ';', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    var v = Abfragen(s);
                    if (v.HasValue) { fertig(v, s); return; }
                }
                var w = PerWebserver();
                fertig(w, w.HasValue ? "www.ptb.de (über Web, NTP gesperrt)" : null);
            });
        }

        static readonly DateTime Epoche = new DateTime(1900, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        static double? Abfragen(string server)
        {
            try
            {
                string host = server; int port = 123; // „host:port“ erlaubt einen anderen Port (z. B. zum Testen)
                int i = server.LastIndexOf(':');
                if (i > 0 && int.TryParse(server.Substring(i + 1), out int p)) { host = server.Substring(0, i); port = p; }
                var adressen = Dns.GetHostAddresses(host);
                var adr = adressen.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork) ?? adressen.First();
                using (var u = new UdpClient(adr.AddressFamily))
                {
                    u.Client.ReceiveTimeout = 3000;
                    u.Client.SendTimeout = 3000;
                    u.Connect(adr, port);
                    var paket = new byte[48];
                    paket[0] = 0x1B; // Version 3, Client
                    var t1 = DateTime.UtcNow;
                    u.Send(paket, paket.Length);
                    IPEndPoint von = null;
                    var b = u.Receive(ref von);
                    var t4 = DateTime.UtcNow;
                    int modus = b.Length >= 48 ? b[0] & 7 : 0;
                    if ((modus != 4 && modus != 5) || b[1] == 0) return null; // Antwort eines Servers mit gültigem Stratum
                    uint U32(int k) => (uint)b[k] << 24 | (uint)b[k + 1] << 16 | (uint)b[k + 2] << 8 | b[k + 3];
                    double Zeit(int k) => U32(k) + U32(k + 4) / 4294967296.0;
                    if (U32(40) == 0) return null;
                    double a1 = (t1 - Epoche).TotalSeconds, a4 = (t4 - Epoche).TotalSeconds;
                    return ((Zeit(32) - a1) + (Zeit(40) - a4)) / 2;
                }
            }
            catch { return null; }
        }

        /// <summary>
        /// „Date“ hat nur volle Sekunden. Jede Antwort grenzt die Abweichung auf ein Fenster ein:
        /// [Date − Empfang, Date + 1 s − Absendung]. Mehrere Anfragen zu verschiedenen Bruchteilen einer Sekunde
        /// schneiden diese Fenster und finden so den Sekundenwechsel – meist auf etwa 0,1 s genau.
        /// </summary>
        static double? PerWebserver()
        {
            try
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                double unten = double.NegativeInfinity, oben = double.PositiveInfinity;
                var epoche = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
                for (int n = 0; n < 6; n++) // die erste Anfrage baut nur die Verbindung auf
                {
                    if (n > 1) Thread.Sleep(230);
                    var r = (HttpWebRequest)WebRequest.Create(WebAdresse);
                    r.Method = "HEAD";
                    r.Timeout = 5000;
                    r.AllowAutoRedirect = false;
                    r.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);
                    var t1 = DateTime.UtcNow;
                    using (var a = (HttpWebResponse)r.GetResponse())
                    {
                        var t4 = DateTime.UtcNow;
                        if (n == 0 || !DateTime.TryParseExact(a.Headers["Date"], "r", CultureInfo.InvariantCulture,
                                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d)) continue;
                        double ds = (d - epoche).TotalSeconds, s1 = (t1 - epoche).TotalSeconds, s4 = (t4 - epoche).TotalSeconds;
                        unten = Math.Max(unten, ds - s4);
                        oben = Math.Min(oben, ds + 1 - s1);
                    }
                }
                if (double.IsInfinity(unten) || double.IsInfinity(oben)) return null;
                return (unten + oben) / 2;
            }
            catch { return null; }
        }
    }
}
