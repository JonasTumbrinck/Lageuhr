// Lageuhr – Abgleich der geteilten Felder zwischen Arbeitsplätzen über lage.php (Schnittstelle: server/PROTOKOLL.md).
// Nur für die App (nicht im Bildschirmschoner). Läuft auf dem Main-Thread; nur die Anfrage selbst läuft im Hintergrund.
import AppKit
import SystemConfiguration

/// Feld, wie es über die Leitung geht (Zeiten als Millisekunden seit 1970, UTC; Farben `#RRGGBB`).
struct LeitungsFeld: Codable {
    var id: String
    var art: String
    var titel = ""
    var text = ""
    var zeit: Int64? = nil
    var intervall = 0
    var sekunden = true
    var schriftfarbe: String? = nil
    var hintergrund: String? = nil
    var geaendert: Int64 = 0
    var von = ""
    var geloescht = false
    var rev: Int? = nil

    init(id: String, art: String) { self.id = id; self.art = art }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func w<T: Decodable>(_ k: CodingKeys, _ std: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? std }
        id = try c.decode(String.self, forKey: .id)
        art = w(.art, "text")
        titel = w(.titel, "")
        text = w(.text, "")
        zeit = try? c.decodeIfPresent(Int64.self, forKey: .zeit)
        intervall = w(.intervall, 0)
        sekunden = w(.sekunden, true)
        schriftfarbe = try? c.decodeIfPresent(String.self, forKey: .schriftfarbe)
        hintergrund = try? c.decodeIfPresent(String.self, forKey: .hintergrund)
        geaendert = w(.geaendert, Int64(0))
        von = w(.von, "")
        geloescht = w(.geloescht, false)
        rev = try? c.decodeIfPresent(Int.self, forKey: .rev)
    }

    static func farbe(_ s: String?) -> String? {
        guard let s = s?.uppercased(), s.count == 7, s.hasPrefix("#"), UInt32(s.dropFirst(), radix: 16) != nil else { return nil }
        return s
    }
}

extension Feld {
    var leitung: LeitungsFeld {
        var l = LeitungsFeld(id: id, art: art.rawValue)
        l.titel = titel; l.text = text
        l.zeit = zeit.map(Feld.ms)
        l.intervall = intervall; l.sekunden = sekunden
        l.schriftfarbe = LeitungsFeld.farbe(schriftfarbe); l.hintergrund = LeitungsFeld.farbe(hintergrund)
        l.geaendert = geaendert; l.von = von
        return l
    }

    /// Geteilte Werte von der Leitung übernehmen (Größe, sichtbar und Reihenfolge bleiben am eigenen Platz).
    mutating func uebernehmen(_ l: LeitungsFeld) {
        art = FeldArt(rawValue: l.art) ?? art
        titel = l.titel; text = l.text
        zeit = l.zeit.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        intervall = l.intervall; sekunden = l.sekunden
        schriftfarbe = LeitungsFeld.farbe(l.schriftfarbe); hintergrund = LeitungsFeld.farbe(l.hintergrund)
        geaendert = l.geaendert; von = l.von
        bekannt = signatur
    }
}

final class Abgleich {
    // Anbindung: Einstellungen holen und zurückschreiben (die App speichert dann und zeichnet neu)
    var lesen: () -> Einstellungen = { Einstellungen() }
    var schreiben: (Einstellungen) -> Void = { _ in }
    var statusGeaendert: (() -> Void)?
    var zeitquelle: () -> Date = { Uhr.jetzt() }

    static let takt: TimeInterval = 3
    static let nachAenderung: TimeInterval = 0.3
    static let warnenNach: TimeInterval = 30
    static let codeZeichen = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    private(set) var laeuft = false
    private var nochmal = false
    private var naechste = Date.distantPast
    private var beitrittFuer: String?   // Lage, der dieser Platz seit dem Start beigetreten ist
    private var generation = 0
    private var wartende: [() -> Void] = []

    // Zustand
    private(set) var verbunden = false
    private(set) var getrenntSeit: Date?
    private(set) var letzterErfolg: Date?
    private(set) var fehler: String?
    private(set) var zuletztGesendet = 0
    private(set) var zuletztEmpfangen = 0

    private let sitzung: URLSession = {
        let k = URLSessionConfiguration.ephemeral
        k.timeoutIntervalForRequest = 10
        k.timeoutIntervalForResource = 10
        k.requestCachePolicy = .reloadIgnoringLocalCacheData
        k.waitsForConnectivity = false
        k.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: k)
    }()

    // MARK: Hilfen

    /// Rechnername (Vorgabe für den Namen des Arbeitsplatzes)
    static let rechnername: String = {
        if let n = SCDynamicStoreCopyComputerName(nil, nil) as String?, !n.isEmpty { return n }
        return Host.current().localizedName ?? "Mac"
    }()

    static func name(_ e: Einstellungen) -> String {
        let n = e.arbeitsplatz.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((n.isEmpty ? rechnername : n).prefix(60))
    }

    /// Server-Adresse: ohne Schema kommt https:// davor; http:// nur für 127.0.0.1 und localhost.
    static func adresse(_ roh: String) -> URL? {
        var s = roh.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard var k = URLComponents(string: s), let host = k.host, !host.isEmpty else { return nil }
        if k.scheme?.lowercased() == "http" && !["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) { k.scheme = "https" }
        return k.url
    }

    /// Lage-Code wie der Server ihn sieht: nur Buchstaben und Ziffern, groß.
    static func code(_ roh: String) -> String {
        String(roh.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    static func eingerichtet(_ e: Einstellungen) -> Bool { adresse(e.abgleichAdresse) != nil && code(e.lageCode).count >= 12 }
    static func aktiv(_ e: Einstellungen) -> Bool { e.abgleich && eingerichtet(e) }

    /// Kennung der Lage (Server und Code) – ändert sie sich, tritt der Platz neu bei.
    static func lage(_ e: Einstellungen) -> String { (adresse(e.abgleichAdresse)?.absoluteString ?? "") + "|" + code(e.lageCode) }

    /// Neuer Lage-Code XXXX-XXXX-XXXX (ohne leicht verwechselbare Zeichen, sicherer Zufall).
    static func neuerCode() -> String {
        var z = SystemRandomNumberGenerator()
        let s = (0..<12).map { _ in codeZeichen.randomElement(using: &z)! }
        return [s[0..<4], s[4..<8], s[8..<12]].map { String($0) }.joined(separator: "-")
    }

    static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d%02d", c.hour!, c.minute!)
    }

    // MARK: Zustand für Menü, Einstellungen, Kasten

    func statusText(_ e: Einstellungen, ausfuehrlich: Bool = false) -> String {
        if !e.abgleich { return "Abgleich ist aus" }
        if Self.adresse(e.abgleichAdresse) == nil { return "Abgleich: Server-Adresse fehlt" }
        if Self.code(e.lageCode).count < 12 { return "Abgleich: Lage-Code fehlt (mindestens 12 Zeichen)" }
        if verbunden { return "Abgleich: verbunden · Lage \(Self.code(e.lageCode).prefix(4))-…" }
        if let g = getrenntSeit {
            var t = "Abgleich: getrennt seit \(Self.hhmm(g))"
            if ausfuehrlich, let f = fehler { t += " – \(f)" }
            return t
        }
        return "Abgleich: verbinde …"
    }

    /// Hinweis im Kasten, wenn länger als 30 s keine Verbindung besteht.
    func warnText(_ e: Einstellungen, jetzt: Date? = nil) -> String? {
        guard Self.aktiv(e), !verbunden, let g = getrenntSeit, (jetzt ?? zeitquelle()).timeIntervalSince(g) > Self.warnenNach else { return nil }
        return "Abgleich getrennt seit \(Self.hhmm(g))"
    }

    // MARK: Zeitplan

    /// Im Takt aufrufen (z. B. alle 0,1 s): gleicht alle 3 s ab.
    func takt() {
        let e = lesen()
        guard Self.aktiv(e) else {
            if verbunden || getrenntSeit != nil || fehler != nil {
                verbunden = false; getrenntSeit = nil; fehler = nil
                statusGeaendert?()
            }
            return
        }
        if !laeuft && Date() >= naechste { runde() }
    }

    /// Nach einer eigenen Änderung: bald abgleichen.
    func bald() {
        naechste = min(naechste, Date().addingTimeInterval(Self.nachAenderung))
        if laeuft { nochmal = true }
    }

    /// Andere Lage (Code oder Server geändert): neu beitreten, Zustand zurücksetzen.
    func zuruecksetzen() {
        generation += 1
        beitrittFuer = nil
        verbunden = false; getrenntSeit = nil; letzterErfolg = nil; fehler = nil
        naechste = .distantPast
        statusGeaendert?()
    }

    // MARK: Eine Runde

    /// Eine Anfrage an den Server: Beitreten oder Senden + Empfangen. `fertig` kommt nach der Antwort (auf dem Main-Thread).
    func runde(fertig: (() -> Void)? = nil) {
        if let f = fertig { wartende.append(f) }
        if laeuft { nochmal = true; return }
        var e = lesen()
        guard Self.aktiv(e), let url = Self.adresse(e.abgleichAdresse) else { fertigMelden(); return }
        let lage = Self.lage(e)
        let beitreten = e.abgleichStand == 0 && beitrittFuer != lage

        var felder: [LeitungsFeld] = []
        var rest = false
        if !beitreten {
            if vorbereiten(&e) { schreiben(e) }
            (felder, rest) = paket(e)
        }
        let stand = beitreten ? 0 : e.abgleichStand
        let anfrage = Anfrage(code: Self.code(e.lageCode), stand: stand, arbeitsplatz: Self.name(e), felder: felder)
        guard let koerper = try? JSONEncoder().encode(anfrage) else { fertigMelden(); return }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = koerper

        laeuft = true
        zuletztGesendet = felder.count
        if rest { nochmal = true }
        let gen = generation
        sitzung.dataTask(with: r) { [weak self] daten, antwort, fehler in
            let (ergebnis, text) = Self.auswerten(daten, antwort, fehler)
            DispatchQueue.main.async {
                self?.verarbeiten(ergebnis, fehlerText: text, gesendet: felder, stand: stand, beitreten: beitreten, lage: lage, gen: gen)
            }
        }.resume()
    }

    private struct Anfrage: Encodable {
        var v = 1
        var code: String
        var stand: Int
        var arbeitsplatz: String
        var felder: [LeitungsFeld]
    }

    private struct Antwort: Decodable {
        var rev: Int
        var felder: [LeitungsFeld]
        var voll: Bool?
    }

    private static func fehlerText(_ f: Error) -> String {
        guard let u = f as? URLError else { return (f as NSError).localizedDescription }
        switch u.code {
        case .notConnectedToInternet: return "keine Netzverbindung"
        case .cannotConnectToHost: return "Server nicht erreichbar"
        case .timedOut: return "Server antwortet nicht (Zeitüberschreitung)"
        case .cannotFindHost, .dnsLookupFailed: return "Server-Adresse nicht gefunden"
        case .networkConnectionLost: return "Verbindung abgebrochen"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected: return "sichere Verbindung fehlgeschlagen (Zertifikat)"
        case .appTransportSecurityRequiresSecureConnection: return "nur https:// erlaubt"
        default: return u.localizedDescription
        }
    }

    private static func auswerten(_ daten: Data?, _ antwort: URLResponse?, _ fehler: Error?) -> (Antwort?, String?) {
        if let f = fehler { return (nil, fehlerText(f)) }
        let status = (antwort as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200, let d = daten, let a = try? JSONDecoder().decode(Antwort.self, from: d) { return (a, nil) }
        if let d = daten, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let f = o["fehler"] as? String {
            return (nil, "Server: \(f)")
        }
        if status == 200 { return (nil, "Antwort ist kein Lageuhr-Abgleich – Adresse prüfen") }
        return (nil, "Server antwortet mit \(status) – Adresse prüfen")
    }

    /// Senden vorbereiten: Geänderte geteilte Felder stempeln, gelöschte erkennen. Liefert true, wenn sich etwas geändert hat.
    private func vorbereiten(_ e: inout Einstellungen) -> Bool {
        let vorher = (e.felder, e.geteilteIds, e.ausstehend, e.loeschungen)
        let jetzt = Feld.ms(zeitquelle())
        let name = Self.name(e)
        let vorhanden = Set(e.felder.map(\.id))
        for id in e.geteilteIds where !vorhanden.contains(id) && e.loeschungen[id] == nil { e.loeschungen[id] = jetzt }
        for i in e.felder.indices where e.felder[i].geteilt {
            let s = e.felder[i].signatur
            guard s != e.felder[i].bekannt else { continue }
            e.felder[i].geaendert = max(jetzt, e.felder[i].geaendert + 1) // immer neuer als der zuletzt gesehene Stand
            e.felder[i].von = name
            e.felder[i].bekannt = s
            if !e.ausstehend.contains(e.felder[i].id) { e.ausstehend.append(e.felder[i].id) }
        }
        let geteilt = e.felder.filter(\.geteilt).map(\.id)
        e.geteilteIds = geteilt   // Teilen ausschalten löscht nicht bei den anderen
        e.ausstehend = e.ausstehend.filter { geteilt.contains($0) }
        return vorher.0 != e.felder || vorher.1 != e.geteilteIds || vorher.2 != e.ausstehend || vorher.3 != e.loeschungen
    }

    /// Was diese Runde hinausgeht (höchstens 60 Felder und gut unter 64 KB); `rest` = es bleibt etwas für die nächste.
    private func paket(_ e: Einstellungen) -> ([LeitungsFeld], Bool) {
        var alle: [LeitungsFeld] = e.ausstehend.compactMap { id in e.felder.first { $0.id == id }?.leitung }
        for (id, t) in e.loeschungen.sorted(by: { $0.key < $1.key }) {
            var l = LeitungsFeld(id: id, art: FeldArt.text.rawValue)
            l.geaendert = t; l.von = Self.name(e); l.geloescht = true
            alle.append(l)
        }
        var paket: [LeitungsFeld] = [], groesse = 200
        for l in alle {
            let g = (try? JSONEncoder().encode(l).count) ?? 1000
            if paket.count >= 60 || (groesse + g > 56_000 && !paket.isEmpty) { return (paket, true) }
            paket.append(l); groesse += g + 1
        }
        return (paket, false)
    }

    private func verarbeiten(_ a: Antwort?, fehlerText: String?, gesendet: [LeitungsFeld], stand: Int, beitreten: Bool, lage: String, gen: Int) {
        laeuft = false
        defer {
            if nochmal { nochmal = false; naechste = min(naechste, Date().addingTimeInterval(Self.nachAenderung)) }
            statusGeaendert?()
            fertigMelden()
        }
        guard gen == generation else { naechste = .distantPast; return } // inzwischen andere Lage
        naechste = Date().addingTimeInterval(Self.takt)
        guard let a = a else {
            verbunden = false
            if getrenntSeit == nil { getrenntSeit = letzterErfolg ?? zeitquelle() }
            fehler = fehlerText
            return
        }
        verbunden = true; getrenntSeit = nil; fehler = nil; letzterErfolg = zeitquelle()
        zuletztEmpfangen = a.felder.count

        var e = lesen()
        // Hat sich inzwischen die Lage oder der Stand geändert (z. B. Einstellungen übernommen), gilt diese Antwort nicht.
        guard Self.aktiv(e), Self.lage(e) == lage, e.abgleichStand == stand else { naechste = Date(); return }
        let vorher = (e.felder, e.geteilteIds, e.ausstehend, e.loeschungen, e.abgleichStand)

        // Angekommenes abhaken
        for g in gesendet {
            if g.geloescht {
                if e.loeschungen[g.id] == g.geaendert { e.loeschungen[g.id] = nil }
            } else if e.felder.first(where: { $0.id == g.id })?.geaendert ?? g.geaendert == g.geaendert {
                e.ausstehend.removeAll { $0 == g.id }
            }
        }

        if beitreten {
            beitrittFuer = lage
            let aktiv = a.felder.filter { !$0.geloescht }
            let ids = Set(aktiv.map(\.id))
            if aktiv.isEmpty {
                // Leere Lage: Die eigenen geteilten Felder gehen in der nächsten Runde hinaus (so entsteht eine Lage).
                for i in e.felder.indices where e.felder[i].geteilt { e.felder[i].bekannt = "" }
                e.geteilteIds = []
                nochmal = true
            } else {
                // Die Lage gilt: eigene geteilte Felder, die dort nicht vorkommen, werden nicht geteilt und ausgeblendet.
                for i in e.felder.indices where e.felder[i].geteilt && !ids.contains(e.felder[i].id) {
                    e.felder[i].geteilt = false
                    e.felder[i].sichtbar = false
                }
                var geteilt: [String] = []
                for l in aktiv {
                    if let i = e.felder.firstIndex(where: { $0.id == l.id }) {
                        guard e.felder[i].geteilt else { continue }
                        e.felder[i].uebernehmen(l)
                    } else {
                        e.felder.append(Self.neuesFeld(l))
                    }
                    geteilt.append(l.id)
                }
                e.geteilteIds = geteilt
            }
            e.ausstehend = []
            e.loeschungen = [:]
        } else {
            for l in a.felder { empfangen(l, &e) }
        }
        e.abgleichStand = a.rev
        // Lage auf dem Server neu (z. B. aufgeräumt): alle eigenen geteilten Felder noch einmal senden
        if a.voll == true && stand > 0 {
            for i in e.felder.indices where e.felder[i].geteilt { e.felder[i].bekannt = "" }
            nochmal = true
        }
        if vorher.0 != e.felder || vorher.1 != e.geteilteIds || vorher.2 != e.ausstehend || vorher.3 != e.loeschungen || vorher.4 != e.abgleichStand {
            schreiben(e)
        }
    }

    private static func neuesFeld(_ l: LeitungsFeld) -> Feld {
        var f = Feld(FeldArt(rawValue: l.art) ?? .text)
        f.id = l.id
        f.uebernehmen(l)
        f.geteilt = true; f.sichtbar = true; f.groesse = 100
        return f
    }

    /// Ein Feld aus der Antwort übernehmen (die letzte Änderung gewinnt).
    private func empfangen(_ l: LeitungsFeld, _ e: inout Einstellungen) {
        if let i = e.felder.firstIndex(where: { $0.id == l.id }) {
            let f = e.felder[i]
            // nicht (mehr) geteilt, nicht neuer, oder hier gerade geändert und noch nicht gesendet: eigener Stand gilt
            guard f.geteilt, l.geaendert > f.geaendert, f.signatur == f.bekannt else { return }
            if l.geloescht {
                e.felder.remove(at: i)
                e.geteilteIds.removeAll { $0 == l.id }
            } else {
                e.felder[i].uebernehmen(l)
            }
            e.ausstehend.removeAll { $0 == l.id }
        } else if !l.geloescht && !e.geteilteIds.contains(l.id) && e.loeschungen[l.id] == nil {
            // neues Feld eines anderen Platzes: hinten anfügen
            e.felder.append(Self.neuesFeld(l))
            e.geteilteIds.append(l.id)
        }
    }

    /// Felder aus dem Einstellungsfenster mit dem aktuellen Stand zusammenführen: Im Fenster unveränderte Felder bekommen,
    /// was inzwischen empfangen wurde; inzwischen bei anderen gelöschte fallen weg; inzwischen neue kommen hinten dazu.
    static func felderZusammenfuehren(fenster: [Feld], aktuell: [Feld], beimOeffnen: Set<String>) -> [Feld] {
        var ergebnis: [Feld] = []
        let imFenster = Set(fenster.map(\.id))
        for var f in fenster {
            let unveraendert = f.signatur == f.bekannt
            if let c = aktuell.first(where: { $0.id == f.id }) {
                if unveraendert && c.geaendert > f.geaendert {
                    let eigen = (f.groesse, f.sichtbar, f.geteilt)
                    f = c
                    (f.groesse, f.sichtbar, f.geteilt) = eigen
                }
            } else if beimOeffnen.contains(f.id) && unveraendert && f.geteilt {
                continue // bei anderen gelöscht, während das Fenster offen war
            }
            ergebnis.append(f)
        }
        ergebnis += aktuell.filter { !imFenster.contains($0.id) && !beimOeffnen.contains($0.id) }
        return ergebnis
    }

    private func fertigMelden() {
        let w = wartende
        wartende = []
        w.forEach { $0() }
    }
}

// MARK: - Test zweier Arbeitsplätze (--abgleichtest <adresse>)

/// Simuliert zwei Arbeitsplätze in einem Prozess gegen einen laufenden Server und gibt OK/FEHLER je Punkt aus.
enum AbgleichTest {
    final class Platz {
        var e = Einstellungen()
        let a = Abgleich()
        var versatz: TimeInterval = 0
        init(_ name: String, _ adresse: String) {
            e.abgleich = true
            e.abgleichAdresse = adresse
            e.arbeitsplatz = name
            a.lesen = { [unowned self] in self.e }
            a.schreiben = { [unowned self] in self.e = $0 }
            a.zeitquelle = { [unowned self] in Date().addingTimeInterval(self.versatz) }
        }
        func runde() async { await withCheckedContinuation { c in a.runde { c.resume() } } }
        func feld(_ id: String) -> Feld? { e.felder.first { $0.id == id } }
        func index(_ id: String) -> Int? { e.felder.firstIndex { $0.id == id } }
    }

    static func starten(_ adresse: String) {
        Task { @MainActor in
            let fehler = await ablauf(adresse)
            print(fehler == 0 ? "Alles OK" : "\(fehler) FEHLER")
            exit(fehler == 0 ? 0 : 1)
        }
        RunLoop.main.run()
    }

    @MainActor
    static func ablauf(_ adresse: String) async -> Int {
        var fehler = 0
        func pruefen(_ ok: Bool, _ text: String) {
            print((ok ? "OK      " : "FEHLER  ") + text)
            if !ok { fehler += 1 }
        }
        let code = Abgleich.neuerCode()
        pruefen(code.range(of: "^[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$", options: .regularExpression) != nil,
                "Neuer Lage-Code \(code)")

        // A legt eine neue Lage an
        let a = Platz("Test-A", adresse), b = Platz("Test-B", adresse)
        a.e.lageCode = code
        let jetzt = Date()
        if let i = a.e.felder.firstIndex(where: { $0.art == .termin }) { a.e.felder[i].zeit = Zeit.minute(jetzt.addingTimeInterval(3600)) }
        if let i = a.e.felder.firstIndex(where: { $0.art == .seit }) { a.e.felder[i].zeit = Zeit.minute(jetzt.addingTimeInterval(-600)) }
        await a.runde() // Beitreten (leer)
        await a.runde() // eigene Felder senden
        let aGeteilt = a.e.felder.filter(\.geteilt)
        pruefen(a.a.verbunden && a.e.abgleichStand >= 2 && aGeteilt.count == 2 && a.e.ausstehend.isEmpty
                && !a.e.felder.first(where: { $0.art == .uhr })!.geteilt,
                "A legt Lage an: \(aGeteilt.count) geteilte Felder gesendet, Stand \(a.e.abgleichStand), Uhrzeit nicht geteilt")
        pruefen(a.a.statusText(a.e).hasPrefix("Abgleich: verbunden · Lage \(code.prefix(4))-…"), "Status A: \(a.a.statusText(a.e))")

        // B tritt bei
        b.e.lageCode = code.lowercased().replacingOccurrences(of: "-", with: " ")
        let bEigene = b.e.felder.map(\.id)
        await b.runde()
        let bEigeneFelder = b.e.felder.filter { bEigene.contains($0.id) }
        let bUhr = bEigeneFelder.first { $0.art == .uhr }
        pruefen(bEigeneFelder.filter { $0.art != .uhr }.allSatisfy { !$0.sichtbar && !$0.geteilt } && bUhr?.sichtbar == true,
                "B tritt bei: eigene Standardfelder ausgeblendet und nicht geteilt, eigene Uhrzeit bleibt")
        pruefen(aGeteilt.allSatisfy { f in b.feld(f.id).map { $0.signatur == f.signatur && $0.sichtbar && $0.geteilt && $0.von == "Test-A" } ?? false }
                && b.e.felder.count == 5, "B hat die Felder von A (\(b.e.felder.count) Felder insgesamt)")
        await b.runde()
        pruefen(b.a.zuletztGesendet == 0, "B sendet nach dem Beitreten nichts Eigenes")

        // B ändert die Termin-Zeit → A übernimmt
        let terminId = aGeteilt.first { $0.art == .termin }!.id
        let neueZeit = Zeit.minute(jetzt.addingTimeInterval(2 * 3600))
        b.e.felder[b.index(terminId)!].zeit = neueZeit
        b.e.felder[b.index(terminId)!].groesse = 150 // nur am eigenen Platz
        await b.runde()
        await a.runde()
        pruefen(a.feld(terminId)?.zeit == neueZeit && a.feld(terminId)?.von == "Test-B" && a.feld(terminId)?.groesse == 100,
                "B ändert Termin-Zeit → A übernimmt (von Test-B), Größe bleibt am eigenen Platz")
        await a.runde()
        pruefen(a.a.zuletztGesendet == 0, "A sendet die übernommene Änderung nicht zurück")

        // A löscht ein Feld → bei B weg
        let seitId = aGeteilt.first { $0.art == .seit }!.id
        a.e.felder.removeAll { $0.id == seitId }
        await a.runde()
        await b.runde()
        pruefen(b.feld(seitId) == nil && !b.e.geteilteIds.contains(seitId), "A löscht Feld → bei B weg")
        await a.runde()
        pruefen(a.e.loeschungen.isEmpty && a.a.zuletztGesendet == 0, "Löschung bei A abgehakt")

        // Gleichzeitige Änderung: die neuere gewinnt (auch wenn die ältere später ankommt)
        a.e.felder[a.index(terminId)!].titel = "Lage A"
        b.versatz = -60 // B ändert „früher“ (Uhr eine Minute zurück)
        b.e.felder[b.index(terminId)!].titel = "Lage B (älter)"
        await a.runde()
        await b.runde()
        b.versatz = 0
        await a.runde()
        pruefen(a.feld(terminId)?.titel == "Lage A" && b.feld(terminId)?.titel == "Lage A", "Gleichzeitig: neuere Änderung (A) gewinnt, ältere (B) kommt später an")
        b.e.felder[b.index(terminId)!].titel = "Lage B"
        a.e.felder[a.index(terminId)!].titel = "Lage A (älter)"
        a.versatz = -60
        await b.runde()
        await a.runde()
        a.versatz = 0
        await b.runde()
        pruefen(a.feld(terminId)?.titel == "Lage B" && b.feld(terminId)?.titel == "Lage B", "Gleichzeitig: neuere Änderung (B) gewinnt")

        // Server nicht erreichbar → getrennt; danach wieder verbunden und Ausstehendes nachgesendet
        await a.runde() // letzter Erfolg mit richtiger Uhr
        a.e.abgleichAdresse = "http://127.0.0.1:9/lage.php"
        let t = a.e.felder[a.index(terminId)!]
        a.e.felder[a.index(terminId)!].text = "offline geändert"
        a.e.felder[a.index(terminId)!].hintergrund = "#B71C1C"
        await a.runde()
        pruefen(!a.a.verbunden && a.a.getrenntSeit != nil && a.a.statusText(a.e).hasPrefix("Abgleich: getrennt seit ")
                && a.e.ausstehend.contains(terminId), "Server nicht erreichbar → \(a.a.statusText(a.e, ausfuehrlich: true))")
        pruefen(a.a.warnText(a.e) == nil && a.a.warnText(a.e, jetzt: Date().addingTimeInterval(31))?.hasPrefix("Abgleich getrennt seit ") == true,
                "Hinweis im Kasten erst nach 30 s: „\(a.a.warnText(a.e, jetzt: Date().addingTimeInterval(31)) ?? "-")“")
        await a.runde()
        pruefen(a.e.ausstehend.contains(terminId) && a.feld(terminId)?.text == "offline geändert", "Zweiter Versuch ohne Server: Änderung bleibt ausstehend")
        a.e.abgleichAdresse = adresse
        await a.runde()
        pruefen(a.a.verbunden && a.a.getrenntSeit == nil && a.e.ausstehend.isEmpty && a.a.warnText(a.e, jetzt: Date().addingTimeInterval(60)) == nil,
                "Wieder verbunden, Ausstehendes nachgesendet")
        await b.runde()
        pruefen(b.feld(terminId)?.text == "offline geändert" && b.feld(terminId)?.hintergrund == "#B71C1C" && t.text != "offline geändert",
                "B hat die nachgesendete Änderung")

        // Wiederkehrender Termin schaltet weiter ohne Senden
        a.e.felder[a.index(terminId)!].zeit = Zeit.minute(Date().addingTimeInterval(-10 * 60))
        a.e.felder[a.index(terminId)!].intervall = 15
        await a.runde()
        await b.runde()
        pruefen(b.feld(terminId)?.intervall == 15, "Wiederkehrender Termin bei B angekommen")
        let standVorher = a.e.abgleichStand
        let wa = a.e.termineWeiterschalten(Date()), wb = b.e.termineWeiterschalten(Date())
        await a.runde()
        let gesendetA = a.a.zuletztGesendet
        await b.runde()
        let gesendetB = b.a.zuletztGesendet
        await a.runde()
        pruefen(wa && wb && gesendetA == 0 && gesendetB == 0 && a.e.abgleichStand == standVorher
                && a.feld(terminId)?.zeit == b.feld(terminId)?.zeit && (a.feld(terminId)?.zeit ?? .distantPast) > Date(),
                "Wiederkehrender Termin schaltet auf beiden Plätzen weiter, ohne zu senden (Stand bleibt \(standVorher))")

        // Teilen ausschalten löscht nicht bei den anderen; neues Feld kommt an
        var neu = Feld(.text, text: "Neu von B")
        neu.hintergrund = "#FFD600"
        b.e.felder.append(neu)
        await b.runde()
        await a.runde()
        pruefen(a.feld(neu.id)?.text == "Neu von B" && a.feld(neu.id)?.hintergrund == "#FFD600", "Neues Feld von B kommt bei A an")
        b.e.felder[b.index(neu.id)!].geteilt = false
        await b.runde()
        b.e.felder.removeAll { $0.id == neu.id }
        await b.runde()
        await a.runde()
        pruefen(a.feld(neu.id) != nil && b.a.zuletztGesendet == 0, "Teilen aus und dann entfernen: bleibt bei A")

        // Einstellungsfenster war offen, während etwas ankam: Zusammenführen verliert nichts
        let fenster = b.e
        let beimOeffnen = Set(fenster.felder.map(\.id))
        var imFenster = fenster.felder
        let uhrId = imFenster.first { $0.art == .uhr }!.id
        imFenster[imFenster.firstIndex { $0.id == uhrId }!].titel = "Uhr im Fenster geändert"
        a.e.felder[a.index(terminId)!].text = "inzwischen von A"
        var neuA = Feld(.text, text: "Neu von A")
        neuA.groesse = 100
        a.e.felder.append(neuA)
        await a.runde()
        await b.runde()
        let zusammen = Abgleich.felderZusammenfuehren(fenster: imFenster, aktuell: b.e.felder, beimOeffnen: beimOeffnen)
        pruefen(zusammen.first { $0.id == terminId }?.text == "inzwischen von A" && zusammen.contains { $0.id == neuA.id }
                && zusammen.first { $0.id == uhrId }?.titel == "Uhr im Fenster geändert" && zusammen.count == b.e.felder.count,
                "Offenes Einstellungsfenster: Empfangenes bleibt beim Übernehmen erhalten, eigene Änderung auch")

        // Lage auf dem Server neu (Stand größer als der Server kennt): eigene geteilte Felder gehen noch einmal hinaus
        let geteiltA = a.e.felder.filter(\.geteilt).count
        a.e.abgleichStand = 99_999
        await a.runde()
        await a.runde()
        pruefen(a.a.zuletztGesendet == geteiltA && a.e.abgleichStand < 99_999, "Lage auf dem Server neu: \(geteiltA) geteilte Felder noch einmal gesendet")

        // Lage-Code falsch → Fehler vom Server
        let c = Platz("Test-C", adresse)
        c.e.lageCode = "ABC"
        pruefen(!Abgleich.aktiv(c.e) && c.a.statusText(c.e).contains("Lage-Code fehlt"), "Zu kurzer Code: \(c.a.statusText(c.e))")
        pruefen(Abgleich.adresse("beispiel.de/lage.php")?.absoluteString == "https://beispiel.de/lage.php"
                && Abgleich.adresse("http://beispiel.de/lage.php")?.absoluteString == "https://beispiel.de/lage.php"
                && Abgleich.adresse("http://127.0.0.1:8472/lage.php")?.absoluteString == "http://127.0.0.1:8472/lage.php",
                "Adresse: https:// ergänzt, http:// nur für 127.0.0.1/localhost")

        // Alte Einstellungen ohne die neuen Schlüssel laden weiter
        let alt = #"{"felder":[{"id":"ALT-0001-x","art":"termin","titel":"Alt"},{"id":"ALT-0002-x","art":"uhr"}],"schriftgroesse":24}"#
        let geladen = Einstellungen.dekodieren(Data(alt.utf8))
        pruefen(geladen?.felder.count == 2 && geladen?.felder[0].geteilt == true && geladen?.felder[1].geteilt == false
                && geladen?.abgleich == false && geladen?.abgleichStand == 0 && geladen?.schriftgroesse == 24,
                "Alte Einstellungen ohne Abgleich-Werte laden (Termin geteilt, Uhrzeit nicht)")
        return fehler
    }
}
