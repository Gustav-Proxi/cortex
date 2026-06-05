import Foundation

// All OS-level automation for the all-in-one app: the engine (launchd watcher on
// :8788), Ollama + the embedding model, one-click MCP wiring, venv setup, indexing.
// The app is unsandboxed, so Process → launchctl/ollama/claude/codex works. PATH-
// dependent tools run through a login shell (`bash -lc`); fixed tools use absolute
// paths. Mirrors install.sh + launchd/cortex.watch.plist.template exactly.
enum Shell {
    static let model = "nomic-embed-text"
    static let label = "dev.cortex.watch"
    static var plistPath: String { ("~/Library/LaunchAgents/dev.cortex.watch.plist" as NSString).expandingTildeInPath }
    static func venvPython(_ repo: String) -> String { repo + "/.venv/bin/python" }
    static func venvExists(_ repo: String) -> Bool { FileManager.default.fileExists(atPath: venvPython(repo)) }

    struct Result { let ok: Bool; let out: String; let code: Int32 }

    /// Run a tool with absolute path, capturing stdout+stderr.
    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: String? = nil, env extra: [String: String] = [:]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                if !extra.isEmpty { var e = ProcessInfo.processInfo.environment; extra.forEach { e[$0] = $1 }; p.environment = e }
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: Result(ok: false, out: error.localizedDescription, code: -1)); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: Result(ok: p.terminationStatus == 0,
                                              out: String(data: data, encoding: .utf8) ?? "", code: p.terminationStatus))
            }
        }
    }

    /// Login shell — for PATH-dependent tools (ollama, claude, codex, brew). Uses the
    /// user's actual shell (their PATH for these tools lives in the zsh profile, not
    /// bash) and force-prepends the usual tool dirs so detection works even when the
    /// app is launched from Finder with a bare launchd environment.
    @discardableResult
    static func bash(_ script: String, cwd: String? = nil, env: [String: String] = [:]) async -> Result {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let prelude = #"export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"; "#
        return await run(shell, ["-lc", prelude + script], cwd: cwd, env: env)
    }

    // MARK: Ollama + model

    static func ollamaInstalled() async -> Bool { await bash("command -v ollama").ok }
    static func ollamaRunning() async -> Bool {
        await run("/usr/bin/curl", ["-fsS", "-m", "3", "http://127.0.0.1:11434/api/tags"]).ok
    }
    static func modelPresent() async -> Bool {
        let r = await run("/usr/bin/curl", ["-fsS", "-m", "3", "http://127.0.0.1:11434/api/tags"])
        return r.ok && r.out.contains(model)
    }
    static func installOllama() async -> Result {
        if (await bash("command -v brew").ok) { let r = await bash("brew install ollama"); if r.ok { return r } }
        return await bash("curl -fsSL https://ollama.com/install.sh | sh")   // official, non-interactive
    }
    static func startOllama() async -> Result {
        await bash("pgrep -x ollama >/dev/null 2>&1 || (nohup ollama serve >/tmp/ollama.log 2>&1 &); " +
                   "for i in $(seq 1 30); do curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1")
    }
    static func pullModel() async -> Result { await bash("ollama pull \(model)") }

    // MARK: engine (launchd watcher → :8788)

    static func engineUp() async -> Bool {
        await run("/usr/bin/curl", ["-fsS", "-m", "3", "http://127.0.0.1:8788/health"]).ok
    }
    static func setupVenv(_ repo: String) async -> Result {
        await bash("python3 -m venv \"\(repo)/.venv\" && \"\(repo)/.venv/bin/pip\" install --upgrade pip --quiet && " +
                   "\"\(repo)/.venv/bin/pip\" install -e \"\(repo)\"")
    }
    static func buildIndex(_ repo: String, vault: String) async -> Result {
        await run(venvPython(repo), ["-m", "cortex.index", "build"], cwd: repo, env: ["CORTEX_VAULT": vault])
    }
    static func renderPlist(repo: String, vault: String) async -> Result {
        let tmpl = "\(repo)/launchd/cortex.watch.plist.template"
        return await bash("sed -e 's#__VENV_PYTHON__#\(repo)/.venv/bin/python#' " +
                          "-e 's#__WORKDIR__#\(repo)#' -e 's#__VAULT__#\(vault)#' " +
                          "\"\(tmpl)\" > \"\(plistPath)\"")
    }
    static func startEngine(repo: String, vault: String) async -> Result {
        _ = await renderPlist(repo: repo, vault: vault)
        return await bash("launchctl load -w \"\(plistPath)\" 2>&1 || launchctl bootstrap gui/$(id -u) \"\(plistPath)\"")
    }
    static func stopEngine() async -> Result {
        await bash("launchctl unload -w \"\(plistPath)\" 2>&1 || launchctl bootout gui/$(id -u) \"\(plistPath)\"")
    }
    static func restartEngine(repo: String, vault: String) async -> Result {
        _ = await stopEngine()
        return await startEngine(repo: repo, vault: vault)
    }

    // MARK: one-click MCP wiring

    /// Claude Code — the CLI is the source of truth (writes ~/.claude.json).
    static func connectClaudeCode(repo: String, vault: String) async -> Result {
        _ = await bash("claude mcp remove cortex -s user >/dev/null 2>&1; true")     // idempotent
        return await bash("claude mcp add cortex -s user -e CORTEX_VAULT=\"\(vault)\" -- \"\(venvPython(repo))\" -m cortex.server")
    }

    /// Codex CLI — `codex mcp add` writes ~/.codex/config.toml [mcp_servers.cortex].
    static func connectCodex(repo: String, vault: String) async -> Result {
        _ = await bash("codex mcp remove cortex >/dev/null 2>&1; true")
        return await bash("codex mcp add cortex --env CORTEX_VAULT=\"\(vault)\" -- \"\(venvPython(repo))\" -m cortex.server")
    }

    /// Claude Desktop — no CLI; merge `cortex` into mcpServers in the config JSON.
    static func connectClaudeDesktop(repo: String, vault: String) -> Result {
        let path = ("~/Library/Application Support/Claude/claude_desktop_config.json" as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        var root: [String: Any] = [:]
        if let d = try? Data(contentsOf: url),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { root = j }
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers["cortex"] = ["command": venvPython(repo), "args": ["-m", "cortex.server"], "env": ["CORTEX_VAULT": vault]]
        root["mcpServers"] = servers
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: url)
            return Result(ok: true, out: "Wrote config — fully quit & reopen Claude Desktop.", code: 0)
        } catch { return Result(ok: false, out: error.localizedDescription, code: -1) }
    }

    // MARK: detect what's already wired (so the UI shows it instead of always "Connect")

    // Read the config files directly — instant, and `claude mcp list` would otherwise
    // network-health-check every server (~10s).
    static func claudeCodeConnected() -> Bool {
        let path = ("~/.claude.json" as NSString).expandingTildeInPath
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        if let s = j["mcpServers"] as? [String: Any], s["cortex"] != nil { return true }
        if let projects = j["projects"] as? [String: Any] {
            for (_, v) in projects {
                if let pv = v as? [String: Any], let s = pv["mcpServers"] as? [String: Any], s["cortex"] != nil { return true }
            }
        }
        return false
    }
    static func codexConnected() -> Bool {
        let toml = ("~/.codex/config.toml" as NSString).expandingTildeInPath
        return (try? String(contentsOfFile: toml, encoding: .utf8))?.contains("mcp_servers.cortex") ?? false
    }
    static func claudeDesktopConnected() -> Bool {
        let path = ("~/Library/Application Support/Claude/claude_desktop_config.json" as NSString).expandingTildeInPath
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let servers = j["mcpServers"] as? [String: Any] else { return false }
        return servers["cortex"] != nil
    }

    /// OpenAI has no one-click for a local stdio server — hand back the Agents-SDK snippet to copy.
    static func openAISnippet(repo: String, vault: String) -> String {
        """
        from agents import Agent, Runner
        from agents.mcp import MCPServerStdio

        async with MCPServerStdio(name="cortex", params={
            "command": "\(venvPython(repo))",
            "args": ["-m", "cortex.server"],
            "env": {"CORTEX_VAULT": "\(vault)"},
        }) as cortex:
            agent = Agent(name="Assistant", mcp_servers=[cortex],
                          instructions="Use Cortex to search and read the vault.")
            print((await Runner.run(agent, "What did I decide about baselines?")).final_output)
        """
    }
}
