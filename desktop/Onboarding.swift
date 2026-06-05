import SwiftUI
import AppKit

// First-run welcome — the no-terminal setup. Phase 0 shows real readiness (Ollama,
// model, engine) and a single "Set up Cortex" that runs the actual pipeline
// (install/start Ollama → opt-in model download → build the engine → index the vault
// → start it); phase 1 shows live progress as each step turns green; phase 2 enters.
// Shown once (UserDefaults); re-openable via Help ▸ Welcome to Cortex.

struct OnboardingOverlay: View {
    @EnvironmentObject var state: AppState
    @State private var phase = 0                 // 0 welcome · 1 setting up · 2 done
    @State private var downloadModel = true

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            VStack(spacing: 0) {
                mark.padding(.bottom, 26)
                switch phase {
                case 0:  welcome
                case 1:  settingUp
                default: done
                }
            }
            .frame(width: 480)
            .animation(.easeOut(duration: 0.25), value: phase)
        }
        .transition(.opacity)
        .task { await state.refreshSetupStatus() }
        .onChange(of: state.setupBusy) { busy in       // setup finished → done (or back to retry)
            if !busy && phase == 1 { withAnimation { phase = state.engineUp ? 2 : 0 } }
        }
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

    // live readiness card — dots turn green as each step completes
    private func step(_ ready: Bool, _ title: String, _ sub: String) -> OBStep {
        OBStep(state: ready ? .done : (state.setupBusy ? .active : .idle), title: title, sub: sub)
    }
    private var statusCard: some View {
        VStack(spacing: 0) {
            step(state.ollamaReady, "Ollama", state.ollamaReady ? "running" : "will install & start")
            Divider().background(Theme.hair)
            step(state.modelReady, "Embedding model · nomic-embed-text", state.modelReady ? "ready · 768-dim" : "downloads on-device (~275 MB)")
            Divider().background(Theme.hair)
            step(state.engineUp, "Engine + index", state.engineUp ? "\(state.notesIndexed) notes · \(state.chunks) chunks" : tilde(state.vaultPath))
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hair))
        .frame(width: 430)
    }

    // MARK: phase 0 — welcome
    private var welcome: some View {
        VStack(spacing: 0) {
            Text("Welcome to Cortex").font(Theme.serif(32, .semibold)).foregroundStyle(Theme.txt).tracking(-0.6).padding(.bottom, 10)
            Text("The local-first brain for your notes — everything stays on this Mac. Set it up once, no terminal.")
                .font(Theme.ui(15)).foregroundStyle(Theme.txt2).multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 390).padding(.bottom, 24)
            statusCard.padding(.bottom, 16)
            if state.engineUp {
                OBButton(title: "Enter Cortex", sym: Sym.arrowRight, primary: true) { dismiss() }
            } else {
                Toggle(isOn: $downloadModel) {
                    Text("Download the model if missing (nomic-embed-text, ~275 MB)")
                        .font(Theme.ui(12)).foregroundStyle(Theme.txt2)
                }.toggleStyle(.checkbox).padding(.bottom, 18)
                OBButton(title: "Set up Cortex", sym: Sym.sparkle, primary: true) {
                    phase = 1; state.setupEverything(downloadModel: downloadModel)
                }
                Button("Enter anyway") { dismiss() }
                    .buttonStyle(.plain).font(Theme.ui(12)).foregroundStyle(Theme.txt3).padding(.top, 12)
            }
        }
    }

    // MARK: phase 1 — setting up (real)
    private var settingUp: some View {
        VStack(spacing: 0) {
            Text("Setting up Cortex").font(Theme.serif(32, .semibold)).foregroundStyle(Theme.txt).tracking(-0.6).padding(.bottom, 10)
            Text("Installing the engine and embedding your vault on-device. The first run can take a few minutes.")
                .font(Theme.ui(15)).foregroundStyle(Theme.txt2).multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 390).padding(.bottom, 24)
            statusCard.padding(.bottom, 18)
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(state.setupStep.isEmpty ? "Working…" : state.setupStep)
                    .font(Theme.ui(13)).foregroundStyle(Theme.txt2).lineLimit(1)
            }
        }
    }

    // MARK: phase 2 — done
    private var done: some View {
        VStack(spacing: 0) {
            Text("Your mind is online").font(Theme.serif(32, .semibold)).foregroundStyle(Theme.txt).tracking(-0.6).padding(.bottom, 10)
            Text("\(state.notesIndexed) notes indexed. Search by meaning, explore the constellation, and let the LLM keep it current.")
                .font(Theme.ui(15)).foregroundStyle(Theme.txt2).multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 390).padding(.bottom, 30)
            OBButton(title: "Enter Cortex", sym: Sym.arrowRight, primary: true) { dismiss() }
        }
    }

    private func tilde(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
    private func dismiss() {
        UserDefaults.standard.set(true, forKey: "cortex.onboarded")
        withAnimation(.easeOut(duration: 0.28)) { state.showOnboarding = false }
    }
}

struct OBButton: View {
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
                    ProgressView().controlSize(.small).scaleEffect(0.55)
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
