import SwiftUI
import AppKit

struct ChromiumViewRepresentable: NSViewRepresentable {
    @ObservedObject var panel: BrowserPanel
    let shouldFocusWebView: Bool
    let isPanelFocused: Bool

    func makeNSView(context: Context) -> ChromiumBrowserHostView {
        panel.chromiumContentView()
    }

    func updateNSView(_ nsView: ChromiumBrowserHostView, context: Context) {
        nsView.needsLayout = true
        nsView.layoutSubtreeIfNeeded()
        if shouldFocusWebView {
            nsView.focusBrowserContent()
        } else if !isPanelFocused {
            nsView.clearBrowserContentFocus()
        }
    }
}
