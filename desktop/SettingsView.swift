import SwiftUI
import AppKit

// The all-in-one control center (App ▸ Settings…, ⌘,). Everything the README's
// `install.sh` + manual MCP config used to require, in one window: a no-terminal
// "Set up everything" path, engine start/stop, opt-in model download, and one-click
// MCP wiring for Claude Code / Claude Desktop / Codex (+ an OpenAI snippet).
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var downloadModel = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                InspSection(title: "SETUP — NO TERMINAL") { setupBody }
                InspSection(title: "ENGINE") { engineBody }
                InspSection(title: "CONNECT AN ASSISTANT") { connectBody }
                InspSection(title: "VAULT & ENGINE") { pathsBody }
                InspSection(title: "PORTS") { portsBody }
                InspSection(title: "ABOUT") { aboutBody }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 18)
        }
        .frame(width: 560, height: 660)
        .background(Theme.stage)
        .task { await state.refreshSetupStatus(); await state.detectConnections() }
    }

    // MARK: header
    private var header: some View {
        HStack(spacing: 12) {
            ConstellationMark(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Cortex").font(Theme.serif(20, .semibold)).foregroundStyle(Theme.txt)
                Text("v\(Updater.current) · all-in-one").font(Theme.ui(11.5)).foregroundStyle(Theme.txt3)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(state.engineUp ? Theme.green : Color.orange).frame(width: 8, height: 8)
                    .shadow(color: (state.engineUp ? Theme.green : .orange).opacity(0.8), radius: 4)
                Text(state.engineUp ? "Engine running" : "Engine offline").font(Theme.ui(12)).foregroundStyle(Theme.txt2)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 16, trailing: 20))
    }

    // MARK: setup
    private var setupBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusRow(title: "Ollama", ok: state.ollamaReady, detail: state.ollamaReady ? "running" : "not running")
            StatusRow(title: "Embedding model · nomic-embed-text", ok: state.modelReady, detail: state.modelReady ? "ready" : "missing")
            StatusRow(title: "Engine · cortex.watch", ok: state.engineUp, detail: state.engineUp ? "\(state.notesIndexed) notes · \(state.chunks) chunks" : "offline")
            Toggle(isOn: $downloadModel) {
                Text("Download the model if missing (nomic-embed-text, ~275 MB)").font(Theme.ui(12)).foregroundStyle(Theme.txt2)
            }.toggleStyle(.checkbox).padding(.top, 2)
            HStack(spacing: 10) {
                OBButton(title: state.setupBusy ? "Setting up…" : "Set up everything", sym: Sym.sparkle, primary: true) {
                    state.setupEverything(downloadModel: downloadModel)
                }
                if state.setupBusy {
                    ProgressView().controlSize(.small)
                    Text(state.setupStep).font(Theme.ui(12)).foregroundStyle(Theme.txt3).lineLimit(1)
                }
            }
            .padding(.top, 2)
            Text("Installs/starts Ollama, builds the engine, indexes your vault, and starts it — no terminal.")
                .font(Theme.ui(11)).foregroundStyle(Theme.txt3)
        }
    }

    // MARK: engine
    private var engineBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Prop(k: "Status", v: state.engineUp ? "Running" : "Offline", dot: state.engineUp ? Theme.green : .orange)
            Prop(k: "Indexed", v: "\(state.notesIndexed) notes · \(state.chunks) chunks")
            HStack(spacing: 10) {
                MiniButton(title: "Start", sym: "play.fill") { state.startEngine() }.disabled(state.engineUp)
                MiniButton(title: "Stop", sym: "stop.fill") { state.stopEngine() }.disabled(!state.engineUp)
                MiniButton(title: "Download model", sym: "arrow.down.circle") { state.downloadModel() }.disabled(state.setupBusy)
                Spacer()
            }.padding(.top, 2)
        }
    }

    // MARK: connect (MCP)
    private var connectBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AppState.MCPClient.allCases, id: \.self) { c in
                let st = state.mcpStatus[c.rawValue]
                ConnectRow(title: c.rawValue, status: st,
                           actionLabel: (st?.hasPrefix("✓") == true) ? "Reconnect" : "Connect") { state.connect(c) }
            }
            ConnectRow(title: "OpenAI (Agents SDK / Codex)", status: state.mcpStatus["OpenAI"], actionLabel: "Copy code") {
                state.copyOpenAISnippet()
            }
            Text("One click writes each client's MCP config. Restart Claude Desktop after connecting. Hosted ChatGPT needs a public HTTPS tunnel — local stdio can't be reached.")
                .font(Theme.ui(11)).foregroundStyle(Theme.txt3).padding(.top, 2)
        }
    }

    // MARK: paths
    private var pathsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Prop(k: "Vault", v: tilde(state.vaultPath)); MiniButton(title: "Reveal", sym: Sym.folder) { state.revealVault() } }
            HStack { Prop(k: "Repo", v: tilde(state.repoPath)); MiniButton(title: "Change…", sym: Sym.folder) { pickRepo() } }
            Text("The repo holds the engine (\(".venv/bin/python")) used to launch the MCP server and the watcher.")
                .font(Theme.ui(11)).foregroundStyle(Theme.txt3)
        }
    }

    // MARK: ports / about
    private var portsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Prop(k: "Engine API", v: "127.0.0.1:8788")
            Prop(k: "Ollama", v: "127.0.0.1:11434")
        }
    }
    private var aboutBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Prop(k: "Version", v: Updater.current)
            HStack(spacing: 10) {
                MiniButton(title: "Check for Updates", sym: Sym.refresh) { state.checkForUpdates() }
                MiniButton(title: "Cortex on GitHub", sym: "arrow.up.right") { state.openRepo() }
                Spacer()
            }.padding(.top, 2)
        }
    }

    private func tilde(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
    private func pickRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Use as Repo"
        panel.directoryURL = URL(fileURLWithPath: state.repoPath)
        if panel.runModal() == .OK, let url = panel.url { state.saveRepoPath(url.path) }
    }
}

// MARK: - small components

private struct StatusRow: View {
    let title: String; let ok: Bool; let detail: String
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(ok ? Theme.green : Color.orange).frame(width: 8, height: 8)
                .shadow(color: (ok ? Theme.green : .orange).opacity(0.8), radius: 3)
            Text(title).font(Theme.ui(12.5)).foregroundStyle(Theme.txt).lineLimit(1)
            Spacer(minLength: 8)
            Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.txt3)
        }.frame(height: 24)
    }
}

private struct ConnectRow: View {
    let title: String; let status: String?; var actionLabel = "Connect"; let action: () -> Void
    var statusColor: Color {
        guard let s = status else { return Theme.txt3 }
        return s.hasPrefix("✓") ? Theme.green : (s.hasPrefix("✕") ? .orange : Theme.txt3)
    }
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.ui(13)).foregroundStyle(Theme.txt)
            Spacer(minLength: 8)
            if let s = status { Text(s).font(Theme.ui(11.5)).foregroundStyle(statusColor).lineLimit(1) }
            MiniButton(title: actionLabel, sym: Sym.link, primary: true, action: action)
        }.frame(height: 30)
    }
}

private struct MiniButton: View {
    let title: String; var sym: String? = nil; var primary = false; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let sym { Image(systemName: sym).font(.system(size: 10.5)) }
                Text(title).font(Theme.ui(12, .medium))
            }
            .foregroundStyle(primary ? .white : Theme.txt)
            .padding(.horizontal, 11).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(primary ? Theme.accent.opacity(hover ? 0.9 : 1) : Color.w(hover ? 0.12 : 0.08)))
            .overlay(primary ? nil : RoundedRectangle(cornerRadius: 7).stroke(Theme.hair2))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}
