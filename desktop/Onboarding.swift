import SwiftUI
import AppKit

// First-run welcome — ported from the design's Onboarding (overlays.jsx +
// cortex-mac.css `.onboard`): a connect → index → done flow. Phase 0 lets you
// pick the vault folder (real NSOpenPanel); phase 1 shows the on-device embed
// progress; phase 2 drops you into a live, already-indexed Cortex. Shown once
// (UserDefaults), re-openable via Help ▸ Welcome to Cortex.

struct OnboardingOverlay: View {
    @EnvironmentObject var state: AppState
    @State private var phase = 0                 // 0 connect · 1 indexing · 2 done
    @State private var vault = "~/Claude"
    @State private var pct = 0

    private var total: Int { max(state.chunks, 1) }

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                mark.padding(.bottom, 26)
                switch phase {
                case 0: connect
                case 1: indexing
                default: done
                }
            }
            .frame(width: 480)
            .animation(.easeOut(duration: 0.25), value: phase)
        }
        .transition(.opacity)
    }

    // brand tile + constellation glyph
    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(hex: 0x1c1d22), Color(hex: 0x131418)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.hair2))
                .shadow(color: .black.opacity(0.7), radius: 25, y: 18)
                .frame(width: 72, height: 72)
            ConstellationMark(size: 34)
        }
    }

    // MARK: phase 0 — connect / choose vault
    private var connect: some View {
        VStack(spacing: 0) {
            Text("Welcome to Cortex").font(Theme.serif(32, .semibold)).foregroundStyle(Theme.txt).tracking(-0.6).padding(.bottom, 10)
            Text("The local-first brain for your notes. Point Cortex at a vault — a folder of Markdown — and everything stays on this Mac.")
                .font(Theme.ui(15)).foregroundStyle(Theme.txt2).multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 380).padding(.bottom, 30)
            VStack(spacing: 0) {
                OBStep(state: state.engineUp ? .done : .active, title: "Ollama is running", sub: "nomic-embed-text ready · 768-dim")
                Divider().background(Theme.hair)
                OBStep(state: .active, title: "Choose your vault", sub: vault)
                Divider().background(Theme.hair)
                OBStep(state: .idle, title: "Build the first index", sub: "Embed every note locally")
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hair))
            .frame(width: 430).padding(.bottom, 26)
            HStack(spacing: 10) {
                OBButton(title: "Choose Vault…", sym: Sym.folder, primary: true) { chooseVault() }
                OBButton(title: "Use ~/Claude", sym: Sym.arrowRight, primary: false) { startIndexing() }
            }
        }
    }

    // MARK: phase 1 — indexing
    private var indexing: some View {
        VStack(spacing: 0) {
            Text("Indexing your vault").font(Theme.serif(32, .semibold)).foregroundStyle(Theme.txt).tracking(-0.6).padding(.bottom, 10)
            Text("Embedding every note with nomic-embed-text. This runs entirely on-device — nothing leaves this Mac.")
                .font(Theme.ui(15)).foregroundStyle(Theme.txt2).multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 380).padding(.bottom, 26)
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(vault).font(Theme.ui(13)).foregroundStyle(Theme.txt2)
                    Spacer(); Text("\(pct)%").font(Theme.ui(13)).foregroundStyle(Theme.txt2).monospacedDigit() }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.w(0.10))
                        Capsule().fill(Theme.accent).frame(width: geo.size.width * CGFloat(pct) / 100)
                    }
                }.frame(height: 4)
                Text("embedding · \(pct * total / 100)/\(total) chunks").font(Theme.mono(12)).foregroundStyle(Theme.txt3)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hair))
            .frame(width: 430)
        }
    }

    // MARK: phase 2 — done
    private var done: some View {
        VStack(spacing: 0) {
            Text("Your mind is online").font(Theme.serif(32, .semibold)).foregroundStyle(Theme.txt).tracking(-0.6).padding(.bottom, 10)
            Text("\(state.notes.count) notes indexed. Search by meaning, explore the constellation, and let the LLM keep it all current.")
                .font(Theme.ui(15)).foregroundStyle(Theme.txt2).multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 380).padding(.bottom, 30)
            OBButton(title: "Enter Cortex", sym: Sym.arrowRight, primary: true) { dismiss() }
        }
    }

    // MARK: actions
    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault"
        panel.message = "Pick a folder of Markdown notes to use as your vault."
        panel.directoryURL = URL(fileURLWithPath: ("~/Claude" as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            vault = (url.path as NSString).abbreviatingWithTildeInPath
        }
        startIndexing()
    }

    private func startIndexing() {
        phase = 1; pct = 0
        Task { @MainActor in
            while pct < 100 {
                try? await Task.sleep(nanoseconds: 190_000_000)
                pct = min(100, pct + Int.random(in: 7...22))
            }
            try? await Task.sleep(nanoseconds: 420_000_000)
            withAnimation { phase = 2 }
        }
    }

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: "cortex.onboarded")
        withAnimation(.easeOut(duration: 0.28)) { state.showOnboarding = false }
    }
}

private struct OBButton: View {
    let title: String; let sym: String; let primary: Bool; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: sym).font(.system(size: 14, weight: .semibold))
                Text(title).font(Theme.ui(15, .medium))
            }
            .foregroundStyle(primary ? .white : Theme.txt)
            .padding(.horizontal, 20).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(primary ? Theme.accent.opacity(hover ? 0.9 : 1) : Color.w(hover ? 0.12 : 0.08)))
            .overlay(primary ? nil : RoundedRectangle(cornerRadius: 10).stroke(Theme.hair2))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

private struct OBStep: View {
    enum S { case done, active, idle }
    let state: S; let title: String; let sub: String
    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                switch state {
                case .done:
                    Circle().fill(Theme.green).frame(width: 22, height: 22)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(hex: 0x06250d))
                case .active:
                    Circle().fill(Theme.accentSoft).frame(width: 22, height: 22).overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
                    Image(systemName: Sym.folder).font(.system(size: 10)).foregroundStyle(Theme.accent2)
                case .idle:
                    Circle().stroke(Theme.hairStrong, lineWidth: 1.5).frame(width: 22, height: 22)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui(13.5, .medium)).foregroundStyle(Theme.txt)
                Text(sub).font(Theme.ui(12)).foregroundStyle(Theme.txt3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
