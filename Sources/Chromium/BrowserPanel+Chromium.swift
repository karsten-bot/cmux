import AppKit

extension BrowserPanel {
    var usesChromiumEngine: Bool {
        browserEngine == .chromium
    }

    func chromiumContentView() -> ChromiumBrowserHostView {
        if let chromiumHostView {
            return chromiumHostView
        }
        let view = ChromiumBrowserHostView(initialURL: currentURL)
        chromiumHostView = view
        return view
    }

    func ownsChromiumShortcutResponder(_ responder: NSResponder?) -> Bool {
        guard usesChromiumEngine, let chromiumHostView else { return false }

        var current = responder
        while let candidate = current {
            if let view = candidate as? NSView,
               view === chromiumHostView || view.isDescendant(of: chromiumHostView) {
                return true
            }
            current = candidate.nextResponder
        }
        return false
    }

    func chromiumGoBackIfNeeded() -> Bool {
        guard usesChromiumEngine else { return false }
        chromiumHostView?.goBack()
        return true
    }

    func chromiumGoForwardIfNeeded() -> Bool {
        guard usesChromiumEngine else { return false }
        chromiumHostView?.goForward()
        return true
    }

    func chromiumReloadIfNeeded() -> Bool {
        guard usesChromiumEngine else { return false }
        chromiumHostView?.reload()
        return true
    }

    func chromiumStopLoadingIfNeeded() -> Bool {
        guard usesChromiumEngine else { return false }
        chromiumHostView?.stopLoading()
        return true
    }

    func toggleChromiumDeveloperToolsIfNeeded() -> Bool? {
        guard usesChromiumEngine else { return nil }
        return chromiumHostView?.toggleDeveloperTools() ?? false
    }

    func showChromiumDeveloperToolsIfNeeded() -> Bool? {
        guard usesChromiumEngine else { return nil }
        return chromiumHostView?.showDeveloperTools() ?? false
    }

    var chromiumDeveloperToolsVisible: Bool {
        chromiumHostView?.isDeveloperToolsVisible ?? false
    }
}
