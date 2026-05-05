import Foundation
import AppKit

enum BrowserEngine: String, CaseIterable, Identifiable {
    case webkit
    case chromium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .webkit:
            return String(localized: "browser.engine.webkit", defaultValue: "WebKit")
        case .chromium:
            return String(localized: "browser.engine.chromium", defaultValue: "Chromium")
        }
    }
}

enum BrowserEngineSettings {
    static let engineKey = "browserEngine"
    static let defaultEngine: BrowserEngine = .chromium

    static func engine(for rawValue: String?) -> BrowserEngine {
        guard let rawValue, let engine = BrowserEngine(rawValue: rawValue) else {
            return defaultEngine
        }
        return engine
    }

    static func currentEngine(defaults: UserDefaults = .standard) -> BrowserEngine {
        engine(for: defaults.string(forKey: engineKey))
    }

    static func chromiumUnavailableMessage() -> String {
        String(
            localized: "browser.engine.chromium.unavailable",
            defaultValue: "Chromium browser panes require a bundled CEF runtime and native adapter. This build does not include them yet."
        )
    }

    @MainActor
    static func presentChromiumUnavailableAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "browser.engine.chromium.unavailable.title", defaultValue: "Chromium Browser Unavailable")
        alert.informativeText = chromiumUnavailableMessage()
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }
}

enum BrowserChromiumRuntime {
    static func isSupportedInThisBuild(bundle: Bundle = .main, fileManager: FileManager = .default) -> Bool {
        isBundled(bundle: bundle, fileManager: fileManager) && cmux_chromium_runtime_available()
    }

    static func isBundled(bundle: Bundle = .main, fileManager: FileManager = .default) -> Bool {
        guard let privateFrameworksURL = bundle.privateFrameworksURL else { return false }
        return fileManager.fileExists(
            atPath: privateFrameworksURL
                .appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
                .path
        )
    }
}
