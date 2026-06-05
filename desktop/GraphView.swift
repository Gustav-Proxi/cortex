import SwiftUI
import AppKit

// Native constellation — a direct Core-Graphics port of the design's
// graph-engine.js (canvas 2D ≈ CGContext), so nodes/edges/connections match the
// HTML pixel-for-pixel: luminous additive-halo orbs with a spherical sheen core,
// gently-curved edges brightened toward their endpoints, a coloured focus-path on
// hover (glow + flowing dashes), and level-of-detail labels that fade in as you
// zoom. Full pan / wheel-&-pinch-zoom / node-drag. The cooling sim is calm and
// hard-clamped (vmax/pmax/isFinite) so it settles smoothly and idles at ~0 CPU.

struct GraphContainer: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.stage
            GraphCanvasView().environmentObject(state)
            if !state.graphChromeHidden {
                GraphControls().padding(.init(top: 18, leading: 18, bottom: 18, trailing: 56))
                Legend().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(18)
                GraphMeta().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(18)
            }
            ChromeToggle().padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .clipped()
    }
}

// A small eye toggle (top-right) to hide every floating panel for a pure
// constellation — the "way to hide the menus on the graph" affordance.
private struct ChromeToggle: View {
    @EnvironmentObject var state: AppState
    @State private var hover = false
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.16)) { state.graphChromeHidden.toggle() } } label: {
            Image(systemName: state.graphChromeHidden ? "eye.slash" : "eye")
                .font(.system(size: 13)).foregroundStyle(Theme.txt2)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.panel2 : Theme.glass))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair2))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help(state.graphChromeHidden ? "Show controls" : "Hide controls")
    }
}

// MARK: - control card (.ctlcard)

private struct GraphControls: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CtlGroup(title: "COLOR BY", options: ColorBy.allCases.map(\.rawValue),
                     selected: state.colorBy.rawValue) { state.colorBy = ColorBy(rawValue: $0) ?? .domain }
            CtlGroup(title: "LINKS", options: LinkMode.allCases.map(\.rawValue),
                     selected: state.linkMode.rawValue) { state.linkMode = LinkMode(rawValue: $0) ?? .wiki }
            CtlGroup(title: "LABELS", options: LabelMode.allCases.map(\.rawValue),
                     selected: state.labelMode.rawValue) { state.labelMode = LabelMode(rawValue: $0) ?? .all }
            HStack(spacing: 8) {
                GraphBtn(label: "Re-layout", sym: Sym.layout) { state.relayoutTick += 1 }
                GraphBtn(label: "Fit", sym: Sym.fit) { state.fitTick += 1 }
            }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .frame(width: 210)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hair2))
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial).opacity(0.5))
    }
}

private struct CtlGroup: View {
    let title: String; let options: [String]; let selected: String; let onPick: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.txt3)
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { o in
                    Text(o).font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(o == selected ? .white : Theme.txt2)
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(o == selected ? Color(white: 0.48, opacity: 0.5) : .clear))
                        .contentShape(Rectangle()).onTapGesture { onPick(o) }
                }
            }
            .padding(2).background(RoundedRectangle(cornerRadius: 7).fill(Color.w(0.06)))
        }
    }
}

private struct GraphBtn: View {
    let label: String; let sym: String; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: sym).font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.txt)
            .frame(maxWidth: .infinity).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.w(hover ? 0.12 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hair2))
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

private struct Legend: View {
    @EnvironmentObject var state: AppState
    // Real vault domains, most-populous first; no-domain notes fold into "Other".
    var counts: [(String, Color, Int)] {
        var byDomain: [String: Int] = [:]
        for n in state.notes { byDomain[n.domain ?? "—", default: 0] += 1 }
        // deterministic tiebreak by name — without it, equal-count domains reshuffle
        // every time the legend re-renders (e.g. on graph hover), which read as glitching.
        return byDomain.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(7).map {
            ($0.key == "—" ? "Other" : DomainColor.label($0.key),
             DomainColor.color($0.key == "—" ? nil : $0.key), $0.value)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DOMAINS").font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(Theme.txt3).padding(.bottom, 9)
            ForEach(counts, id: \.0) { c in
                HStack(spacing: 9) {
                    Circle().fill(c.1).frame(width: 8, height: 8).shadow(color: c.1.opacity(0.8), radius: 4)
                    Text(c.0).font(.system(size: 12.5)).foregroundStyle(Theme.txt)
                    Spacer(minLength: 12)
                    Text("\(c.2)").font(.system(size: 11.5)).foregroundStyle(Theme.txt3).monospacedDigit()
                }.frame(height: 22)
            }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        // Hug content (≥184pt) — the greedy Spacer would otherwise stretch the card
        // full-width and collide with the meta pill. Mirrors `min-width:184px`.
        .frame(minWidth: 184, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hair2))
    }
}

private struct GraphMeta: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Group {
            if let h = state.hoverInfo {
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.title).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.txt)
                    Text(h.path).font(Theme.mono(11)).foregroundStyle(Theme.txt3)
                    Text("\(h.links) links").font(Theme.ui(11.5)).foregroundStyle(Theme.txt2).padding(.top, 2)
                }
            } else {
                Text("\(state.notes.count) notes · \(state.graphEdges().count) links · \(state.semanticEdges.count) semantic · \(state.chunks) chunks")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.txt2).monospacedDigit()
            }
        }
        .padding(EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 13))
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hair2))
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: 420, alignment: .leading)
    }
}

// MARK: - SwiftUI ↔ AppKit bridge

private struct GraphCanvasView: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeNSView(context: Context) -> GraphCanvas {
        let v = GraphCanvas()
        v.onSelect = { id in Task { @MainActor in state.open(id) } }
        v.onHover  = { info in Task { @MainActor in state.hoverInfo = info } }
        sync(v, context)
        return v
    }

    func updateNSView(_ v: GraphCanvas, context: Context) { sync(v, context) }

    private func sync(_ v: GraphCanvas, _ context: Context) {
        let c = context.coordinator
        let es = edgesFor(state.linkMode)
        if v.nodeCount != state.notes.count {
            v.load(nodes: state.graph?.nodes ?? [], edges: es, colorBy: state.colorBy, labelMode: state.labelMode)
            c.edgeCount = es.count
        } else if c.linkMode != state.linkMode || c.edgeCount != es.count {
            // link-mode switch OR a live vault edit changed the links → update in place,
            // keeping node positions (a gentle reheat re-seats the new connections).
            v.setEdges(es); c.edgeCount = es.count
        }
        c.linkMode = state.linkMode
        if c.colorBy != state.colorBy { c.colorBy = state.colorBy; v.setColorBy(state.colorBy) }
        if c.labelMode != state.labelMode { c.labelMode = state.labelMode; v.setLabelMode(state.labelMode) }
        if c.relayout != state.relayoutTick { c.relayout = state.relayoutTick; v.relayout() }
        if c.fit != state.fitTick { c.fit = state.fitTick; v.fit() }
    }

    // (source, target, isSemantic) per current link mode.
    private func edgesFor(_ m: LinkMode) -> [(String, String, Bool)] {
        let wiki = (state.graph?.edges ?? []).map { ($0.source, $0.target, false) }
        let sem  = state.semanticEdges.map { ($0.source, $0.target, true) }
        switch m {
        case .wiki: return wiki
        case .semantic: return sem
        case .both: return wiki + sem
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var colorBy: ColorBy = .domain
        var linkMode: LinkMode = .wiki
        var labelMode: LabelMode = .all
        var relayout = 0, fit = 0, edgeCount = -1
    }
}

// Compact local-graph map for the reader inspector: the open note (pinned, lit) +
// its 1-hop wiki neighbours and the links among them. Click a neighbour to open it.
struct MiniGraphView: NSViewRepresentable {
    @EnvironmentObject var state: AppState
    let noteId: String

    func makeNSView(context: Context) -> GraphCanvas {
        let v = GraphCanvas()
        v.mini = true
        v.onSelect = { id in Task { @MainActor in state.open(id) } }
        context.coordinator.loaded = noteId
        loadNeighborhood(into: v)
        return v
    }
    func updateNSView(_ v: GraphCanvas, context: Context) {
        if context.coordinator.loaded != noteId {
            context.coordinator.loaded = noteId
            loadNeighborhood(into: v)
        }
    }
    private func loadNeighborhood(into v: GraphCanvas) {
        guard let g = state.graph else { return }
        var ids: Set<String> = [noteId]
        for e in g.edges where e.source == noteId || e.target == noteId { ids.insert(e.source); ids.insert(e.target) }
        let subNodes = g.nodes.filter { ids.contains($0.id) }
        let subEdges = g.edges.filter { ids.contains($0.source) && ids.contains($0.target) }.map { ($0.source, $0.target, false) }
        v.pinId = noteId
        v.load(nodes: subNodes, edges: subEdges, colorBy: state.colorBy, labelMode: .off)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded: String? = nil }
}

// MARK: - The canvas

final class GraphCanvas: NSView {
    private struct N {
        let id: String, label: String
        let domain: String?, status: String?, folder: String?
        var x: CGFloat = 0, y: CGFloat = 0, vx: CGFloat = 0, vy: CGFloat = 0
        var deg = 0
        var color = NSColor.gray
    }
    private struct E { let s: Int, t: Int, sem: Bool }

    private var nodes: [N] = []
    private var index: [String: Int] = [:]
    private var edges: [E] = []
    private var adj: [Int: Set<Int>] = [:]
    var nodeCount: Int { nodes.count }

    // view transform: screen = (t.x + world.x * t.k, t.y + world.y * t.k)
    private var tk: CGFloat = 1, tx: CGFloat = 0, ty: CGFloat = 0
    private var alpha: CGFloat = 0
    private var hoverId: Int? = nil
    private var hoverSet: Set<Int> = []
    private var dragNode: Int? = nil
    private var panning = false
    private var lastMouse: CGPoint = .zero
    private var moved = false
    private var colorBy: ColorBy = .domain
    private var labelMode: LabelMode = .all
    private var flow: CGFloat = 0
    var mini = false                 // compact neighbourhood map (reader inspector)
    var pinId: String? = nil         // the focused note in mini mode
    var circular = false             // force "neuron" spread (the ring looked bad with this many links)

    // fit/zoom animation
    private var animFrom: (CGFloat, CGFloat, CGFloat)?
    private var animTo: (CGFloat, CGFloat, CGFloat)?
    private var animStart: CFTimeInterval = 0
    private var animDur: CFTimeInterval = 0

    private var timer: Timer?
    private var tracking: NSTrackingArea?

    var onSelect: ((String) -> Void)?
    var onHover: ((HoverInfo?) -> Void)?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; layer?.backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }            // y-up world, so CG text draws upright
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    private var W: CGFloat { max(bounds.width, 1) }
    private var H: CGFloat { max(bounds.height, 1) }

    // MARK: data

    func load(nodes ns: [GraphNode], edges es: [(String, String, Bool)], colorBy cb: ColorBy, labelMode lm: LabelMode) {
        colorBy = cb; labelMode = lm
        let prev = index
        let prevNodes = nodes
        nodes = []; index = [:]
        let count = ns.count
        let ga = CGFloat.pi * (3 - sqrt(5))                 // golden angle
        let spread = 64 * sqrt(CGFloat(max(1, count)))
        for (i, g) in ns.enumerated() {
            index[g.id] = i
            var n = N(id: g.id, label: g.label, domain: g.domain, status: g.status, folder: g.folder)
            if let old = prev[g.id] { n.x = prevNodes[old].x; n.y = prevNodes[old].y }   // keep prior positions on reload
            else {
                // deterministic phyllotaxis seed → even disc, consistent settling
                let rr = spread * sqrt((CGFloat(i) + 0.5) / CGFloat(max(1, count)))
                let th = CGFloat(i) * ga
                n.x = cos(th) * rr; n.y = sin(th) * rr
            }
            nodes.append(n)
        }
        setEdges(es)
        applyColors()
        if circular && !mini {
            arrangeCircle()                                  // even ring — no force clumping
        } else {
            alpha = 1
            for _ in 0..<300 { tick() }                      // synchronous warmup, fully off-screen
        }
        alpha = 0                                            // appear already settled — no node animation on first paint
        fitInstant(pad: 80)
        // deferred recentre once the view actually has its real size (instant — no zoom animation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in self?.fit(dur: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.60) { [weak self] in self?.fit(dur: 0) }
        needsDisplay = true
    }

    func setEdges(_ es: [(String, String, Bool)]) {
        edges = es.compactMap { a in
            guard let s = index[a.0], let t = index[a.1], s != t else { return nil }
            return E(s: s, t: t, sem: a.2)
        }
        adj = [:]
        for i in nodes.indices { nodes[i].deg = 0 }
        for e in edges {
            nodes[e.s].deg += 1; nodes[e.t].deg += 1
            adj[e.s, default: []].insert(e.t); adj[e.t, default: []].insert(e.s)
        }
        if !circular { alpha = max(alpha, 0.18) }            // force mode nudges; ring stays put on live link changes
        start()
    }

    func setColorBy(_ cb: ColorBy) { colorBy = cb; applyColors(); needsDisplay = true }
    func setLabelMode(_ lm: LabelMode) { labelMode = lm; needsDisplay = true }
    func relayout() {
        if circular && !mini { arrangeCircle(); alpha = 0; fit(dur: 0.5); return }
        let ga = CGFloat.pi * (3 - sqrt(5)), n = nodes.count
        let spread = 64 * sqrt(CGFloat(max(1, n)))
        for i in nodes.indices {
            let rr = spread * sqrt((CGFloat(i) + 0.5) / CGFloat(max(1, n)))
            let th = CGFloat(i) * ga
            nodes[i].x = cos(th) * rr; nodes[i].y = sin(th) * rr; nodes[i].vx = 0; nodes[i].vy = 0
        }
        alpha = 0.9; start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.fit() }
    }

    private func applyColors() {
        for i in nodes.indices {
            let h: UInt32
            switch colorBy {
            case .domain: h = DomainColor.identityHex(domain: nodes[i].domain, folder: nodes[i].folder)
            case .status: h = Maturity.hex(nodes[i].status)
            case .folder: h = DomainColor.hex(nodes[i].folder?.split(separator: "/").first.map(String.init))
            }
            nodes[i].color = NSColor(srgbRed: CGFloat((h>>16)&0xff)/255, green: CGFloat((h>>8)&0xff)/255,
                                     blue: CGFloat(h&0xff)/255, alpha: 1)
        }
    }

    // Even ring layout — nodes spaced by angle, grouped by domain so colours form
    // arcs, ordered by degree within a domain. Frozen (no sim) so it never clumps.
    private func arrangeCircle() {
        let n = nodes.count; if n == 0 { return }
        let order = nodes.indices.sorted {
            let da = nodes[$0].domain ?? "~", db = nodes[$1].domain ?? "~"
            return da != db ? da < db : nodes[$0].deg > nodes[$1].deg
        }
        let r = max(320, CGFloat(n) * 34 / (2 * .pi))
        for (k, i) in order.enumerated() {
            let th = CGFloat(k) / CGFloat(n) * 2 * .pi - .pi/2
            nodes[i].x = cos(th) * r; nodes[i].y = sin(th) * r
            nodes[i].vx = 0; nodes[i].vy = 0
        }
    }

    private func radius(_ i: Int) -> CGFloat {
        if mini { return nodes[i].id == pinId ? 5.5 : 3.6 }
        return 2.4 + min(CGFloat(nodes[i].deg), 20) * 0.32                                       // ~2.4–8.8px
    }

    // MARK: physics (calm cooling sim — design constants + hard clamps)

    private func tick() {
        let n = nodes.count; if n == 0 { return }
        let a = alpha
        // stronger repulsion than the springs → an even spread instead of a dense
        // central ball (just scaling up wouldn't help: the auto-fit would re-zoom).
        let charge: CGFloat = mini ? -900 : -3000, repRange: CGFloat = mini ? 420 : 1100
        let linkDist: CGFloat = mini ? 48 : 100, linkK: CGFloat = 0.38
        let center: CGFloat = mini ? 0.05 : 0.012, vmax: CGFloat = mini ? 50 : 60, pmax: CGFloat = 6000
        // repulsion + soft collision (O(n²), fine < 200 nodes) — each pair once
        for i in 0..<n {
            for j in (i+1)..<n {
                var dx = nodes[i].x - nodes[j].x, dy = nodes[i].y - nodes[j].y
                var d2 = dx*dx + dy*dy
                if d2 < 1e-4 { dx = (i % 2 == 0 ? 0.5 : -0.5); dy = 0.5; d2 = 1 }
                let dist = sqrt(d2)
                if dist < repRange {
                    let f = charge * a / d2
                    let fx = dx/dist * f, fy = dy/dist * f
                    nodes[i].vx += fx; nodes[i].vy += fy; nodes[j].vx -= fx; nodes[j].vy -= fy
                }
                let rr = radius(i) + radius(j) + (mini ? 10 : 18)
                if dist < rr {
                    let push = (rr - dist) / dist * 0.6 * a
                    nodes[i].vx += dx*push; nodes[i].vy += dy*push
                    nodes[j].vx -= dx*push; nodes[j].vy -= dy*push
                }
            }
        }
        // springs (semantic links sit looser + pull softer)
        for e in edges {
            var dx = nodes[e.t].x - nodes[e.s].x, dy = nodes[e.t].y - nodes[e.s].y
            let dist = max(sqrt(dx*dx + dy*dy), 0.01)
            let want = e.sem ? linkDist * 1.5 : linkDist
            let f = (dist - want) / dist * linkK * a * (e.sem ? 0.4 : 1)
            dx *= f; dy *= f
            nodes[e.s].vx += dx; nodes[e.s].vy += dy
            nodes[e.t].vx -= dx; nodes[e.t].vy -= dy
        }
        // centering + integrate, hard-clamped so the sim can never diverge
        for i in 0..<n {
            nodes[i].vx -= nodes[i].x * center * a * 0.06
            nodes[i].vy -= nodes[i].y * center * a * 0.06
            if i == dragNode { continue }
            nodes[i].vx *= 0.80; nodes[i].vy *= 0.80
            if !nodes[i].vx.isFinite { nodes[i].vx = 0 }
            if !nodes[i].vy.isFinite { nodes[i].vy = 0 }
            nodes[i].vx = min(max(nodes[i].vx, -vmax), vmax)
            nodes[i].vy = min(max(nodes[i].vy, -vmax), vmax)
            nodes[i].x = min(max(nodes[i].x + nodes[i].vx, -pmax), pmax)
            nodes[i].y = min(max(nodes[i].y + nodes[i].vy, -pmax), pmax)
        }
        alpha *= 0.985; if alpha < 0.01 { alpha = 0 }
    }

    // MARK: view / camera

    private func fitInstant(pad padIn: CGFloat) {
        let pad = mini ? 22 : padIn
        guard !nodes.isEmpty, W > 2, H > 2 else { return }
        let (minX, minY, maxX, maxY) = bbox()
        let w = max(1, maxX - minX), h = max(1, maxY - minY)
        let k = min(max(min((W - 2*pad)/w, (H - 2*pad)/h), 0.15), 2.0)
        let cx = (minX+maxX)/2, cy = (minY+maxY)/2
        tk = k; tx = W/2 - cx*k; ty = H/2 - cy*k
    }
    func fit(pad padIn: CGFloat = 90, dur: Double = 0.6) {
        let pad = mini ? 24 : padIn
        guard !nodes.isEmpty, W > 2, H > 2 else { return }
        let (minX, minY, maxX, maxY) = bbox()
        let w = max(1, maxX - minX), h = max(1, maxY - minY)
        let k = min(max(min((W - 2*pad)/w, (H - 2*pad)/h), 0.15), 2.0)
        let cx = (minX+maxX)/2, cy = (minY+maxY)/2
        let target = (W/2 - cx*k, H/2 - cy*k, k)
        if dur <= 0 { tx = target.0; ty = target.1; tk = target.2; needsDisplay = true; return }
        animFrom = (tx, ty, tk); animTo = target; animStart = CACurrentMediaTime(); animDur = dur; start()
    }
    private func bbox() -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
        for n in nodes { minX = min(minX, n.x); maxX = max(maxX, n.x); minY = min(minY, n.y); maxY = max(maxY, n.y) }
        return (minX, minY, maxX, maxY)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let was = bounds.size
        super.setFrameSize(newSize)
        updateTrackingAreas()
        if was.width < 2 || was.height < 2 { fit(dur: 0) }   // first real layout → frame the graph
    }

    // MARK: run loop (ticks the sim + animation; idles to ~0 CPU when settled)

    private func start() {
        if timer != nil { return }
        let t = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }
    private func stop() { timer?.invalidate(); timer = nil }
    private func frame() {
        if let from = animFrom, let to = animTo {
            let p = min((CACurrentMediaTime() - animStart) / max(animDur, 0.0001), 1)
            let e = 1 - pow(1 - p, 3)
            tx = from.0 + (to.0 - from.0)*e; ty = from.1 + (to.1 - from.1)*e; tk = from.2 + (to.2 - from.2)*e
            if p >= 1 { animFrom = nil; animTo = nil }
        }
        if alpha > 0 { tick() }
        if hoverId != nil { flow += 0.6 }
        needsDisplay = true
        if alpha <= 0 && animFrom == nil && hoverId == nil && dragNode == nil && !panning { stop() }
    }

    // MARK: render (port of graph-engine.js _render)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)
        let k = tk
        ctx.saveGState()
        ctx.translateBy(x: tx, y: ty); ctx.scaleBy(x: k, y: k)

        drawEdges(ctx, k)
        drawHalos(ctx)
        drawCores(ctx, k)
        ctx.restoreGState()

        drawLabels(k)
    }

    private func focused(_ i: Int) -> Bool { hoverId == nil || i == hoverId || hoverSet.contains(i) }

    private func drawEdges(_ ctx: CGContext, _ k: CGFloat) {
        ctx.setLineCap(.round)
        let cs = CGColorSpaceCreateDeviceRGB()
        for e in edges {
            let hot = hoverId != nil && (e.s == hoverId || e.t == hoverId)
            let faded = (hoverId != nil && !hot)
            let s = nodes[e.s], t = nodes[e.t]
            let mx = (s.x + t.x)/2, my = (s.y + t.y)/2
            let dx = t.x - s.x, dy = t.y - s.y
            let bow: CGFloat = e.sem ? 0.16 : 0.05
            let cpx = mx - dy*bow, cpy = my + dx*bow
            let path = CGMutablePath()
            path.move(to: CGPoint(x: s.x, y: s.y))
            path.addQuadCurve(to: CGPoint(x: t.x, y: t.y), control: CGPoint(x: cpx, y: cpy))

            if hot {
                // focus path: soft glow underlay → true two-colour gradient → flowing dashes
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.addPath(path); ctx.setStrokeColor(s.color.withAlphaComponent(0.22).cgColor)
                ctx.setLineWidth(4.6 / k); ctx.strokePath()

                ctx.saveGState()
                ctx.addPath(path); ctx.setLineWidth(1.6 / k); ctx.replacePathWithStrokedPath(); ctx.clip()
                let grad = CGGradient(colorsSpace: cs, colors: [s.color.withAlphaComponent(0.95).cgColor,
                                                                t.color.withAlphaComponent(0.95).cgColor] as CFArray,
                                      locations: [0, 1])!
                ctx.drawLinearGradient(grad, start: CGPoint(x: s.x, y: s.y), end: CGPoint(x: t.x, y: t.y), options: [])
                ctx.restoreGState()

                ctx.addPath(path)
                ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
                ctx.setLineWidth(1.0 / k)
                ctx.setLineDash(phase: -(flow.truncatingRemainder(dividingBy: 16/k)), lengths: [7/k, 9/k])
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            } else {
                let a: CGFloat = e.sem ? (faded ? 0.035 : 0.11) : (faded ? 0.05 : 0.2)
                ctx.addPath(path)
                ctx.setStrokeColor(NSColor(white: 1, alpha: a).cgColor)
                ctx.setLineWidth((e.sem ? 0.55 : 0.85) / k)
                if e.sem { ctx.setLineDash(phase: 0, lengths: [2.5/k, 4.5/k]) } else { ctx.setLineDash(phase: 0, lengths: []) }
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
    }

    private func drawHalos(_ ctx: CGContext) {
        let cs = CGColorSpaceCreateDeviceRGB()
        ctx.setBlendMode(.plusLighter)
        for i in nodes.indices where focused(i) {
            let isHot = i == hoverId || (mini && nodes[i].id == pinId)
            let r = radius(i)
            let boost: CGFloat = isHot ? 2.6 : 1
            let hr = r * 4.2 * boost
            let col = nodes[i].color
            let grad = CGGradient(colorsSpace: cs, colors: [
                col.withAlphaComponent(0.34 * (isHot ? 1.25 : 1)).cgColor,
                col.withAlphaComponent(0.07).cgColor,
                col.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1])!
            ctx.drawRadialGradient(grad, startCenter: CGPoint(x: nodes[i].x, y: nodes[i].y), startRadius: 0,
                                   endCenter: CGPoint(x: nodes[i].x, y: nodes[i].y), endRadius: hr, options: [])
        }
        ctx.setBlendMode(.normal)
    }

    private func drawCores(_ ctx: CGContext, _ k: CGFloat) {
        let cs = CGColorSpaceCreateDeviceRGB()
        for i in nodes.indices {
            let isHot = i == hoverId || (mini && nodes[i].id == pinId)
            let r = radius(i)
            let col = nodes[i].color
            let on = focused(i)
            let x = nodes[i].x, y = nodes[i].y
            // spherical core: sheen toward top-left → full colour at the rim
            ctx.saveGState()
            ctx.setAlpha(on ? 1 : 0.14)
            ctx.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2*r, height: 2*r)); ctx.clip()
            let grad = CGGradient(colorsSpace: cs, colors: [
                lighten(col, 0.7).cgColor, lighten(col, 0.12).cgColor, col.cgColor] as CFArray, locations: [0, 0.45, 1])!
            ctx.drawRadialGradient(grad, startCenter: CGPoint(x: x - r*0.36, y: y + r*0.4), startRadius: r*0.1,
                                   endCenter: CGPoint(x: x, y: y), endRadius: r*1.05, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
            // crisp contact rim
            ctx.setAlpha(on ? 0.5 : 0.1)
            ctx.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2*r, height: 2*r))
            ctx.setStrokeColor(NSColor(white: 0, alpha: 0.45).cgColor); ctx.setLineWidth(0.75 / k); ctx.strokePath()
            ctx.setAlpha(1)
            if isHot {                                   // focus ring
                let rr = r + 3.5/k
                ctx.addEllipse(in: CGRect(x: x - rr, y: y - rr, width: 2*rr, height: 2*rr))
                ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5 / k); ctx.strokePath()
            }
        }
    }

    // labels drawn in screen space (constant size, crisp) with LOD by zoom
    private func drawLabels(_ k: CGFloat) {
        for i in nodes.indices {
            let la = labelAlpha(i, k)
            if la <= 0 { continue }
            let isHot = i == hoverId
            let sx = tx + nodes[i].x * k, sy = ty + nodes[i].y * k
            let r = radius(i) * k
            let font = NSFont(name: "Menlo", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
            let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.8); shadow.shadowBlurRadius = 3
            let color: NSColor = isHot ? .white : NSColor(srgbRed: 0xdf/255, green: 0xe2/255, blue: 0xe7/255, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(la), .shadow: shadow]
            let str = NSAttributedString(string: nodes[i].label, attributes: attrs)
            let sz = str.size()
            let lx = sx - sz.width/2, ly = sy - r - 4 - sz.height   // below the node (screen y-up)
            if isHot {                                   // legibility chip behind the focused label
                let chip = CGRect(x: lx - 5, y: ly - 2, width: sz.width + 10, height: sz.height + 4)
                let p = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
                NSColor(srgbRed: 8/255, green: 10/255, blue: 14/255, alpha: 0.82).setFill(); p.fill()
            }
            str.draw(at: CGPoint(x: lx, y: ly))
        }
    }

    private func labelAlpha(_ i: Int, _ k: CGFloat) -> CGFloat {
        if mini { return 0 }                 // mini map stays clean — no labels
        if i == hoverId { return 1 }
        if hoverId != nil { return hoverSet.contains(i) ? 0.9 : 0 }
        switch labelMode {
        case .off: return 0
        case .all: return k > 1.25 ? 0.92 : (k > 0.7 ? 0.5 : 0)
        case .hubs:
            if nodes[i].deg >= 8 && k > 0.5 { return 0.85 }   // only the big hubs, so labels stop piling up
            return k > 1.9 ? 0.5 : 0
        }
    }

    private func lighten(_ c: NSColor, _ t: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return NSColor(srgbRed: s.redComponent + (1 - s.redComponent)*t,
                       green: s.greenComponent + (1 - s.greenComponent)*t,
                       blue: s.blueComponent + (1 - s.blueComponent)*t, alpha: 1)
    }

    // MARK: interaction

    private func toWorld(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - tx)/tk, y: (p.y - ty)/tk) }
    private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private func nodeAt(_ p: CGPoint) -> Int? {
        let w = toWorld(p)
        var best: Int? = nil; var bestD = CGFloat.greatestFiniteMagnitude
        for i in nodes.indices {
            let dx = nodes[i].x - w.x, dy = nodes[i].y - w.y, d = dx*dx + dy*dy
            let rr = radius(i) + 6/tk
            if d < rr*rr && d < bestD { bestD = d; best = i }
        }
        return best
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with e: NSEvent) {
        let p = local(e)
        let hit = nodeAt(p)
        if hit != hoverId {
            hoverId = hit
            hoverSet = hit.flatMap { adj[$0] } ?? []
            NSCursor.pointingHand.set()
            if hit == nil { NSCursor.arrow.set() }
            start()
        }
        if let h = hit { onHover?(HoverInfo(title: nodes[h].label, path: nodes[h].id, links: nodes[h].deg)) }
        else { onHover?(nil) }
    }
    override func mouseExited(with e: NSEvent) {
        if hoverId != nil { hoverId = nil; hoverSet = []; onHover?(nil); NSCursor.arrow.set(); start() }
    }

    override func mouseDown(with e: NSEvent) {
        let p = local(e); moved = false; lastMouse = p
        if let i = nodeAt(p) { dragNode = i }
        else if !mini { panning = true; NSCursor.closedHand.set() }
    }
    override func mouseDragged(with e: NSEvent) {
        if mini { moved = true; return }     // mini map: click-to-open only, no drag/pan
        let p = local(e)
        if let i = dragNode {
            let w = toWorld(p)
            nodes[i].x = w.x; nodes[i].y = w.y; nodes[i].vx = 0; nodes[i].vy = 0
            // FREEZE the sim while dragging — no reheat, so the physics never ticks:
            // only the grabbed node moves (its edges stretch to follow it), every other
            // node stays exactly put. This fully removes the repulsion "dancing".
            moved = true; needsDisplay = true
        } else if panning {
            tx += p.x - lastMouse.x; ty += p.y - lastMouse.y; lastMouse = p; moved = true; needsDisplay = true
        }
    }
    override func mouseUp(with e: NSEvent) {
        if let i = dragNode, !moved { onSelect?(nodes[i].id) }
        // no reheat on release — the node stays exactly where you drop it; nothing settles
        dragNode = nil; panning = false; NSCursor.arrow.set(); start()
    }

    override func scrollWheel(with e: NSEvent) {
        if mini { return }
        let p = local(e); let w = toWorld(p)
        let factor = exp(e.scrollingDeltaY * 0.0015)         // scroll up → zoom in
        let k = min(max(tk * factor, 0.12), 6)
        tk = k; tx = p.x - w.x*k; ty = p.y - w.y*k
        animFrom = nil; animTo = nil
        needsDisplay = true; start()
    }
    override func magnify(with e: NSEvent) {                  // trackpad pinch
        if mini { return }
        let p = local(e); let w = toWorld(p)
        let k = min(max(tk * (1 + e.magnification), 0.12), 6)
        tk = k; tx = p.x - w.x*k; ty = p.y - w.y*k
        animFrom = nil; animTo = nil
        needsDisplay = true; start()
    }
}
