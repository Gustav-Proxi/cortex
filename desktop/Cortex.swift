// Cortex Desktop — a minimal native macOS shell (AppKit + WKWebView) around the
// local web UI the cortex engine serves on 127.0.0.1:8788. No Tauri, no Rust,
// no bundled runtime: the engine already runs in the background via launchd, and
// this is just the window. Compile with build.sh (system swiftc).
import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let url = URL(string: "http://127.0.0.1:8788/")!
    var window: NSWindow!
    var web: WKWebView!

    func applicationDidFinishLaunching(_ note: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1240, height: 840)
        window = NSWindow(contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Cortex"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1)
        window.setFrameAutosaveName("CortexWindow")

        web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1)
        }
        window.contentView = web

        load()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func load() { web.load(URLRequest(url: url)) }
    @objc func reload(_ sender: Any?) { web.reload() }

    // Engine may still be starting on first launch — retry quietly.
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { retry() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { retry() }
    func retry() { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.load() } }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

func buildMenu(_ d: AppDelegate) -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About Cortex", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Cortex", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(withTitle: "Quit Cortex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let viewItem = NSMenuItem(); main.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    let reload = NSMenuItem(title: "Reload", action: #selector(AppDelegate.reload(_:)), keyEquivalent: "r")
    reload.target = d; viewMenu.addItem(reload)
    viewMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    viewItem.submenu = viewMenu
    return main
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = buildMenu(delegate)
app.run()
