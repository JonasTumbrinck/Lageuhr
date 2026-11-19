import AppKit
import CryptoKit

// MARK: - Update über GitHub-Releases (nur die App, nicht der Bildschirmschoner)
//
// Versionsdatei: <Quelle>/releases/latest/download/lageuhr-version.txt (GitHub leitet auf das neueste Release um)
//   version 1.5.1
//   sha256 Lageuhr.exe <hex>
//   sha256 Lageuhr-mac.zip <hex>
//   neu <Text>            (beliebig viele; unbekannte Zeilen werden übergangen)
// Datei: <Quelle>/releases/download/v<version>/Lageuhr-mac.zip
//
// Die Suche im Hintergrund meldet nur. Installiert wird nie automatisch, sondern erst nach Rückfrage.

final class Update {
    struct Info {
        var version = ""
        var sha256: [String: String] = [:]
        var neu: [String] = []
    }

    enum Ergebnis {
        case neu(Info)
        case aktuell
        case fehler(String)
    }

    enum Fehler: Error {
        case text(String)
        case verschieben              // App läuft abgeschirmt aus dem Download-Ordner (AppTranslocation)
        case schreibgeschuetzt(String) // Ordner der App nicht beschreibbar

        var text: String {
            switch self {
            case .text(let t): return t
            case .verschieben:
                return "Die Lageuhr läuft noch aus dem Download-Ordner. Lageuhr erst in den Programme-Ordner verschieben, " +
                    "von dort starten und dann das Update installieren."
            case .schreibgeschuetzt(let o):
                return "Der Ordner „\(o)“ ist schreibgeschützt. Die neue Version von der Download-Seite laden " +
                    "und Lageuhr.app von Hand ersetzen."
            }
        }
        /// Fehler, bei denen der Knopf zur Download-Seite hilft
        var mitDownloadSeite: Bool { if case .text = self { return false }; return true }
    }

    // Umgebungsvariablen nur zum Testen
    static let quelle: String = {
        var q = ProcessInfo.processInfo.environment["LAGEUHR_UPDATE_QUELLE"] ?? "https://github.com/JonasTumbrinck/Lageuhr"
        while q.hasSuffix("/") { q.removeLast() }
        return q
    }()
    static let downloadSeite = URL(string: "https://github.com/JonasTumbrinck/Lageuhr/releases/latest")!
    static let zipName = "Lageuhr-mac.zip"
    static let bundleId = "local.lageuhr"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var kennung: String { "Lageuhr/\(version)" }
    static let ersteSucheNach: TimeInterval = 30
    static let abstand: TimeInterval = 24 * 3600

    /// Ordner für Lageuhr.saver, der beim Update mit ersetzt wird. Zum Testen per LAGEUHR_SCHONER_ORDNER umlenkbar;
    /// unter --profil (Test) ohne Umlenkung nil, d. h. nicht anfassen.
    static var schonerOrdner: URL? {
        if let u = schonerUmlenkung { return u }
        if CommandLine.arguments.contains("--profil") { return nil }
        return URL(fileURLWithPath: Lagebild.echtesZuhause + "/Library/Screen Savers")
    }
    static var schonerUmlenkung: URL? {
        guard let o = ProcessInfo.processInfo.environment["LAGEUHR_SCHONER_ORDNER"], !o.isEmpty else { return nil }
        return URL(fileURLWithPath: o)
    }

    // Zustand
    private(set) var verfuegbar: Info?
    private(set) var sucht = false
    private(set) var installiert = false        // Installation läuft
    private(set) var schritt: String?           // während der Installation
    private(set) var zuletztGesucht: Date?
    private(set) var fehler: String?
    var statusGeaendert: (() -> Void)?
    private var naechste = Date().addingTimeInterval(Update.ersteSucheNach)
    private var wartende: [(Ergebnis) -> Void] = []

    var beschaeftigt: Bool { sucht || installiert }

    private static func sitzung(_ sekunden: TimeInterval, gesamt: TimeInterval) -> URLSession {
        let k = URLSessionConfiguration.ephemeral
        k.timeoutIntervalForRequest = sekunden
        k.timeoutIntervalForResource = gesamt
        k.requestCachePolicy = .reloadIgnoringLocalCacheData
        k.waitsForConnectivity = false
        k.httpAdditionalHeaders = ["User-Agent": kennung]
        return URLSession(configuration: k)
    }
    private let kurz = Update.sitzung(15, gesamt: 15)
    private let lang = Update.sitzung(30, gesamt: 15 * 60) // Download: 30 s ohne Daten, höchstens 15 min

    // MARK: Text für Menü und Einstellungen

    var statusText: String {
        if let s = schritt { return s }
        if sucht { return "Suche nach Updates …" }
        if let v = verfuegbar { return "Version \(v.version) ist da (installiert: \(Self.version))" }
        if let f = fehler { return "Suche fehlgeschlagen – \(f)" }
        if let z = zuletztGesucht { return "Version \(Self.version) ist aktuell (gesucht um \(Self.hhmm(z)))" }
        return "Version \(Self.version)"
    }

    static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    // MARK: Zeitplan

    /// Im Takt aufrufen: sucht 30 s nach dem Start und dann alle 24 h (nur wenn `an`).
    func takt(an: Bool) {
        guard an, !beschaeftigt, Date() >= naechste else { return }
        suchen()
    }

    // MARK: Suchen

    func suchen(fertig: ((Ergebnis) -> Void)? = nil) {
        if let f = fertig { wartende.append(f) }
        guard !sucht else { return }
        guard !installiert else { melden(.fehler("Update wird gerade installiert")); return }
        guard let url = URL(string: Self.quelle + "/releases/latest/download/lageuhr-version.txt") else {
            melden(.fehler("Update-Adresse ungültig")); return
        }
        sucht = true
        statusGeaendert?()
        let r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        kurz.dataTask(with: r) { [weak self] daten, antwort, fehler in
            let ergebnis: Ergebnis
            if let t = Self.netzFehler(antwort, fehler) {
                ergebnis = .fehler(t)
            } else if let d = daten, d.count <= 64 * 1024, let text = String(data: d, encoding: .utf8), let info = Self.lesen(text) {
                ergebnis = Self.neuer(info.version, als: Self.version) ? .neu(info) : .aktuell
            } else {
                ergebnis = .fehler("Versionsdatei nicht lesbar")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.sucht = false
                self.zuletztGesucht = Date()
                self.naechste = Date().addingTimeInterval(Self.abstand)
                switch ergebnis {
                case .neu(let i): self.verfuegbar = i; self.fehler = nil
                case .aktuell: self.verfuegbar = nil; self.fehler = nil
                case .fehler(let t): self.fehler = t // ein bekanntes Update bleibt bekannt
                }
                self.melden(ergebnis)
            }
        }.resume()
    }

    private func melden(_ e: Ergebnis) {
        let w = wartende
        wartende = []
        statusGeaendert?()
        for f in w { f(e) }
    }

    /// Versionsdatei lesen; nil, wenn keine gültige Version darin steht.
    static func lesen(_ roh: String) -> Info? {
        var info = Info()
        for zeile in roh.replacingOccurrences(of: "\u{FEFF}", with: "").split(whereSeparator: \.isNewline) {
            let teile = zeile.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            guard let wort = teile.first else { continue }
            let rest = teile.count > 1 ? teile[1].trimmingCharacters(in: .whitespaces) : ""
            switch wort.lowercased() {
            case "version": info.version = rest
            case "sha256":
                let p = rest.split(whereSeparator: \.isWhitespace)
                if p.count == 2 { info.sha256[String(p[0])] = p[1].lowercased() }
            case "neu": if !rest.isEmpty { info.neu.append(rest) }
            default: break // unbekannte Zeilen übergehen
            }
        }
        return gueltig(info.version) ? info : nil
    }

    /// Nur Ziffern und Punkte (landet in der Download-Adresse).
    static func gueltig(_ v: String) -> Bool {
        !v.isEmpty && v.count <= 20 && v.allSatisfy { $0 == "." || ("0"..."9").contains($0) }
            && !v.hasPrefix(".") && !v.hasSuffix(".") && !v.contains("..")
    }

    /// Versionen numerisch je Teil vergleichen (1.10 > 1.9, 1.5 = 1.5.0).
    static func neuer(_ a: String, als b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static func netzFehler(_ antwort: URLResponse?, _ fehler: Error?) -> String? {
        if let f = fehler {
            guard let u = f as? URLError else { return f.localizedDescription }
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "keine Internetverbindung"
            case .timedOut: return "Zeitüberschreitung"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Server nicht erreichbar"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "sichere Verbindung fehlgeschlagen"
            default: return u.localizedDescription
            }
        }
        guard let h = antwort as? HTTPURLResponse else { return "keine Antwort" }
        if h.statusCode == 404 { return "keine Version gefunden (404)" }
        if h.statusCode != 200 { return "Server antwortet mit Fehler \(h.statusCode)" }
        return nil
    }

    // MARK: Installieren

    /// Ziel ist die laufende App. Prüft, ob sie ersetzt werden darf.
    static func zielPruefen() throws -> URL {
        let ziel = Bundle.main.bundleURL.resolvingSymlinksInPath()
        if ziel.path.contains("/AppTranslocation/") { throw Fehler.verschieben }
        guard ziel.pathExtension == "app" else { throw Fehler.text("Die Lageuhr läuft nicht als Lageuhr.app – Update nicht möglich.") }
        let ordner = ziel.deletingLastPathComponent().path
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: ordner), fm.isWritableFile(atPath: ziel.path) else { throw Fehler.schreibgeschuetzt(ordner) }
        return ziel
    }

    /// Lädt, prüft und ersetzt die App. `fertig` (auf dem Main-Thread): neue App und ggf. Warnung zum Bildschirmschoner.
    func installieren(_ info: Info, fertig: @escaping (Result<(URL, String?), Fehler>) -> Void) {
        guard !installiert else { return }
        let ziel: URL
        do { ziel = try Self.zielPruefen() } catch { fertig(.failure(error as? Fehler ?? .text(error.localizedDescription))); return }
        guard let hash = info.sha256[Self.zipName], hash.count == 64 else { fertig(.failure(.text("Prüfsumme für \(Self.zipName) fehlt in der Versionsdatei."))); return }
        guard Self.gueltig(info.version),
              let url = URL(string: Self.quelle + "/releases/download/v\(info.version)/\(Self.zipName)") else {
            fertig(.failure(.text("Update-Adresse ungültig"))); return
        }
        installiert = true
        schrittSetzen("Lade Version \(info.version) …")

        let ende: (Result<(URL, String?), Fehler>) -> Void = { [weak self] r in
            DispatchQueue.main.async {
                self?.installiert = false
                self?.schritt = nil
                if case .success = r { self?.verfuegbar = nil }
                self?.statusGeaendert?()
                fertig(r)
            }
        }

        // Arbeitsordner auf demselben Laufwerk wie die App (für das Ersetzen)
        let fm = FileManager.default
        let arbeit: URL
        do {
            arbeit = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: ziel, create: true)
        } catch {
            arbeit = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lageuhr-update-" + UUID().uuidString)
            try? fm.createDirectory(at: arbeit, withIntermediateDirectories: true)
        }
        let zip = arbeit.appendingPathComponent(Self.zipName)

        let r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        lang.downloadTask(with: r) { [weak self] datei, antwort, fehler in
            if let t = Self.netzFehler(antwort, fehler) {
                try? fm.removeItem(at: arbeit)
                ende(.failure(.text("Download fehlgeschlagen – \(t)"))); return
            }
            guard let d = datei, (try? fm.moveItem(at: d, to: zip)) != nil else {
                try? fm.removeItem(at: arbeit)
                ende(.failure(.text("Download fehlgeschlagen"))); return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Self.pruefenUndErsetzen(zip: zip, arbeit: arbeit, ziel: ziel, info: info, hash: hash) { t in
                    DispatchQueue.main.async { self?.schrittSetzen(t) }
                }
                try? fm.removeItem(at: arbeit)
                ende(r)
            }
        }.resume()
    }

    private func schrittSetzen(_ t: String) { schritt = t; statusGeaendert?() }

    private static func pruefenUndErsetzen(zip: URL, arbeit: URL, ziel: URL, info: Info, hash: String,
                                           schritt: (String) -> Void) -> Result<(URL, String?), Fehler> {
        let fm = FileManager.default
        schritt("Prüfe Version \(info.version) …")
        guard let ist = try? sha256(zip) else { return .failure(.text("Download nicht lesbar")) }
        guard ist == hash else { return .failure(.text("Prüfsumme stimmt nicht – Download beschädigt oder verändert. Es wurde nichts geändert.")) }

        let aus = arbeit.appendingPathComponent("entpackt")
        let (dOk, dText) = ausfuehren("/usr/bin/ditto", ["-x", "-k", zip.path, aus.path])
        guard dOk else { return .failure(.text("Entpacken fehlgeschlagen" + (dText.isEmpty ? "" : " – " + dText))) }
        let neu = aus.appendingPathComponent("Lageuhr.app")
        guard fm.fileExists(atPath: neu.path) else { return .failure(.text("Lageuhr.app fehlt im Download")) }

        let (sOk, sText) = ausfuehren("/usr/bin/codesign", ["--verify", "--deep", "--strict", neu.path])
        guard sOk else { return .failure(.text("Signatur ungültig" + (sText.isEmpty ? "" : " – " + sText))) }
        guard let plist = NSDictionary(contentsOf: neu.appendingPathComponent("Contents/Info.plist")) else {
            return .failure(.text("Info.plist fehlt im Download"))
        }
        guard plist["CFBundleIdentifier"] as? String == bundleId else { return .failure(.text("Download ist keine Lageuhr")) }
        let v = plist["CFBundleShortVersionString"] as? String ?? "?"
        guard v == info.version else { return .failure(.text("Download hat Version \(v) statt \(info.version)")) }

        schritt("Installiere Version \(info.version) …")
        let fertig: URL
        do {
            fertig = try fm.replaceItemAt(ziel, withItemAt: neu, backupItemName: nil, options: []) ?? ziel
        } catch {
            return .failure(.text("Ersetzen fehlgeschlagen – \(error.localizedDescription)"))
        }
        return .success((fertig, schonerErsetzen(aus: fertig)))
    }

    /// Ist der Bildschirmschoner eingerichtet, ihn durch den aus der neuen App ersetzen. Liefert eine Warnung bei Fehlern.
    static func schonerErsetzen(aus app: URL) -> String? {
        guard let ordner = schonerOrdner else { return nil }
        let fm = FileManager.default
        let alt = ordner.appendingPathComponent("Lageuhr.saver")
        guard fm.fileExists(atPath: alt.path) else { return nil }
        let quelle = app.appendingPathComponent("Contents/Resources/Lageuhr.saver")
        guard fm.fileExists(atPath: quelle.path) else { return "Bildschirmschoner fehlt in der neuen Version – der alte bleibt." }
        do {
            let tmp = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: alt, create: true)
            defer { try? fm.removeItem(at: tmp) }
            let kopie = tmp.appendingPathComponent("Lageuhr.saver")
            try fm.copyItem(at: quelle, to: kopie)
            _ = try fm.replaceItemAt(alt, withItemAt: kopie, backupItemName: nil, options: [])
            return nil
        } catch {
            return "Bildschirmschoner nicht ersetzt – \(error.localizedDescription). Bei Bedarf neu einrichten."
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var s = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { s.update(data: d) }
        return s.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Programm ausführen und warten; liefert Erfolg und (gekürzte) Ausgabe.
    static func ausfuehren(_ programm: String, _ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: programm)
        p.arguments = args
        let rohr = Pipe()
        p.standardOutput = rohr
        p.standardError = rohr
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let d = rohr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let t = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus == 0, String(t.prefix(300)))
    }

    // MARK: Neustart

    /// Startet die (neue) App nach 1 s neu. Der Pfad geht als eigenes Argument an die Shell, nicht in den Befehlstext.
    static func neuStarten(_ app: URL, zusatz: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$0\" --args \"$@\"", app.path, "--nach-update"] + zusatz
        try p.run()
    }
}
