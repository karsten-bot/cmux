import AppKit
import WebKit

@objc(CmuxChromiumNavigationPolicy)
final class CmuxChromiumNavigationPolicy: NSObject {
    @objc(shouldOpenURLExternally:)
    static func shouldOpenURLExternally(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return browserShouldOpenURLExternally(url)
    }
}

@objc(CmuxChromiumContextMenuPolicy)
final class CmuxChromiumContextMenuPolicy: NSObject {
    @objc(menuItemsWithLinkURL:sourceURL:mediaType:)
    static func menuItems(linkURL: String, sourceURL: String, mediaType: String) -> NSArray {
        let items = NSMutableArray()
        var addedCustomItems = false

        if !linkURL.isEmpty {
            items.add(["separatorIfNeeded": true])
            items.add([
                "action": "openLinkInNewTab",
                "title": String(localized: "browser.contextMenu.openLinkInNewTab", defaultValue: "Open Link in New Tab"),
            ])
            items.add([
                "action": "openLinkInDefaultBrowser",
                "title": String(localized: "browser.contextMenu.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser"),
            ])
            items.add([
                "action": "downloadLinkedFile",
                "title": String(localized: "browser.contextMenu.downloadLinkedFile", defaultValue: "Download Linked File"),
            ])
            addedCustomItems = true
        }

        if !sourceURL.isEmpty, mediaType == "image" {
            items.add([addedCustomItems ? "separator" : "separatorIfNeeded": true])
            items.add([
                "action": "downloadImage",
                "title": String(localized: "browser.contextMenu.downloadImage", defaultValue: "Download Image"),
            ])
            addedCustomItems = true
        }

        if addedCustomItems {
            items.add(["separator": true])
        } else {
            items.add(["separatorIfNeeded": true])
        }
        items.add([
            "action": "inspectElement",
            "title": String(localized: "browser.contextMenu.inspectElement", defaultValue: "Inspect Element"),
        ])
        items.add([
            "action": "moveTabToNewWorkspace",
            "title": String(localized: "browser.contextMenu.moveTabToNewWorkspace", defaultValue: "Move Tab to New Workspace"),
        ])

        return items
    }
}

@objc(CmuxChromiumPermissionPromptPolicy)
final class CmuxChromiumPermissionPromptPolicy: NSObject {
    @objc(promptConfigurationWithOrigin:permissionKeys:)
    static func promptConfiguration(origin: String, permissionKeys: NSArray) -> NSDictionary {
        let site = origin.isEmpty
            ? String(localized: "browser.permission.thisSite", defaultValue: "This site")
            : origin
        let names = permissionKeys.compactMap { $0 as? String }.map(permissionName).filter { !$0.isEmpty }
        let permissionText = names.isEmpty
            ? String(localized: "browser.permission.browserPermissions", defaultValue: "browser permissions")
            : names.joined(separator: ", ")

        return [
            "title": String(
                localized: "browser.permission.prompt.title",
                defaultValue: "Allow \(site) to use \(permissionText)?"
            ),
            "message": String(
                localized: "browser.permission.prompt.message",
                defaultValue: "cmux will ask again next time."
            ),
            "allowTitle": String(localized: "common.allow", defaultValue: "Allow"),
            "denyTitle": String(localized: "browser.permission.deny", defaultValue: "Don't Allow"),
        ]
    }

    private static func permissionName(_ key: String) -> String {
        switch key {
        case "arSession":
            return String(localized: "browser.permission.arSession", defaultValue: "augmented reality")
        case "cameraPanTiltZoom":
            return String(localized: "browser.permission.cameraPanTiltZoom", defaultValue: "camera pan, tilt, and zoom")
        case "camera":
            return String(localized: "browser.permission.camera", defaultValue: "camera")
        case "capturedSurfaceControl":
            return String(localized: "browser.permission.capturedSurfaceControl", defaultValue: "captured screen control")
        case "clipboard":
            return String(localized: "browser.permission.clipboard", defaultValue: "clipboard")
        case "topLevelStorageAccess":
            return String(localized: "browser.permission.topLevelStorageAccess", defaultValue: "top-level storage access")
        case "diskQuota":
            return String(localized: "browser.permission.diskQuota", defaultValue: "extra storage")
        case "localFonts":
            return String(localized: "browser.permission.localFonts", defaultValue: "local fonts")
        case "geolocation":
            return String(localized: "browser.permission.geolocation", defaultValue: "location")
        case "handTracking":
            return String(localized: "browser.permission.handTracking", defaultValue: "hand tracking")
        case "identityProvider":
            return String(localized: "browser.permission.identityProvider", defaultValue: "identity provider")
        case "idleDetection":
            return String(localized: "browser.permission.idleDetection", defaultValue: "idle detection")
        case "microphone":
            return String(localized: "browser.permission.microphone", defaultValue: "microphone")
        case "midiSysex":
            return String(localized: "browser.permission.midiSysex", defaultValue: "MIDI devices")
        case "multipleDownloads":
            return String(localized: "browser.permission.multipleDownloads", defaultValue: "multiple downloads")
        case "notifications":
            return String(localized: "browser.permission.notifications", defaultValue: "notifications")
        case "keyboardLock":
            return String(localized: "browser.permission.keyboardLock", defaultValue: "keyboard lock")
        case "pointerLock":
            return String(localized: "browser.permission.pointerLock", defaultValue: "pointer lock")
        case "protectedMediaIdentifier":
            return String(localized: "browser.permission.protectedMediaIdentifier", defaultValue: "protected media identifier")
        case "registerProtocolHandler":
            return String(localized: "browser.permission.registerProtocolHandler", defaultValue: "protocol handler registration")
        case "storageAccess":
            return String(localized: "browser.permission.storageAccess", defaultValue: "storage access")
        case "vrSession":
            return String(localized: "browser.permission.vrSession", defaultValue: "virtual reality")
        case "webAppInstallation":
            return String(localized: "browser.permission.webAppInstallation", defaultValue: "web app installation")
        case "windowManagement":
            return String(localized: "browser.permission.windowManagement", defaultValue: "window management")
        case "fileSystemAccess":
            return String(localized: "browser.permission.fileSystemAccess", defaultValue: "file system access")
        case "localNetwork":
            return String(localized: "browser.permission.localNetwork", defaultValue: "local network")
        case "loopbackNetwork":
            return String(localized: "browser.permission.loopbackNetwork", defaultValue: "loopback network")
        case "sensors":
            return String(localized: "browser.permission.sensors", defaultValue: "sensors")
        case "desktopAudio":
            return String(localized: "browser.permission.desktopAudio", defaultValue: "desktop audio")
        case "desktopVideo":
            return String(localized: "browser.permission.desktopVideo", defaultValue: "screen recording")
        default:
            return String(localized: "browser.permission.browserPermissions", defaultValue: "browser permissions")
        }
    }
}

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
            chromiumHostView.onFindResult = { [weak self] count, activeMatchOrdinal in
                self?.applyChromiumFindResult(count: count, activeMatchOrdinal: activeMatchOrdinal)
            }
            chromiumHostView.onCloseRequested = { [weak self] in
                self?.webViewDidRequestClose?()
            }
            chromiumHostView.onContextMenuMoveTabToNewWorkspace = { [weak self] in
                guard let self else { return false }
                return AppDelegate.shared?.moveSurfaceToNewWorkspace(
                    panelId: self.id,
                    focus: true,
                    focusWindow: false
                ) != nil
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
        view.onFindResult = { [weak self] count, activeMatchOrdinal in
            self?.applyChromiumFindResult(count: count, activeMatchOrdinal: activeMatchOrdinal)
        }
        view.onCloseRequested = { [weak self] in
            self?.webViewDidRequestClose?()
        }
        view.onContextMenuMoveTabToNewWorkspace = { [weak self] in
            guard let self else { return false }
            return AppDelegate.shared?.moveSurfaceToNewWorkspace(
                panelId: self.id,
                focus: true,
                focusWindow: false
            ) != nil
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

    func browserFocusNotificationWindow(for object: Any?) -> NSWindow? {
        if let webView = object as? WKWebView, webView === self.webView {
            return webView.window
        }
        if let chromiumHostView = object as? ChromiumBrowserHostView,
           chromiumHostView === self.chromiumHostView {
            return chromiumHostView.window
        }
        return nil
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
