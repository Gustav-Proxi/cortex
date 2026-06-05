import Foundation
import CoreServices

// Watches the vault folder for Markdown changes via FSEvents and fires `onChange`
// the instant a note is saved (the engine re-embeds in parallel). This is what makes
// the app feel live: every save refreshes the graph/counts immediately instead of
// waiting on the slow poll, and lets the UI flash a "synced" pulse even when an edit
// doesn't move any visible number. The periodic poll stays as a backstop.
final class VaultWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(path: String, onChange: @escaping () -> Void) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, numEvents, pathsPtr, _, _ in
            guard let info = info else { return }
            let me = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes the paths arrive as a CFArray of
            // CFString — bridge it safely. (Without that flag they're a C char**, and
            // casting that to NSArray segfaults — which is exactly what crashed.)
            guard let paths = unsafeBitCast(pathsPtr, to: NSArray.self) as? [String], numEvents > 0 else { return }
            // ignore the engine's own caches / dotfiles; only real note edits count
            if paths.contains(where: { $0.hasSuffix(".md") && !$0.contains("/.") }) { me.onChange() }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }
}
