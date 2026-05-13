import Foundation
import AppKit
import SwiftUI

struct ChromiumNavigationState {
    let url: URL?
    let title: String?
    let isLoading: Bool?
    let isFullscreen: Bool?
    let canGoBack: Bool?
    let canGoForward: Bool?
    let backHistoryURLStrings: [String]?
    let forwardHistoryURLStrings: [String]?
}

struct ChromiumJavaScriptError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
final class ChromiumBrowserHostView: NSView {
    private final class DevToolsDividerView: NSView {
        weak var hostView: ChromiumBrowserHostView?

        init(hostView: ChromiumBrowserHostView) {
            self.hostView = hostView
            super.init(frame: .zero)
            toolTip = String(localized: "browser.chromium.devtools.divider.tooltip", defaultValue: "Resize Developer Tools")
            setAccessibilityIdentifier("ChromiumDevToolsDivider")
        }

        required init?(coder: NSCoder) {
            nil
        }

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let hostView else { return }
            NSColor.separatorColor
                .withAlphaComponent(hostView.isDraggingDevToolsDivider ? 0.42 : 0.22)
                .setFill()

            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let width = 1 / scale
            let line = NSRect(
                x: floor(bounds.midX * scale) / scale,
                y: bounds.minY,
                width: width,
                height: bounds.height
            )
            NSBezierPath(rect: line).fill()
        }

        override func mouseDown(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
            hostView?.beginDevToolsDividerDrag()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let hostView else { return }
            let point = hostView.convert(event.locationInWindow, from: nil)
            hostView.updateDevToolsWidthFromDividerX(point.x)
        }

        override func mouseUp(with event: NSEvent) {
            hostView?.endDevToolsDividerDrag()
        }
    }

    private var browserHandle: UnsafeMutableRawPointer?
    private var devToolsBrowserHandle: UnsafeMutableRawPointer?
    private var pendingURL: URL?
    private var currentURL: URL?
    private var devToolsOpenTask: Task<Void, Never>?
    private var devToolsDividerEventMonitor: Any?
    private var devToolsDividerTrackingArea: NSTrackingArea?
    private var pendingJavaScript: [String] = []
    private var isObservingBrowserNotifications = false
    private let pageContainerView = NSView(frame: .zero)
    private let devToolsContainerView = NSView(frame: .zero)
    private lazy var devToolsDividerView = DevToolsDividerView(hostView: self)
    private var devToolsVisible = false
    private var isDraggingDevToolsDivider = false
    private var devToolsWidth: CGFloat = ChromiumBrowserHostView.initialDevToolsWidth()
    private var searchOverlayHostingView: NSHostingView<BrowserSearchOverlay>?
    private var searchOverlayFocusGeneration: UInt64?
    private var pageZoomFactor: CGFloat = 1.0
    private let devToolsPreferredWidth: CGFloat = 520
    private let devToolsMinimumWidth: CGFloat = 360
    private let devToolsMinimumPageWidth: CGFloat = 160
    private static let devToolsDividerCursor = NSCursor.resizeLeftRight
    private static let devToolsWidthDefaultsKey = "chromiumDevToolsAttachedWidth"
    private static let reactGrabMessageNotification = Notification.Name("CmuxChromiumReactGrabMessageNotification")
    private static let navigationStateNotification = Notification.Name("CmuxChromiumNavigationStateNotification")
    private static let browserClosedNotification = Notification.Name("CmuxChromiumBrowserClosedNotification")
    private static let popupRequestNotification = Notification.Name("CmuxChromiumPopupRequestNotification")
    private static let downloadEventNotification = Notification.Name("CmuxChromiumDownloadEventNotification")
    private static let faviconURLsNotification = Notification.Name("CmuxChromiumFaviconURLsNotification")
    private static let findResultNotification = Notification.Name("CmuxChromiumFindResultNotification")
    private static let contextMenuActionNotification = Notification.Name("CmuxChromiumContextMenuActionNotification")
    var onReactGrabMessage: (([String: Any]) -> Void)?
    var onNavigationStateChanged: ((ChromiumNavigationState) -> Void)?
    var onPopupRequest: ((URL) -> Void)?
    var onDownloadEvent: (([String: Any]) -> Void)?
    var onFaviconURLsChanged: (([URL]) -> Void)?
    var onFindResult: ((Int, Int) -> Void)?
    var onContextMenuMoveTabToNewWorkspace: (() -> Bool)?

    init(initialURL: URL?) {
        pendingURL = initialURL
        currentURL = initialURL
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        pageContainerView.autoresizingMask = []
        pageContainerView.wantsLayer = true
        pageContainerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(pageContainerView)

        devToolsContainerView.autoresizingMask = []
        devToolsContainerView.wantsLayer = true
        devToolsContainerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        devToolsContainerView.isHidden = true
        addSubview(devToolsContainerView)

        devToolsDividerView.isHidden = true
        addSubview(devToolsDividerView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    deinit {
        devToolsOpenTask?.cancel()
        if let devToolsDividerEventMonitor {
            NSEvent.removeMonitor(devToolsDividerEventMonitor)
        }
        if let devToolsDividerTrackingArea {
            removeTrackingArea(devToolsDividerTrackingArea)
        }
        NotificationCenter.default.removeObserver(self)
        if let devToolsBrowserHandle {
            cmux_chromium_dispose_browser(devToolsBrowserHandle)
        }
        if let browserHandle {
            cmux_chromium_dispose_browser(browserHandle)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureBrowserCreated()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        layoutChromiumSubviews()
        if let searchOverlayHostingView {
            moveSearchOverlayToFront(searchOverlayHostingView)
        }
        if let browserHandle {
            cmux_chromium_resize_browser(browserHandle)
            if let devToolsBrowserHandle {
                cmux_chromium_resize_browser(devToolsBrowserHandle)
            }
        } else {
            ensureBrowserCreated()
        }
    }

    override func becomeFirstResponder() -> Bool {
        setBrowserFocused(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        setBrowserFocused(false)
        return true
    }

    override func updateTrackingAreas() {
        if let devToolsDividerTrackingArea {
            removeTrackingArea(devToolsDividerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .inVisibleRect,
                .activeAlways,
                .cursorUpdate,
                .mouseMoved,
                .mouseEnteredAndExited,
                .enabledDuringMouseDrag,
            ],
            owner: self
        )
        addTrackingArea(trackingArea)
        devToolsDividerTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if devToolsVisible, !devToolsDividerView.isHidden {
            addCursorRect(devToolsDividerInteractionRect, cursor: Self.devToolsDividerCursor)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateDevToolsDividerCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateDevToolsDividerCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDraggingDevToolsDivider else { return }
        NSCursor.arrow.set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if devToolsVisible,
           !devToolsDividerView.isHidden,
           devToolsDividerView.frame.contains(point) {
            return devToolsDividerView
        }
        return super.hitTest(point)
    }

    func load(_ url: URL) {
        pendingURL = url
        guard let browserHandle else {
            ensureBrowserCreated()
            return
        }
        cmux_chromium_load_url(browserHandle, url.absoluteString)
    }

    func goBack() {
        guard let browserHandle else { return }
        cmux_chromium_go_back(browserHandle)
    }

    func goForward() {
        guard let browserHandle else { return }
        cmux_chromium_go_forward(browserHandle)
    }

    func refreshNavigationEntries() {
        guard let browserHandle else { return }
        cmux_chromium_refresh_navigation_entries(browserHandle)
    }

    func reload() {
        guard let browserHandle else { return }
        cmux_chromium_reload(browserHandle)
    }

    func stopLoading() {
        guard let browserHandle else { return }
        cmux_chromium_stop_loading(browserHandle)
    }

    func focusBrowserContent() {
        guard browserHandle != nil else {
            ensureBrowserCreated()
            return
        }
        _ = window?.makeFirstResponder(self)
        setBrowserFocused(true)
    }

    func clearBrowserContentFocus() {
        if ownsFirstResponder {
            _ = window?.makeFirstResponder(nil)
        }
        setBrowserFocused(false)
    }

    func executeJavaScript(_ script: String) {
        guard let browserHandle else {
            pendingJavaScript.append(script)
            ensureBrowserCreated()
            return
        }
        cmux_chromium_execute_javascript(browserHandle, script)
    }

    func evaluateJavaScript(_ script: String, timeout: TimeInterval = 5.0) async throws -> Any? {
        if browserHandle == nil {
            ensureBrowserCreated()
            if browserHandle == nil {
                throw ChromiumJavaScriptError(message: String(cString: cmux_chromium_last_error()))
            }
        }

        let pageURL = currentURL ?? pendingURL
        return try await Task.detached {
            try Self.evaluateJavaScriptWithRemoteDebuggingSync(script, pageURL: pageURL, timeout: timeout)
        }.value
    }

    private func inspectElementAt(x: Int, y: Int) {
        guard browserHandle != nil else { return }
        let pageURL = currentURL ?? pendingURL
        _ = showDeveloperTools()
        Task.detached {
            try? Self.inspectElementWithRemoteDebuggingSync(x: x, y: y, pageURL: pageURL, timeout: 3)
        }
    }

    func takeSnapshot() -> NSImage? {
        let targetView = pageContainerView
        guard targetView.bounds.width > 0,
              targetView.bounds.height > 0,
              let representation = targetView.bitmapImageRepForCachingDisplay(in: targetView.bounds) else {
            return nil
        }
        targetView.cacheDisplay(in: targetView.bounds, to: representation)
        let image = NSImage(size: targetView.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    func setPageZoomFactor(_ factor: CGFloat) {
        pageZoomFactor = factor
        guard let browserHandle else { return }
        cmux_chromium_set_zoom_level(browserHandle, Self.chromiumZoomLevel(for: factor))
    }

    func find(_ searchText: String, forward: Bool, findNext: Bool) {
        guard let browserHandle else { return }
        searchText.withCString { text in
            cmux_chromium_find(browserHandle, text, forward, findNext)
        }
    }

    func stopFinding(clearSelection: Bool) {
        guard let browserHandle else { return }
        cmux_chromium_stop_finding(browserHandle, clearSelection)
    }

    func setSearchOverlay(_ configuration: BrowserPortalSearchOverlayConfiguration?) {
        guard let configuration else {
            searchOverlayHostingView?.removeFromSuperview()
            searchOverlayHostingView = nil
            searchOverlayFocusGeneration = nil
            return
        }

        let rootView = BrowserSearchOverlay(
            panelId: configuration.panelId,
            searchState: configuration.searchState,
            focusRequestGeneration: configuration.focusRequestGeneration,
            canApplyFocusRequest: configuration.canApplyFocusRequest,
            onNext: configuration.onNext,
            onPrevious: configuration.onPrevious,
            onClose: configuration.onClose,
            onFieldDidFocus: configuration.onFieldDidFocus
        )

        if let overlay = searchOverlayHostingView {
            overlay.rootView = rootView
            moveSearchOverlayToFront(overlay)
        } else {
            let overlay = NSHostingView(rootView: rootView)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: topAnchor),
                overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            searchOverlayHostingView = overlay
        }

        if searchOverlayFocusGeneration != configuration.focusRequestGeneration {
            searchOverlayFocusGeneration = configuration.focusRequestGeneration
            DispatchQueue.main.async {
                self.postSearchOverlayFocus(configuration)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.postSearchOverlayFocus(configuration)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.postSearchOverlayFocus(configuration)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.postSearchOverlayFocus(configuration)
            }
        }
    }

    func showDeveloperTools() -> Bool {
        guard let browserHandle else { return false }
        devToolsVisible = true
        devToolsContainerView.isHidden = false
        devToolsDividerView.isHidden = false
        installDevToolsDividerEventMonitor()
        layoutChromiumSubviews()
        window?.invalidateCursorRects(for: self)
        cmux_chromium_resize_browser(browserHandle)
        if let devToolsBrowserHandle {
            cmux_chromium_resize_browser(devToolsBrowserHandle)
            return true
        }

        let pageURL = pendingURL
        devToolsOpenTask?.cancel()
        devToolsOpenTask = Task { [weak self] in
            guard let devToolsURL = await Self.resolveDevToolsFrontendURL(for: pageURL) else {
                #if DEBUG
                cmuxDebugLog("browser.chromium.devtools.resolve.failed")
                #endif
                return
            }
            await MainActor.run {
                guard let self, self.devToolsVisible, self.devToolsBrowserHandle == nil else { return }
                self.devToolsBrowserHandle = cmux_chromium_create_browser(
                    self.devToolsContainerView,
                    devToolsURL.absoluteString
                )
                if self.devToolsBrowserHandle == nil {
                    #if DEBUG
                    let message = String(cString: cmux_chromium_last_error())
                    cmuxDebugLog("browser.chromium.devtools.create.failed \(message)")
                    #endif
                }
            }
        }
        return true
    }

    func toggleDeveloperTools() -> Bool {
        guard let browserHandle else { return false }
        if devToolsVisible || cmux_chromium_has_dev_tools(browserHandle) {
            closeDeveloperTools()
            return true
        }
        return showDeveloperTools()
    }

    var isDeveloperToolsVisible: Bool {
        devToolsVisible
    }

    func closeDeveloperTools() {
        hideDeveloperToolsChrome()
        if let devToolsBrowserHandle {
            self.devToolsBrowserHandle = nil
            cmux_chromium_dispose_browser(devToolsBrowserHandle)
        }
    }

    func beginDevToolsDividerDrag() {
        isDraggingDevToolsDivider = true
        devToolsDividerView.needsDisplay = true
    }

    func updateDevToolsWidthFromDividerX(_ dividerX: CGFloat) {
        guard devToolsVisible else { return }
        devToolsWidth = clampedDevToolsWidth(for: bounds.maxX - dividerX)
        Self.persistDevToolsWidth(devToolsWidth)
        layoutChromiumSubviews()
        if let browserHandle {
            cmux_chromium_resize_browser(browserHandle)
        }
        if let devToolsBrowserHandle {
            cmux_chromium_resize_browser(devToolsBrowserHandle)
        }
    }

    func endDevToolsDividerDrag() {
        isDraggingDevToolsDivider = false
        devToolsDividerView.needsDisplay = true
        NSCursor.arrow.set()
    }

    private func installDevToolsDividerEventMonitor() {
        guard devToolsDividerEventMonitor == nil else { return }
        devToolsDividerEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
        ) { [weak self] event in
            self?.handleDevToolsDividerEvent(event) ?? event
        }
    }

    private func removeDevToolsDividerEventMonitor() {
        guard let devToolsDividerEventMonitor else { return }
        NSEvent.removeMonitor(devToolsDividerEventMonitor)
        self.devToolsDividerEventMonitor = nil
    }

    private func handleDevToolsDividerEvent(_ event: NSEvent) -> NSEvent? {
        guard devToolsVisible, event.window === window else { return event }
        let point = convert(event.locationInWindow, from: nil)

        switch event.type {
        case .mouseMoved:
            updateDevToolsDividerCursor(at: point)
            return event
        case .leftMouseDown:
            guard devToolsDividerInteractionRect.contains(point) else { return event }
            NSCursor.resizeLeftRight.set()
            beginDevToolsDividerDrag()
            return nil
        case .leftMouseDragged:
            guard isDraggingDevToolsDivider else { return event }
            updateDevToolsWidthFromDividerX(point.x)
            return nil
        case .leftMouseUp:
            guard isDraggingDevToolsDivider else { return event }
            endDevToolsDividerDrag()
            return nil
        default:
            return event
        }
    }

    private func updateDevToolsDividerCursor(at point: NSPoint) {
        guard devToolsVisible, !devToolsDividerView.isHidden else { return }
        guard devToolsDividerInteractionRect.contains(point) || isDraggingDevToolsDivider else { return }
        Self.devToolsDividerCursor.set()
        DispatchQueue.main.async {
            guard let window = self.window,
                  self.devToolsVisible,
                  self.devToolsDividerInteractionRect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
                    || self.isDraggingDevToolsDivider else { return }
            Self.devToolsDividerCursor.set()
        }
    }

    private func layoutChromiumSubviews() {
        let bounds = self.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            pageContainerView.frame = bounds
            devToolsContainerView.frame = .zero
            devToolsDividerView.frame = .zero
            return
        }

        guard devToolsVisible else {
            pageContainerView.frame = bounds
            devToolsContainerView.frame = .zero
            devToolsDividerView.frame = .zero
            return
        }

        devToolsWidth = clampedDevToolsWidth(for: devToolsWidth)
        let clampedDevToolsWidth = devToolsWidth
        pageContainerView.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(1, bounds.width - clampedDevToolsWidth),
            height: bounds.height
        )
        devToolsContainerView.frame = NSRect(
            x: pageContainerView.frame.maxX,
            y: bounds.minY,
            width: max(1, clampedDevToolsWidth),
            height: bounds.height
        )
        devToolsDividerView.frame = NSRect(
            x: pageContainerView.frame.maxX - (SidebarResizeInteraction.totalHitWidth * 0.5),
            y: bounds.minY,
            width: SidebarResizeInteraction.totalHitWidth,
            height: bounds.height
        )
        devToolsContainerView.needsLayout = true
        devToolsDividerView.needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if isDraggingDevToolsDivider {
            NSCursor.resizeLeftRight.set()
        }
    }

    private var devToolsDividerInteractionRect: NSRect {
        NSRect(
            x: devToolsContainerView.frame.minX - SidebarResizeInteraction.totalHitWidth,
            y: bounds.minY,
            width: SidebarResizeInteraction.totalHitWidth * 2,
            height: bounds.height
        )
    }

    private func clampedDevToolsWidth(for width: CGFloat) -> CGFloat {
        let availableDevToolsWidth = max(0, bounds.width - devToolsMinimumPageWidth)
        guard availableDevToolsWidth > 0 else { return 0 }
        let defaultWidth = min(devToolsPreferredWidth, max(devToolsMinimumWidth, max(0, bounds.width - 240) * 0.42))
        let requestedWidth = width > 0 ? width : defaultWidth
        return min(max(requestedWidth, min(devToolsMinimumWidth, availableDevToolsWidth)), availableDevToolsWidth)
    }

    private static func initialDevToolsWidth(defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.double(forKey: devToolsWidthDefaultsKey)
        return stored > 0 ? CGFloat(stored) : 520
    }

    private static func persistDevToolsWidth(_ width: CGFloat, defaults: UserDefaults = .standard) {
        guard width > 0 else { return }
        defaults.set(Double(width), forKey: devToolsWidthDefaultsKey)
    }

    private nonisolated static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    private static func chromiumZoomLevel(for factor: CGFloat) -> Double {
        log(Double(max(0.25, factor))) / log(1.2)
    }

    private func postSearchOverlayFocus(_ configuration: BrowserPortalSearchOverlayConfiguration) {
        guard configuration.canApplyFocusRequest(configuration.focusRequestGeneration) else { return }
        NotificationCenter.default.post(
            name: .browserSearchFocus,
            object: configuration.panelId,
            userInfo: [FindFocusNotificationKey.selectAll: false]
        )
        focusSearchOverlayField()
    }

    private func moveSearchOverlayToFront(_ overlay: NSView) {
        guard overlay.superview === self else { return }
        addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    private func focusSearchOverlayField() {
        guard let field = searchOverlayTextField(in: searchOverlayHostingView),
              let window = field.window else { return }
        _ = window.makeFirstResponder(field)
    }

    private func searchOverlayTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField,
           field.accessibilityIdentifier() == "BrowserFindSearchTextField" {
            return field
        }
        for subview in view.subviews {
            if let field = searchOverlayTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func ensureBrowserCreated() {
        guard browserHandle == nil, window != nil else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }
        layoutChromiumSubviews()
        guard cmux_chromium_initialize() else {
            #if DEBUG
            let message = String(cString: cmux_chromium_last_error())
            cmuxDebugLog("browser.chromium.init.failed \(message)")
            #endif
            return
        }
        let initialURLString = pendingURL?.absoluteString ?? "about:blank"
        browserHandle = cmux_chromium_create_browser(pageContainerView, initialURLString)
        if browserHandle == nil {
            #if DEBUG
            let message = String(cString: cmux_chromium_last_error())
            cmuxDebugLog("browser.chromium.create.failed \(message)")
            #endif
        } else if let browserHandle {
            cmux_chromium_set_zoom_level(browserHandle, Self.chromiumZoomLevel(for: pageZoomFactor))
            if !isObservingBrowserNotifications {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleReactGrabMessageNotification(_:)),
                    name: Self.reactGrabMessageNotification,
                    object: nil
                )
                isObservingBrowserNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleNavigationStateNotification(_:)),
                    name: Self.navigationStateNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleBrowserClosedNotification(_:)),
                    name: Self.browserClosedNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handlePopupRequestNotification(_:)),
                    name: Self.popupRequestNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleDownloadEventNotification(_:)),
                    name: Self.downloadEventNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleFaviconURLsNotification(_:)),
                    name: Self.faviconURLsNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleFindResultNotification(_:)),
                    name: Self.findResultNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleContextMenuActionNotification(_:)),
                    name: Self.contextMenuActionNotification,
                    object: nil
                )
            }
            pendingJavaScript.forEach { cmux_chromium_execute_javascript(browserHandle, $0) }
            pendingJavaScript.removeAll()
        }
    }

    @objc private func handleBrowserClosedNotification(_ notification: Notification) {
        guard let closedBrowserHandle = notification.userInfo?["browserHandle"] as? NSValue else {
            return
        }

        guard let pointer = closedBrowserHandle.pointerValue else { return }
        if pointer == devToolsBrowserHandle {
            devToolsBrowserHandle = nil
            hideDeveloperToolsChrome()
            cmux_chromium_dispose_browser(pointer)
        } else if pointer == browserHandle {
            browserHandle = nil
            cmux_chromium_dispose_browser(pointer)
        }
    }

    @objc private func handlePopupRequestNotification(_ notification: Notification) {
        guard let browserHandle,
              let notifiedBrowserHandle = notification.userInfo?["browserHandle"] as? NSValue,
              notifiedBrowserHandle.pointerValue == browserHandle,
              let rawURL = notification.userInfo?["url"] as? String,
              let url = URL(string: rawURL) else {
            return
        }
        if browserShouldOpenURLExternally(url) {
            NSWorkspace.shared.open(url)
            return
        }
        let openerURL = (notification.userInfo?["openerURL"] as? String).flatMap(URL.init(string:)) ?? currentURL
        let userGesture = (notification.userInfo?["userGesture"] as? NSNumber)?.boolValue ?? false
        let popupFeaturesWereSpecified = (notification.userInfo?["popupFeaturesWereSpecified"] as? NSNumber)?.boolValue ?? false
        if browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
            navigationType: .other,
            requestMethod: "GET",
            requestURL: url,
            openerURL: openerURL,
            currentEventType: userGesture ? .leftMouseUp : nil,
            popupFeaturesWereSpecified: popupFeaturesWereSpecified
        ) {
            load(url)
            return
        }
        onPopupRequest?(url)
    }

    @objc private func handleDownloadEventNotification(_ notification: Notification) {
        guard let browserHandle,
              let notifiedBrowserHandle = notification.userInfo?["browserHandle"] as? NSValue,
              notifiedBrowserHandle.pointerValue == browserHandle else {
            return
        }
        let event = Dictionary(uniqueKeysWithValues: (notification.userInfo ?? [:]).compactMap { key, value in
            (key as? String).map { ($0, value) }
        })
        onDownloadEvent?(event)
    }

    @objc private func handleFaviconURLsNotification(_ notification: Notification) {
        guard let browserHandle,
              let notifiedBrowserHandle = notification.userInfo?["browserHandle"] as? NSValue,
              notifiedBrowserHandle.pointerValue == browserHandle,
              let rawURLs = notification.userInfo?["urls"] as? [String] else {
            return
        }
        let urls = rawURLs.compactMap(URL.init(string:))
        onFaviconURLsChanged?(urls)
    }

    @objc private func handleFindResultNotification(_ notification: Notification) {
        guard let browserHandle,
              let notifiedBrowserHandle = notification.userInfo?["browserHandle"] as? NSValue,
              notifiedBrowserHandle.pointerValue == browserHandle,
              let count = notification.userInfo?["count"] as? Int,
              let activeMatchOrdinal = notification.userInfo?["activeMatchOrdinal"] as? Int else {
            return
        }
        onFindResult?(count, activeMatchOrdinal)
    }

    @objc private func handleContextMenuActionNotification(_ notification: Notification) {
        guard let browserHandle,
              let notifiedBrowserHandle = notification.userInfo?["browserHandle"] as? NSValue,
              notifiedBrowserHandle.pointerValue == browserHandle,
              let action = notification.userInfo?["action"] as? String else {
            return
        }

        switch action {
        case "openLinkInNewTab":
            if let url = contextMenuURL(from: notification.userInfo?["linkURL"]) {
                onPopupRequest?(url)
            }
        case "openLinkInDefaultBrowser":
            if let url = contextMenuURL(from: notification.userInfo?["linkURL"]) {
                NSWorkspace.shared.open(url)
            }
        case "moveTabToNewWorkspace":
            if onContextMenuMoveTabToNewWorkspace?() != true {
                NSSound.beep()
            }
        case "inspectElement":
            let x = (notification.userInfo?["x"] as? NSNumber)?.intValue ?? 0
            let y = (notification.userInfo?["y"] as? NSNumber)?.intValue ?? 0
            inspectElementAt(x: x, y: y)
        default:
            break
        }
    }

    private func contextMenuURL(from value: Any?) -> URL? {
        guard let rawURL = value as? String, !rawURL.isEmpty else { return nil }
        return URL(string: rawURL)
    }

    @objc private func handleNavigationStateNotification(_ notification: Notification) {
        guard let browserHandle,
              let notifiedBrowserHandle = notification.userInfo?["browserHandle"] as? NSValue,
              notifiedBrowserHandle.pointerValue == browserHandle else {
            return
        }

        let rawURL = notification.userInfo?["url"] as? String
        let url = rawURL.flatMap(URL.init(string:))
        if let url {
            currentURL = url
        }
        let title = notification.userInfo?["title"] as? String
        let isLoading = notification.userInfo?["isLoading"] as? Bool
        let isFullscreen = notification.userInfo?["isFullscreen"] as? Bool
        let canGoBack = notification.userInfo?["canGoBack"] as? Bool
        let canGoForward = notification.userInfo?["canGoForward"] as? Bool
        let backHistoryURLStrings = notification.userInfo?["backHistoryURLStrings"] as? [String]
        let forwardHistoryURLStrings = notification.userInfo?["forwardHistoryURLStrings"] as? [String]
        onNavigationStateChanged?(
            ChromiumNavigationState(
                url: url,
                title: title,
                isLoading: isLoading,
                isFullscreen: isFullscreen,
                canGoBack: canGoBack,
                canGoForward: canGoForward,
                backHistoryURLStrings: backHistoryURLStrings,
                forwardHistoryURLStrings: forwardHistoryURLStrings
            )
        )
    }

    private func setBrowserFocused(_ focused: Bool) {
        guard let browserHandle else { return }
        cmux_chromium_set_focus(browserHandle, focused)
    }

    private func hideDeveloperToolsChrome() {
        devToolsOpenTask?.cancel()
        devToolsOpenTask = nil
        devToolsVisible = false
        isDraggingDevToolsDivider = false
        devToolsContainerView.isHidden = true
        devToolsDividerView.isHidden = true
        removeDevToolsDividerEventMonitor()
        layoutChromiumSubviews()
        window?.invalidateCursorRects(for: self)
        if let browserHandle {
            cmux_chromium_resize_browser(browserHandle)
        }
    }

    private var ownsFirstResponder: Bool {
        guard let firstResponder = window?.firstResponder else { return false }
        guard let view = firstResponder as? NSView else { return firstResponder === self }
        return view === self || view.isDescendant(of: self)
    }

    @objc private func handleReactGrabMessageNotification(_ notification: Notification) {
        guard let browserHandle,
              let notifiedBrowserHandle = notification.userInfo?["browserHandle"] as? NSValue,
              notifiedBrowserHandle.pointerValue == browserHandle,
              let payload = notification.userInfo?["payload"] as? String,
              let data = payload.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        onReactGrabMessage?(body)
    }

    private struct DevToolsTarget: Decodable {
        let type: String?
        let title: String?
        let url: String?
        let devtoolsFrontendUrl: String?
        let webSocketDebuggerUrl: String?
    }

    private nonisolated static func decodeDevToolsEvaluationResult(_ object: [String: Any]) throws -> Any? {
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw ChromiumJavaScriptError(message: message)
        }
        let result = object["result"] as? [String: Any]
        if let exception = result?["exceptionDetails"] as? [String: Any] {
            let text = (exception["text"] as? String) ?? "Chromium JavaScript failed."
            throw ChromiumJavaScriptError(message: text)
        }
        guard let remoteObject = result?["result"] as? [String: Any] else { return nil }
        if (remoteObject["type"] as? String) == "undefined" {
            return nil
        }
        if let value = remoteObject["value"] {
            return value is NSNull ? nil : value
        }
        if let value = remoteObject["unserializableValue"] as? String {
            return value
        }
        return remoteObject["description"] as? String
    }

    nonisolated static func evaluateJavaScriptWithRemoteDebuggingSync(
        _ script: String,
        pageURL: URL?,
        timeout: TimeInterval
    ) throws -> Any? {
        guard let webSocketURL = resolveDevToolsWebSocketURLSync(for: pageURL) else {
            throw ChromiumJavaScriptError(message: "Chromium DevTools target was not available.")
        }

        let expressionLiteral = jsonLiteral(script)
        let message = """
        {"id":1,"method":"Runtime.evaluate","params":{"expression":\(expressionLiteral),"awaitPromise":true,"returnByValue":true}}
        """
        let data = try sendDevToolsWebSocketMessageSync(message, to: webSocketURL, timeout: timeout)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] as? Int == 1 else {
            throw ChromiumJavaScriptError(message: "Chromium DevTools returned an invalid response.")
        }
        return try decodeDevToolsEvaluationResult(object)
    }

    private nonisolated static func inspectElementWithRemoteDebuggingSync(
        x: Int,
        y: Int,
        pageURL: URL?,
        timeout: TimeInterval
    ) throws {
        guard let webSocketURL = resolveDevToolsWebSocketURLSync(for: pageURL) else {
            throw ChromiumJavaScriptError(message: "Chromium DevTools target was not available.")
        }
        let node = try sendDevToolsCommandSync(
            method: "DOM.getNodeForLocation",
            params: [
                "x": x,
                "y": y,
                "includeUserAgentShadowDOM": true,
                "ignorePointerEventsNone": true,
            ],
            to: webSocketURL,
            timeout: timeout
        )
        let result = node["result"] as? [String: Any]
        if let backendNodeId = result?["backendNodeId"] as? Int {
            _ = try sendDevToolsCommandSync(
                method: "DOM.inspectNode",
                params: ["backendNodeId": backendNodeId],
                to: webSocketURL,
                timeout: timeout
            )
        } else if let nodeId = result?["nodeId"] as? Int {
            _ = try sendDevToolsCommandSync(
                method: "DOM.inspectNode",
                params: ["nodeId": nodeId],
                to: webSocketURL,
                timeout: timeout
            )
        }
    }

    private nonisolated static func sendDevToolsCommandSync(
        method: String,
        params: [String: Any],
        to url: URL,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let object: [String: Any] = [
            "id": 1,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let message = String(decoding: data, as: UTF8.self)
        let responseData = try sendDevToolsWebSocketMessageSync(message, to: url, timeout: timeout)
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              response["id"] as? Int == 1 else {
            throw ChromiumJavaScriptError(message: "Chromium DevTools returned an invalid response.")
        }
        if let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw ChromiumJavaScriptError(message: message)
        }
        return response
    }

    private nonisolated static func sendDevToolsWebSocketMessageSync(_ message: String, to url: URL, timeout: TimeInterval) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        var result: Result<Data, Error>?

        task.resume()
        task.send(.string(message)) { error in
            if let error {
                result = .failure(error)
                semaphore.signal()
                return
            }
            task.receive { received in
                switch received {
                case .success(.string(let text)):
                    result = .success(Data(text.utf8))
                case .success(.data(let data)):
                    result = .success(data)
                case .failure(let error):
                    result = .failure(error)
                @unknown default:
                    result = .failure(ChromiumJavaScriptError(message: "Chromium DevTools returned an unsupported WebSocket message."))
                }
                semaphore.signal()
            }
        }

        guard semaphore.wait(timeout: .now() + max(0.1, timeout)) == .success else {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw ChromiumJavaScriptError(message: "Timed out waiting for Chromium JavaScript result.")
        }

        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        return try result?.get() ?? Data()
    }

    private nonisolated static func devToolsListEndpoint() -> URL {
        URL(string: "http://127.0.0.1:\(cmux_chromium_remote_debugging_port())/json/list")!
    }

    private nonisolated static func resolveDevToolsWebSocketURLSync(for pageURL: URL?) -> URL? {
        let endpoint = devToolsListEndpoint()
        for _ in 0..<20 {
            if let target = targetFromDevToolsSync(endpoint: endpoint, pageURL: pageURL),
               let webSocketDebuggerUrl = target.webSocketDebuggerUrl,
               let url = URL(string: webSocketDebuggerUrl) {
                return url
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private static func resolveDevToolsFrontendURL(for pageURL: URL?) async -> URL? {
        let endpoint = Self.devToolsListEndpoint()
        for _ in 0..<20 {
            if Task.isCancelled { return nil }
            if let url = await fetchDevToolsFrontendURL(endpoint: endpoint, pageURL: pageURL) {
                return url
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private static func fetchDevToolsFrontendURL(endpoint: URL, pageURL: URL?) async -> URL? {
        guard let target = await targetFromDevTools(endpoint: endpoint, pageURL: pageURL) else { return nil }
        if let websocket = target.webSocketDebuggerUrl,
           let range = websocket.range(of: "://") {
            let wsTarget = String(websocket[range.upperBound...])
            return URL(string: "http://127.0.0.1:\(cmux_chromium_remote_debugging_port())/devtools/inspector.html?ws=\(wsTarget)")
        }
        if let frontend = target.devtoolsFrontendUrl, !frontend.isEmpty {
            if frontend.hasPrefix("http://") || frontend.hasPrefix("https://") {
                return URL(string: frontend)
            }
            return URL(string: "http://127.0.0.1:\(cmux_chromium_remote_debugging_port())\(frontend)")
        }
        return nil
    }

    private nonisolated static func targetFromDevToolsSync(endpoint: URL, pageURL: URL?) -> DevToolsTarget? {
        guard let data = try? Data(contentsOf: endpoint),
              let targets = try? JSONDecoder().decode([DevToolsTarget].self, from: data) else {
            return nil
        }
        return selectDevToolsTarget(from: targets, pageURL: pageURL)
    }

    private nonisolated static func targetFromDevTools(endpoint: URL, pageURL: URL?) async -> DevToolsTarget? {
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint),
              let targets = try? JSONDecoder().decode([DevToolsTarget].self, from: data) else {
            return nil
        }
        return selectDevToolsTarget(from: targets, pageURL: pageURL)
    }

    private nonisolated static func selectDevToolsTarget(from targets: [DevToolsTarget], pageURL: URL?) -> DevToolsTarget? {
        let pageURLString = pageURL?.absoluteString
        let pageTargets = targets.filter { target in
            guard target.type == "page" else { return false }
            if target.title == "DevTools" { return false }
            if target.url?.contains("/devtools/") == true { return false }
            return true
        }
        let target = pageTargets.first { target in
            guard let pageURLString else { return false }
            return target.url == pageURLString
        } ?? pageTargets.first

        return target
    }
}
