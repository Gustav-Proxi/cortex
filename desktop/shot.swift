// Dev tool: render a URL in WKWebView and save a PNG snapshot, so the graph/UI
// can be inspected headlessly. Usage: shot <url> <out.png> [delaySeconds] [jsToRun]
import Cocoa
import WebKit

let a = CommandLine.arguments
guard a.count >= 3, let argURL = URL(string: a[1]) else {
    FileHandle.standardError.write("usage: shot <url> <out.png> [delay] [js]\n".data(using: .utf8)!); exit(1)
}

final class D: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let url: URL; let out: String; let delay: Double; let js: String
    var window: NSWindow!; var web: WKWebView!
    init(url: URL, out: String, delay: Double, js: String) {
        self.url = url; self.out = out; self.delay = delay; self.js = js; super.init()
    }
    func applicationDidFinishLaunching(_ n: Notification) {
        let f = NSRect(x: 0, y: 0, width: 1440, height: 920)
        window = NSWindow(contentRect: f, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        web = WKWebView(frame: f, configuration: WKWebViewConfiguration())
        web.navigationDelegate = self
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: url))
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if !self.js.isEmpty { w.evaluateJavaScript(self.js, completionHandler: nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.delay) { self.snap() }
        }
    }
    func snap() {
        web.takeSnapshot(with: WKSnapshotConfiguration()) { img, err in
            guard let img = img, let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write("snapshot failed: \(String(describing: err))\n".data(using: .utf8)!); exit(2)
            }
            try? png.write(to: URL(fileURLWithPath: self.out))
            print("wrote \(self.out)"); exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = D(url: argURL, out: a[2], delay: a.count > 3 ? (Double(a[3]) ?? 7) : 7, js: a.count > 4 ? a[4] : "")
app.delegate = d
app.run()
