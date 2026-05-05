import AppKit
import Foundation

enum BrowserEngineAvailability {
    static func canCreateBrowserSurface(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Bool {
        BrowserEngineSettings.currentEngine(defaults: defaults) == .webkit
            || BrowserChromiumRuntime.isSupportedInThisBuild(bundle: bundle, fileManager: fileManager)
    }

    @MainActor
    static func presentUnavailableAlertIfNeeded(_ shouldPresent: Bool) {
        guard shouldPresent else { return }
        BrowserEngineSettings.presentChromiumUnavailableAlert()
    }

    static func browserV2UnavailableResult(method: String) -> TerminalController.V2CallResult {
        .err(
            code: "not_supported",
            message: "\(method) is not supported because Chromium is selected but unavailable",
            data: ["details": BrowserEngineSettings.chromiumUnavailableMessage()]
        )
    }
}

extension Workspace.BrowserPanelCreationPolicy {
    var reportsUnavailableBrowserEngine: Bool {
        self == .userInitiated
    }
}
