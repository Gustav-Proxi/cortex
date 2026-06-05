import Foundation
import AppKit

// Lightweight self-updater over GitHub Releases. Checks the repo for a newer
// version and, on the user's OK, downloads the release zip and swaps the running
// `.app` in place: a small detached helper waits for this process to quit, replaces
// the bundle, strips quarantine, and relaunches. No Sparkle, no extra dependency —
// the app is already distributed as `Cortex-macos.zip` on the Releases page.
enum Updater {
    static let repo = "Gustav-Proxi/cortex"
    static var current: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }

    struct Release { let tag: String; let version: String; let zip: URL; let notes: String }

    /// Fetch the latest published release + its `.zip` asset (nil on any failure/offline).
    static func latest() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Cortex", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let assets = j["assets"] as? [[String: Any]],
              let zipStr = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })?["browser_download_url"] as? String,
              let zip = URL(string: zipStr)
        else { return nil }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(tag: tag, version: v, zip: zip, notes: (j["body"] as? String) ?? "")
    }

    /// Numeric dot-compare (0.1.10 > 0.1.9), ignoring any non-numeric suffix.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Download → unpack → swap the running bundle, then quit (the helper relaunches).
    static func install(_ rel: Release) async throws {
        let (tmp, _) = try await URLSession.shared.download(from: rel.zip)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-update")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("Cortex.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)
        try sh("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])          // unzip
        let newApp = work.appendingPathComponent("Cortex.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw NSError(domain: "Updater", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The download didn't contain Cortex.app."])
        }
        let dest = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let swap = work.appendingPathComponent("swap.sh")
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(dest)"
        /usr/bin/ditto "\(newApp.path)" "\(dest)"
        /usr/bin/xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null
        /usr/bin/open "\(dest)"
        """
        try script.write(to: swap, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [swap.path]
        try p.run()                                                           // detached; runs once we quit
        await MainActor.run { NSApp.terminate(nil) }
    }

    private static func sh(_ tool: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "Updater", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) failed (\(p.terminationStatus))."])
        }
    }
}
