// Cortex — native macOS app (SwiftUI + SpriteKit), client of the local engine on
// :8788. Graphite design system per mac/cortex-mac.css: monochrome chrome, colour
// only in the constellation + domain dots. Build with build.sh (system swiftc).
import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
            CommandGroup(replacing: .appInfo) {
                Button("About Cortex") { state.showAbout() }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { state.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {       // restores the File menu
                Button("Open Note…") { state.openNotePicker() }.keyboardShortcut("o", modifiers: .command)
                Button("Open Vault…") { state.showOnboarding = true }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Reveal Vault in Finder") { state.revealVault() }
            }
            CommandGroup(after: .toolbar) {
                Button("Search") { state.showSpotlight = true }.keyboardShortcut("k", modifiers: .command)
                Button("Constellation") { state.route = .graph }.keyboardShortcut("1", modifiers: .command)
                Button("Library") { state.route = .library }.keyboardShortcut("2", modifiers: .command)
                Button("Reload") { Task { await state.reload() } }.keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Cortex") { state.showOnboarding = true }
                Button("Cortex on GitHub") { state.openRepo() }
            }
        }

        Settings {                                   // App ▸ Settings… (⌘,) for free
            SettingsView().environmentObject(state).preferredColorScheme(.dark)
        }
    }
}

enum Route: Equatable { case graph, library, daily, reader }
struct HoverInfo: Equatable { let title: String; let path: String; let links: Int }
enum ColorBy: String, CaseIterable { case domain = "Domain", folder = "Folder", status = "Status", community = "Cluster" }
enum LinkMode: String, CaseIterable { case wiki = "Wiki", both = "Both", semantic = "Semantic" }
enum LabelMode: String, CaseIterable { case all = "All", hubs = "Hubs", off = "Off" }

@MainActor
final class AppState: ObservableObject {
    // canonical data (one /graph call → every note's metadata + link structure)
    @Published var graph: Graph?
    @Published var notes: [VaultNote] = []
    @Published var byId: [String: VaultNote] = [:]
    @Published var semanticEdges: [GraphEdge] = []
    @Published var externalNodes: [GraphNode] = []        // code/PDF files under indexed roots (graph-only, not the sidebar)
    @Published var externalEdges: [GraphEdge] = []        // their semantic links to the rest of the constellation
    @Published var communityOf: [String: Int] = [:]      // note id → cluster (for Color by Cluster)
    @Published var chunks = 0
    @Published var notesIndexed = 0
    @Published var loading = false
    @Published var engineUp = true
    @Published var errorMessage: String?

    // all-in-one control center (engine setup + MCP wiring)
    @Published var repoPath = UserDefaults.standard.string(forKey: "cortex.repoPath")
        ?? ("~/cortex" as NSString).expandingTildeInPath
    @Published var ollamaReady = false
    @Published var modelReady = false
    @Published var setupBusy = false
    @Published var setupStep = ""                       // live status while setting up
    @Published var mcpStatus: [String: String] = [:]    // client name → result line

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
            let h = try await api.healthInfo(); chunks = h.chunks; notesIndexed = h.notes; engineUp = true
        } catch { engineUp = false }
        await reload()
        startPolling()
        startWatching()
        checkForUpdates(silent: true)        // auto-check GitHub Releases on launch
        Task { await refreshSetupStatus() }
    }

    private var watcher: VaultWatcher?
    private func startWatching() {
        watcher = VaultWatcher(path: vaultPath) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.poll()
                self.syncPulse &+= 1          // instant "Synced" feedback, even if no count changed
            }
        }
    }

    // MARK: - menu actions

    var vaultPath: String { ("~/Claude" as NSString).expandingTildeInPath }

    func revealVault() { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: vaultPath) }
    func openRepo()    { NSWorkspace.shared.open(URL(string: "https://github.com/Gustav-Proxi/cortex")!) }

    /// File ▸ Open Note… — pick a `.md` inside the vault and open it in the reader.
    func openNotePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        panel.directoryURL = URL(fileURLWithPath: vaultPath); panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"
        if url.path.hasPrefix(root) { open(String(url.path.dropFirst(root.count))) }
        else { alert("Outside the vault", "That note isn't inside \(vaultPath), so the engine can't open it.") }
    }

    func showAbout() {
        let credits = NSAttributedString(
            string: "The local-first brain for your notes — a thin client of the local Cortex engine.\n\ngithub.com/Gustav-Proxi/cortex",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Cortex", .credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    func alert(_ title: String, _ msg: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = msg; a.addButton(withTitle: "OK"); a.runModal()
    }

    // MARK: - auto-update (GitHub Releases)

    @Published var checkingUpdate = false

    func checkForUpdates(silent: Bool = false) {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        Task { @MainActor in
            defer { checkingUpdate = false }
            guard let rel = await Updater.latest() else {
                if !silent { alert("Couldn't check for updates", "Couldn't reach GitHub — try again later.") }
                return
            }
            if Updater.isNewer(rel.version, than: Updater.current) {
                let a = NSAlert()
                a.messageText = "Update available — Cortex \(rel.version)"
                a.informativeText = "You have \(Updater.current). Download and install \(rel.version)? Cortex will relaunch."
                a.addButton(withTitle: "Install & Relaunch"); a.addButton(withTitle: "Later")
                if a.runModal() == .alertFirstButtonReturn {
                    do { try await Updater.install(rel) }
                    catch { alert("Update failed", error.localizedDescription) }
                }
            } else if !silent {
                alert("You're up to date", "Cortex \(Updater.current) is the latest version.")
            }
        }
    }

    // MARK: - all-in-one setup + MCP wiring

    func saveRepoPath(_ p: String) { repoPath = p; UserDefaults.standard.set(p, forKey: "cortex.repoPath") }

    func refreshSetupStatus() async {
        ollamaReady = await Shell.ollamaRunning()
        modelReady = ollamaReady ? (await Shell.modelPresent()) : false
        engineUp = await Shell.engineUp()
    }

    /// Hands-off setup — the no-terminal path: install/start Ollama, (opt-in) pull the
    /// model, build the venv, index the vault, start the engine watcher.
    func setupEverything(downloadModel: Bool) {
        guard !setupBusy else { return }
        setupBusy = true; setupStep = "Starting…"
        Task { @MainActor in
            defer { setupBusy = false; setupStep = "" }
            if !(await Shell.ollamaInstalled()) { setupStep = "Installing Ollama…"; _ = await Shell.installOllama() }
            setupStep = "Starting Ollama…"; _ = await Shell.startOllama(); ollamaReady = await Shell.ollamaRunning()
            if downloadModel {
                let present = await Shell.modelPresent()
                if !present { setupStep = "Downloading model (nomic-embed-text)…"; _ = await Shell.pullModel() }
            }
            modelReady = await Shell.modelPresent()
            if !Shell.venvExists(repoPath) { setupStep = "Setting up the engine…"; _ = await Shell.setupVenv(repoPath) }
            setupStep = "Building the index…"; _ = await Shell.buildIndex(repoPath, vault: vaultPath)
            setupStep = "Starting the engine…"; _ = await Shell.startEngine(repo: repoPath, vault: vaultPath)
            await refreshSetupStatus(); await reload()
        }
    }

    func startEngine() { runStep("Starting engine…") { _ = await Shell.startEngine(repo: self.repoPath, vault: self.vaultPath); await self.reload() } }
    func stopEngine()  { runStep("Stopping engine…")  { _ = await Shell.stopEngine() } }
    func downloadModel() {
        runStep("Downloading model…") { _ = await Shell.startOllama(); _ = await Shell.pullModel(); self.modelReady = await Shell.modelPresent() }
    }
    private func runStep(_ label: String, _ work: @escaping () async -> Void) {
        guard !setupBusy else { return }
        setupBusy = true; setupStep = label
        Task { @MainActor in defer { setupBusy = false; setupStep = "" }; await work(); await refreshSetupStatus() }
    }

    enum MCPClient: String, CaseIterable { case claudeCode = "Claude Code", claudeDesktop = "Claude Desktop", codex = "Codex" }
    func connect(_ c: MCPClient) {
        mcpStatus[c.rawValue] = "Connecting…"
        Task { @MainActor in
            let r: Shell.Result
            switch c {
            case .claudeCode:    r = await Shell.connectClaudeCode(repo: repoPath, vault: vaultPath)
            case .claudeDesktop: r = Shell.connectClaudeDesktop(repo: repoPath, vault: vaultPath)
            case .codex:         r = await Shell.connectCodex(repo: repoPath, vault: vaultPath)
            }
            let tail = r.out.split(separator: "\n").last.map(String.init) ?? "failed"
            mcpStatus[c.rawValue] = r.ok ? "✓ Connected" : "✕ " + String(tail.prefix(90))
        }
    }

    /// Detect which clients already have `cortex` wired, so the panel reflects reality.
    func detectConnections() async {
        if Shell.claudeCodeConnected()    { mcpStatus[MCPClient.claudeCode.rawValue] = "✓ Connected" }
        if Shell.claudeDesktopConnected() { mcpStatus[MCPClient.claudeDesktop.rawValue] = "✓ Connected" }
        if Shell.codexConnected()         { mcpStatus[MCPClient.codex.rawValue] = "✓ Connected" }
    }
    func copyOpenAISnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Shell.openAISnippet(repo: repoPath, vault: vaultPath), forType: .string)
        mcpStatus["OpenAI"] = "✓ Snippet copied"
    }

    func reload() async {
        loading = true; defer { loading = false }
        do {
            let g = try await api.graph()
            applyGraph(g)
            engineUp = true; errorMessage = nil
            if let sem = try? await api.semanticEdges() { semanticEdges = sem }
            if let ext = try? await api.externalGraph() { externalNodes = ext.nodes; externalEdges = ext.edges }
            if let cm = try? await api.communityMap() { communityOf = cm }
            if let h = try? await api.healthInfo() { chunks = h.chunks; notesIndexed = h.notes }
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
        stemIndex = Dictionary(ns.map { (Self.stem($0.path), $0.path) }, uniquingKeysWith: { a, _ in a })
        lastGraphSig = graphSig(g)
    }

    // wiki-link resolution for the reader — Obsidian-style, by basename/stem.
    private var stemIndex: [String: String] = [:]
    static func stem(_ path: String) -> String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "").lowercased()
    }
    func resolveWiki(_ target: String) -> String? { stemIndex[Self.stem(target)] }

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
        if let h = try? await api.healthInfo() { engineUp = true; if h.chunks != chunks { chunks = h.chunks }; notesIndexed = h.notes }
        guard let g = try? await api.graph() else { engineUp = false; return }
        engineUp = true
        guard graphSig(g) != lastGraphSig else { return }
        applyGraph(g)
        if let sem = try? await api.semanticEdges() { semanticEdges = sem }
        if let ext = try? await api.externalGraph() { externalNodes = ext.nodes; externalEdges = ext.edges }
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
        if n.external == true { return GraphCanvas.externalHex(n.type) }   // code/PDF: by kind, not COLOR BY
        switch colorBy {
        case .domain: return DomainColor.hex(n.domain)
        case .status: return Maturity.hex(n.status)
        case .folder: return DomainColor.hex(n.folder?.split(separator: "/").first.map(String.init))
        case .community: return GraphCanvas.communityHex(communityOf[n.id] ?? -1)
        }
    }
}
