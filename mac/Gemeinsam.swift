// Lageuhr – gemeinsamer Teil für App, Vollbild und Bildschirmschoner (Zeit, Felder, Einstellungen, Darstellung).
import AppKit
import Network

// MARK: - Zeit

enum Zeit {
    static let monate = ["jan", "feb", "mär", "apr", "mai", "jun", "jul", "aug", "sep", "okt", "nov", "dez"]

    static func taktisch(_ d: Date, _ schreibweise: Int) -> String {
        let c = Calendar.current.dateComponents([.day, .hour, .minute, .month, .year], from: d)
        var m = monate[c.month! - 1]
        if schreibweise == 1 { m = m.prefix(1).uppercased() + m.dropFirst() }
        else if schreibweise == 2 { m = m.uppercased() }
        return String(format: "%02d%02d%02d", c.day!, c.hour!, c.minute!) + m + String(format: "%02d", c.year! % 100)
    }

    /// Restzeit bis zu einem Termin, aufgerundet (nie „in 0 min“).
    static func rest(_ s: TimeInterval) -> String {
        if s <= 600 { let x = Int(ceil(s)); return String(format: "%d:%02d min", x / 60, x % 60) }
        let m = Int(ceil(s / 60))
        if m < 60 { return "\(m) min" }
        if m < 1440 { return String(format: "%d:%02d h", m / 60, m % 60) }
        return String(format: "%d T %d:%02d h", m / 1440, m % 1440 / 60, m % 60)
    }

    static func vergangen(_ s: TimeInterval) -> String {
        let m = Int(floor(s / 60))
        if m < 60 { return "\(m) min" }
        if m < 1440 { return String(format: "%d:%02d h", m / 60, m % 60) }
        return String(format: "%d T %02d:%02d h", m / 1440, m % 1440 / 60, m % 60)
    }

    static func laufzeit(_ s: TimeInterval) -> String {
        let m = Int(floor(s / 60))
        if m < 1440 { return String(format: "%d:%02d h", m / 60, m % 60) }
        return String(format: "%d T %02d:%02d h", m / 1440, m % 1440 / 60, m % 60)
    }

    static func minute(_ d: Date) -> Date {
        Calendar.current.dateInterval(of: .minute, for: d)?.start ?? d
    }

    static func runden5(_ d: Date) -> Date {
        let m = minute(d.addingTimeInterval(30))
        let r = Calendar.current.component(.minute, from: m) % 5
        return m.addingTimeInterval(Double(r < 3 ? -r : 5 - r) * 60)
    }

    static func uhrzeit(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
        return String(format: "%02d:%02d:%02d", c.hour!, c.minute!, c.second!)
    }
}

// MARK: - Uhr mit Atomuhr-Abgleich

/// Angezeigte Zeit = Rechnerzeit + Abweichung zur Atomuhr (die Rechneruhr selbst wird nicht verstellt).
enum Uhr {
    static var versatz: TimeInterval = 0
    static func jetzt() -> Date { Date().addingTimeInterval(versatz) }

    static func abweichungText(_ v: TimeInterval) -> String {
        let a = abs(v)
        if a < 0.05 { return "Rechneruhr stimmt genau" }
        let wert = a >= 120 ? String(format: "%.0f min", a / 60) : String(format: "%.1f s", a).replacingOccurrences(of: ".", with: ",")
        return "Rechneruhr geht \(wert) " + (v > 0 ? "nach" : "vor")
    }
}

/// Abfrage eines Zeitservers (NTP, UDP 123). Standard: PTB Braunschweig, die gesetzliche Zeit in Deutschland.
enum Atomuhr {
    static let standardServer = "ptbtime1.ptb.de ptbtime2.ptb.de ptbtime3.ptb.de"

    static func abfragen(_ server: String, fertig: @escaping (TimeInterval?) -> Void) {
        let q = DispatchQueue(label: "atomuhr")
        // „host:port“ erlaubt einen anderen Port (z. B. zum Testen)
        var host = server, port: UInt16 = 123
        if let i = server.lastIndex(of: ":"), let p = UInt16(server[server.index(after: i)...]) { host = String(server[..<i]); port = p }
        let v = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        var erledigt = false
        func ende(_ x: TimeInterval?) {
            q.async {
                guard !erledigt else { return }
                erledigt = true
                v.cancel()
                DispatchQueue.main.async { fertig(x) }
            }
        }
        var t1 = Date()
        v.stateUpdateHandler = { zustand in
            switch zustand {
            case .ready:
                var paket = Data(count: 48)
                paket[0] = 0x1B // Version 3, Client
                t1 = Date()
                v.send(content: paket, completion: .contentProcessed { f in if f != nil { ende(nil) } })
                v.receiveMessage { daten, _, _, fehler in
                    let t4 = Date()
                    guard fehler == nil, let d = daten, d.count >= 48 else { ende(nil); return }
                    let b = [UInt8](d)
                    let modus = b[0] & 0x7
                    guard modus == 4 || modus == 5, b[1] != 0 else { ende(nil); return } // Antwort eines Servers mit gültigem Stratum
                    func u32(_ i: Int) -> UInt32 { b[i..<i + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
                    func zeit(_ i: Int) -> Double { Double(u32(i)) - 2_208_988_800 + Double(u32(i + 4)) / 4_294_967_296 }
                    let t2 = zeit(32), t3 = zeit(40)
                    guard u32(40) != 0 else { ende(nil); return }
                    let a = t1.timeIntervalSince1970, z = t4.timeIntervalSince1970
                    ende(((t2 - a) + (t3 - z)) / 2)
                }
            case .failed, .cancelled, .waiting: ende(nil)
            default: break
            }
        }
        v.start(queue: q)
        q.asyncAfter(deadline: .now() + 4) { ende(nil) }
    }

    /// Ersatzweg, wenn NTP gesperrt ist (häufig in Firmen- und Behördennetzen): Uhrzeit aus der Antwort des
    /// PTB-Webservers. Der Kopf „Date“ hat nur volle Sekunden; jede Antwort grenzt die Abweichung auf ein Fenster
    /// [Date − Empfang, Date + 1 s − Absendung] ein. Mehrere Anfragen zu verschiedenen Bruchteilen einer Sekunde
    /// schneiden diese Fenster und finden so den Sekundenwechsel – meist auf etwa 0,1 s genau.
    static let webAdresse = URL(string: "https://www.ptb.de/cms/")!

    static func perWebserver(fertig: @escaping (TimeInterval?) -> Void) {
        let q = DispatchQueue(label: "atomuhr.web")
        var unten = -Double.infinity, oben = Double.infinity
        func anfrage(_ n: Int) {
            guard n < 6 else {
                let v: TimeInterval? = unten.isFinite && oben.isFinite ? (unten + oben) / 2 : nil
                DispatchQueue.main.async { fertig(v) }
                return
            }
            var r = URLRequest(url: webAdresse, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
            r.httpMethod = "HEAD"
            let t1 = Date()
            URLSession.shared.dataTask(with: r) { _, antwort, _ in
                let t4 = Date()
                let kopf = (antwort as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date")
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(identifier: "GMT")
                f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                q.async {
                    if antwort == nil { n == 0 ? anfrage(6) : anfrage(n + 1); return } // keine Verbindung
                    if n > 0, let d = kopf.flatMap({ f.date(from: $0) }) { // die erste Anfrage baut nur die Verbindung auf
                        unten = max(unten, d.timeIntervalSince1970 - t4.timeIntervalSince1970)
                        oben = min(oben, d.timeIntervalSince1970 + 1 - t1.timeIntervalSince1970)
                    }
                    q.asyncAfter(deadline: .now() + (n == 0 ? 0 : 0.23)) { anfrage(n + 1) }
                }
            }.resume()
        }
        q.async { anfrage(0) }
    }

    /// Server der Reihe nach probieren, notfalls über den Webserver; liefert Abweichung und Quelle.
    static func abgleichen(_ liste: String, fertig: @escaping (TimeInterval?, String?) -> Void) {
        let server = liste.split(whereSeparator: { " ,;\n".contains($0) }).map(String.init)
        func versuch(_ i: Int) {
            guard i < server.count else {
                perWebserver { v in fertig(v, v == nil ? nil : "www.ptb.de (über Web, NTP gesperrt)") }
                return
            }
            abfragen(server[i]) { v in if let v = v { fertig(v, server[i]) } else { versuch(i + 1) } }
        }
        versuch(0)
    }
}

// MARK: - Felder und Einstellungen

enum FeldArt: String, Codable, CaseIterable {
    case text, uhr, seit, termin

    var name: String {
        switch self {
        case .text: return "Text"
        case .uhr: return "Aktuelle Zeit"
        case .seit: return "Seit … (z. B. Kat-Fall)"
        case .termin: return "Termin mit Countdown"
        }
    }
    var kurz: String {
        switch self {
        case .text: return "Text"
        case .uhr: return "Uhrzeit"
        case .seit: return "Seit"
        case .termin: return "Termin"
        }
    }
    var standardTitel: String {
        switch self {
        case .text: return ""
        case .uhr: return "Aktuelle Zeit"
        case .seit: return "Kat-Fall seit"
        case .termin: return "Nächste Lagebesprechung"
        }
    }
}

struct Feld: Codable, Equatable {
    var id = UUID().uuidString
    var art: FeldArt = .text
    var titel = ""
    var text = ""
    var zeit: Date? = nil
    var intervall = 0          // Minuten, nur Termin
    var sekunden = true        // nur Uhrzeit
    var schriftfarbe: String? = nil   // nil = wie der Kasten
    var hintergrund: String? = nil    // nil = kein eigener Hintergrund
    var groesse = 100          // Prozent der Schriftgröße
    var sichtbar = true

    init(_ art: FeldArt, titel: String? = nil, text: String = "") {
        self.art = art
        self.titel = titel ?? art.standardTitel
        self.text = text
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func w<T: Decodable>(_ k: CodingKeys, _ std: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? std }
        id = w(.id, UUID().uuidString)
        art = w(.art, FeldArt.text)
        titel = w(.titel, "")
        text = w(.text, "")
        zeit = try? c.decodeIfPresent(Date.self, forKey: .zeit)
        intervall = w(.intervall, 0)
        sekunden = w(.sekunden, true)
        schriftfarbe = try? c.decodeIfPresent(String.self, forKey: .schriftfarbe)
        hintergrund = try? c.decodeIfPresent(String.self, forKey: .hintergrund)
        groesse = w(.groesse, 100)
        sichtbar = w(.sichtbar, true)
    }

    /// Name in Liste und Menü
    var name: String {
        if !titel.trimmingCharacters(in: .whitespaces).isEmpty { return titel }
        if art == .text, let z = text.split(separator: "\n").first { return String(z) }
        return art.kurz
    }
}

struct Einstellungen: Codable {
    var felder: [Feld] = Einstellungen.standardFelder
    var nebeneinander = false
    var schriftgroesse: Double = 30
    var deckkraft = 90
    var hintergrund = "#181D25"
    var schriftfarbe = "#FFFFFF"
    var monatsschreibweise = 0
    var fixiert = false
    var durchklickbar = false
    var deckendBeiMaus = true  // unter der Maus voll deckend
    var andocken = 0           // 0 = frei, 1 = links, 2 = rechts, 3 = oben, 4 = unten
    var einklappen = true      // angedockt: zur Lasche einklappen wie das Dock
    var atomuhr = true
    var zeitserver = Atomuhr.standardServer
    var vollbildNachMin = 0     // Vollbild-Lagebild nach so vielen Minuten ohne Eingabe (0 = aus)
    var vollbildAlle = true     // auf allen Bildschirmen
    var links: Double? = nil   // linke obere Ecke
    var oben: Double? = nil

    /// Wiederkehrende Termine 5 Minuten nach Beginn auf den nächsten springen lassen. Liefert true, wenn sich etwas geändert hat.
    mutating func termineWeiterschalten(_ jetzt: Date, nachlauf: TimeInterval = 300) -> Bool {
        var weiter = false
        for i in felder.indices where felder[i].art == .termin && felder[i].intervall > 0 {
            guard var t = felder[i].zeit, jetzt >= t.addingTimeInterval(nachlauf) else { continue }
            while jetzt >= t.addingTimeInterval(nachlauf) { t = t.addingTimeInterval(Double(felder[i].intervall) * 60) }
            felder[i].zeit = t
            weiter = true
        }
        return weiter
    }

    /// JSON lesen; fehlende (neuere) Einstellungen behalten ihren Standardwert.
    static func dekodieren(_ data: Data) -> Einstellungen? {
        guard let gespeichert = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stdData = try? JSONEncoder().encode(Einstellungen()),
              var basis = try? JSONSerialization.jsonObject(with: stdData) as? [String: Any] else { return nil }
        basis.merge(gespeichert) { $1 }
        guard let neu = try? JSONSerialization.data(withJSONObject: basis) else { return nil }
        return try? JSONDecoder().decode(Einstellungen.self, from: neu)
    }

    static let schluessel = "einstellungen"
    static let standardHintergrund = "#181D25"
    static var standardFelder: [Feld] { [Feld(.uhr), Feld(.seit), Feld(.termin)] }

    /// Aufbau bis 1.0 (feste Zeilen) – wird beim Laden in Felder umgewandelt.
    private struct Alt: Decodable {
        var textOben: String?, textUnten: String?
        var uhrZeigen: Bool?, uhrTitel: String?, uhrSekunden: Bool?
        var katZeigen: Bool?, katTitel: String?, katBeginn: Date?
        var lageZeigen: Bool?, lageTitel: String?, lageZeit: Date?, lageIntervall: Int?
    }

    static func laden() -> Einstellungen {
        let std = Einstellungen()
        guard let data = UserDefaults.standard.data(forKey: schluessel),
              let gespeichert = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stdData = try? JSONEncoder().encode(std),
              var basis = try? JSONSerialization.jsonObject(with: stdData) as? [String: Any]
        else { return std }
        basis.merge(gespeichert) { $1 } // neue Einstellungen behalten ihren Standardwert
        guard let neu = try? JSONSerialization.data(withJSONObject: basis),
              var e = try? JSONDecoder().decode(Einstellungen.self, from: neu) else { return std }
        if gespeichert["felder"] == nil, gespeichert["uhrZeigen"] != nil, let a = try? JSONDecoder().decode(Alt.self, from: data) {
            var f: [Feld] = []
            if let t = a.textOben, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { f.append(Feld(.text, text: t)) }
            var u = Feld(.uhr, titel: a.uhrTitel); u.sekunden = a.uhrSekunden ?? true; u.sichtbar = a.uhrZeigen ?? true; f.append(u)
            var k = Feld(.seit, titel: a.katTitel); k.zeit = a.katBeginn; k.sichtbar = a.katZeigen ?? true; f.append(k)
            var l = Feld(.termin, titel: a.lageTitel); l.zeit = a.lageZeit; l.intervall = a.lageIntervall ?? 0
            l.sichtbar = a.lageZeigen ?? true; f.append(l)
            if let t = a.textUnten, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var x = Feld(.text, text: t); x.groesse = 80; f.append(x)
            }
            e.felder = f
            e.speichern()
        }
        return e
    }

    func speichern() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.schluessel) }
    }

    static func begrenzen(_ pt: Double) -> Double { max(10, min(200, pt)) }
}

/// Farbvorlagen für einzelne Felder: Name, Hintergrund, Schrift (nil = wie der Kasten)
let feldVorlagen: [(String, String?, String?)] = [
    ("Standard", nil, nil), ("Rot", "#B71C1C", "#FFFFFF"), ("Orange", "#E65100", "#FFFFFF"),
    ("Gelb", "#FFD600", "#000000"), ("Grün", "#2E7D32", "#FFFFFF"), ("Blau", "#1565C0", "#FFFFFF"),
    ("Grau", "#455A64", "#FFFFFF"), ("Weiß", "#FFFFFF", "#000000"),
]

// MARK: - Farben

extension NSColor {
    convenience init(hex: String, ersatz: NSColor = .white) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            let e = ersatz.usingColorSpace(.sRGB) ?? .white
            self.init(srgbRed: e.redComponent, green: e.greenComponent, blue: e.blueComponent, alpha: 1)
            return
        }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        let c = usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    var leuchtdichte: CGFloat {
        let c = usingColorSpace(.sRGB) ?? .white
        func k(_ x: CGFloat) -> CGFloat { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * k(c.redComponent) + 0.7152 * k(c.greenComponent) + 0.0722 * k(c.blueComponent)
    }

    func kontrast(zu b: NSColor) -> CGFloat {
        let l1 = leuchtdichte, l2 = b.leuchtdichte
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func gemischt(mit b: NSColor, anteil t: CGFloat) -> NSColor {
        let x = usingColorSpace(.sRGB) ?? .white, y = b.usingColorSpace(.sRGB) ?? .black
        return NSColor(srgbRed: x.redComponent * t + y.redComponent * (1 - t),
                       green: x.greenComponent * t + y.greenComponent * (1 - t),
                       blue: x.blueComponent * t + y.blueComponent * (1 - t), alpha: 1)
    }
}

/// Warnfarbe, die auf dem Grund lesbar ist; sonst die Schriftfarbe.
func warnfarbe(_ kandidaten: [String], grund: NSColor, schrift: NSColor) -> String {
    for k in kandidaten where NSColor(hex: k).kontrast(zu: grund) >= 4.5 { return k }
    return schrift.hex
}

// MARK: - Kasten

struct Block: Equatable {
    var art: FeldArt
    var titel: String?, wert: String?, zusatz: String?
    var titelFarbe: String, wertFarbe: String, zusatzFarbe: String
    var hintergrund: String?
    var faktor: Double
}

// MARK: - Felder → Darstellung

/// Baut aus den sichtbaren Feldern die anzuzeigenden Blöcke (Texte und Farben).
func bloeckeBauen(_ e: Einstellungen, _ jetzt: Date, nachlauf: TimeInterval = 300) -> [Block] {
    let sw = e.monatsschreibweise
    let blinkAn = jetzt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) < 0.5
    return e.felder.filter { $0.sichtbar }.map { f in
        let grund = NSColor(hex: f.hintergrund ?? e.hintergrund)
        let schrift = NSColor(hex: f.schriftfarbe ?? e.schriftfarbe)
        let zusatz = schrift.gemischt(mit: grund, anteil: 0.85).hex
        let blass = schrift.gemischt(mit: grund, anteil: 0.62).hex
        let gelb = warnfarbe(["#FFC107", "#B26A00"], grund: grund, schrift: schrift)
        let rot = warnfarbe(["#FF5252", "#C62828", "#FFFFFF"], grund: grund, schrift: schrift)
        let titel = f.titel.trimmingCharacters(in: .whitespaces).isEmpty ? nil : f.titel
        var b = Block(art: f.art, titel: titel, wert: nil, zusatz: nil, titelFarbe: blass, wertFarbe: schrift.hex,
                      zusatzFarbe: zusatz, hintergrund: f.hintergrund, faktor: Double(f.groesse) / 100)
        switch f.art {
        case .text:
            b.wert = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if (b.wert ?? "").isEmpty && b.titel == nil { b.wert = "(leerer Text)"; b.wertFarbe = blass }
        case .uhr:
            b.wert = Zeit.taktisch(jetzt, sw)
            b.zusatz = f.sekunden ? Zeit.uhrzeit(jetzt) : nil
        case .seit:
            if let k = f.zeit {
                let d = jetzt.timeIntervalSince(k)
                b.wert = Zeit.taktisch(k, sw)
                b.zusatz = d >= 0 ? "Dauer " + Zeit.laufzeit(d) : "beginnt in " + Zeit.rest(-d)
            } else { b.wert = "—"; b.zusatz = "nicht festgelegt"; b.zusatzFarbe = blass }
        case .termin:
            if let t = f.zeit {
                let rest = t.timeIntervalSince(jetzt)
                b.wert = Zeit.taktisch(t, sw)
                if rest > 0 {
                    b.zusatz = "in " + Zeit.rest(rest)
                    if rest <= 600 { b.zusatzFarbe = gelb }
                } else if -rest < nachlauf {
                    b.zusatz = "JETZT"; b.zusatzFarbe = blinkAn ? rot : blass; b.wertFarbe = rot
                } else {
                    b.zusatz = "überfällig seit " + Zeit.vergangen(-rest); b.zusatzFarbe = rot
                }
            } else { b.wert = "—"; b.zusatz = "nicht festgelegt"; b.zusatzFarbe = blass }
        }
        return b
    }
}

// MARK: - Anordnung (Kasten, Vollbild, Bildschirmschoner)

/// Ordnet die Blöcke an – in einer gespiegelten Ansicht (y nach unten), mit Rand, Kacheln und Trennlinien.
struct Anordnung {
    struct Zeichnung { let text: NSAttributedString; let ort: NSPoint }
    struct Kachel { var rect: NSRect; let farbe: String? }
    private struct Gemessen { var zeilen: [(NSAttributedString, CGFloat)]; var groesse: NSSize; var block: Block }

    private(set) var zeichnungen: [Zeichnung] = []
    private(set) var kacheln: [Kachel] = []
    private(set) var trenner: [NSRect] = []
    private(set) var groesse = NSSize.zero

    init() {}

    init(_ bloecke: [Block], schriftgroesse: Double, nebeneinander: Bool, schriftfarbe: String, leerHinweis: String) {
        let f = CGFloat(schriftgroesse) / 30
        let rand = max(9, 9 * f), innen = max(8, 9 * f), abstand = max(4, 5 * f), linie = max(1, round(f))

        func messen(_ b: Block) -> Gemessen {
            let g = CGFloat(schriftgroesse) * CGFloat(b.faktor)
            var zeilen: [(NSAttributedString, CGFloat)] = []
            var y: CGFloat = 0, w: CGFloat = 0
            func zeile(_ t: String?, _ font: NSFont, _ farbe: String) {
                guard let t = t, !t.isEmpty else { return }
                let a = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: NSColor(hex: farbe)])
                let s = a.size()
                zeilen.append((a, y))
                y += ceil(s.height)
                w = max(w, ceil(s.width))
            }
            zeile(b.titel, .systemFont(ofSize: max(8, g * 0.43)), b.titelFarbe)
            if b.art == .text { zeile(b.wert, .systemFont(ofSize: max(8, g * 0.6), weight: .semibold), b.wertFarbe) }
            else { zeile(b.wert, .monospacedDigitSystemFont(ofSize: g, weight: .bold), b.wertFarbe) }
            zeile(b.zusatz, .monospacedDigitSystemFont(ofSize: max(8, g * 0.5), weight: .regular), b.zusatzFarbe)
            return Gemessen(zeilen: zeilen, groesse: NSSize(width: w, height: y), block: b)
        }
        let alle = bloecke.map(messen)
        var zeichnungen: [Zeichnung] = [], kacheln: [Kachel] = [], trenner: [NSRect] = []

        func setzen(_ m: Gemessen, _ r: NSRect) {
            kacheln.append(Kachel(rect: r, farbe: m.block.hintergrund))
            for (a, dy) in m.zeilen { zeichnungen.append(Zeichnung(text: a, ort: NSPoint(x: r.minX + innen, y: r.minY + innen + dy))) }
        }
        // Trennlinie nur zwischen zwei Feldern ohne eigenen Hintergrund
        func trennen(_ a: Gemessen?, _ b: Gemessen) -> Bool { a != nil && a!.block.hintergrund == nil && b.block.hintergrund == nil }

        var breite: CGFloat = 140, y = rand
        if !nebeneinander {
            breite = max(breite, (alle.map { $0.groesse.width }.max() ?? 0) + 2 * innen)
            var vorher: Gemessen?
            for m in alle {
                if vorher != nil {
                    if trennen(vorher, m) { trenner.append(NSRect(x: rand + innen, y: y + abstand / 2, width: breite - 2 * innen, height: linie)) }
                    y += abstand
                }
                setzen(m, NSRect(x: rand, y: y, width: breite, height: m.groesse.height + 2 * innen))
                y += m.groesse.height + 2 * innen
                vorher = m
            }
        } else {
            // Text-Felder am Anfang und Ende der Liste gehen über die ganze Breite, der Rest steht nebeneinander
            var kopf: [Gemessen] = [], mitte = alle, fuss: [Gemessen] = []
            while let m = mitte.first, m.block.art == .text { kopf.append(mitte.removeFirst()) }
            while let m = mitte.last, m.block.art == .text { fuss.insert(mitte.removeLast(), at: 0) }
            let hoehe = (mitte.map { $0.groesse.height }.max() ?? 0) + 2 * innen
            let reihe = mitte.reduce(CGFloat(0)) { $0 + $1.groesse.width + 2 * innen } + CGFloat(max(0, mitte.count - 1)) * abstand
            breite = max(breite, reihe, ((kopf + fuss).map { $0.groesse.width }.max() ?? 0) + 2 * innen)

            var vorher: Gemessen?
            var vorherFarbig = false
            func ganz(_ m: Gemessen) {
                if vorher != nil || vorherFarbig {
                    if !vorherFarbig && trennen(vorher, m) { trenner.append(NSRect(x: rand + innen, y: y + abstand / 2, width: breite - 2 * innen, height: linie)) }
                    y += abstand
                }
                setzen(m, NSRect(x: rand, y: y, width: breite, height: m.groesse.height + 2 * innen))
                y += m.groesse.height + 2 * innen
                vorher = m; vorherFarbig = false
            }
            kopf.forEach(ganz)
            if !mitte.isEmpty {
                let reiheFarbig = mitte.contains { $0.block.hintergrund != nil }
                if let v = vorher {
                    if v.block.hintergrund == nil && !reiheFarbig {
                        trenner.append(NSRect(x: rand + innen, y: y + abstand / 2, width: breite - 2 * innen, height: linie))
                    }
                    y += abstand
                }
                var x = rand
                var links: Gemessen?
                for m in mitte {
                    if links != nil {
                        if trennen(links, m) { trenner.append(NSRect(x: x + abstand / 2, y: y + innen, width: linie, height: hoehe - 2 * innen)) }
                        x += abstand
                    }
                    setzen(m, NSRect(x: x, y: y, width: m.groesse.width + 2 * innen, height: hoehe))
                    x += m.groesse.width + 2 * innen
                    links = m
                }
                y += hoehe
                vorher = reiheFarbig ? nil : mitte.last
                vorherFarbig = reiheFarbig
            }
            fuss.forEach(ganz)
        }
        if alle.isEmpty {
            let a = NSAttributedString(string: leerHinweis, attributes: [.font: NSFont.systemFont(ofSize: max(13, 13 * f)),
                                                                        .foregroundColor: NSColor(hex: schriftfarbe)])
            zeichnungen.append(Zeichnung(text: a, ort: NSPoint(x: rand + innen, y: rand + innen)))
            breite = max(breite, a.size().width + 2 * innen)
            y += a.size().height + 2 * innen
        }
        self.zeichnungen = zeichnungen
        self.kacheln = kacheln
        self.trenner = trenner
        groesse = NSSize(width: ceil(breite + 2 * rand), height: ceil(y + rand))
    }

    /// Zeichnet Kacheln, Trennlinien und Texte, verschoben um `versatz` (in einer gespiegelten Ansicht).
    func zeichnen(versatz v: NSPoint = .zero, trennfarbe: NSColor, eckradius: CGFloat = 6) {
        for k in kacheln {
            guard let c = k.farbe else { continue }
            NSColor(hex: c).setFill()
            NSBezierPath(roundedRect: k.rect.offsetBy(dx: v.x, dy: v.y), xRadius: eckradius, yRadius: eckradius).fill()
        }
        trennfarbe.setFill()
        trenner.forEach { $0.offsetBy(dx: v.x, dy: v.y).fill() }
        for z in zeichnungen { z.text.draw(at: NSPoint(x: z.ort.x + v.x, y: z.ort.y + v.y)) }
    }
}

// MARK: - Vollbild-Lagebild (App und Bildschirmschoner)

/// Füllt den Bildschirm mit den Feldern, groß und mittig; verschiebt sich jede Minute leicht (gegen Einbrennen).
final class LagebildAnsicht: NSView {
    var e = Einstellungen()
    private var anordnung = Anordnung()
    private var letzte: [Block] = []
    private var groesseFuer = (NSSize.zero, 0.0, "")   // Bildschirmgröße, Schriftgröße, Feldaufbau
    private var schriftgroesse = 40.0
    private var versatz = NSPoint.zero
    private var naechsteDrift = Date.distantPast
    private var grund = Einstellungen.lagebildGrund, schrift = "#FFFFFF"

    override var isFlipped: Bool { true }

    func aktualisieren(jetzt: Date) {
        let e = self.e.dunkel // Vollbild und Bildschirmschoner immer dunkel
        grund = e.hintergrund; schrift = e.schriftfarbe
        let b = bloeckeBauen(e, jetzt)
        // Schriftgröße nur neu bestimmen, wenn sich Bildschirm oder Feldaufbau ändern (sonst „pumpt“ das Bild)
        let aufbau = b.map { "\($0.art)\($0.titel ?? "")\($0.faktor)\($0.hintergrund ?? "")" }.joined(separator: "|") + "\(e.nebeneinander)"
        if groesseFuer.0 != bounds.size || groesseFuer.2 != aufbau {
            let probe = Anordnung(b, schriftgroesse: 40, nebeneinander: e.nebeneinander, schriftfarbe: e.schriftfarbe, leerHinweis: "Keine Felder")
            let k = min(bounds.width * 0.82 / max(1, probe.groesse.width), bounds.height * 0.78 / max(1, probe.groesse.height))
            schriftgroesse = max(12, min(400, 40 * Double(k)))
            groesseFuer = (bounds.size, schriftgroesse, aufbau)
            naechsteDrift = .distantPast
        }
        guard b != letzte || anordnung.groesse == .zero || Date() >= naechsteDrift else { return }
        letzte = b
        anordnung = Anordnung(b, schriftgroesse: schriftgroesse, nebeneinander: e.nebeneinander, schriftfarbe: e.schriftfarbe,
                              leerHinweis: "Keine Felder")
        if Date() >= naechsteDrift {
            let frei = NSSize(width: max(0, bounds.width - anordnung.groesse.width), height: max(0, bounds.height - anordnung.groesse.height))
            versatz = NSPoint(x: frei.width / 2 + CGFloat.random(in: -0.15...0.15) * frei.width,
                              y: frei.height / 2 + CGFloat.random(in: -0.15...0.15) * frei.height)
            naechsteDrift = Date().addingTimeInterval(60)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let g = NSColor(hex: grund)
        g.setFill()
        bounds.fill()
        anordnung.zeichnen(versatz: versatz, trennfarbe: NSColor(hex: schrift).gemischt(mit: g, anteil: 0.22), eckradius: 14)
    }
}

// MARK: - Datenaustausch mit dem Bildschirmschoner

/// Die App legt ihre Felder und die Abweichung zur Atomuhr ab; der Bildschirmschoner bekommt sie per Nachricht.
/// Der Schoner läuft abgeschottet (legacyScreenSaver): In dessen Container darf die App nicht schreiben (macOS sperrt das),
/// und er selbst darf außerhalb nichts lesen. Deshalb: Die App verschickt den Stand als systemweite Nachricht
/// (bei jeder Änderung und auf Anfrage), der Schoner fragt alle 10 s nach und merkt sich den letzten Stand in seinem Container.
enum Lagebild {
    static let dateiname = "Library/Application Support/Lageuhr/lagebild.json"
    static let nachrichtStand = Notification.Name("local.lageuhr.lagebild")
    static let nachrichtAnfrage = Notification.Name("local.lageuhr.anfrage")

    struct Daten: Codable { var einstellungen: Data; var versatz: Double; var stand: Date }

    static var echtesZuhause: String { String(cString: getpwuid(getuid()).pointee.pw_dir) }
    private static var zuletzt: String?
    private static var beobachter: NSObjectProtocol?

    static func schreiben(_ e: Einstellungen, versatz: Double) {
        if CommandLine.arguments.contains("--beispiel") { return } // Testdaten nicht an den Bildschirmschoner geben
        guard let ed = try? JSONEncoder().encode(e),
              let d = try? JSONEncoder().encode(Daten(einstellungen: ed, versatz: versatz, stand: Date())),
              let text = String(data: d, encoding: .utf8) else { return }
        ablegen(d)
        zuletzt = text
        senden()
        if beobachter == nil { // Anfragen des Bildschirmschoners beantworten
            beobachter = DistributedNotificationCenter.default().addObserver(forName: nachrichtAnfrage, object: nil, queue: .main) { _ in senden() }
        }
    }

    private static func senden() {
        guard let t = zuletzt else { return }
        DistributedNotificationCenter.default().postNotificationName(nachrichtStand, object: t, userInfo: nil, deliverImmediately: true)
    }

    /// Stand in die eigene Ablage schreiben (App: Benutzerordner, Schoner: sein Container).
    static func ablegen(_ d: Data) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/" + dateiname)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }

    static func dekodieren(_ d: Data) -> (Einstellungen, Double)? {
        guard let daten = try? JSONDecoder().decode(Daten.self, from: d),
              let e = Einstellungen.dekodieren(daten.einstellungen) else { return nil }
        return (e, daten.versatz)
    }

    static func lesen() -> (Einstellungen, Double)? {
        for pfad in [NSHomeDirectory() + "/" + dateiname, echtesZuhause + "/" + dateiname] {
            if let d = FileManager.default.contents(atPath: pfad), let r = dekodieren(d) { return r }
        }
        return nil
    }
}

// MARK: - Dunkles Lagebild

extension Einstellungen {
    static let lagebildGrund = "#0B0D12"

    /// Für Vollbild und Bildschirmschoner: dunkler Grund, helle Schrift. Farbige Felder bleiben;
    /// eine eigene Schriftfarbe ohne eigenen Hintergrund, die auf Dunkel nicht lesbar wäre, wird hell.
    var dunkel: Einstellungen {
        var d = self
        d.hintergrund = Self.lagebildGrund
        d.schriftfarbe = "#FFFFFF"
        let g = NSColor(hex: Self.lagebildGrund)
        for i in d.felder.indices where d.felder[i].hintergrund == nil {
            if let f = d.felder[i].schriftfarbe, NSColor(hex: f).kontrast(zu: g) < 3 { d.felder[i].schriftfarbe = nil }
        }
        return d
    }
}
