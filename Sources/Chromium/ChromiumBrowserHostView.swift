import Foundation
import AppKit

struct ChromiumNavigationState {
    let url: URL?
    let title: String?
    let isLoading: Bool?
    let canGoBack: Bool
    let canGoForward: Bool
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
    private var devToolsOpenTask: Task<Void, Never>?
    private var devToolsDividerEventMonitor: Any?
    private var devToolsDividerTrackingArea: NSTrackingArea?
    private var pendingJavaScript: [String] = []
    private var isObservingReactGrabMessages = false
    private let pageContainerView = NSView(frame: .zero)
    private let devToolsContainerView = NSView(frame: .zero)
    private lazy var devToolsDividerView = DevToolsDividerView(hostView: self)
    private var devToolsVisible = false
    private var isDraggingDevToolsDivider = false
    private var devToolsWidth: CGFloat = ChromiumBrowserHostView.initialDevToolsWidth()
    private let devToolsPreferredWidth: CGFloat = 520
    private let devToolsMinimumWidth: CGFloat = 360
    private let devToolsMinimumPageWidth: CGFloat = 160
    private static let devToolsDividerCursor = NSCursor.resizeLeftRight
    private static let devToolsWidthDefaultsKey = "chromiumDevToolsAttachedWidth"
    private static let reactGrabMessageNotification = Notification.Name("CmuxChromiumReactGrabMessageNotification")
    private static let navigationStateNotification = Notification.Name("CmuxChromiumNavigationStateNotification")
    var onReactGrabMessage: (([String: Any]) -> Void)?
    var onNavigationStateChanged: ((ChromiumNavigationState) -> Void)?

    init(initialURL: URL?) {
        pendingURL = initialURL
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
            cmux_chromium_close_browser(devToolsBrowserHandle)
        }
        if let browserHandle {
            cmux_chromium_close_browser(browserHandle)
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
            if !isObservingReactGrabMessages {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleReactGrabMessageNotification(_:)),
                    name: Self.reactGrabMessageNotification,
                    object: nil
                )
                isObservingReactGrabMessages = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleNavigationStateNotification(_:)),
                    name: Self.navigationStateNotification,
                    object: nil
                )
            }
            pendingJavaScript.forEach { cmux_chromium_execute_javascript(browserHandle, $0) }
            pendingJavaScript.removeAll()
        }
    }

    @objc private func handleNavigationStateNotification(_ notification: Notification) {
        guard let browserHandle,
              let notifiedBrowserHandle = notification.userInfo?["browserHandle"] as? NSValue,
              notifiedBrowserHandle.pointerValue == browserHandle else {
            return
        }

        let rawURL = notification.userInfo?["url"] as? String
        let url = rawURL.flatMap(URL.init(string:))
        let title = notification.userInfo?["title"] as? String
        let isLoading = notification.userInfo?["isLoading"] as? Bool
        let canGoBack = (notification.userInfo?["canGoBack"] as? Bool) ?? false
        let canGoForward = (notification.userInfo?["canGoForward"] as? Bool) ?? false
        onNavigationStateChanged?(
            ChromiumNavigationState(
                url: url,
                title: title,
                isLoading: isLoading,
                canGoBack: canGoBack,
                canGoForward: canGoForward
            )
        )
    }

    private func setBrowserFocused(_ focused: Bool) {
        guard let browserHandle else { return }
        cmux_chromium_set_focus(browserHandle, focused)
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

    private static func resolveDevToolsFrontendURL(for pageURL: URL?) async -> URL? {
        let endpoint = URL(string: "http://127.0.0.1:9223/json/list")!
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
        guard let (data, _) = try? await URLSession.shared.data(from: endpoint),
              let targets = try? JSONDecoder().decode([DevToolsTarget].self, from: data) else {
            return nil
        }

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

        guard let target else { return nil }
        if let websocket = target.webSocketDebuggerUrl,
           let wsURL = URL(string: websocket),
           let range = websocket.range(of: "://") {
            let wsTarget = String(websocket[range.upperBound...])
            return URL(string: "http://127.0.0.1:9223/devtools/inspector.html?ws=\(wsTarget)")
        }
        if let frontend = target.devtoolsFrontendUrl, !frontend.isEmpty {
            if frontend.hasPrefix("http://") || frontend.hasPrefix("https://") {
                return URL(string: frontend)
            }
            return URL(string: "http://127.0.0.1:9223\(frontend)")
        }
        return nil
    }
}
