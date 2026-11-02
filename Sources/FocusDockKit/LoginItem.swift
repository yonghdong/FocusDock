import Foundation
import ServiceManagement

/// Opens FocusDock when you log in, so the dock is there whenever the Mac starts. On unless turned off
/// in Setup or the menu bar. Checked on every launch: each new build or update is a new app to macOS,
/// which can drop the login item.
enum LoginItem {
    enum State { case on, off, needsApproval, unavailable }

    static let wantedKey = "openAtLogin"

    /// `swift run` has no app bundle to open at login.
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var state: State {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    static func isWanted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: wantedKey) as? Bool ?? true
    }

    /// Turned off in System Settings shows up as `needsApproval`: that choice is left alone.
    static func shouldRegister(wanted: Bool, state: State) -> Bool { wanted && state == .off }

    static func sync(_ defaults: UserDefaults = .standard) {
        if shouldRegister(wanted: isWanted(defaults), state: state) { apply(true) }
    }

    static func setWanted(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: wantedKey)
        apply(on)
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    private static func apply(_ on: Bool) {
        guard isBundled else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("FocusDock: open at login \(on ? "on" : "off") failed: \(error.localizedDescription)")
        }
    }
}
