import SwiftUI
import AppKit

// Native markdown editor: an NSTextView (in a scroll view) bound to a String.
// Monospaced, dark, soft-wrapping. Writes go back to the vault via /write — the
// engine's watcher re-embeds within ~2s, so search/graph stay current.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.string = text
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = NSColor(white: 0.90, alpha: 1)
        tv.insertionPointColor = NSColor(red: 0.74, green: 0.86, blue: 1.0, alpha: 1)
        tv.backgroundColor = NSColor(white: 0.04, alpha: 1)
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 16, height: 16)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.04, alpha: 1)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }   // external change (e.g. switched note)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MarkdownEditor
        init(_ p: MarkdownEditor) { parent = p }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
