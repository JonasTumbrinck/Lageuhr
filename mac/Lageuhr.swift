// Lageuhr für macOS – Kasten auf dem Bildschirm mit Feldern: Text, taktische Zeit, „Seit …“, Termin mit Countdown.
// Bauen: ./bauen.sh (im Ordner darüber)
import AppKit
import Network
import IOKit.pwr_mgt


final class KastenFenster: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar // auch über Vollbild-Präsentationen
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class KastenAnsicht: NSView {
    weak var steuerung: Steuerung?
    var e: Einstellungen { steuerung?.e ?? Einstellungen() }

    private var anordnung = Anordnung()
    private var mausDrin = false
    private var skaliert = false
    private var skalStart = NSPoint.zero, skalBreite: CGFloat = 1, skalPunkt: Double = 30
    private var rollRest: CGFloat = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var faktor: CGFloat { CGFloat(e.schriftgroesse) / 30 }
    let griff: CGFloat = 20
    var griffVerschieben: NSRect { NSRect(x: 0, y: 0, width: griff, height: griff) }
    var griffGroesse: NSRect { NSRect(x: bounds.width - griff, y: bounds.height - griff, width: griff, height: griff) }

    // Inhalt anordnen, liefert die nötige Größe
    func anordnen(_ bloecke: [Block]) -> NSSize {
        anordnung = Anordnung(bloecke, schriftgroesse: e.schriftgroesse, nebeneinander: e.nebeneinander, schriftfarbe: e.schriftfarbe,
                              leerHinweis: "Keine Felder – Doppelklick für Einstellungen")
        needsDisplay = true
        return anordnung.groesse
    }

    // MARK: Lasche (angedockt und eingeklappt)

    private var laschenSchrift: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .bold) }

    private func laschenText(_ seite: Int) -> String {
        let t = steuerung?.laschenZeit ?? "--:--"
        if seite == 1 || seite == 2 { return t.replacingOccurrences(of: ":", with: "\n") }
        return t
    }

    func laschenGroesse(_ seite: Int) -> NSSize {
        let s = NSAttributedString(string: laschenText(seite), attributes: [.font: laschenSchrift]).size()
        if seite == 1 || seite == 2 { return NSSize(width: ceil(s.width) + 14, height: ceil(s.height) + 34) }
        return NSSize(width: ceil(s.width) + 40, height: ceil(s.height) + 12)
    }

    private func laschenZeichnen() {
        let seite = e.andocken
        let stufe = steuerung?.warnstufe ?? 0
        let blinkAn = Uhr.jetzt().timeIntervalSince1970.truncatingRemainder(dividingBy: 1) < 0.5
        var grund = NSColor(hex: e.hintergrund), schrift = NSColor(hex: e.schriftfarbe)
        if stufe == 2 && blinkAn { grund = NSColor(hex: "#D32F2F"); schrift = .white }
        if stufe == 1 { grund = NSColor(hex: "#FFC107"); schrift = .black }
        // Ecken an der Bildschirmkante liegen außerhalb und werden nicht gezeichnet
        var r = bounds
        switch seite {
        case 1: r.origin.x -= 12; r.size.width += 12
        case 2: r.size.width += 12
        case 3: r.origin.y -= 12; r.size.height += 12 // Ansicht ist gespiegelt: oben = y 0
        default: r.size.height += 12
        }
        let form = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        grund.setFill(); form.fill()
        schrift.gemischt(mit: grund, anteil: 0.25).setStroke(); form.lineWidth = 1; form.stroke()

        let absatz = NSMutableParagraphStyle(); absatz.alignment = .center
        let text = NSAttributedString(string: laschenText(seite), attributes: [.font: laschenSchrift, .foregroundColor: schrift, .paragraphStyle: absatz])
        let pfeil = ["", "›", "‹", "⌄", "⌃"][max(0, min(4, seite))]
        let pf = NSAttributedString(string: pfeil, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .bold),
                                                                .foregroundColor: schrift.gemischt(mit: grund, anteil: 0.7), .paragraphStyle: absatz])
        let ts = text.size(), ps = pf.size()
        if seite == 1 || seite == 2 {
            text.draw(in: NSRect(x: 0, y: 8, width: bounds.width, height: ts.height))
            pf.draw(in: NSRect(x: 0, y: bounds.height - ps.height - 4, width: bounds.width, height: ps.height))
        } else {
            text.draw(in: NSRect(x: 8, y: (bounds.height - ts.height) / 2, width: ts.width + 4, height: ts.height))
            pf.draw(in: NSRect(x: bounds.width - ps.width - 10, y: (bounds.height - ps.height) / 2 + (seite == 3 ? -2 : 3), width: ps.width + 4, height: ps.height))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if steuerung?.eingeklappt == true { laschenZeichnen(); return }
        let grund = NSColor(hex: e.hintergrund)
        let schrift = NSColor(hex: e.schriftfarbe)
        let form = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        grund.setFill(); form.fill()
        schrift.gemischt(mit: grund, anteil: 0.22).setStroke(); form.lineWidth = 1; form.stroke()
        anordnung.zeichnen(trennfarbe: schrift.gemischt(mit: grund, anteil: 0.22))

        if !e.fixiert && (mausDrin || skaliert) {
            schrift.gemischt(mit: grund, anteil: 0.55).setFill()
            let d: CGFloat = 3, a: CGFloat = 5, o: CGFloat = 4
            for i in 0..<3 { for j in 0..<3 {
                NSBezierPath(ovalIn: NSRect(x: o + CGFloat(i) * a, y: o + CGFloat(j) * a, width: d, height: d)).fill()
            } }
            let bx = bounds.width - o - d, by = bounds.height - o - d
            for i in 0..<3 { for j in 0...i {
                NSBezierPath(ovalIn: NSRect(x: bx - CGFloat(i - j) * a, y: by - CGFloat(j) * a, width: d, height: d)).fill()
            } }
        }
    }

    // MARK: Maus

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { mausDrin = true; needsDisplay = true; steuerung?.mausRein() }
    override func mouseExited(with event: NSEvent) {
        if !skaliert { mausDrin = false; needsDisplay = true; NSCursor.arrow.set(); steuerung?.mausRaus() }
    }
    var ziehtGroesse: Bool { skaliert }

    override func cursorUpdate(with event: NSEvent) { zeigerSetzen(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { zeigerSetzen(convert(event.locationInWindow, from: nil)) }

    private func zeigerSetzen(_ p: NSPoint) {
        if e.fixiert { NSCursor.arrow.set() }
        else if griffVerschieben.contains(p) { NSCursor.openHand.set() }
        else if griffGroesse.contains(p) {
            if #available(macOS 15.0, *) { NSCursor.frameResize(position: .bottomRight, directions: .all).set() }
            else { NSCursor.crosshair.set() }
        } else { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if steuerung?.eingeklappt == true { steuerung?.ausklappen(); return }
        if event.clickCount == 2 { steuerung?.einstellungenOeffnen(); return }
        guard !e.fixiert else { return }
        if griffVerschieben.contains(p) {
            NSCursor.closedHand.set()
            window?.performDrag(with: event)
            steuerung?.nachVerschieben()
        } else if griffGroesse.contains(p) {
            skaliert = true
            skalStart = NSEvent.mouseLocation
            skalBreite = bounds.width
            skalPunkt = e.schriftgroesse
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard skaliert else { return }
        let dx = NSEvent.mouseLocation.x - skalStart.x
        let pt = Einstellungen.begrenzen((skalPunkt * Double((skalBreite + dx) / skalBreite) * 2).rounded() / 2)
        steuerung?.schriftSetzen(pt, obenLinksFest: true, speichern: false)
    }

    override func mouseUp(with event: NSEvent) {
        if skaliert {
            skaliert = false
            steuerung?.schriftSetzen(e.schriftgroesse, obenLinksFest: true, speichern: true)
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        rollRest += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : (event.scrollingDeltaY > 0 ? 1 : event.scrollingDeltaY < 0 ? -1 : 0)
        let schritte = rollRest.rounded(.towardZero)
        if schritte != 0 {
            rollRest -= schritte
            steuerung?.schriftSetzen(e.schriftgroesse + Double(schritte), obenLinksFest: false, speichern: true)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        steuerung?.menueFuellen(m)
        m.delegate = steuerung // merkt sich, dass ein Menü offen ist (dann nicht einklappen)
        return m
    }
}

// MARK: - Steuerung

final class Steuerung: NSObject, NSMenuDelegate {
    var e = Einstellungen.laden()
    let fenster = KastenFenster()
    let ansicht = KastenAnsicht()
    var statusItem: NSStatusItem?
    var timer: Timer?
    var letzte: [Block] = []
    var letzteDarstellung = ""
    var einstellungen: EinstellungenFenster?
    var obenLinksFest = false
    let nachlauf: TimeInterval = 5 * 60

    // Andocken und Einklappen
    var eingeklappt = false
    var boxGroesse = NSSize(width: 200, height: 100)
    var laschenZeit = "--:--"
    var warnstufe = 0          // 0 = nichts, 1 = Termin in ≤ 10 min, 2 = Termin JETZT
    private var rausSeit: Date?
    private var offeneMenues = 0
    var angedockt: Bool { e.andocken != 0 }
    var klappbar: Bool { angedockt && e.einklappen && !e.durchklickbar }

    // Abgleich zwischen Arbeitsplätzen
    let abgleich = Abgleich()

    // Update (Update.swift)
    let update = Update()
    private var aktualisiertBis: Date?   // nach einem Update kurz „aktualisiert“ im Tooltip zeigen

    // Atomuhr
    var zeitStatus = "Noch nicht abgeglichen"
    private var abgleichLaeuft = false
    private var naechsterAbgleich = Date.distantPast
    private var letzterAbgleich: Date?

    // Vollbild-Lagebild
    private var vollbild: [NSWindow] = []
    private var vollbildMaus = NSPoint.zero
    private var vollbildSeit = Date()
    private var vollbildMonitor: Any?
    private var wachHalten: IOPMAssertionID = 0
    private var aktivGemeldet = Date.distantPast
    var vollbildAktiv: Bool { !vollbild.isEmpty }

    func starten(mitStatusSymbol: Bool = true) {
        ansicht.steuerung = self
        // Hülle: der Inhalt gleitet beim Ein- und Ausklappen innerhalb des Fensters (nichts ragt auf einen Nachbarbildschirm)
        let huelle = NSView(frame: fenster.contentRect(forFrameRect: fenster.frame))
        huelle.wantsLayer = true
        fenster.contentView = huelle
        ansicht.frame = huelle.bounds
        ansicht.autoresizingMask = [.width, .height]
        ansicht.wantsLayer = true
        huelle.addSubview(ansicht)
        deckkraftSetzen()
        fenster.ignoresMouseEvents = e.durchklickbar
        if e.arbeitsplatz.isEmpty { e.arbeitsplatz = Abgleich.rechnername }
        abgleich.lesen = { [unowned self] in self.e }
        abgleich.schreiben = { [unowned self] neu in self.vomAbgleich(neu) }
        abgleich.statusGeaendert = { [unowned self] in self.einstellungen?.abgleichStatusZeigen(self.abgleich.statusText(self.e, ausfuehrlich: true)) }
        update.statusGeaendert = { [unowned self] in self.updateGeaendert() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.naechsterAbgleich = .distantPast // nach dem Ruhezustand neu abgleichen
            self?.abgleich.bald()
        }

        if mitStatusSymbol {
            let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            s.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Lageuhr")
            let m = NSMenu()
            m.delegate = self
            s.menu = m
            statusItem = s
            updateGeaendert()
        }

        aktualisieren(erzwingen: true)
        positionSetzen()
        einblenden()
        Lagebild.schreiben(e, versatz: Uhr.versatz)

        let automatisch = !argumente.contains("--updatetest")
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            s.aktualisieren(); s.abgleich.takt()
            s.update.takt(an: s.e.updateSuchen && automatisch) // sucht nur, installiert nie selbst
        }
        RunLoop.main.add(t, forMode: .common) // läuft auch, während ein Menü offen ist
        timer = t
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.positionSetzen()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { menu.removeAllItems(); menueFuellen(menu) }
    func menuWillOpen(_ menu: NSMenu) { offeneMenues += 1 }
    func menuDidClose(_ menu: NSMenu) { offeneMenues = max(0, offeneMenues - 1) }

    // MARK: Atomuhr

    func zeitAbgleichen(server: String? = nil, fertig: ((String) -> Void)? = nil) {
        guard !abgleichLaeuft else { return }
        abgleichLaeuft = true
        zeitStatus = "Gleiche ab …"
        Atomuhr.abgleichen(server ?? e.zeitserver) { [weak self] v, s in
            guard let self = self else { return }
            self.abgleichLaeuft = false
            if let v = v, let s = s, self.e.atomuhr || server != nil {
                Uhr.versatz = v
                self.letzterAbgleich = Date()
                self.zeitStatus = "Atomuhr: abgeglichen um \(Zeit.uhrzeit(Uhr.jetzt())) mit \(s) – \(Uhr.abweichungText(v))"
                self.naechsterAbgleich = Date().addingTimeInterval(30 * 60)
            } else {
                self.zeitStatus = "Atomuhr nicht erreichbar – " +
                    (self.letzterAbgleich != nil ? "letzter Abgleich gilt weiter" : "es gilt die Rechnerzeit")
                self.naechsterAbgleich = Date().addingTimeInterval(120)
            }
            self.aktualisieren(erzwingen: true)
            Lagebild.schreiben(self.e, versatz: Uhr.versatz)
            fertig?(self.zeitStatus)
        }
    }

    // MARK: Maus, Andocken, Einklappen

    func deckkraftSetzen() {
        let voll = e.deckendBeiMaus && !e.durchklickbar && !eingeklappt &&
            fenster.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        fenster.alphaValue = voll || eingeklappt ? 1 : CGFloat(e.deckkraft) / 100
    }

    func mausRein() {
        rausSeit = nil
        if eingeklappt { ausklappen() }
        deckkraftSetzen()
    }

    func mausRaus() { deckkraftSetzen() }

    // MARK: Animation

    private(set) var animiert = false
    /// Nur zum Testen: LAGEUHR_ZEITLUPE=10 macht alle Animationen zehnmal langsamer.
    private let zeitlupe = Double(ProcessInfo.processInfo.environment["LAGEUHR_ZEITLUPE"] ?? "") ?? 1

    /// Verschiebung des Inhalts zur angedockten Kante hin (Anteil der Größe; 1 = ganz hinaus).
    private func zurKante(_ g: NSSize, _ anteil: CGFloat) -> NSPoint {
        switch e.andocken {
        case 1: return NSPoint(x: -g.width * anteil, y: 0)
        case 2: return NSPoint(x: g.width * anteil, y: 0)
        case 3: return NSPoint(x: 0, y: g.height * anteil)   // Hülle ist nicht gespiegelt: y nach oben
        case 4: return NSPoint(x: 0, y: -g.height * anteil)
        default: return .zero
        }
    }

    /// Inhalt von `von` an seinen Platz gleiten lassen und dabei einblenden.
    private func hereingleiten(von: NSPoint, alpha: CGFloat, dauer: TimeInterval, fertig: (() -> Void)? = nil) {
        animiert = true
        ansicht.setFrameOrigin(von)
        ansicht.alphaValue = alpha
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = dauer * zeitlupe
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ansicht.animator().setFrameOrigin(.zero)
            ansicht.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.animiert = false
            self?.fenster.invalidateShadow()
            fertig?()
        })
    }

    func ausklappen() {
        guard eingeklappt else { return }
        eingeklappt = false
        rausSeit = nil
        aktualisieren(erzwingen: true)
        deckkraftSetzen()
        hereingleiten(von: zurKante(boxGroesse, 0.35), alpha: 0.15, dauer: 0.18)
    }

    func einklappen() {
        guard klappbar, !eingeklappt, !animiert else { return }
        animiert = true
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.16 * zeitlupe
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ansicht.animator().setFrameOrigin(zurKante(ansicht.bounds.size, 0.6))
            ansicht.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.animiert = false
            // Maus inzwischen zurück? Dann wieder hereingleiten statt einklappen.
            if self.fenster.frame.contains(NSEvent.mouseLocation) {
                self.hereingleiten(von: self.ansicht.frame.origin, alpha: self.ansicht.alphaValue, dauer: 0.12)
                return
            }
            self.eingeklappt = true
            self.ansicht.setFrameOrigin(.zero)
            self.aktualisieren(erzwingen: true)
            self.deckkraftSetzen()
            self.hereingleiten(von: self.zurKante(self.ansicht.laschenGroesse(self.e.andocken), 1), alpha: 0.3, dauer: 0.12)
        })
    }

    /// Kasten einblenden (Start, Menü „Einblenden“).
    func einblenden() {
        deckkraftSetzen()
        let ziel = fenster.alphaValue
        fenster.alphaValue = 0
        fenster.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.2 * zeitlupe
            fenster.animator().alphaValue = ziel
        }
    }

    /// Kasten ausblenden (Menü „Ausblenden“), erreichbar bleibt er über das Uhr-Symbol.
    func ausblenden() {
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.18 * zeitlupe
            fenster.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.fenster.orderOut(nil)
            self?.deckkraftSetzen()
        })
    }

    /// Prüft im Takt, ob die Maus den ausgeklappten Kasten verlassen hat (1 s Nachlauf wie beim Dock).
    private func einklappenPruefen() {
        guard !animiert else { return }
        if !klappbar { if eingeklappt { ausklappen() }; return }
        guard !eingeklappt else { return }
        let drin = fenster.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if drin || offeneMenues > 0 || einstellungen != nil || ansicht.ziehtGroesse || NSEvent.pressedMouseButtons != 0 {
            rausSeit = nil
        } else if let r = rausSeit {
            if Date().timeIntervalSince(r) > 1.0 { einklappen() }
        } else { rausSeit = Date() }
    }

    /// Bildschirm, an dem angedockt wird: der mit der gemerkten Ecke, sonst der aktuelle.
    private func dockBereich() -> NSRect {
        let p = NSPoint(x: (e.links ?? fenster.frame.minX) + 1, y: (e.oben ?? fenster.frame.maxY) - 1)
        let s = NSScreen.screens.first { $0.frame.contains(p) } ?? fenster.screen ?? NSScreen.main
        return s?.visibleFrame ?? fenster.frame
    }

    private func dockRahmenSetzen() {
        let b = dockBereich()
        let seite = e.andocken
        let box = boxGroesse
        let s = eingeklappt ? ansicht.laschenGroesse(seite) : box
        var r = NSRect(origin: .zero, size: s)
        if seite == 1 || seite == 2 {
            let oben = min(b.maxY, max(b.minY + box.height, e.oben ?? b.maxY))
            r.origin.x = seite == 1 ? b.minX : b.maxX - s.width
            r.origin.y = eingeklappt ? oben - box.height / 2 - s.height / 2 : oben - s.height
        } else {
            let links = min(b.maxX - box.width, max(b.minX, e.links ?? b.minX))
            r.origin.y = seite == 3 ? b.maxY - s.height : b.minY
            r.origin.x = eingeklappt ? links + box.width / 2 - s.width / 2 : links
        }
        if fenster.frame != r { fenster.setFrame(r, display: true) }
        ansicht.needsDisplay = true
    }

    /// Nach dem Verschieben: nah an einer Bildschirmkante andocken, sonst frei schweben.
    func nachVerschieben() {
        let f = fenster.frame
        let b = (fenster.screen ?? NSScreen.main)?.visibleFrame ?? f
        let abstaende: [(Int, CGFloat)] = [(1, f.minX - b.minX), (2, b.maxX - f.maxX), (3, b.maxY - f.maxY), (4, f.minY - b.minY)]
        let naechste = abstaende.min { $0.1 < $1.1 }!
        e.links = f.minX
        e.oben = f.maxY
        e.andocken = naechste.1 <= 12 ? naechste.0 : 0
        geaendert()
    }

    func andocken(_ seite: Int) {
        e.links = fenster.frame.minX
        e.oben = fenster.frame.maxY
        e.andocken = seite
        eingeklappt = false
        rausSeit = nil
        geaendert()
    }

    // MARK: Inhalt

    func bloecke(_ jetzt: Date) -> [Block] {
        var b = bloeckeBauen(e, jetzt, nachlauf: nachlauf)
        if let t = abgleich.warnText(e, jetzt: jetzt) { // Abgleich länger als 30 s getrennt: klein unten im Kasten
            let grund = NSColor(hex: e.hintergrund), schrift = NSColor(hex: e.schriftfarbe)
            let farbe = warnfarbe(["#FFC107", "#B26A00"], grund: grund, schrift: schrift)
            b.append(Block(art: .text, titel: nil, wert: t, zusatz: nil, titelFarbe: farbe, wertFarbe: farbe, zusatzFarbe: farbe,
                           hintergrund: nil, faktor: 0.6))
        }
        return b
    }

    func aktualisieren(erzwingen: Bool = false, jetzt: Date = Uhr.jetzt()) {
        // Wiederkehrende Termine: 5 Minuten nach Beginn auf den nächsten springen
        if e.termineWeiterschalten(jetzt, nachlauf: nachlauf) { e.speichern(); Lagebild.schreiben(e, versatz: Uhr.versatz) }

        // Atomuhr: beim Start, dann alle 30 Minuten (bei Fehler nach 2 Minuten erneut)
        if e.atomuhr && !abgleichLaeuft && Date() >= naechsterAbgleich { zeitAbgleichen() }
        if !e.atomuhr && Uhr.versatz != 0 { Uhr.versatz = 0; zeitStatus = "Atomuhr-Abgleich ist aus – es gilt die Rechnerzeit" }

        // Lasche: Uhrzeit und Warnung bei bevorstehendem Termin
        let c = Calendar.current.dateComponents([.hour, .minute], from: jetzt)
        laschenZeit = String(format: "%02d:%02d", c.hour!, c.minute!)
        warnstufe = 0
        for f in e.felder where f.art == .termin && f.sichtbar {
            guard let t = f.zeit else { continue }
            let rest = t.timeIntervalSince(jetzt)
            if rest <= 0 && -rest < nachlauf { warnstufe = 2 } else if rest > 0 && rest <= 600 { warnstufe = max(warnstufe, 1) }
        }
        einklappenPruefen()
        vollbildPruefen(jetzt)
        if eingeklappt && warnstufe == 2 { ansicht.needsDisplay = true } // Lasche blinkt

        let neu = bloecke(jetzt)
        let darstellung = "\(e.schriftgroesse)|\(e.nebeneinander)|\(e.hintergrund)|\(e.schriftfarbe)|\(e.fixiert)|\(e.andocken)|\(eingeklappt)|\(eingeklappt ? laschenZeit : "")|\(warnstufe)"
        guard erzwingen || neu != letzte || darstellung != letzteDarstellung else { return }
        letzte = neu
        letzteDarstellung = darstellung
        groesseSetzen(ansicht.anordnen(neu))
    }

    func groesseSetzen(_ s: NSSize) {
        boxGroesse = s
        if angedockt { dockRahmenSetzen(); return }
        var f = fenster.frame
        guard f.size != s else { ansicht.needsDisplay = true; return }
        let bereich = (fenster.screen ?? NSScreen.main)?.visibleFrame ?? f
        let rechts = !obenLinksFest && f.midX > bereich.midX
        let unten = !obenLinksFest && f.midY < bereich.midY
        f.origin.x = rechts ? f.maxX - s.width : f.minX
        f.origin.y = unten ? f.minY : f.maxY - s.height
        f.size = s
        fenster.setFrame(f, display: true)
    }

    func positionSetzen() {
        if angedockt { dockRahmenSetzen(); return }
        let s = fenster.frame.size
        if let x = e.links, let y = e.oben {
            let r = NSRect(x: x, y: y - s.height, width: s.width, height: s.height)
            if NSScreen.screens.contains(where: { let i = $0.visibleFrame.intersection(r); return i.width >= 40 && i.height >= 30 }) {
                fenster.setFrameOrigin(r.origin); return
            }
        }
        if let b = NSScreen.main?.visibleFrame {
            fenster.setFrameOrigin(NSPoint(x: b.maxX - s.width - 20, y: b.maxY - s.height - 20))
        }
    }

    func positionMerken() {
        if !angedockt { // angedockt bleibt die gemerkte Stelle an der Kante
            e.links = fenster.frame.minX
            e.oben = fenster.frame.maxY
        }
        e.speichern()
    }

    func schriftSetzen(_ pt: Double, obenLinksFest fest: Bool, speichern: Bool) {
        e.schriftgroesse = Einstellungen.begrenzen(pt)
        obenLinksFest = fest
        aktualisieren(erzwingen: true)
        obenLinksFest = false
        if speichern { positionMerken() }
    }

    func geaendert() {
        abgleich.bald()
        e.speichern()
        Lagebild.schreiben(e, versatz: Uhr.versatz)
        fenster.ignoresMouseEvents = e.durchklickbar
        if !klappbar { eingeklappt = false }
        aktualisieren(erzwingen: true)
        deckkraftSetzen()
    }

    /// Ergebnis einer Abgleich-Runde übernehmen (Felder von anderen Plätzen, Stand, Signaturen).
    func vomAbgleich(_ neu: Einstellungen) {
        e = neu
        e.speichern()
        Lagebild.schreiben(e, versatz: Uhr.versatz)
        aktualisieren(erzwingen: true)
    }

    func feldSetzen(_ id: String, _ aendern: (inout Feld) -> Void) {
        guard let i = e.felder.firstIndex(where: { $0.id == id }) else { return }
        aendern(&e.felder[i])
        geaendert()
    }

    // MARK: Vollbild-Lagebild

    /// Sekunden seit der letzten Eingabe (Maus, Tastatur) im ganzen System.
    private var leerlauf: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Im Takt: Vollbild nach Leerlauf zeigen, laufendes Vollbild aktualisieren oder bei Bewegung beenden.
    private func vollbildPruefen(_ jetzt: Date) {
        // Solange das Vollbild nach Leerlauf eingeschaltet ist: Bildschirmschoner und Bildschirm-Aus unterdrücken
        let halten = e.vollbildNachMin > 0
        if halten && wachHalten == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Lageuhr: Vollbild-Lagebild statt Bildschirmschoner" as CFString, &wachHalten)
        } else if !halten && wachHalten != 0 {
            IOPMAssertionRelease(wachHalten)
            wachHalten = 0
        }

        if vollbildAktiv {
            for w in vollbild { (w.contentView as? LagebildAnsicht)?.e = e; (w.contentView as? LagebildAnsicht)?.aktualisieren(jetzt: jetzt) }
            // „Nutzer aktiv“ melden, damit der Mac-Bildschirmschoner nicht über dem Lagebild startet
            if Date().timeIntervalSince(aktivGemeldet) > 20 {
                var id: IOPMAssertionID = 0
                IOPMAssertionDeclareUserActivity("Lageuhr: Vollbild-Lagebild" as CFString, kIOPMUserActiveLocal, &id)
                aktivGemeldet = Date()
            }
            let m = NSEvent.mouseLocation
            if Date().timeIntervalSince(vollbildSeit) > 0.8 && hypot(m.x - vollbildMaus.x, m.y - vollbildMaus.y) > 8 { vollbildBeenden() }
            return
        }
        guard halten, einstellungen == nil, offeneMenues == 0 else { return }
        // vor dem Mac-Bildschirmschoner da sein, sonst würde er zuerst starten
        var grenze = Double(e.vollbildNachMin) * 60
        if let warten = CFPreferencesCopyValue("idleTime" as CFString, "com.apple.screensaver" as CFString,
                                               kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int, warten > 20 {
            grenze = min(grenze, Double(warten - 10))
        }
        if leerlauf >= grenze { vollbildZeigen() }
    }

    func vollbildZeigen() {
        guard !vollbildAktiv else { return }
        let bildschirme = e.vollbildAlle ? NSScreen.screens : [fenster.screen ?? NSScreen.main].compactMap { $0 }
        for b in bildschirme {
            let w = VollbildFenster(contentRect: b.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.backgroundColor = NSColor(hex: Einstellungen.lagebildGrund)
            w.isReleasedWhenClosed = false
            let v = LagebildAnsicht(frame: NSRect(origin: .zero, size: b.frame.size))
            v.e = e
            w.contentView = v
            w.setFrame(b.frame, display: false)
            v.aktualisieren(jetzt: Uhr.jetzt())
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.4; w.animator().alphaValue = 1 }
            vollbild.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        vollbild.first?.makeKeyAndOrderFront(nil)
        NSCursor.hide()
        vollbildMaus = NSEvent.mouseLocation
        vollbildSeit = Date()
        vollbildMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] _ in
            self?.vollbildBeenden()
            return nil
        }
    }

    func vollbildBeenden() {
        guard vollbildAktiv else { return }
        if let m = vollbildMonitor { NSEvent.removeMonitor(m); vollbildMonitor = nil }
        NSCursor.unhide()
        let fenster = vollbild
        vollbild = []
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.25
            for w in fenster { w.animator().alphaValue = 0 }
        }, completionHandler: { for w in fenster { w.orderOut(nil) } })
    }

    // MARK: Bildschirmschoner

    /// Kopiert Lageuhr.saver nach ~/Library/Screen Savers und öffnet die Einstellungen zum Auswählen.
    func bildschirmschonerEinrichten() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        guard let quelle = Bundle.main.url(forResource: "Lageuhr", withExtension: "saver") else {
            a.messageText = "Bildschirmschoner nicht gefunden"
            a.informativeText = "Lageuhr.saver fehlt in dieser Lageuhr. Bitte die vollständige Lageuhr.app verwenden."
            a.runModal()
            return
        }
        let ziel = (Update.schonerUmlenkung ?? URL(fileURLWithPath: Lagebild.echtesZuhause + "/Library/Screen Savers"))
            .appendingPathComponent("Lageuhr.saver")
        do {
            try FileManager.default.createDirectory(at: ziel.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: ziel.path) { try FileManager.default.removeItem(at: ziel) }
            try FileManager.default.copyItem(at: quelle, to: ziel)
        } catch {
            a.messageText = "Einrichten hat nicht geklappt"
            a.informativeText = error.localizedDescription
            a.runModal()
            return
        }
        Lagebild.schreiben(e, versatz: Uhr.versatz)
        a.messageText = "Bildschirmschoner „Lageuhr“ ist eingerichtet"
        a.informativeText = "In den Systemeinstellungen jetzt unter „Bildschirmschoner“ die Lageuhr auswählen.\n\n" +
            "Er zeigt die Felder der Lageuhr groß auf dem Bildschirm. Die Bildschirmsperre bleibt wie eingestellt: " +
            "Nach Maus oder Taste kommt wie gewohnt die Anmeldung.\n\n" +
            "Änderungen in der Lageuhr kommen nach spätestens 10 Sekunden im Bildschirmschoner an."
        a.addButton(withTitle: "Einstellungen öffnen")
        a.addButton(withTitle: "Später")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menü

    func menueFuellen(_ m: NSMenu) {
        func punkt(_ titel: String, _ an: Bool = false, _ aktion: @escaping () -> Void) -> NSMenuItem {
            let i = AktionsEintrag(title: titel, aktion: aktion)
            i.state = an ? .on : .off
            return i
        }
        if update.installiert {
            let i = NSMenuItem(title: update.statusText, action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
            m.addItem(.separator())
        } else if let v = update.verfuegbar {
            let titel = "Update auf \(v.version) installieren …"
            let i = punkt(titel) { [weak self] in self?.updateFragen(v) }
            i.attributedTitle = NSAttributedString(string: titel, attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.controlAccentColor])
            i.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            m.addItem(i)
            m.addItem(.separator())
        }
        let einst = punkt("Einstellungen …") { [weak self] in self?.einstellungenOeffnen() }
        einst.attributedTitle = NSAttributedString(string: "Einstellungen …", attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        m.addItem(einst)

        let seit = e.felder.filter { $0.art == .seit }
        let termine = e.felder.filter { $0.art == .termin }
        if !seit.isEmpty || !termine.isEmpty { m.addItem(.separator()) }
        for f in seit {
            m.addItem(punkt("\(f.name): beginnt jetzt") { [weak self] in self?.seitJetzt(f.id) })
        }
        for f in termine {
            let item = NSMenuItem(title: f.name, action: nil, keyEquivalent: "")
            let um = NSMenu()
            for min in [15, 30, 45, 60, 90, 120, 180, 240] {
                let t = min < 60 ? "\(min) min" : (min % 60 == 0 ? "\(min / 60) h" : String(format: "%d:%02d h", min / 60, min % 60))
                um.addItem(punkt("in " + t) { [weak self] in
                    self?.feldSetzen(f.id) { $0.zeit = Zeit.runden5(Uhr.jetzt().addingTimeInterval(Double(min) * 60)); $0.sichtbar = true }
                })
            }
            um.addItem(.separator())
            um.addItem(punkt("Andere Zeit …") { [weak self] in self?.einstellungenOeffnen(feld: f.id) })
            um.addItem(punkt("Keine") { [weak self] in self?.feldSetzen(f.id) { $0.zeit = nil } })
            item.submenu = um
            m.addItem(item)
        }
        m.addItem(.separator())

        m.addItem(punkt("Schrift größer") { [weak self] in guard let s = self else { return }; s.schriftSetzen(s.e.schriftgroesse + 2, obenLinksFest: false, speichern: true) })
        m.addItem(punkt("Schrift kleiner") { [weak self] in guard let s = self else { return }; s.schriftSetzen(s.e.schriftgroesse - 2, obenLinksFest: false, speichern: true) })
        m.addItem(punkt("Position fixieren", e.fixiert) { [weak self] in self?.e.fixiert.toggle(); self?.geaendert() })
        m.addItem(punkt("Durchklickbar (dann nur über das Uhr-Symbol oben in der Menüleiste)", e.durchklickbar) { [weak self] in
            self?.e.durchklickbar.toggle(); self?.geaendert()
        })
        m.addItem(punkt(fenster.isVisible ? "Ausblenden" : "Einblenden") { [weak self] in
            guard let s = self else { return }
            if s.fenster.isVisible { s.ausblenden() } else { s.einblenden() }
        })

        m.addItem(.separator())
        let dock = NSMenuItem(title: "Andocken", action: nil, keyEquivalent: "")
        let dm = NSMenu()
        for (i, t) in ["Nicht angedockt (frei)", "Links", "Rechts", "Oben", "Unten"].enumerated() {
            dm.addItem(punkt(t, e.andocken == i) { [weak self] in self?.andocken(i) })
        }
        dock.submenu = dm
        m.addItem(dock)
        let klapp = punkt("Angedockt automatisch einklappen (wie das Dock)", e.einklappen) { [weak self] in
            self?.e.einklappen.toggle(); self?.geaendert()
        }
        m.addItem(klapp)
        m.addItem(punkt("Unter der Maus voll deckend", e.deckendBeiMaus) { [weak self] in self?.e.deckendBeiMaus.toggle(); self?.geaendert() })

        m.addItem(.separator())
        m.addItem(punkt("Vollbild-Lagebild jetzt (Taste oder Maus beendet)") { [weak self] in self?.vollbildZeigen() })
        m.addItem(punkt("Als Bildschirmschoner einrichten …") { [weak self] in self?.bildschirmschonerEinrichten() })
        m.addItem(.separator())
        m.addItem(punkt("Zeit jetzt mit Atomuhr abgleichen") { [weak self] in self?.zeitAbgleichen(server: self?.e.zeitserver) })
        let status = NSMenuItem(title: zeitStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        if update.verfuegbar == nil && !update.installiert {
            if update.sucht {
                let i = NSMenuItem(title: "Suche nach Updates …", action: nil, keyEquivalent: "")
                i.isEnabled = false
                m.addItem(i)
            } else {
                m.addItem(punkt("Nach Update suchen") { [weak self] in self?.updateSuchenManuell() })
            }
        }

        if Abgleich.aktiv(e) {
            m.addItem(.separator())
            let zustand = NSMenuItem(title: abgleich.statusText(e), action: nil, keyEquivalent: "")
            zustand.isEnabled = false
            m.addItem(zustand)
            m.addItem(punkt("Jetzt abgleichen") { [weak self] in self?.abgleich.runde() })
        }

        m.addItem(.separator())
        m.addItem(punkt("Lageuhr beenden") { NSApp.terminate(nil) })
    }

    func seitJetzt(_ id: String) {
        guard let f = e.felder.first(where: { $0.id == id }) else { return }
        if let k = f.zeit {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "„\(f.name)“ auf jetzt setzen?"
            a.informativeText = "Bisher: " + Zeit.taktisch(k, e.monatsschreibweise)
            a.addButton(withTitle: "Auf jetzt setzen")
            a.addButton(withTitle: "Abbrechen")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        feldSetzen(id) { $0.zeit = Zeit.minute(Uhr.jetzt()); $0.sichtbar = true }
    }

    func einstellungenOeffnen(feld: String? = nil) {
        if einstellungen == nil {
            einstellungen = EinstellungenFenster(e) { [weak self] neu in self?.uebernehmen(neu) }
            einstellungen?.beimSchliessen = { [weak self] in self?.einstellungen = nil }
            einstellungen?.abgleichen = { [weak self] server, fertig in self?.zeitAbgleichen(server: server, fertig: fertig) }
            einstellungen?.lbZeitStatus.stringValue = zeitStatus
            einstellungen?.schonerEinrichten = { [weak self] in self?.bildschirmschonerEinrichten() }
            einstellungen?.abgleichJetzt = { [weak self] in self?.abgleich.runde() }
            einstellungen?.abgleichStatusZeigen(abgleich.statusText(e, ausfuehrlich: true))
            einstellungen?.updateKnopf = { [weak self] in self?.updateKnopfGeklickt() }
            updateGeaendert()
        }
        if let id = feld { einstellungen?.auswaehlen(id) }
        NSApp.activate(ignoringOtherApps: true)
        einstellungen?.fenster.makeKeyAndOrderFront(nil)
    }

    func uebernehmen(_ neu: Einstellungen) {
        var n = neu
        n.links = e.links; n.oben = e.oben; n.fixiert = e.fixiert; n.durchklickbar = e.durchklickbar
        // Abgleich: Was während der offenen Einstellungen von anderen Plätzen kam, nicht mit dem alten Stand überschreiben
        n.felder = Abgleich.felderZusammenfuehren(fenster: n.felder, aktuell: e.felder, beimOeffnen: einstellungen?.startIds ?? [])
        n.abgleichStand = e.abgleichStand; n.geteilteIds = e.geteilteIds; n.ausstehend = e.ausstehend; n.loeschungen = e.loeschungen
        // Anderer Lage-Code oder Server: neu beitreten (Stand 0)
        let neueLage = Abgleich.lage(n) != Abgleich.lage(e)
        if neueLage {
            n.abgleichStand = 0; n.geteilteIds = []; n.ausstehend = []; n.loeschungen = [:]
        }
        e = n
        if neueLage { abgleich.zuruecksetzen() }
        geaendert()
        einstellungen?.neuLaden(e)
    }

    // MARK: Update

    /// Menüleisten-Symbol, Tooltip und Einstellungen auf den Stand der Update-Suche bringen.
    func updateGeaendert() {
        if let b = statusItem?.button {
            let da = update.verfuegbar != nil
            b.image = NSImage(systemSymbolName: da ? "clock.badge.exclamationmark" : "clock", accessibilityDescription: "Lageuhr")
                ?? NSImage(systemSymbolName: "clock", accessibilityDescription: "Lageuhr")
            if let v = update.verfuegbar { b.toolTip = "Lageuhr \(Update.version) – Update auf \(v.version) ist da" }
            else if let bis = aktualisiertBis, Date() < bis { b.toolTip = "Lageuhr auf \(Update.version) aktualisiert" }
            else { b.toolTip = "Lageuhr \(Update.version)" }
        }
        einstellungen?.updateZeigen(update.statusText, verfuegbar: update.verfuegbar != nil, beschaeftigt: update.beschaeftigt)
    }

    /// Aus dem Menü: suchen und das Ergebnis immer melden.
    func updateSuchenManuell() {
        update.suchen { [weak self] r in
            switch r {
            case .neu(let i): self?.updateFragen(i)
            case .aktuell: self?.meldung("Die Lageuhr ist aktuell (\(Update.version)).")
            case .fehler(let t): self?.meldung("Suche nach Updates fehlgeschlagen", t)
            }
        }
    }

    /// Knopf im Einstellungsfenster: suchen (Ergebnis in der Statuszeile) oder ein gefundenes Update installieren.
    func updateKnopfGeklickt() {
        if let v = update.verfuegbar { updateFragen(v) } else { update.suchen() }
    }

    func updateFragen(_ info: Update.Info) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Lageuhr \(info.version) ist da."
        var t = ""
        if !info.neu.isEmpty { t += "Neu:\n" + info.neu.map { "• " + $0 }.joined(separator: "\n") + "\n\n" }
        t += "Die Lageuhr startet danach neu; Felder und Einstellungen bleiben."
        a.informativeText = t
        a.addButton(withTitle: "Installieren")
        a.addButton(withTitle: "Später")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        updateInstallieren(info)
    }

    func updateInstallieren(_ info: Update.Info, test: Bool = false) {
        update.installieren(info) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let (app, warnung)):
                if test { testAusgabe("installiert: \(app.path)" + (warnung.map { " – Warnung: \($0)" } ?? "")) }
                else if let w = warnung { self.meldung("Bildschirmschoner nicht ersetzt", w) }
                self.neuStarten(app, test: test)
            case .failure(let f):
                if test { testAusgabe((f.mitDownloadSeite ? "hinweis: " : "fehler: ") + f.text); exit(3) }
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = f.mitDownloadSeite ? "Update hier nicht möglich" : "Update fehlgeschlagen"
                a.informativeText = f.text
                if f.mitDownloadSeite {
                    a.addButton(withTitle: "Download-Seite öffnen")
                    a.addButton(withTitle: "OK")
                    if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Update.downloadSeite) }
                } else {
                    a.runModal()
                }
            }
        }
    }

    /// Einstellungen sichern, neue App starten (mit --nach-update und Test-Argumenten wie --profil), diese beenden.
    func neuStarten(_ app: URL, test: Bool = false) {
        if !argumente.contains("--beispiel") { e.speichern(); positionMerken() }
        var zusatz: [String] = []
        if let i = argumente.firstIndex(of: "--profil"), i + 1 < argumente.count { zusatz += ["--profil", argumente[i + 1]] }
        do {
            try Update.neuStarten(app, zusatz: zusatz)
        } catch {
            if test { testAusgabe("fehler: Neustart – \(error.localizedDescription)"); exit(4) }
            meldung("Neustart nicht möglich", "Das Update ist installiert. Bitte die Lageuhr von Hand neu starten.")
            return
        }
        if test { testAusgabe("neustart: \(app.path)"); exit(0) }
        NSApp.terminate(nil)
    }

    /// Nach dem Neustart durch ein Update: kurzer Hinweis am Menüleisten-Symbol (keine Mitteilung, keine Rechte nötig).
    func nachUpdate() {
        let text = "Lageuhr auf \(Update.version) aktualisiert"
        NSLog("%@", text)
        aktualisiertBis = Date().addingTimeInterval(3600)
        updateGeaendert()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let b = self?.statusItem?.button, b.window != nil else { return }
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: NSFont.systemFontSize)
            l.translatesAutoresizingMaskIntoConstraints = false
            let v = NSView()
            v.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
                l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
                l.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
                l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10),
            ])
            let c = NSViewController()
            c.view = v
            let p = NSPopover()
            p.contentViewController = c
            p.behavior = .transient
            p.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { p.performClose(nil) }
        }
    }

    /// Test (--updatetest): ohne Rückfragen suchen und installieren, Ergebnis auf stdout.
    func updateTest() {
        testAusgabe("updatetest: Version \(Update.version), Quelle \(Update.quelle), App \(Bundle.main.bundlePath)")
        update.suchen { [weak self] r in
            switch r {
            case .aktuell: testAusgabe("aktuell: Die Lageuhr ist aktuell (\(Update.version))."); exit(0)
            case .fehler(let t): testAusgabe("fehler: \(t)"); exit(2)
            case .neu(let i):
                testAusgabe("neu: \(i.version)" + i.neu.map { " | " + $0 }.joined())
                self?.updateInstallieren(i, test: true)
            }
        }
    }

    func meldung(_ titel: String, _ text: String = "") {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = titel
        a.informativeText = text
        a.runModal()
    }
}

func testAusgabe(_ t: String) {
    print(t)
    fflush(stdout)
}

final class AktionsEintrag: NSMenuItem {
    let aktion: () -> Void
    init(title: String, aktion: @escaping () -> Void) {
        self.aktion = aktion
        super.init(title: title, action: #selector(ausfuehren), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func ausfuehren() { aktion() }
}

// MARK: - Einstellungen-Fenster

final class EinstellungenFenster: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let fenster: NSWindow
    var e: Einstellungen
    let uebernehmen: (Einstellungen) -> Void
    var beimSchliessen: (() -> Void)?
    private var aktuell: Int?
    private(set) var startIds: Set<String> = []   // Felder beim Öffnen (Abgleich: inzwischen neue erkennen)

    // Felderliste
    let tabelle = NSTableView()
    let puNeu = NSPopUpButton(frame: .zero, pullsDown: true)
    var btEntfernen: NSButton!, btHoch: NSButton!, btRunter: NSButton!, btKopie: NSButton!

    // ein Feld
    let raster = NSGridView()
    let lbArt = NSTextField(labelWithString: "")
    let cbSichtbar = NSButton(checkboxWithTitle: "anzeigen", target: nil, action: nil)
    let tfTitel = NSTextField()
    let tfText = EinstellungenFenster.mehrzeilig()
    let cbZeit = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let dpZeit = EinstellungenFenster.datum()
    var reiheSchnell: NSStackView!
    let lbTaktisch = EinstellungenFenster.hinweis("")
    let tfIntervall = NSTextField(), stIntervall = NSStepper()
    let cbSek = NSButton(checkboxWithTitle: "zusätzlich mit Sekunden (14:32:07)", target: nil, action: nil)
    let tfGroesse = NSTextField(), stGroesse = NSStepper()
    let cbEigeneSchrift = NSButton(checkboxWithTitle: "eigene", target: nil, action: nil)
    let cbEigenerGrund = NSButton(checkboxWithTitle: "eigener", target: nil, action: nil)
    let cwFeldSchrift = NSColorWell(), cwFeldGrund = NSColorWell()
    let cbGeteilt = NSButton(checkboxWithTitle: "Mit anderen Arbeitsplätzen teilen", target: nil, action: nil)
    let lbGeaendert = EinstellungenFenster.hinweis("")
    private enum Zeile: Int { case art, titel, text, zeit, schnell, taktisch, intervall, sekunden, groesse, schrift, grund, vorlagen, geteilt, geaendert }

    // Darstellung (ganzer Kasten)
    let tfSchrift = NSTextField(), stSchrift = NSStepper()
    let slDeckkraft = NSSlider(value: 90, minValue: 30, maxValue: 100, target: nil, action: nil)
    let lbDeckkraft = EinstellungenFenster.hinweis("90 %")
    let cwHintergrund = NSColorWell(), cwSchrift = NSColorWell()
    let puAnordnung = NSPopUpButton(), puMonat = NSPopUpButton()
    let cbDeckend = NSButton(checkboxWithTitle: "unter der Maus voll deckend", target: nil, action: nil)

    // Andocken und Atomuhr
    let puAndocken = NSPopUpButton()
    let cbEinklappen = NSButton(checkboxWithTitle: "automatisch einklappen (wie das Dock)", target: nil, action: nil)
    let cbAtomuhr = NSButton(checkboxWithTitle: "Zeit mit Atomuhr abgleichen (beim Start und alle 30 min)", target: nil, action: nil)
    let tfServer = NSTextField()
    let lbZeitStatus = EinstellungenFenster.hinweis("")
    var abgleichen: ((String, @escaping (String) -> Void) -> Void)?
    var schonerEinrichten: (() -> Void)?
    let puVollbild = NSPopUpButton()
    let cbVollbildAlle = NSButton(checkboxWithTitle: "auf allen Bildschirmen", target: nil, action: nil)
    let cbUpdate = NSButton(checkboxWithTitle: "automatisch nach Updates suchen (beim Start und täglich)", target: nil, action: nil)
    var btUpdate: NSButton!
    let lbUpdateStatus = EinstellungenFenster.hinweis("")
    var updateKnopf: (() -> Void)?
    static let vollbildMinuten = [0, 2, 5, 10, 15, 20, 30, 45, 60]

    // Abgleich zwischen Arbeitsplätzen
    let cbAbgleich = NSButton(checkboxWithTitle: "an", target: nil, action: nil)
    let tfAdresse = NSTextField(), tfCode = NSTextField(), tfArbeitsplatz = NSTextField()
    var btNeueLage: NSButton!, btAbgleichJetzt: NSButton!
    let lbAbgleichStatus = EinstellungenFenster.hinweis("")
    var abgleichJetzt: (() -> Void)?

    init(_ e: Einstellungen, uebernehmen: @escaping (Einstellungen) -> Void) {
        self.e = e
        self.startIds = Set(e.felder.map(\.id))
        self.uebernehmen = uebernehmen
        fenster = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        super.init()
        fenster.title = "Lageuhr – Einstellungen"
        fenster.isReleasedWhenClosed = false
        fenster.level = .floating
        fenster.delegate = self
        aufbauen()
        darstellungZeigen()
        tabelle.reloadData()
        auswahl(e.felder.isEmpty ? nil : 0)
        fenster.center()
    }

    // MARK: Bausteine

    static func mehrzeilig() -> NSTextField {
        let t = NSTextField()
        t.usesSingleLineMode = false
        t.cell?.wraps = true
        t.cell?.isScrollable = false
        t.lineBreakMode = .byWordWrapping
        t.heightAnchor.constraint(equalToConstant: 52).isActive = true
        t.placeholderString = "Zeilenumbruch mit ⏎"
        return t
    }

    static func datum() -> NSDatePicker {
        let d = NSDatePicker()
        d.datePickerStyle = .textFieldAndStepper
        d.datePickerElements = [.yearMonthDay, .hourMinute]
        d.locale = Locale(identifier: "de_DE")
        return d
    }

    static func hinweis(_ t: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: t)
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return l
    }

    static func knopf(_ t: String, _ ziel: AnyObject, _ aktion: Selector, tag: Int = 0) -> NSButton {
        let b = NSButton(title: t, target: ziel, action: aktion)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.tag = tag
        return b
    }

    static func reihe(_ v: [NSView], abstand: CGFloat = 6) -> NSStackView {
        let s = NSStackView(views: v)
        s.orientation = .horizontal
        s.spacing = abstand
        s.alignment = .centerY
        return s
    }

    static func raster(_ g: NSGridView, _ zeilen: [[NSView]]) {
        for z in zeilen { g.addRow(with: z.count == 1 ? [z[0], NSGridCell.emptyContentView] : z) }
        g.rowSpacing = 7
        g.columnSpacing = 8
        g.column(at: 0).xPlacement = .trailing
        g.rowAlignment = .none
        for i in 0..<g.numberOfRows {
            g.row(at: i).yPlacement = .center
            if zeilen[i].count == 1 {
                g.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .leading
                g.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: i, length: 1))
            }
        }
    }

    static func gruppe(_ titel: String, _ inhalt: NSView) -> NSBox {
        let box = NSBox()
        box.title = titel
        box.titleFont = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        inhalt.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(inhalt)
        if let c = box.contentView {
            NSLayoutConstraint.activate([
                inhalt.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
                inhalt.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -10),
                inhalt.topAnchor.constraint(equalTo: c.topAnchor, constant: 8),
                inhalt.bottomAnchor.constraint(lessThanOrEqualTo: c.bottomAnchor, constant: -10),
            ])
        }
        return box
    }

    func label(_ t: String) -> NSTextField { NSTextField(labelWithString: t) }

    func zahlfeld(_ t: NSTextField, _ s: NSStepper, min: Double, max: Double, schritt: Double, nachkomma: Int = 0) {
        t.widthAnchor.constraint(equalToConstant: 52).isActive = true
        t.alignment = .right
        t.delegate = self
        let f = NumberFormatter()
        f.minimum = NSNumber(value: min); f.maximum = NSNumber(value: max)
        f.maximumFractionDigits = nachkomma; f.allowsFloats = nachkomma > 0
        f.locale = Locale(identifier: "de_DE")
        t.formatter = f
        s.minValue = min; s.maxValue = max; s.increment = schritt; s.valueWraps = false
        s.target = self; s.action = #selector(stepper(_:))
    }

    // MARK: Aufbau

    func aufbauen() {
        // --- Felderliste ---
        let spalte = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("feld"))
        spalte.width = 230
        tabelle.addTableColumn(spalte)
        tabelle.headerView = nil
        tabelle.rowHeight = 24
        tabelle.dataSource = self
        tabelle.delegate = self
        tabelle.style = .inset
        let scroll = NSScrollView()
        scroll.documentView = tabelle
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 250).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 168).isActive = true

        puNeu.addItem(withTitle: "Neues Feld")
        for a in FeldArt.allCases { puNeu.addItem(withTitle: a.name); puNeu.lastItem?.representedObject = a.rawValue }
        puNeu.target = self; puNeu.action = #selector(neuesFeld(_:))
        puNeu.controlSize = .small
        puNeu.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        btEntfernen = Self.knopf("Entfernen", self, #selector(entfernen))
        btKopie = Self.knopf("Kopieren", self, #selector(kopieren))
        btHoch = Self.knopf("▲", self, #selector(verschieben(_:)), tag: -1)
        btRunter = Self.knopf("▼", self, #selector(verschieben(_:)), tag: 1)
        let listenKnoepfe = Self.reihe([puNeu, btKopie, btEntfernen, btHoch, btRunter], abstand: 4)
        let liste = NSStackView(views: [scroll, listenKnoepfe])
        liste.orientation = .vertical
        liste.alignment = .leading
        liste.spacing = 6

        // --- ein Feld ---
        tfTitel.widthAnchor.constraint(equalToConstant: 250).isActive = true
        tfTitel.delegate = self
        tfText.widthAnchor.constraint(equalToConstant: 250).isActive = true
        tfText.delegate = self
        lbArt.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        zahlfeld(tfIntervall, stIntervall, min: 0, max: 1440, schritt: 15)
        zahlfeld(tfGroesse, stGroesse, min: 30, max: 300, schritt: 10)
        for c in [cbSichtbar, cbZeit, cbSek, cbEigeneSchrift, cbEigenerGrund, cbGeteilt] { c.target = self; c.action = #selector(feldGeaendert) }
        lbGeaendert.preferredMaxLayoutWidth = 330
        dpZeit.target = self; dpZeit.action = #selector(feldGeaendert)
        for w in [cwFeldSchrift, cwFeldGrund] {
            w.target = self; w.action = #selector(feldGeaendert)
            if #available(macOS 13.0, *) { w.colorWellStyle = .minimal }
            w.widthAnchor.constraint(equalToConstant: 44).isActive = true
            w.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        reiheSchnell = Self.reihe([Self.knopf("Jetzt", self, #selector(schnell(_:)), tag: 0),
                                   Self.knopf("in 30 min", self, #selector(schnell(_:)), tag: 30),
                                   Self.knopf("in 1 h", self, #selector(schnell(_:)), tag: 60),
                                   Self.knopf("in 2 h", self, #selector(schnell(_:)), tag: 120)], abstand: 4)
        var vorlagen: [NSView] = []
        for (i, v) in feldVorlagen.enumerated() {
            let b = Self.knopf(v.0, self, #selector(feldVorlage(_:)), tag: i)
            if let g = v.1 {
                b.bezelColor = NSColor(hex: g)
                b.attributedTitle = NSAttributedString(string: v.0, attributes: [
                    .foregroundColor: NSColor(hex: v.2 ?? "#FFFFFF"), .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
            }
            vorlagen.append(b)
        }
        let vorlagenRaster = NSGridView(views: [Array(vorlagen[0..<4]), Array(vorlagen[4...])])
        vorlagenRaster.rowSpacing = 4; vorlagenRaster.columnSpacing = 4

        Self.raster(raster, [
            [label("Art"), lbArt],
            [label("Beschriftung"), Self.reihe([tfTitel, cbSichtbar], abstand: 10)],
            [label("Text"), tfText],
            [label("Zeitpunkt"), Self.reihe([cbZeit, dpZeit])],
            [label(""), reiheSchnell],
            [label(""), lbTaktisch],
            [label("Wiederholen alle"), Self.reihe([tfIntervall, stIntervall, Self.hinweis("Minuten (0 = einmalig)")])],
            [label(""), cbSek],
            [label("Größe"), Self.reihe([tfGroesse, stGroesse, Self.hinweis("% der Schriftgröße")])],
            [label("Schriftfarbe"), Self.reihe([cbEigeneSchrift, cwFeldSchrift])],
            [label("Hintergrund"), Self.reihe([cbEigenerGrund, cwFeldGrund])],
            [label("Farbvorlage"), vorlagenRaster],
            [label("Abgleich"), cbGeteilt],
            [label(""), lbGeaendert],
        ])

        // --- Darstellung ---
        zahlfeld(tfSchrift, stSchrift, min: 10, max: 200, schritt: 1, nachkomma: 1)
        slDeckkraft.target = self; slDeckkraft.action = #selector(deckkraftGeaendert)
        slDeckkraft.widthAnchor.constraint(equalToConstant: 140).isActive = true
        puAnordnung.addItems(withTitles: ["untereinander", "nebeneinander (Leiste)"])
        let bsp = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 14, minute: 32))!
        puMonat.addItems(withTitles: (0...2).map { Zeit.taktisch(bsp, $0) })
        puMonat.target = self; puMonat.action = #selector(feldGeaendert)
        for w in [cwHintergrund, cwSchrift] {
            if #available(macOS 13.0, *) { w.colorWellStyle = .minimal }
            w.widthAnchor.constraint(equalToConstant: 44).isActive = true
            w.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let darstellung = NSGridView()
        Self.raster(darstellung, [
            [label("Schriftgröße"), Self.reihe([tfSchrift, stSchrift, Self.hinweis("pt (auch: scrollen)")])],
            [label("Farben"), Self.reihe([cwSchrift, Self.hinweis("Schrift"), cwHintergrund, Self.hinweis("Hintergrund")])],
            [label(""), Self.reihe([Self.knopf("Dunkel", self, #selector(kastenVorlage(_:)), tag: 0),
                                    Self.knopf("Hell", self, #selector(kastenVorlage(_:)), tag: 1)], abstand: 4)],
            [label("Deckkraft"), Self.reihe([slDeckkraft, lbDeckkraft])],
            [label("Anordnung"), puAnordnung],
            [label("Taktische Zeit"), puMonat],
            [cbDeckend],
        ])

        // --- Andocken und Atomuhr ---
        puAndocken.addItems(withTitles: ["nicht angedockt (frei)", "links", "rechts", "oben", "unten"])
        puVollbild.addItems(withTitles: Self.vollbildMinuten.map { $0 == 0 ? "aus" : "nach \($0) min ohne Eingabe" })
        tfServer.widthAnchor.constraint(equalToConstant: 300).isActive = true
        tfServer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tfServer.placeholderString = Atomuhr.standardServer
        lbZeitStatus.preferredMaxLayoutWidth = 380
        lbUpdateStatus.preferredMaxLayoutWidth = 380
        btUpdate = Self.knopf("Jetzt suchen", self, #selector(updateGeklickt))
        let vollbildHinweis = Self.hinweis("Statt Bildschirmschoner: Lagebild groß nach dieser Zeit ohne Eingabe. Solange an, startet kein Bildschirmschoner und der Rechner sperrt sich nicht von selbst.")
        vollbildHinweis.preferredMaxLayoutWidth = 380
        let zeitRaster = NSGridView()
        Self.raster(zeitRaster, [
            [label("Andocken"), Self.reihe([puAndocken, cbEinklappen], abstand: 10)],
            [label(""), Self.hinweis("Oder am Griff an eine Bildschirmkante ziehen; wegziehen löst ihn.")],
            [label("Atomuhr"), Self.reihe([cbAtomuhr, Self.knopf("Jetzt abgleichen", self, #selector(jetztAbgleichen))], abstand: 10)],
            [label("Zeitserver"), tfServer],
            [label(""), lbZeitStatus],
            [label("Vollbild"), Self.reihe([puVollbild, cbVollbildAlle], abstand: 10)],
            [label(""), vollbildHinweis],
            [label("Bildschirmschoner"), Self.reihe([Self.knopf("Als Bildschirmschoner einrichten …", self, #selector(schonerKnopf)),
                                                    Self.hinweis("Sperre bleibt aktiv")])],
            [label("Update"), Self.reihe([cbUpdate, btUpdate], abstand: 10)],
            [label(""), lbUpdateStatus],
        ])

        // --- Abgleich zwischen Arbeitsplätzen ---
        cbAbgleich.target = self; cbAbgleich.action = #selector(abgleichUmgeschaltet)
        for t in [tfAdresse, tfCode, tfArbeitsplatz] { t.font = .systemFont(ofSize: NSFont.smallSystemFontSize); t.delegate = self }
        tfAdresse.widthAnchor.constraint(equalToConstant: 236).isActive = true
        tfAdresse.placeholderString = "https://…/lageuhr/lage.php"
        tfCode.widthAnchor.constraint(equalToConstant: 150).isActive = true
        tfCode.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        tfCode.placeholderString = "XXXX-XXXX-XXXX"
        tfArbeitsplatz.widthAnchor.constraint(equalToConstant: 236).isActive = true
        tfArbeitsplatz.placeholderString = Abgleich.rechnername
        btNeueLage = Self.knopf("Neue Lage", self, #selector(neueLage))
        btAbgleichJetzt = Self.knopf("Jetzt abgleichen", self, #selector(abgleichKnopf))
        tfCode.toolTip = "Alle Arbeitsplätze mit gleichem Code und gleichem Server zeigen dieselben geteilten Felder."
        lbAbgleichStatus.preferredMaxLayoutWidth = 236
        let abgleichRaster = NSGridView()
        Self.raster(abgleichRaster, [
            [label("Abgleich"), Self.reihe([cbAbgleich, btAbgleichJetzt], abstand: 10)],
            [label("Server"), tfAdresse],
            [label("Lage-Code"), Self.reihe([tfCode, btNeueLage])],
            [label("Arbeitsplatz"), tfArbeitsplatz],
            [label(""), lbAbgleichStatus],
        ])

        let hilfe = Self.hinweis("Verschieben: am Griff oben links ziehen · Größe: am Griff unten rechts ziehen oder scrollen · " +
                                 "Menü: Rechtsklick auf den Kasten oder das Uhr-Symbol in der Menüleiste · Einstellungen: Doppelklick")

        let abgleichBox = Self.gruppe("Abgleich zwischen Arbeitsplätzen", abgleichRaster)
        let kastenBox = Self.gruppe("Ganzer Kasten", darstellung)
        let links = NSStackView(views: [Self.gruppe("Felder (von oben nach unten)", liste), kastenBox, abgleichBox])
        let feldBox = Self.gruppe("Ausgewähltes Feld", raster)
        let zeitBox = Self.gruppe("Andocken, Atomuhr, Vollbild", zeitRaster)
        let rechts = NSStackView(views: [feldBox, zeitBox])
        for s in [links, rechts] { s.orientation = .vertical; s.alignment = .leading; s.spacing = 10 }
        for s in [links, rechts] { for v in s.arrangedSubviews { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true } }
        let spalten = NSStackView(views: [links, rechts])
        spalten.orientation = .horizontal
        spalten.alignment = .top
        spalten.spacing = 14
        links.bottomAnchor.constraint(equalTo: rechts.bottomAnchor).isActive = true
        rechts.distribution = .fill
        feldBox.setContentHuggingPriority(.defaultLow, for: .vertical)        // das Feld füllt die Höhe auf
        zeitBox.setContentHuggingPriority(.defaultHigh + 1, for: .vertical)
        lbUpdateStatus.stringValue = "Version 0.0.0 ist aktuell (gesucht um 00:00)" // Höhe mit einzeiliger Statuszeile messen
        zeitBox.heightAnchor.constraint(equalToConstant: zeitRaster.fittingSize.height + 36).isActive = true // volle Höhe für Andocken und Atomuhr
        lbUpdateStatus.stringValue = ""
        abgleichBox.setContentHuggingPriority(.defaultHigh + 1, for: .vertical)
        kastenBox.setContentHuggingPriority(.defaultLow, for: .vertical)   // links füllt der Kasten die Höhe auf
        // Höhe für eine zweizeilige Statuszeile messen
        lbAbgleichStatus.stringValue = "Abgleich: getrennt seit 0000 – Server antwortet nicht (Zeitüberschreitung)"
        abgleichBox.heightAnchor.constraint(equalToConstant: abgleichRaster.fittingSize.height + 36).isActive = true
        lbAbgleichStatus.stringValue = ""

        let abbrechen = NSButton(title: "Abbrechen", target: self, action: #selector(abbrechenGeklickt))
        abbrechen.keyEquivalent = "\u{1b}"
        let anwenden = NSButton(title: "Übernehmen", target: self, action: #selector(anwendenGeklickt))
        let ok = NSButton(title: "OK", target: self, action: #selector(okGeklickt))
        ok.keyEquivalent = "\r"
        for b in [abbrechen, anwenden, ok] { b.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true }
        let knoepfe = NSStackView(views: [abbrechen, anwenden, ok])
        knoepfe.orientation = .horizontal
        knoepfe.spacing = 8

        let inhalt = NSView()
        for v in [spalten, knoepfe, hilfe] { v.translatesAutoresizingMaskIntoConstraints = false; inhalt.addSubview(v) }
        NSLayoutConstraint.activate([
            spalten.leadingAnchor.constraint(equalTo: inhalt.leadingAnchor, constant: 16),
            spalten.trailingAnchor.constraint(equalTo: inhalt.trailingAnchor, constant: -16),
            spalten.topAnchor.constraint(equalTo: inhalt.topAnchor, constant: 16),
            hilfe.leadingAnchor.constraint(equalTo: inhalt.leadingAnchor, constant: 18),
            hilfe.trailingAnchor.constraint(lessThanOrEqualTo: knoepfe.leadingAnchor, constant: -20),
            hilfe.centerYAnchor.constraint(equalTo: knoepfe.centerYAnchor),
            knoepfe.topAnchor.constraint(equalTo: spalten.bottomAnchor, constant: 14),
            knoepfe.trailingAnchor.constraint(equalTo: inhalt.trailingAnchor, constant: -16),
            knoepfe.bottomAnchor.constraint(equalTo: inhalt.bottomAnchor, constant: -16),
        ])
        hilfe.preferredMaxLayoutWidth = 420
        fenster.contentView = inhalt
        // Höhe für das größte Feld (Termin) messen: Text und Sekunden erscheinen nie zusammen mit den Termin-Zeilen
        zeile(.text, false); zeile(.sekunden, false)
        fenster.setContentSize(inhalt.fittingSize)
    }

    // MARK: Liste

    func numberOfRows(in tableView: NSTableView) -> Int { e.felder.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let f = e.felder[row]
        // gefüllter Punkt = eigener Hintergrund, hohler Kreis = wie der Kasten
        let s = NSMutableAttributedString(string: f.hintergrund != nil ? "● " : "○ ", attributes: [
            .foregroundColor: f.hintergrund.map { NSColor(hex: $0) } ?? NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 15)])
        s.append(NSAttributedString(string: f.name.replacingOccurrences(of: "\n", with: " "),
                                    attributes: [.foregroundColor: f.sichtbar ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                                                 .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]))
        s.append(NSAttributedString(string: "  " + f.art.kurz + (f.sichtbar ? "" : " · ausgeblendet"),
                                    attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]))
        let l = NSTextField(labelWithAttributedString: s)
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = tabelle.selectedRow
        aktuellZeigen(r >= 0 ? r : nil)
    }

    func auswahl(_ i: Int?) {
        if let i = i, i < e.felder.count {
            tabelle.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            tabelle.scrollRowToVisible(i)
        } else { tabelle.deselectAll(nil) }
        aktuellZeigen(i)
    }

    /// Nach dem Übernehmen: Felder neu zeigen (mit dem, was der Abgleich inzwischen gebracht hat).
    func neuLaden(_ neu: Einstellungen) {
        let id = aktuell.flatMap { $0 < e.felder.count ? e.felder[$0].id : nil }
        e = neu
        startIds = Set(e.felder.map(\.id))
        tabelle.reloadData()
        auswahl(id.flatMap { i in e.felder.firstIndex { $0.id == i } } ?? (e.felder.isEmpty ? nil : 0))
    }

    func auswaehlen(_ id: String) {
        if let i = e.felder.firstIndex(where: { $0.id == id }) { auswahl(i) }
    }

    func zeileNeu(_ i: Int) {
        guard i < e.felder.count else { return }
        tabelle.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 0))
    }

    @objc func neuesFeld(_ p: NSPopUpButton) {
        guard let roh = p.selectedItem?.representedObject as? String, let art = FeldArt(rawValue: roh) else { return }
        var f = Feld(art)
        if art == .text { f.text = "Neuer Text" }
        if art == .seit { f.titel = "Seit" }
        if art == .termin { f.titel = "Termin" }
        let i = (aktuell.map { $0 + 1 }) ?? e.felder.count
        e.felder.insert(f, at: i)
        tabelle.reloadData()
        auswahl(i)
        fenster.makeFirstResponder(art == .text ? tfText : tfTitel)
    }

    @objc func entfernen() {
        guard let i = aktuell else { return }
        e.felder.remove(at: i)
        tabelle.reloadData()
        auswahl(e.felder.isEmpty ? nil : min(i, e.felder.count - 1))
    }

    @objc func kopieren() {
        guard let i = aktuell else { return }
        var f = e.felder[i]
        f.id = UUID().uuidString
        f.geaendert = 0; f.von = ""; f.bekannt = "" // neues Feld für den Abgleich
        e.felder.insert(f, at: i + 1)
        tabelle.reloadData()
        auswahl(i + 1)
    }

    @objc func verschieben(_ b: NSButton) {
        guard let i = aktuell else { return }
        let j = i + b.tag
        guard j >= 0, j < e.felder.count else { return }
        e.felder.swapAt(i, j)
        tabelle.reloadData()
        auswahl(j)
    }

    // MARK: ein Feld

    private func zeile(_ z: Zeile, _ sichtbar: Bool) { raster.row(at: z.rawValue).isHidden = !sichtbar }

    func aktuellZeigen(_ i: Int?) {
        cwFeldSchrift.deactivate(); cwFeldGrund.deactivate()
        aktuell = i
        let da = i != nil
        for b in [btEntfernen, btKopie, btHoch, btRunter] { b?.isEnabled = da }
        btHoch.isEnabled = da && i! > 0
        btRunter.isEnabled = da && i! < e.felder.count - 1
        raster.isHidden = !da
        guard let i = i else { return }
        let f = e.felder[i]
        lbArt.stringValue = f.art.name
        cbSichtbar.state = f.sichtbar ? .on : .off
        tfTitel.stringValue = f.titel
        tfTitel.placeholderString = f.art == .text ? "(optional, klein über dem Text)" : f.art.standardTitel
        tfText.stringValue = f.text
        cbZeit.state = f.zeit != nil ? .on : .off
        dpZeit.dateValue = f.zeit ?? Zeit.runden5(Uhr.jetzt().addingTimeInterval(f.art == .termin ? 3600 : 0))
        tfIntervall.integerValue = f.intervall; stIntervall.integerValue = f.intervall
        cbSek.state = f.sekunden ? .on : .off
        tfGroesse.integerValue = f.groesse; stGroesse.integerValue = f.groesse
        cbEigeneSchrift.state = f.schriftfarbe != nil ? .on : .off
        cbEigenerGrund.state = f.hintergrund != nil ? .on : .off
        cwFeldSchrift.color = NSColor(hex: f.schriftfarbe ?? cwSchrift.color.hex)
        cwFeldGrund.color = NSColor(hex: f.hintergrund ?? "#B71C1C")
        cbGeteilt.state = f.geteilt ? .on : .off
        if !f.von.isEmpty && f.geaendert > 0 {
            let d = Date(timeIntervalSince1970: Double(f.geaendert) / 1000)
            lbGeaendert.stringValue = "zuletzt geändert von \(f.von) um \(Zeit.taktisch(d, max(0, puMonat.indexOfSelectedItem)))"
        } else { lbGeaendert.stringValue = "" }
        zeile(.geteilt, cbAbgleich.state == .on)
        zeile(.geaendert, cbAbgleich.state == .on && !lbGeaendert.stringValue.isEmpty)

        zeile(.text, f.art == .text)
        zeile(.zeit, f.art == .seit || f.art == .termin)
        zeile(.schnell, f.art == .seit || f.art == .termin)
        zeile(.taktisch, f.art == .seit || f.art == .termin)
        zeile(.intervall, f.art == .termin)
        zeile(.sekunden, f.art == .uhr)
        if let r = reiheSchnell {
            r.arrangedSubviews[0].isHidden = f.art != .seit           // „Jetzt“ beim Seit-Feld
            for v in r.arrangedSubviews[1...] { v.isHidden = f.art != .termin }
        }
        aktualisierenHinweise()
    }

    func aktualisierenHinweise() {
        let sw = max(0, puMonat.indexOfSelectedItem)
        dpZeit.isEnabled = cbZeit.state == .on
        lbTaktisch.stringValue = cbZeit.state == .on ? "taktisch: " + Zeit.taktisch(dpZeit.dateValue, sw) : "nicht festgelegt (Haken setzen)"
        cwFeldSchrift.isEnabled = cbEigeneSchrift.state == .on
        cwFeldGrund.isEnabled = cbEigenerGrund.state == .on
    }

    @objc func feldGeaendert() {
        aktualisierenHinweise()
        guard let i = aktuell, i < e.felder.count else { return }
        var f = e.felder[i]
        f.sichtbar = cbSichtbar.state == .on
        f.titel = tfTitel.stringValue
        f.text = tfText.stringValue
        f.zeit = cbZeit.state == .on ? Zeit.minute(dpZeit.dateValue) : nil
        f.intervall = max(0, min(1440, tfIntervall.integerValue))
        f.sekunden = cbSek.state == .on
        f.groesse = max(30, min(300, tfGroesse.integerValue))
        f.schriftfarbe = cbEigeneSchrift.state == .on ? cwFeldSchrift.color.hex : nil
        f.hintergrund = cbEigenerGrund.state == .on ? cwFeldGrund.color.hex : nil
        f.geteilt = cbGeteilt.state == .on
        e.felder[i] = f
        zeileNeu(i)
    }

    @objc func schnell(_ b: NSButton) {
        dpZeit.dateValue = b.tag == 0 ? Zeit.minute(Uhr.jetzt()) : Zeit.runden5(Uhr.jetzt().addingTimeInterval(Double(b.tag) * 60))
        cbZeit.state = .on
        feldGeaendert()
    }

    @objc func feldVorlage(_ b: NSButton) {
        let v = feldVorlagen[b.tag]
        cbEigenerGrund.state = v.1 != nil ? .on : .off
        cbEigeneSchrift.state = v.2 != nil ? .on : .off
        if let g = v.1 { cwFeldGrund.color = NSColor(hex: g) }
        if let s = v.2 { cwFeldSchrift.color = NSColor(hex: s) }
        feldGeaendert()
    }

    // MARK: ganzer Kasten

    func darstellungZeigen() {
        tfSchrift.doubleValue = e.schriftgroesse; stSchrift.doubleValue = e.schriftgroesse
        slDeckkraft.integerValue = e.deckkraft
        cwHintergrund.color = NSColor(hex: e.hintergrund)
        cwSchrift.color = NSColor(hex: e.schriftfarbe)
        puAnordnung.selectItem(at: e.nebeneinander ? 1 : 0)
        puMonat.selectItem(at: e.monatsschreibweise)
        cbDeckend.state = e.deckendBeiMaus ? .on : .off
        puAndocken.selectItem(at: max(0, min(4, e.andocken)))
        cbEinklappen.state = e.einklappen ? .on : .off
        cbAtomuhr.state = e.atomuhr ? .on : .off
        tfServer.stringValue = e.zeitserver
        puVollbild.selectItem(at: Self.vollbildMinuten.firstIndex(of: e.vollbildNachMin) ?? 0)
        cbVollbildAlle.state = e.vollbildAlle ? .on : .off
        cbUpdate.state = e.updateSuchen ? .on : .off
        cbAbgleich.state = e.abgleich ? .on : .off
        tfAdresse.stringValue = e.abgleichAdresse
        tfCode.stringValue = e.lageCode
        tfArbeitsplatz.stringValue = e.arbeitsplatz
        deckkraftGeaendert()
        abgleichUmgeschaltet()
    }

    // MARK: Abgleich

    func abgleichStatusZeigen(_ t: String) { lbAbgleichStatus.stringValue = t }

    @objc func abgleichUmgeschaltet() {
        let an = cbAbgleich.state == .on
        for v in [tfAdresse, tfCode, tfArbeitsplatz] { v.isEnabled = an }
        btNeueLage?.isEnabled = an
        btAbgleichJetzt?.isEnabled = an
        if let i = aktuell, i < e.felder.count { aktuellZeigen(i) }
    }

    @objc func abgleichKnopf() {
        anwendenGeklickt() // erst die Einstellungen übernehmen (Adresse, Code)
        abgleichJetzt?()
    }

    @objc func neueLage() {
        let code = Abgleich.neuerCode()
        tfCode.stringValue = code
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        let a = NSAlert()
        a.messageText = "Neue Lage \(code)"
        a.informativeText = "Der Code ist in der Zwischenablage. Code an die anderen Arbeitsplätze weitergeben – " +
            "dort unter Abgleich eintragen. Gilt hier nach „Übernehmen“ oder „OK“."
        a.beginSheetModal(for: fenster)
    }

    @objc func schonerKnopf() { schonerEinrichten?() }

    @objc func updateGeklickt() { updateKnopf?() }

    func updateZeigen(_ text: String, verfuegbar: Bool, beschaeftigt: Bool) {
        lbUpdateStatus.stringValue = text
        btUpdate.title = verfuegbar ? "Installieren …" : "Jetzt suchen"
        btUpdate.isEnabled = !beschaeftigt
    }

    @objc func jetztAbgleichen() {
        lbZeitStatus.stringValue = "Gleiche ab …"
        let s = tfServer.stringValue.trimmingCharacters(in: .whitespaces)
        abgleichen?(s.isEmpty ? Atomuhr.standardServer : s) { [weak self] t in self?.lbZeitStatus.stringValue = t }
    }

    func darstellungLesen() {
        e.schriftgroesse = Einstellungen.begrenzen(tfSchrift.doubleValue)
        e.deckkraft = slDeckkraft.integerValue
        e.hintergrund = cwHintergrund.color.hex
        e.schriftfarbe = cwSchrift.color.hex
        e.nebeneinander = puAnordnung.indexOfSelectedItem == 1
        e.monatsschreibweise = max(0, puMonat.indexOfSelectedItem)
        e.deckendBeiMaus = cbDeckend.state == .on
        e.andocken = max(0, puAndocken.indexOfSelectedItem)
        e.einklappen = cbEinklappen.state == .on
        e.atomuhr = cbAtomuhr.state == .on
        let s = tfServer.stringValue.trimmingCharacters(in: .whitespaces)
        e.zeitserver = s.isEmpty ? Atomuhr.standardServer : s
        e.vollbildNachMin = Self.vollbildMinuten[max(0, puVollbild.indexOfSelectedItem)]
        e.vollbildAlle = cbVollbildAlle.state == .on
        e.updateSuchen = cbUpdate.state == .on
        e.abgleich = cbAbgleich.state == .on
        e.abgleichAdresse = tfAdresse.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        e.lageCode = tfCode.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let platz = tfArbeitsplatz.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        e.arbeitsplatz = platz.isEmpty ? Abgleich.rechnername : platz
    }

    @objc func kastenVorlage(_ b: NSButton) {
        cwHintergrund.color = NSColor(hex: b.tag == 0 ? Einstellungen.standardHintergrund : "#FFFFFF")
        cwSchrift.color = NSColor(hex: b.tag == 0 ? "#FFFFFF" : "#1E1E1E")
    }

    @objc func stepper(_ s: NSStepper) {
        switch s {
        case stIntervall: tfIntervall.integerValue = s.integerValue; feldGeaendert()
        case stGroesse: tfGroesse.integerValue = s.integerValue; feldGeaendert()
        default: tfSchrift.doubleValue = s.doubleValue
        }
    }

    func controlTextDidChange(_ n: Notification) {
        guard let t = n.object as? NSTextField else { return }
        if t === tfIntervall { stIntervall.integerValue = tfIntervall.integerValue }
        if t === tfGroesse { stGroesse.integerValue = tfGroesse.integerValue }
        if t === tfSchrift { stSchrift.doubleValue = tfSchrift.doubleValue; return }
        if t === tfAdresse || t === tfCode || t === tfArbeitsplatz { return }
        feldGeaendert()
    }

    // Zeilenumbruch im Textfeld mit ⏎
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === tfText, sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    @objc func deckkraftGeaendert() { lbDeckkraft.stringValue = "\(slDeckkraft.integerValue) %" }

    @objc func anwendenGeklickt() {
        fenster.makeFirstResponder(nil)
        feldGeaendert()
        darstellungLesen()
        uebernehmen(e)
    }
    @objc func okGeklickt() { anwendenGeklickt(); fenster.close() }
    @objc func abbrechenGeklickt() { fenster.close() }

    func windowWillClose(_ notification: Notification) {
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
        beimSchliessen?()
    }
}

// MARK: - Testbilder (--bild <pfad> [hell] [leiste] [jetzt] [einstellungen])

func bildSpeichern(_ v: NSView, _ pfad: String, grund: NSColor? = nil) {
    v.layoutSubtreeIfNeeded()
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    if let g = grund { // Fensterhintergrund (zeichnet die Inhaltsansicht nicht selbst)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        v.effectiveAppearance.performAsCurrentDrawingAppearance { g.setFill(); NSRect(origin: .zero, size: rep.size).fill() }
        NSGraphicsContext.restoreGraphicsState()
    }
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: pfad))
}

func beispielEinstellungen(_ args: [String]) -> Einstellungen {
    var e = Einstellungen()
    let jetzt = Date()
    var oben = Feld(.text, text: args.contains("leiste") ? "Hochwasser Musterstadt – Einsatzleitung" : "Hochwasser Musterstadt\nEinsatzleitung")
    oben.groesse = 100
    var uhr = Feld(.uhr)
    uhr.sekunden = true
    var kat = Feld(.seit)
    kat.zeit = Zeit.minute(jetzt.addingTimeInterval(-(3 * 3600 + 14 * 60)))
    kat.hintergrund = "#B71C1C"; kat.schriftfarbe = "#FFFFFF"
    var lage = Feld(.termin)
    lage.zeit = Zeit.minute(jetzt.addingTimeInterval(args.contains("jetzt") ? -60 : 7 * 60 + 30))
    var abschnitt = Feld(.text, titel: "Einsatzabschnitt Nord", text: "Deich Brücke B 7 gesperrt")
    abschnitt.hintergrund = "#FFD600"; abschnitt.schriftfarbe = "#000000"; abschnitt.groesse = 90
    var unten = Feld(.text, text: "Funk: Kanal 34 · Lagedienst 0123 456")
    unten.groesse = 80
    e.felder = [oben, uhr, kat, lage, abschnitt, unten]
    if args.contains("leiste") { e.nebeneinander = true; e.felder = [oben, uhr, kat, lage, unten] }
    if args.contains("hell") { e.hintergrund = "#FFFFFF"; e.schriftfarbe = "#1E1E1E" }
    if let i = args.firstIndex(of: "--dock"), i + 1 < args.count { e.andocken = Int(args[i + 1]) ?? 0 }
    if args.contains("bald") { e.felder[3].zeit = Zeit.minute(jetzt.addingTimeInterval(5 * 60)) }
    return e
}

func testbild(_ args: [String]) {
    let pfad = args[args.firstIndex(of: "--bild")! + 1]
    let s = Steuerung()
    s.e = beispielEinstellungen(args)
    if args.contains("einstellungen") { // Fensteraufbau als PDF (Bedienelemente zeichnet PDF nur teilweise)
        let f = EinstellungenFenster(s.e) { _ in }
        f.fenster.appearance = NSAppearance(named: .aqua)
        let v = f.fenster.contentView!
        v.layoutSubtreeIfNeeded()
        try? v.dataWithPDF(inside: v.bounds).write(to: URL(fileURLWithPath: pfad))
        return
    }
    s.ansicht.steuerung = s
    s.ansicht.frame = NSRect(origin: .zero, size: s.ansicht.anordnen(s.bloecke(Date())))
    bildSpeichern(s.ansicht, pfad)
}

// MARK: - Start

let argumente = CommandLine.arguments

final class AppDelegate: NSObject, NSApplicationDelegate {
    let steuerung = Steuerung()
    func applicationDidFinishLaunching(_ n: Notification) {
        if argumente.contains("--beispiel") { steuerung.e = beispielEinstellungen(argumente) } // nur zum Testen, wird nicht gespeichert
        steuerung.starten()
        if argumente.contains("--nach-update") { steuerung.nachUpdate() }
        if argumente.contains("--updatetest") { steuerung.updateTest() } // Test: ohne Rückfragen suchen und installieren
        if argumente.contains("--vollbildtest") { // Test: nach 1 s Vollbild-Lagebild zeigen
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.steuerung.vollbildZeigen() }
        }
        if argumente.contains("--animationstest") { // Test: nach 3 s ohne Maus aufklappen (klappt 1 s später wieder ein)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.steuerung.ausklappen() }
        }
        if argumente.contains("--einstellungen") {
            steuerung.einstellungenOeffnen()
            if let i = argumente.firstIndex(of: "--feld"), i + 1 < argumente.count, let n = Int(argumente[i + 1]) {
                steuerung.einstellungen?.auswahl(n)
            }
        }
        // Test: alle 2 s Bilder vom Kasten und vom Einstellungsfenster (falls offen) in einen Ordner schreiben
        if let i = argumente.firstIndex(of: "--bilder"), i + 1 < argumente.count {
            let ordner = argumente[i + 1]
            try? FileManager.default.createDirectory(atPath: ordner, withIntermediateDirectories: true)
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                guard let s = self?.steuerung else { return }
                bildSpeichern(s.ansicht, ordner + "/kasten.png")
                if let v = s.einstellungen?.fenster.contentView { bildSpeichern(v, ordner + "/einstellungen.png", grund: .windowBackgroundColor) }
            }
            RunLoop.main.add(t, forMode: .common)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !steuerung.fenster.isVisible { steuerung.einblenden() } // erneutes Öffnen holt den Kasten nach vorne
        steuerung.fenster.orderFrontRegardless()
        return false
    }
    func applicationWillTerminate(_ n: Notification) { if !argumente.contains("--beispiel") { steuerung.positionMerken() } }
}

@main
enum Start {
    static let delegat = AppDelegate()

    static func main() {
        // Test: eigenes Profil (eigene Einstellungen, keine Ablage für den Bildschirmschoner), z. B. für zwei Instanzen nebeneinander
        if let i = argumente.firstIndex(of: "--profil"), i + 1 < argumente.count {
            Einstellungen.ablage = UserDefaults(suiteName: "local.lageuhr.test." + argumente[i + 1]) ?? .standard
        }
        if let i = argumente.firstIndex(of: "--abgleichtest"), i + 1 < argumente.count { // Test: zwei Arbeitsplätze gegen einen Server
            AbgleichTest.starten(argumente[i + 1])
        }
        if argumente.contains("--bild") {
            testbild(argumente)
            exit(0)
        }
        if argumente.contains("--atomuhr") { // Test: einmal abgleichen und Ergebnis ausgeben
            let i = argumente.firstIndex(of: "--atomuhr")!
            Atomuhr.abgleichen(i + 1 < argumente.count ? argumente[i + 1] : Atomuhr.standardServer) { v, s in
                if let v = v, let s = s { print("\(s): Versatz \(String(format: "%+.3f", v)) s – \(Uhr.abweichungText(v))") }
                else { print("Atomuhr nicht erreichbar") }
                exit(v == nil ? 1 : 0)
            }
            RunLoop.main.run()
        }
        let app = NSApplication.shared
        app.delegate = delegat
        app.setActivationPolicy(.accessory) // kein Dock-Symbol, nur Menüleiste
        app.run()
    }
}

/// Vollbildfenster, das Tastendrücke bekommt (zum Beenden).
final class VollbildFenster: NSWindow {
    override var canBecomeKey: Bool { true }
}
