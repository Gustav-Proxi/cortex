import SwiftUI
import AppKit

// Root layout — a custom graphite window: vibrant sidebar + main (toolbar + stage),
// with the ⌘K Spotlight overlaying everything. Mirrors mac/cortex-mac.css.

struct RootView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            HStack(spacing: 0) {
                Sidebar()
                VStack(spacing: 0) {
                    Toolbar()
                    ZStack {
                        switch state.route {
                        case .graph:   GraphContainer()
                        case .library: LibraryScreen()
                        case .reader:  ReaderScreen()
                        case .daily:   DailyStub()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if state.showSpotlight { Spotlight() }
            if state.showOnboarding { OnboardingOverlay().transition(.opacity).zIndex(10) }
        }
        .background(Theme.stage)
        .ignoresSafeArea()
        // instant refresh when you switch back to Cortex after editing notes elsewhere
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await state.poll() }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var state: AppState
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 52)          // traffic-light / drag strip
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    NavRow(icon: .constellation, label: "Constellation",
                           count: state.notes.count, active: state.route == .graph) { state.route = .graph }
                    NavRow(icon: .sf(Sym.library), label: "Library",
                           active: state.route == .library) { state.route = .library }
                    NavRow(icon: .sf(Sym.calendar), label: "Daily Notes",
                           active: state.route == .daily) { state.route = .daily }

                    ForEach(state.sidebarGroups, id: \.folder) { group in
                        SectionHeader(title: group.folder.uppercased(),
                                      collapsed: collapsed.contains(group.folder)) {
                            if collapsed.contains(group.folder) { collapsed.remove(group.folder) }
                            else { collapsed.insert(group.folder) }
                        }
                        if !collapsed.contains(group.folder) {
                            ForEach(group.notes) { n in NoteRow(note: n) }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            SidebarFooter()
        }
        .frame(width: 262)
        .background(Theme.sidebar)
        .overlay(Rectangle().frame(width: 0.5).foregroundStyle(Theme.hair), alignment: .trailing)
    }
}

private enum NavIcon { case constellation; case sf(String) }

private struct NavRow: View {
    let icon: NavIcon; let label: String; var count: Int? = nil
    var active: Bool; let action: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 9) {
            Group {
                switch icon {
                case .constellation: ConstellationMark(size: 16)
                case .sf(let s): Image(systemName: s).font(.system(size: 14))
                }
            }
            .frame(width: 16, height: 16)
            .foregroundStyle(active ? Theme.txt : Theme.txt2)
            Text(label).font(Theme.ui(13)).foregroundStyle(Theme.txt).lineLimit(1)
            Spacer(minLength: 0)
            if let c = count { Text("\(c)").font(Theme.ui(11)).foregroundStyle(Theme.txt3).monospacedDigit() }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.sel : (hover ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

private struct SectionHeader: View {
    let title: String; let collapsed: Bool; let toggle: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.4)
                .foregroundStyle(Theme.txt3)
            Spacer()
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.txt4).rotationEffect(.degrees(collapsed ? -90 : 0))
        }
        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
        .contentShape(Rectangle()).onTapGesture(perform: toggle)
    }
}

private struct NoteRow: View {
    let note: VaultNote
    @EnvironmentObject var state: AppState
    @State private var hover = false
    var sel: Bool { state.selection == note.id && state.route == .reader }
    var body: some View {
        HStack(spacing: 9) {
            Text(Maturity.glyph(note.status))
                .font(.system(size: 9))
                .foregroundStyle(DomainColor.color(note.domain))
                .shadow(color: DomainColor.color(note.domain).opacity(0.8), radius: 3)
                .frame(width: 12)
            Text(note.title).font(Theme.ui(13)).foregroundStyle(Theme.txt).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Theme.sel : (hover ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture { state.open(note.id) }
        .onHover { hover = $0 }
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(state.engineUp ? Theme.green : Color.orange)
                .frame(width: 7, height: 7)
                .shadow(color: (state.engineUp ? Theme.green : .orange).opacity(0.9), radius: 4)
            Text(state.engineUp ? "Engine running" : "Engine offline")
                .font(Theme.ui(11.5)).foregroundStyle(Theme.txt2)
            Spacer()
            Button { Task { await state.reload() } } label: {
                Image(systemName: Sym.refresh).font(.system(size: 12)).foregroundStyle(Theme.txt2)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).frame(height: 38)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.hair), alignment: .top)
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    @EnvironmentObject var state: AppState
    var title: String {
        switch state.route {
        case .graph: return "Constellation"
        case .library: return "Library"
        case .daily: return "Daily Notes"
        case .reader: return state.selected?.title ?? "Note"
        }
    }
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.serif(18, .semibold)).foregroundStyle(Theme.txt)
            Spacer()
            Seg(options: [("Graph", Sym.related), ("Library", Sym.library)],
                selected: state.route == .library ? "Library" : "Graph") { pick in
                state.route = (pick == "Library") ? .library : .graph
            }
            if state.route == .reader {
                TBButton(sym: state.editing ? Sym.check : Sym.pencil) {
                    if state.editing { Task { await state.save() } } else { state.beginEdit() }
                }
                if state.editing { TBButton(sym: Sym.close) { state.cancelEdit() } }
            }
            SearchField()
            TBButton(sym: Sym.refresh) { Task { await state.reload() } }
        }
        .padding(.leading, 18).padding(.trailing, 14)
        .frame(height: 52)
        .background(Theme.toolbar)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.hair), alignment: .bottom)
    }
}

private struct TBButton: View {
    let sym: String; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: sym).font(.system(size: 14)).foregroundStyle(Theme.txt2)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.hover : .clear))
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

private struct SearchField: View {
    @EnvironmentObject var state: AppState
    @State private var hover = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Sym.search).font(.system(size: 12)).foregroundStyle(Theme.txt3)
            Text("Search your mind…").font(Theme.ui(12.5)).foregroundStyle(Theme.txt3)
            Spacer(minLength: 0)
            Text("⌘K").font(Theme.ui(11)).foregroundStyle(Theme.txt3)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hair2))
        }
        .padding(.horizontal, 9).frame(width: 190, height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.w(hover ? 0.08 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hair2))
        .contentShape(Rectangle())
        .onTapGesture { state.showSpotlight = true }
        .onHover { hover = $0 }
    }
}

/// Graphite segmented control (matches .seg).
struct Seg: View {
    let options: [(String, String?)]      // label, optional SF symbol
    let selected: String
    let onPick: (String) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { opt in
                HStack(spacing: 6) {
                    if let s = opt.1 { Image(systemName: s).font(.system(size: 11)) }
                    Text(opt.0).font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(opt.0 == selected ? .white : Theme.txt2)
                .padding(.horizontal, 11).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(opt.0 == selected ? Color(white: 0.48, opacity: 0.55) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { onPick(opt.0) }
            }
        }
        .padding(2).background(RoundedRectangle(cornerRadius: 7).fill(Color.w(0.06)))
    }
}

// MARK: - Reader (+ inspector)

private struct ReaderScreen: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let n = state.selected {
                        HStack(spacing: 8) {
                            Circle().fill(DomainColor.color(n.domain)).frame(width: 7, height: 7)
                                .shadow(color: DomainColor.color(n.domain).opacity(0.8), radius: 4)
                            Text(n.path).font(Theme.mono(12)).foregroundStyle(Theme.txt3)
                        }.padding(.bottom, 16)
                        Text(n.title).font(Theme.serif(34, .semibold)).foregroundStyle(Theme.txt)
                            .padding(.bottom, 6)
                        HStack(spacing: 14) {
                            Text(Maturity.label(n.type ?? "note")).foregroundStyle(Theme.txt3)
                            Label { Text(Maturity.label(n.status)) } icon: {
                                Text(Maturity.glyph(n.status)).foregroundStyle(DomainColor.color(n.domain))
                            }
                            Text("\(n.outLinks) links").foregroundStyle(Theme.txt3)
                            Text("\(n.backLinks) backlinks").foregroundStyle(Theme.txt3)
                        }.font(Theme.ui(13)).padding(.bottom, 30)

                        if state.editing {
                            MarkdownEditor(text: $state.draft)
                                .frame(minHeight: 480)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hair))
                        } else {
                            Prose(text: state.content)
                        }
                    } else {
                        Text("Select a note").foregroundStyle(Theme.txt3).padding(40)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 48).padding(.top, 56).padding(.bottom, 120)
            }
            if state.selected != nil { Inspector() }
        }
        .background(Theme.stage)
        .overlay { if state.loadingNote { ProgressView().controlSize(.small) } }
    }
}

private struct Inspector: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let n = state.selected {
                    InspSection(title: "LOCAL GRAPH") {
                        MiniGraphView(noteId: n.id)
                            .frame(height: 190).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.w(0.02)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hair))
                    }
                    InspSection(title: "PROPERTIES") {
                        Prop(k: "Type", v: Maturity.label(n.type ?? "note"))
                        Prop(k: "Status", v: Maturity.label(n.status), dot: DomainColor.color(n.domain))
                        Prop(k: "Domain", v: (n.domain?.capitalized ?? "—"), dot: DomainColor.color(n.domain))
                        Prop(k: "Links", v: "\(n.outLinks) out · \(n.backLinks) in")
                    }
                    if !state.related.isEmpty {
                        InspSection(title: "RELATED · SEMANTIC") {
                            ForEach(state.related.prefix(6)) { r in
                                LinkRow(path: r.path, score: r.score) { state.open(r.path) }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 300)
        .background(Color.w(0.012))
        .overlay(Rectangle().frame(width: 0.5).foregroundStyle(Theme.hair), alignment: .leading)
    }
}

private struct InspSection<C: View>: View {
    let title: String; @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Theme.txt3)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.hair), alignment: .bottom)
    }
}

private struct Prop: View {
    let k: String; let v: String; var dot: Color? = nil
    var body: some View {
        HStack {
            Text(k).foregroundStyle(Theme.txt3)
            Spacer()
            HStack(spacing: 6) {
                if let d = dot { Circle().fill(d).frame(width: 7, height: 7).shadow(color: d.opacity(0.8), radius: 3) }
                Text(v).foregroundStyle(Theme.txt)
            }
        }.font(Theme.ui(12.5)).frame(height: 26)
    }
}

private struct LinkRow: View {
    let path: String; let score: Double; let action: () -> Void
    @State private var hover = false
    var title: String { (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "") }
    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(Theme.txt3).frame(width: 6, height: 6)
            Text(title).font(Theme.ui(13)).foregroundStyle(Theme.txt).lineLimit(1)
            Spacer(minLength: 4)
            ProgressView(value: min(max(score, 0), 1)).frame(width: 42).tint(Color.w(0.5))
        }
        .padding(.horizontal, 8).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.hover : .clear))
        .contentShape(Rectangle()).onTapGesture(perform: action).onHover { hover = $0 }
    }
}

// MARK: - Library

private struct LibraryScreen: View {
    @EnvironmentObject var state: AppState
    let cols = [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 14)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Text("Library").font(Theme.serif(24, .semibold)).foregroundStyle(Theme.txt)
                    Text("\(state.notes.count) notes").font(Theme.ui(13)).foregroundStyle(Theme.txt3)
                }.padding(.bottom, 22)
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(state.libraryNotes) { n in NoteCard(note: n) }
                }
            }
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 60)
        }
        .background(Theme.stage)
    }
}

private struct NoteCard: View {
    let note: VaultNote
    @EnvironmentObject var state: AppState
    @State private var hover = false
    var c: Color { DomainColor.color(note.domain) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(c).frame(width: 8, height: 8).shadow(color: c.opacity(0.8), radius: 4)
                Text(note.folder).font(Theme.mono(11)).foregroundStyle(Theme.txt3).lineLimit(1)
                Spacer()
                Text(Maturity.glyph(note.status)).font(.system(size: 11)).foregroundStyle(c)
            }.padding(.bottom, 11)
            Text(note.title).font(Theme.serif(17, .semibold)).foregroundStyle(Theme.txt)
                .lineLimit(2).padding(.bottom, 7)
            Spacer(minLength: 8)
            HStack(spacing: 14) {
                Label("\(note.outLinks)", systemImage: Sym.link)
                Label("\(note.backLinks)", systemImage: Sym.back)
                Spacer()
                Text(Maturity.label(note.status))
            }.font(Theme.ui(11)).foregroundStyle(Theme.txt3)
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
        .frame(minHeight: 130, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Theme.panel2 : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(hover ? Theme.hairStrong : Theme.hair))
        .overlay(HStack { Rectangle().fill(c).frame(width: 3); Spacer() }.clipShape(RoundedRectangle(cornerRadius: 12)))
        .offset(y: hover ? -2 : 0)
        .contentShape(Rectangle())
        .onTapGesture { state.open(note.id) }
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
    }
}

private struct DailyStub: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: Sym.calendar).font(.system(size: 34)).foregroundStyle(Theme.txt3)
            Text("Daily Notes").font(Theme.serif(20)).foregroundStyle(Theme.txt)
            Text("Timeline + calendar — coming next").font(Theme.ui(12)).foregroundStyle(Theme.txt3)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.stage)
    }
}

// MARK: - Prose (serif markdown reader)

struct Prose: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks().enumerated()), id: \.offset) { item in item.element.view }
        }
    }
    private enum B { case h2(String), h3(String), code(String), bullet(String), para(String)
        @ViewBuilder var view: some View {
            switch self {
            case .h2(let s): Text(ProseInline.attr(s)).font(Theme.serif(21, .semibold)).foregroundStyle(Theme.txt).padding(.top, 18)
            case .h3(let s): Text(ProseInline.attr(s)).font(Theme.serif(17, .semibold)).foregroundStyle(Theme.txt).padding(.top, 10)
            case .code(let s): Text(s).font(Theme.mono(13)).foregroundStyle(Color(hex: 0xc8ccd4)).textSelection(.enabled)
                    .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hair))
            case .bullet(let s): HStack(alignment: .top, spacing: 10) {
                    Text("•").foregroundStyle(Theme.txt3); Text(ProseInline.attr(s)).foregroundStyle(Color.w(0.84))
                }.font(Theme.serif(17, .regular)).lineSpacing(5)
            case .para(let s): Text(ProseInline.attr(s)).font(Theme.serif(17, .regular)).foregroundStyle(Color.w(0.84))
                    .lineSpacing(5).textSelection(.enabled)
            }
        }
    }
    private func blocks() -> [B] {
        var out: [B] = []; let lines = text.components(separatedBy: "\n"); var i = 0; var para = ""
        func flush() { if !para.isEmpty { out.append(.para(para)); para = "" } }
        while i < lines.count {
            let ln = lines[i]
            if ln.hasPrefix("```") { flush(); var code = ""; i += 1
                while i < lines.count, !lines[i].hasPrefix("```") { code += lines[i] + "\n"; i += 1 }
                out.append(.code(code.trimmingCharacters(in: .newlines))); i += 1; continue }
            if ln.hasPrefix("# ") || ln.hasPrefix("## ") { flush(); out.append(.h2(strip(ln))) }
            else if ln.hasPrefix("### ") || ln.hasPrefix("#### ") { flush(); out.append(.h3(strip(ln))) }
            else if ln.hasPrefix("- ") || ln.hasPrefix("* ") { flush(); out.append(.bullet(String(ln.dropFirst(2)))) }
            else if ln.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else { para += (para.isEmpty ? "" : " ") + ln }
            i += 1
        }
        flush(); return out
    }
    private func strip(_ l: String) -> String { String(l.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
}

enum ProseInline {
    static func attr(_ s: String) -> AttributedString {
        let cleaned = s.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        if let a = try? AttributedString(markdown: cleaned,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return a }
        return AttributedString(cleaned)
    }
}

// MARK: - Spotlight (⌘K)

enum SpotMode: String, CaseIterable { case semantic = "Semantic", hybrid = "Hybrid", ask = "Ask" }

struct Spotlight: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var mode: SpotMode = .hybrid
    @State private var hits: [SearchHit] = []
    @State private var sel = 0
    @State private var busy = false
    @State private var asking = false
    @State private var askResult: CortexAPI.AskResult?
    @FocusState private var focused: Bool

    var rows: [SearchHit] { query.isEmpty ? [] : hits }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.42).ignoresSafeArea()
                .onTapGesture { state.showSpotlight = false }
            VStack(spacing: 0) {
                // field
                HStack(spacing: 12) {
                    Image(systemName: Sym.search).font(.system(size: 18)).foregroundStyle(Theme.txt3)
                    TextField(mode == .ask ? "Ask your vault anything…" : "Search your mind…", text: $query)
                        .textFieldStyle(.plain).font(Theme.ui(19)).foregroundStyle(Theme.txt)
                        .focused($focused)
                        .onSubmit { if mode == .ask { runAsk() } else { open(sel) } }
                    HStack(spacing: 6) {
                        ForEach(SpotMode.allCases, id: \.self) { m in
                            Text(m == .ask ? "Ask ✦" : m.rawValue)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(m == mode ? (m == .ask ? Theme.accent2 : Theme.txt) : Theme.txt2)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(m == mode ? (m == .ask ? Theme.accentSoft : Theme.selStrong) : Color.w(0.06)))
                                .onTapGesture { mode = m; askResult = nil; if m != .ask { runSearch() } }
                        }
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.hair), alignment: .bottom)

                // results
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if mode == .ask { askCard }
                        let header = mode == .ask ? (askResult?.sources?.isEmpty == false ? "SOURCES & MATCHES" : "")
                                                  : (query.isEmpty ? "MOST LINKED" : "RESULTS")
                        if !header.isEmpty {
                            Text(header).font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                                .foregroundStyle(Theme.txt3).padding(EdgeInsets(top: 8, leading: 12, bottom: 5, trailing: 12))
                        }
                        if mode == .ask {
                            ForEach(Array((askResult?.sources ?? []).enumerated()), id: \.offset) { item in
                                SpotRow(title: (item.element.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""),
                                        path: item.element.path, snip: item.element.text, score: item.element.score,
                                        domain: state.byId[item.element.path]?.domain, selected: false)
                                    .onTapGesture { state.open(item.element.path); state.showSpotlight = false }
                            }
                        } else if query.isEmpty {
                            ForEach(Array(state.hubs.prefix(6).enumerated()), id: \.offset) { item in
                                SpotRow(title: item.element.title, path: item.element.path,
                                        snip: nil, score: nil, domain: item.element.domain, selected: item.offset == sel)
                                    .onTapGesture { state.open(item.element.id); state.showSpotlight = false }
                            }
                        } else {
                            ForEach(Array(rows.enumerated()), id: \.offset) { item in
                                SpotRow(title: (item.element.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""),
                                        path: item.element.path, snip: item.element.text, score: item.element.score,
                                        domain: state.byId[item.element.path]?.domain, selected: item.offset == sel)
                                    .onTapGesture { open(item.offset) }
                            }
                        }
                    }.padding(8)
                }
                .frame(maxHeight: 380)

                // footer
                HStack(spacing: 16) {
                    Text("↵ open").foregroundStyle(Theme.txt3)
                    Text("⇥ switch mode").foregroundStyle(Theme.txt3)
                    Text("esc close").foregroundStyle(Theme.txt3)
                    Spacer()
                    Text("\(state.chunks) chunks indexed").foregroundStyle(Theme.txt3).monospacedDigit()
                }
                .font(Theme.ui(11)).padding(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.hair), alignment: .top)
            }
            .frame(width: 660)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.glass))
            .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairStrong))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
            .padding(.top, 96)
        }
        .onExitCommand { state.showSpotlight = false }
        .onAppear { focused = true }
        .onChange(of: query) { _ in sel = 0; if mode == .ask { askResult = nil } else { runSearch() } }
    }

    @ViewBuilder private var askCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if asking {
                HStack(spacing: 9) { ProgressView().controlSize(.small)
                    Text("Thinking…").font(Theme.ui(13)).foregroundStyle(Theme.txt3) }
            } else if let r = askResult {
                if let err = r.error, r.answer == nil {
                    Text(err).font(Theme.ui(13)).foregroundStyle(Theme.txt3)
                } else if let a = r.answer {
                    Text(ProseInline.attr(a)).font(Theme.serif(15.5, .regular))
                        .foregroundStyle(Color.w(0.88)).lineSpacing(4)
                    if let m = r.model {
                        HStack(spacing: 6) { Image(systemName: Sym.cpu).font(.system(size: 11))
                            Text(m).font(Theme.ui(11)) }.foregroundStyle(Theme.txt3)
                    }
                }
            } else {
                Text("Press ↵ to ask your vault — grounded in your notes, answered on your Claude subscription.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.txt3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.w(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hair))
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 10, trailing: 8))
    }

    private func runAsk() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        asking = true; askResult = nil
        Task {
            defer { asking = false }
            askResult = try? await state.client().ask(q)
        }
    }

    private func open(_ i: Int) {
        if query.isEmpty { let h = Array(state.hubs.prefix(6)); if i < h.count { state.open(h[i].id) } }
        else if i < rows.count { state.open(rows[i].path) }
        state.showSpotlight = false
    }
    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { hits = []; return }
        busy = true
        Task {
            defer { busy = false }
            hits = (try? await state.client().search(q, hybrid: mode != .semantic)) ?? []
        }
    }
}

private struct SpotRow: View {
    let title: String; let path: String; let snip: String?; let score: Double?
    let domain: String?; let selected: Bool
    var body: some View {
        HStack(spacing: 11) {
            Circle().fill(DomainColor.color(domain)).frame(width: 8, height: 8)
                .shadow(color: DomainColor.color(domain).opacity(0.8), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(Theme.ui(14)).foregroundStyle(Theme.txt)
                    Text((path as NSString).deletingLastPathComponent).font(Theme.mono(11)).foregroundStyle(Theme.txt3)
                }
                if let s = snip, !s.isEmpty {
                    Text(s).font(Theme.ui(12)).foregroundStyle(Theme.txt2).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let sc = score { Text(String(format: "%.2f", sc)).font(Theme.mono(11)).foregroundStyle(Theme.txt3) }
            if selected { Text("↵").font(Theme.ui(11)).foregroundStyle(Theme.txt3)
                .padding(.horizontal, 6).overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hair2)) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.sel : .clear))
        .contentShape(Rectangle())
    }
}
