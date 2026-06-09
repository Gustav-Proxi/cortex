// Native client for the Cortex engine's loopback JSON API (127.0.0.1:8788).
// The engine (Python, launchd-managed) owns embeddings, search, and vault CRUD;
// this app is a pure client — no business logic, just typed calls + models.
import Foundation

// MARK: - Models (shapes mirror cortex/http_api.py exactly)

/// A note as it appears in the library: the engine returns bare vault-relative paths.
struct NoteRef: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var title: String { (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "") }
    var folder: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "—" : dir
    }
}

struct NoteContent: Decodable { let path: String; let content: String }

struct GraphNode: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let folder: String?
    let type: String?
    let status: String?
    let domain: String?
}
struct GraphEdge: Decodable, Hashable { let source: String; let target: String }
struct Graph: Decodable { let nodes: [GraphNode]; let edges: [GraphEdge] }

struct SearchHit: Decodable, Identifiable, Hashable {
    let path: String
    let heading: String?
    let text: String
    let score: Double
    var id: String { path + "#" + (heading ?? "") }
}

struct SemanticGraph: Decodable { let edges: [GraphEdge] }

// A note enriched with graph metadata + link degree — the canonical model behind
// the sidebar, library, reader kicker, and inspector. Built from /graph (one call
// gives every note's folder/type/status/domain plus the wiki-link structure).
struct VaultNote: Identifiable, Hashable {
    let node: GraphNode
    let outLinks: Int      // [[wikilinks]] this note makes
    let backLinks: Int     // notes that link to it
    var id: String { node.id }
    var path: String { node.id }
    var title: String { node.label }
    var domain: String? { node.domain }
    var status: String? { node.status }
    var type: String? { node.type }
    var deg: Int { outLinks + backLinks }
    var folder: String {
        let f = node.folder ?? ""
        return f.isEmpty ? "—" : f
    }
    var topFolder: String {
        let f = node.folder ?? ""
        return f.isEmpty ? "—" : String(f.split(separator: "/").first ?? "—")
    }
}

// MARK: - Client

enum CortexError: LocalizedError {
    case http(Int), offline(String)
    var errorDescription: String? {
        switch self {
        case .http(let c): return "Engine returned HTTP \(c)"
        case .offline(let m): return "Can't reach the Cortex engine on :8788 — \(m)"
        }
    }
}

struct CortexAPI {
    static let base = URL(string: "http://127.0.0.1:8788")!
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 90      // /ask shells to the Claude CLI; allow it time
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: Self.base) else { throw CortexError.http(0) }
        do {
            let (data, resp) = try await session.data(from: url)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else {
                throw CortexError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
            }
            return data
        } catch let e as CortexError { throw e }
        catch { throw CortexError.offline(error.localizedDescription) }
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        guard let url = URL(string: path, relativeTo: Self.base) else { throw CortexError.http(0) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else {
                throw CortexError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
            }
            return data
        } catch let e as CortexError { throw e }
        catch { throw CortexError.offline(error.localizedDescription) }
    }

    func health() async throws { _ = try await get("/health") }
    struct Health: Decodable { let notes: Int?; let chunks: Int? }
    func healthInfo() async throws -> (notes: Int, chunks: Int) {
        let h = try JSONDecoder().decode(Health.self, from: try await get("/health"))
        return (h.notes ?? 0, h.chunks ?? 0)
    }

    func list(folder: String? = nil, limit: Int? = nil) async throws -> [NoteRef] {
        var q = "/list?"
        if let f = folder, !f.isEmpty { q += "folder=\(f.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&" }
        if let l = limit { q += "limit=\(l)" }
        let paths = try JSONDecoder().decode([String].self, from: try await get(q))
        return paths.map(NoteRef.init(path:))
    }

    func note(_ path: String) async throws -> NoteContent {
        let q = "/note?path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path)"
        return try JSONDecoder().decode(NoteContent.self, from: try await get(q))
    }

    func graph() async throws -> Graph {
        try JSONDecoder().decode(Graph.self, from: try await get("/graph"))
    }

    func semanticEdges(k: Int = 4) async throws -> [GraphEdge] {
        try JSONDecoder().decode(SemanticGraph.self, from: try await get("/semantic_graph?k=\(k)")).edges
    }

    /// note id → community index (−1 = meta/isolated) for Color by Cluster.
    func communityMap() async throws -> [String: Int] {
        try JSONDecoder().decode([String: Int].self, from: try await get("/graph_community_map"))
    }

    func related(_ path: String, k: Int = 6) async throws -> [SearchHit] {
        let data = try await post("/related", ["path": path, "k": k])
        return try JSONDecoder().decode([SearchHit].self, from: data)
    }

    struct AskResult: Decodable { let answer: String?; let model: String?; let sources: [SearchHit]?; let error: String? }
    func ask(_ query: String, k: Int = 6) async throws -> AskResult {
        // /ask shells out to the Claude Code CLI (subscription) — can take several seconds
        let data = try await post("/ask", ["query": query, "k": k])
        return try JSONDecoder().decode(AskResult.self, from: data)
    }

    func search(_ query: String, hybrid: Bool = true, k: Int = 14) async throws -> [SearchHit] {
        let data = try await post(hybrid ? "/hybrid" : "/search", ["query": query, "k": k])
        return try JSONDecoder().decode([SearchHit].self, from: data)
    }

    @discardableResult
    func write(path: String, content: String, overwrite: Bool = true) async throws -> Bool {
        _ = try await post("/write", ["path": path, "content": content, "overwrite": overwrite])
        return true
    }
}
