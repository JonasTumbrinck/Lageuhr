using System;
using System.Globalization;

namespace Lageuhr
{
    /// <summary>Taktische Zeit (TTHHMMmmmJJ, z. B. 161432nov26) und Dauern.</summary>
    public static class Zeit
    {
        static readonly string[] Monate = { "jan", "feb", "mär", "apr", "mai", "jun", "jul", "aug", "sep", "okt", "nov", "dez" };

        /// <summary>Abweichung der Rechneruhr zur Atomuhr in Sekunden (die Rechneruhr selbst wird nicht verstellt).</summary>
        public static double Versatz;

        /// <summary>Angezeigte Zeit = Rechnerzeit + Abweichung zur Atomuhr.</summary>
        public static DateTime Jetzt => DateTime.Now.AddSeconds(Versatz);

        public static string AbweichungText(double v)
        {
            double a = Math.Abs(v);
            if (a < 0.05) return "Rechneruhr stimmt genau";
            string wert = a >= 120 ? Math.Round(a / 60) + " min" : a.ToString("0.0", CultureInfo.GetCultureInfo("de-DE")) + " s";
            return "Rechneruhr geht " + wert + (v > 0 ? " nach" : " vor");
        }

        public static string Taktisch(DateTime t, int schreibweise)
        {
            string m = Monate[t.Month - 1];
            if (schreibweise == 1) m = char.ToUpper(m[0]) + m.Substring(1);
            else if (schreibweise == 2) m = m.ToUpper(CultureInfo.GetCultureInfo("de-DE"));
            return t.ToString("ddHHmm", CultureInfo.InvariantCulture) + m + t.ToString("yy", CultureInfo.InvariantCulture);
        }

        /// <summary>Restzeit bis zu einem Termin, aufgerundet (nie „in 0 min“).</summary>
        public static string Rest(TimeSpan d)
        {
            if (d.TotalMinutes <= 10)
            {
                int s = (int)Math.Ceiling(d.TotalSeconds);
                return $"{s / 60}:{s % 60:00} min";
            }
            int m = (int)Math.Ceiling(d.TotalMinutes);
            if (m < 60) return m + " min";
            if (m < 1440) return $"{m / 60}:{m % 60:00} h";
            return $"{m / 1440} T {m % 1440 / 60}:{m % 60:00} h";
        }

        /// <summary>Vergangene Zeit, abgerundet.</summary>
        public static string Vergangen(TimeSpan d)
        {
            int m = (int)Math.Floor(d.TotalMinutes);
            if (m < 60) return m + " min";
            if (m < 1440) return $"{m / 60}:{m % 60:00} h";
            return $"{m / 1440} T {m % 1440 / 60:00}:{m % 60:00} h";
        }

        /// <summary>Laufzeit eines Ereignisses, immer als Stunden:Minuten.</summary>
        public static string Laufzeit(TimeSpan d)
        {
            int m = (int)Math.Floor(d.TotalMinutes);
            if (m < 1440) return $"{m / 60}:{m % 60:00} h";
            return $"{m / 1440} T {m % 1440 / 60:00}:{m % 60:00} h";
        }

        /// <summary>Auf volle Minute abschneiden.</summary>
        public static DateTime Minute(DateTime t) => new DateTime(t.Year, t.Month, t.Day, t.Hour, t.Minute, 0);

        /// <summary>Auf die nächsten vollen 5 Minuten runden.</summary>
        public static DateTime Runden5(DateTime t)
        {
            var m = Minute(t.AddSeconds(30));
            int rest = m.Minute % 5;
            return rest < 3 ? m.AddMinutes(-rest) : m.AddMinutes(5 - rest);
        }
    }
}
