import AppKit

extension BrowserPanel {
    var usesChromiumEngine: Bool {
        browserEngine == .chromium
    }

    func chromiumContentView() -> ChromiumBrowserHostView {
        if let chromiumHostView {
            chromiumHostView.onReactGrabMessage = { [weak self] body in
                guard let message = ReactGrabBridgeMessage(body: body) else { return }
                self?.handleReactGrabBridgeMessage(message)
            }
            chromiumHostView.onNavigationStateChanged = { [weak self] state in
                self?.applyChromiumNavigationState(state)
            }
            chromiumHostView.onPopupRequest = { [weak self] url in
                self?.openLinkInNewTab(url: url)
            }
            chromiumHostView.onDownloadEvent = { [weak self] event in
                self?.handleChromiumDownloadEvent(event)
            }
            chromiumHostView.onFaviconURLsChanged = { [weak self] urls in
                self?.refreshChromiumFavicon(from: urls)
            }
            return chromiumHostView
        }
        let view = ChromiumBrowserHostView(initialURL: currentURL)
        view.onReactGrabMessage = { [weak self] body in
            guard let message = ReactGrabBridgeMessage(body: body) else { return }
            self?.handleReactGrabBridgeMessage(message)
        }
        view.onNavigationStateChanged = { [weak self] state in
            self?.applyChromiumNavigationState(state)
        }
        view.onPopupRequest = { [weak self] url in
            self?.openLinkInNewTab(url: url)
        }
        view.onDownloadEvent = { [weak self] event in
            self?.handleChromiumDownloadEvent(event)
        }
        view.onFaviconURLsChanged = { [weak self] urls in
            self?.refreshChromiumFavicon(from: urls)
        }
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

    func executeChromiumJavaScript(_ script: String) -> Bool {
        guard usesChromiumEngine else { return false }
        chromiumContentView().executeJavaScript(script)
        return true
    }

    func injectChromiumReactGrab(scriptSource: String, sessionTokenLiteral: String) -> Bool {
        guard usesChromiumEngine else { return false }
        // Keep this Chromium copy separate from ReactGrab.swift to avoid conflicts with upstream WebKit changes.
        let script = """
        (function() {
            var postMessage = function(message) {
                console.info('__CMUX_REACT_GRAB__' + JSON.stringify(message));
            };
            var updaterName = '\(reactGrabBridgeSessionUpdaterName)';
            var refreshSessionToken = function() {
                var syncToken = window[updaterName];
                if (typeof syncToken !== 'function') return false;
                return !!syncToken(\(sessionTokenLiteral));
            };
            var installBridge = function(api) {
                if (!api || window.__CMUX_REACT_GRAB_BRIDGE_INSTALLED__) return;
                window.__CMUX_REACT_GRAB_BRIDGE_INSTALLED__ = true;
                var activeToken = null;
                var syncSessionToken = function(token) {
                    activeToken = (typeof token === 'string' && token.length > 0) ? token : null;
                    return true;
                };
                try {
                    Object.defineProperty(window, updaterName, {
                        value: syncSessionToken,
                        writable: false,
                        configurable: false,
                        enumerable: false
                    });
                } catch (_) {
                    if (typeof window[updaterName] !== 'function') return;
                }
                refreshSessionToken();
                var lastActive;
                api.registerPlugin({
                    name: 'cmux-bridge',
                    hooks: {
                        onStateChange: function(state) {
                            if (state.isActive === lastActive) return;
                            lastActive = state.isActive;
                            postMessage({ type: 'stateChange', isActive: state.isActive });
                        },
                        onCopySuccess: function(elements, content) {
                            var token = activeToken;
                            activeToken = null;
                            postMessage({ type: 'copySuccess', content: String(content || ''), token: token });
                        }
                    }
                });
            }
            if (window.__REACT_GRAB__) {
                installBridge(window.__REACT_GRAB__);
                refreshSessionToken();
                window.__REACT_GRAB__.activate();
                return;
            }
            window.addEventListener('react-grab:init', function(e) {
                var api = e.detail;
                if (!api) return;
                installBridge(api);
                refreshSessionToken();
                api.activate();
            }, { once: true });
        })();
        \(scriptSource)
        """
        chromiumContentView().executeJavaScript(script)
        return true
    }
}
