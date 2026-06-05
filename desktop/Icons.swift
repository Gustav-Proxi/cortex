import SwiftUI

// Icon layer for the design's icon set (mac/icons.jsx). The source glyphs are
// explicitly "SF-Symbols-style (1.6–1.8 stroke, rounded)", so the faithful +
// native choice is to map each to its SF Symbol. The one true brand mark — the
// `graph` constellation glyph (4 nodes + hub + links) — is hand-drawn as a Path
// so the app/nav identity matches the design exactly.

enum Sym {
    // name (from icons.jsx) → SF Symbol
    static let search    = "magnifyingglass"
    static let library   = "square.grid.2x2"
    static let calendar  = "calendar"
    static let doc        = "doc"
    static let folder     = "folder"
    static let pencil     = "pencil"
    static let gear       = "gearshape"
    static let sidebar    = "sidebar.left"
    static let sparkle    = "sparkles"
    static let command    = "command"
    static let link       = "link"
    static let related    = "point.3.connected.trianglepath.dotted"
    static let chevron     = "chevron.right"
    static let chevronDown = "chevron.down"
    static let plus        = "plus"
    static let refresh     = "arrow.clockwise"
    static let inspector   = "sidebar.right"
    static let check       = "checkmark"
    static let close       = "xmark"
    static let back        = "chevron.left"
    static let fit         = "arrow.up.left.and.arrow.down.right"
    static let layout      = "circle.grid.cross"
    static let clock       = "clock"
    static let shield      = "shield"
    static let cpu         = "cpu"
    static let eye         = "eye"
    static let arrowRight  = "arrow.right"
    static let enter       = "return"
}

/// The Cortex constellation brand mark — exact port of icons.jsx `graph`:
/// four outer nodes, a filled hub, and the links between them.
struct ConstellationMark: View {
    var size: CGFloat = 16
    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 24.0   // source viewBox is 24×24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let stroke = GraphicsContext.Shading.color(.white)
            // links
            var links = Path()
            links.move(to: p(7.8, 8.4)); links.addLine(to: p(10, 10))
            links.move(to: p(14, 10.2)); links.addLine(to: p(16.8, 7.3))
            links.move(to: p(13.6, 12.6)); links.addLine(to: p(16, 15.6))
            links.move(to: p(10.1, 12.7)); links.addLine(to: p(9, 14.8))
            ctx.stroke(links, with: stroke, style: StrokeStyle(lineWidth: 1.7 * s, lineCap: .round))
            // outer nodes (r 1.9)
            for c in [p(6, 7), p(18, 6), p(17, 17), p(8, 16.5)] {
                let r = 1.9 * s
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2*r, height: 2*r)),
                           with: stroke, lineWidth: 1.7 * s)
            }
            // hub (filled, r 2.4)
            let hr = 2.4 * s, hc = p(12, 11)
            ctx.fill(Path(ellipseIn: CGRect(x: hc.x - hr, y: hc.y - hr, width: 2*hr, height: 2*hr)),
                     with: stroke)
        }
        .frame(width: size, height: size)
    }
}

/// Convenience: an SF Symbol sized like the design's icons.
struct Icon: View {
    let name: String
    var size: CGFloat = 16
    var weight: Font.Weight = .regular
    init(_ name: String, size: CGFloat = 16, weight: Font.Weight = .regular) {
        self.name = name; self.size = size; self.weight = weight
    }
    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
    }
}
