import Bonsplit
import SwiftUI

struct BrowserEngineSurfaceView: View {
    let panel: BrowserPanel
    let paneId: PaneID
    let shouldAttachWebView: Bool
    let useLocalInlineHosting: Bool
    let shouldFocusWebView: Bool
    let isPanelFocused: Bool
    let portalZPriority: Int
    let paneDropZone: DropZone?
    let searchOverlay: BrowserPortalSearchOverlayConfiguration?
    let paneTopChromeHeight: CGFloat

    var body: some View {
        if panel.usesChromiumEngine {
            ChromiumViewRepresentable(
                panel: panel,
                shouldFocusWebView: shouldFocusWebView,
                isPanelFocused: isPanelFocused,
                searchOverlay: searchOverlay
            )
        } else {
            WebViewRepresentable(
                panel: panel,
                paneId: paneId,
                shouldAttachWebView: shouldAttachWebView,
                useLocalInlineHosting: useLocalInlineHosting,
                shouldFocusWebView: shouldFocusWebView,
                isPanelFocused: isPanelFocused,
                portalZPriority: portalZPriority,
                paneDropZone: paneDropZone,
                searchOverlay: searchOverlay,
                paneTopChromeHeight: paneTopChromeHeight
            )
        }
    }
}
