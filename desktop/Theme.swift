import SwiftUI

// Cortex design system — ported verbatim from the Claude Design handoff
// (mac/cortex-mac.css). Core principle: "Graphite UI — the only colour in the
// product is the knowledge itself (graph nodes + domain dots). Everything else
// is near-black + white." So chrome is monochrome; accent blue is reserved for
// genuine controls (focus/active/primary), and hue lives only in status dots,
// the graph, and the colour-left-stripe on cards.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
    /// White at a given opacity — the workhorse of a graphite UI.
    static func w(_ o: Double) -> Color { Color(white: 1, opacity: o) }
}

enum Theme {
    // surfaces
    static let desktop = Color(hex: 0x06070a)
    static let stage   = Color(hex: 0x0b0c0f)     // main content bg
    static let stage2  = Color(hex: 0x0e1014)
    static let sidebar = Color(hex: 0x16171b, alpha: 0.72)
    static let toolbar = Color(hex: 0x121317, alpha: 0.62)
    static let panel   = Color(hex: 0x17181c)     // raised cards / inspector
    static let panel2  = Color(hex: 0x1c1d22)
    static let glass   = Color(hex: 0x1c1d22, alpha: 0.66)

    // hairlines
    static let hair       = Color.w(0.07)
    static let hair2      = Color.w(0.11)
    static let hairStrong = Color.w(0.16)

    // ink
    static let txt  = Color.w(0.92)
    static let txt2 = Color(.sRGB, red: 235/255, green: 235/255, blue: 245/255, opacity: 0.58)
    static let txt3 = Color(.sRGB, red: 235/255, green: 235/255, blue: 245/255, opacity: 0.30)
    static let txt4 = Color(.sRGB, red: 235/255, green: 235/255, blue: 245/255, opacity: 0.18)

    // graphite selection (monochrome)
    static let sel       = Color.w(0.10)
    static let selStrong = Color.w(0.14)
    static let hover     = Color.w(0.055)

    // system blue — ONLY for genuine controls
    static let accent     = Color(hex: 0x2f81f7)
    static let accent2    = Color(hex: 0x4c93ff)
    static let accentSoft = Color(hex: 0x2f81f7, alpha: 0.16)

    // engine / live status
    static let green = Color(hex: 0x28c840)

    // fonts
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // NSColor mirrors for SpriteKit / AppKit
    enum NS {
        static let stage   = NSColor(srgbRed: 0x0b/255, green: 0x0c/255, blue: 0x0f/255, alpha: 1)
        static let txt     = NSColor(white: 1, alpha: 0.92)
        static let hairRGB = NSColor(white: 1, alpha: 0.07)
        static let accent  = NSColor(srgbRed: 0x2f/255, green: 0x81/255, blue: 0xf7/255, alpha: 1)
    }
}

// Domain → node/dot hue. The ONLY chromatic palette in the app (locked, from the
// design's vault-data.js): muted jewel tones, one hue per domain. Deterministic
// per domain so a note's dot/node colour is stable across the app.
enum DomainColor {
    static let fallback: UInt32 = 0x9aa0a9   // graphite grey, no domain
    // exact design keys + common synonyms for the real vault's frontmatter
    static let map: [String: UInt32] = [
        "ml": 0x67E8F9, "ai": 0x67E8F9, "machine learning": 0x67E8F9, "machine-learning": 0x67E8F9,
        "systems": 0xA78BFA, "code": 0xA78BFA, "systems & code": 0xA78BFA, "engineering": 0xA78BFA,
        "writing": 0xFCD34D, "ideas": 0xFCD34D, "ideas & writing": 0xFCD34D,
        "health": 0x86EFAC, "body": 0x86EFAC, "body & health": 0x86EFAC, "fitness": 0x86EFAC,
        "life": 0xFDA4AF, "logs": 0xFDA4AF, "life & logs": 0xFDA4AF, "daily": 0xFDA4AF,
        "meta": 0x93C5FD, "moc": 0x93C5FD, "maps of content": 0x93C5FD, "research": 0x93C5FD,
    ]
    // jewel-tone ring used to assign a stable hue to any unmapped domain
    static let jewels: [UInt32] = [0x67E8F9, 0xA78BFA, 0xFCD34D, 0x86EFAC, 0xFDA4AF, 0x93C5FD]
    static func hex(_ domain: String?) -> UInt32 {
        guard let d = domain?.lowercased(), !d.isEmpty, d != "none" else { return fallback }
        if let c = map[d] { return c }
        // keyword routing so the real vault's domains land on a sensible hue
        func has(_ ks: [String]) -> Bool { ks.contains { d.contains($0) } }
        if has(["ml", "ai", "model", "nlp", "vision", "generative", "audio", "agent"]) { return 0x67E8F9 } // cyan
        if has(["health", "fitness", "bio", "med", "clinical", "body"])                { return 0x86EFAC } // green
        if has(["system", "hardware", "code", "infra", "eng", "devops"])               { return 0xA78BFA } // violet
        if has(["writ", "idea", "paper", "research", "note"])                          { return 0xFCD34D } // amber
        if has(["life", "career", "daily", "log", "personal"])                         { return 0xFDA4AF } // rose
        if has(["meta", "moc", "map"])                                                 { return 0x93C5FD } // sky
        return jewels[abs(d.hashValue) % jewels.count]
    }
    static func color(_ domain: String?) -> Color { Color(hex: hex(domain)) }

    /// A note's identity colour: its domain hue if set, otherwise a stable hue from
    /// its top-level folder — so the ~45 domain-less utility notes (READMEs, resumes,
    /// decisions…) read as grouped-by-area instead of an undifferentiated grey.
    static func identityHex(domain: String?, folder: String?) -> UInt32 {
        if let d = domain, !d.isEmpty, d.lowercased() != "none" { return hex(d) }
        if let f = folder?.split(separator: "/").first.map(String.init), !f.isEmpty { return hex(f) }
        return fallback
    }
    static func identityColor(domain: String?, folder: String?) -> Color {
        Color(hex: identityHex(domain: domain, folder: folder))
    }
    /// Pretty legend/inspector label for a raw domain key (kebab → Title Case,
    /// with common ML acronyms upper-cased). e.g. "medical-ai" → "Medical AI".
    static func label(_ domain: String) -> String {
        let acronyms: Set<String> = ["ai", "ml", "nlp", "rag", "llm", "cv", "ar", "vr", "hpc"]
        return domain.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { acronyms.contains($0.lowercased()) ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
    static func ns(_ domain: String?) -> NSColor {
        let h = hex(domain)
        return NSColor(srgbRed: Double((h>>16)&0xff)/255, green: Double((h>>8)&0xff)/255,
                       blue: Double(h&0xff)/255, alpha: 1)
    }
}

// Digital-garden maturity — encoded as a monochrome glyph (NOT a colour); the
// glyph is drawn in the note's domain colour so it doubles as the domain dot.
enum Maturity {
    // map the real vault's project statuses onto the digital-garden ramp ○ ◐ ●
    private enum Stage { case ripe, growing, seed }
    private static func stage(_ status: String?) -> Stage? {
        guard let s = status?.lowercased(), !s.isEmpty, s != "none" else { return nil }
        if s.contains("evergreen") || s.contains("complete") || s.contains("done")
            || s.contains("ship") || s.contains("publish") || s.contains("evolved") { return .ripe }
        if s.contains("seed") || s.contains("plan") || s.contains("next") || s.contains("captur")
            || s.contains("idea") || s.contains("draft") || s.contains("backlog") { return .seed }
        return .growing   // active / ready / ongoing / wip / …
    }
    static func glyph(_ status: String?) -> String {
        switch stage(status) { case .ripe: return "●"; case .growing: return "◐"; case .seed: return "○"; case nil: return "●" }
    }
    static func label(_ status: String?) -> String {
        guard let s = status, !s.isEmpty, s.lowercased() != "none" else { return "Note" }
        return s.prefix(1).uppercased() + s.dropFirst()
    }
    // COLOR BY = Status palette (graph mode only)
    static func hex(_ status: String?) -> UInt32 {
        switch stage(status) {
        case .seed:    return 0x86EFAC
        case .growing: return 0xFCD34D
        case .ripe:    return 0x67E8F9
        case nil:      return 0x9aa0a9
        }
    }
}
