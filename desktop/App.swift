// Cortex — native macOS app (SwiftUI + SpriteKit), client of the local engine on
// :8788. Graphite design system per mac/cortex-mac.css: monochrome chrome, colour
// only in the constellation + domain dots. Build with build.sh (system swiftc).
import SwiftUI

@main
struct CortexApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
                .task { await state.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Search") { state.showSpotlight = true }.keyboardShortcut("k", modifiers: .command)
                Button("Constellation") { state.route = .graph }.keyboardShortcut("1", modifiers: .command)
                Button("Library") { state.route = .library }.keyboardShortcut("2", modifiers: .command)
                Button("Reload") { Task { await state.reload() } }.keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Cortex") { state.showOnboarding = true }
            }
        }
    }
}

enum Route: Equatable { case graph, library, daily, reader }
struct HoverInfo: Equatable { let title: String; let path: String; let links: Int }
enum ColorBy: String, CaseIterable { case domain = "Domain", folder = "Folder", status = "Status" }
enum LinkMode: String, CaseIterable { case wiki = "Wiki", both = "Both", semantic = "Semantic" }
enum LabelMode: String, CaseIterable { case all = "All", hubs = "Hubs", off = "Off" }

@MainActor
final class AppState: ObservableObject {
    // canonical data (one /graph call → every note's metadata + link structure)
    @Published var graph: Graph?
    @Published var notes: [VaultNote] = []
    @Published var byId: [String: VaultNote] = [:]
    @Published var semanticEdges: [GraphEdge] = []
    @Published var chunks = 0
    @Published var loading = false
    @Published var engineUp = true
    @Published var errorMessage: String?

    // navigation + selection
    @Published var route: Route = .graph
    @Published var selection: String?
    @Published var content = ""
    @Published var loadingNote = false

    // reader editing
    @Published var editing = false
    @Published var draft = ""
    @Published var saving = false
    @Published var related: [SearchHit] = []

    // overlays
    @Published var showSpotlight = false
    @Published var hoverInfo: HoverInfo?
    @Published var graphChromeHidden = false
    @Published var showOnboarding = false
    @Published var syncPulse = 0          // bumped on every live vault save (footer flashes "Synced")

    // graph controls
    @Published var colorBy: ColorBy = .domain
    @Published var linkMode: LinkMode = .wiki
    @Published var labelMode: LabelMode = .hubs   // hub-only labels keep the resting constellation clean
    @Published var relayoutTick = 0
    @Published var fitTick = 0

    private let api = CortexAPI()
    func client() -> CortexAPI { api }

    var selected: VaultNote? { selection.flatMap { byId[$0] } }

    /// Sidebar grouping: notes by top-level folder, MOCs surfaced first.
    var sidebarGroups: [(folder: String, notes: [VaultNote])] {
        Dictionary(grouping: notes, by: \.topFolder)
            .map { ($0.key, $0.value.sorted { $0.title.lowercased() < $1.title.lowercased() }) }
            .sorted { $0.folder.lowercased() < $1.folder.lowercased() }
    }
    /// Library: most-connected first (matches the design).
    var libraryNotes: [VaultNote] { notes.sorted { $0.deg > $1.deg } }
    /// Hubs (for label mode + empty-search "most linked").
    var hubs: [VaultNote] { notes.sorted { $0.deg > $1.deg } }

    func bootstrap() async {
        showOnboarding = !UserDefaults.standard.bool(forKey: "cortex.onboarded")
        do {
            let h = try await api.healthInfo(); chunks = h.chunks; engineUp = true
        } catch { engineUp = false }
        await reload()
        startPolling()
        startWatching()
    }

    private var watcher: VaultWatcher?
    private func startWatching() {
        let vault = ("~/Claude" as NSString).expandingTildeInPath
        watcher = VaultWatcher(path: vault) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.poll()
                self.syncPulse &+= 1          // instant "Synced" feedback, even if no count changed
            }
        }
    }

    func reload() async {
        loading = true; defer { loading = false }
        do {
            let g = try await api.graph()
            applyGraph(g)
            engineUp = true; errorMessage = nil
            if let sem = try? await api.semanticEdges() { semanticEdges = sem }
            if let h = try? await api.healthInfo() { chunks = h.chunks }
        } catch {
            engineUp = false
            errorMessage = (error as? CortexError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func applyGraph(_ g: Graph) {
        var out: [String: Int] = [:], back: [String: Int] = [:]
        for e in g.edges { out[e.source, default: 0] += 1; back[e.target, default: 0] += 1 }
        let ns = g.nodes.map { VaultNote(node: $0, outLinks: out[$0.id] ?? 0, backLinks: back[$0.id] ?? 0) }
        graph = g; notes = ns
        byId = Dictionary(uniqueKeysWithValues: ns.map { ($0.id, $0) })
        lastGraphSig = graphSig(g)
    }

    private var lastGraphSig = ""
    private func graphSig(_ g: Graph) -> String {
        var h = Hasher(); h.combine(g.nodes.count)
        for e in g.edges { h.combine(e.source); h.combine(e.target) }
        return String(h.finalize())
    }

    /// Live refresh — re-fetch the cheap link graph and only republish when it
    /// actually changed (the engine's watcher re-embeds on save; this surfaces it
    /// in the constellation without a manual reload). Cheap enough to run on a timer.
    func poll() async {
        // refresh chunk count every cycle so a content-only edit (re-embed, no link
        // change) is still visibly reflected; only re-pull the graph when it changed.
        if let h = try? await api.healthInfo() { engineUp = true; if h.chunks != chunks { chunks = h.chunks } }
        guard let g = try? await api.graph() else { engineUp = false; return }
        engineUp = true
        guard graphSig(g) != lastGraphSig else { return }
        applyGraph(g)
        if let sem = try? await api.semanticEdges() { semanticEdges = sem }
    }

    private var polling = false
    private func startPolling() {
        guard !polling else { return }
        polling = true
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 3_000_000_000)   // backstop poll every 3s
                await poll()
            }
        }
    }

    func open(_ id: String) {
        selection = id; route = .reader; editing = false
        Task { await loadSelected() }
    }

    func loadSelected() async {
        editing = false; related = []
        guard let path = selection else { content = ""; return }
        loadingNote = true; defer { loadingNote = false }
        do {
            content = try await api.note(path).content
            if let r = try? await api.related(path) { related = r }
        } catch { content = ""; errorMessage = (error as? CortexError)?.errorDescription }
    }

    func beginEdit() { draft = content; editing = true }
    func cancelEdit() { editing = false }
    func save() async {
        guard let path = selection else { return }
        saving = true; defer { saving = false }
        do { try await api.write(path: path, content: draft); content = draft; editing = false }
        catch { errorMessage = (error as? CortexError)?.errorDescription }
    }

    // edges for the graph per current link mode
    func graphEdges() -> [GraphEdge] {
        switch linkMode {
        case .wiki: return graph?.edges ?? []
        case .semantic: return semanticEdges
        case .both: return (graph?.edges ?? []) + semanticEdges
        }
    }
    func colorHex(_ n: GraphNode) -> UInt32 {
        switch colorBy {
        case .domain: return DomainColor.hex(n.domain)
        case .status: return Maturity.hex(n.status)
        case .folder: return DomainColor.hex(n.folder?.split(separator: "/").first.map(String.init))
        }
    }
}
