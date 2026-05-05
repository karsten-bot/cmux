import AppKit

extension AppDelegate {
    func shortcutChromiumBrowserPanel(for responder: NSResponder?) -> BrowserPanel? {
        guard let responder else { return nil }
        let candidates = [tabManager] + mainWindowContexts.values.map { Optional($0.tabManager) }
        var seen = Set<ObjectIdentifier>()

        for candidate in candidates {
            guard let manager = candidate else { continue }
            let identifier = ObjectIdentifier(manager)
            guard seen.insert(identifier).inserted else { continue }

            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    guard let browserPanel = panel as? BrowserPanel,
                          browserPanel.ownsChromiumShortcutResponder(responder) else {
                        continue
                    }
                    return browserPanel
                }
            }
        }

        return nil
    }
}
