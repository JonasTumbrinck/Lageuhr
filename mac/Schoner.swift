// Lageuhr als macOS-Bildschirmschoner (Lageuhr.saver): zeigt die Felder der Lageuhr groß.
// Die Daten schickt die Lageuhr-App als systemweite Nachricht (Lagebild.schreiben); der Schoner fragt alle 10 s nach
// und merkt sich den letzten Stand. Ohne App und ohne gemerkten Stand zeigt er die Uhrzeit.
import ScreenSaver

@objc(LageuhrSchoner)
final class LageuhrSchoner: ScreenSaverView {
    private let bild = LagebildAnsicht()
    private var gelesen = Date.distantPast
    private var vonApp = false
    private var beobachter: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        einrichten()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        einrichten()
    }

    private func einrichten() {
        animationTimeInterval = 0.25
        bild.frame = bounds
        bild.autoresizingMask = [.width, .height]
        addSubview(bild)
        beobachter = DistributedNotificationCenter.default().addObserver(forName: Lagebild.nachrichtStand, object: nil, queue: .main) { [weak self] n in
            guard let text = n.object as? String, let d = text.data(using: .utf8), let (e, versatz) = Lagebild.dekodieren(d) else { return }
            Lagebild.ablegen(d) // für den nächsten Start ohne laufende App
            self?.uebernehmen(e, versatz)
        }
        if let (e, versatz) = Lagebild.lesen() { uebernehmen(e, versatz) } else { platzhalter() }
        nachfragen()
    }

    deinit { if let b = beobachter { DistributedNotificationCenter.default().removeObserver(b) } }

    private func uebernehmen(_ e: Einstellungen, _ versatz: Double) {
        bild.e = e
        Uhr.versatz = versatz
        vonApp = true
    }

    /// Die laufende App um den aktuellen Stand bitten (alle 10 s, damit Änderungen ankommen).
    private func nachfragen() {
        gelesen = Date()
        DistributedNotificationCenter.default().postNotificationName(Lagebild.nachrichtAnfrage, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func platzhalter() {
        if !vonApp {
            var e = Einstellungen()
            var hinweis = Feld(.text, text: "Lageuhr-App starten, um die Felder hier zu zeigen")
            hinweis.groesse = 50
            e.felder = [Feld(.uhr), hinweis]
            bild.e = e
        }
    }

    override func animateOneFrame() {
        if Date().timeIntervalSince(gelesen) > 10 { nachfragen() }
        let jetzt = Uhr.jetzt()
        var e = bild.e
        if e.termineWeiterschalten(jetzt) { bild.e = e }
        bild.aktualisieren(jetzt: jetzt)
    }

    override var hasConfigureSheet: Bool { false }
}
