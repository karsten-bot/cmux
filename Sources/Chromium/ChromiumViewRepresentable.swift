import SwiftUI
import AppKit

struct ChromiumViewRepresentable: NSViewRepresentable {
    @ObservedObject var panel: BrowserPanel
    let shouldFocusWebView: Bool

    func makeNSView(context: Context) -> ChromiumBrowserHostView {
        panel.chromiumContentView()
    }

    func updateNSView(_ nsView: ChromiumBrowserHostView, context: Context) {
        nsView.needsLayout = true
        nsView.layoutSubtreeIfNeeded()
        if shouldFocusWebView, let window = nsView.window {
            window.makeFirstResponder(nsView)
        }
    }
}
