import AppKit
import CoreServices

/// What FocusDock needs from System Settings, for the setup window.
enum Permissions {
    enum Automation: Equatable {
        case allowed, denied, notAsked, notRunning
    }

    /// Full Disk Access, checked by actually reading Notification Center's database.
    static var canReadNotifications: Bool { NotificationFeed.canRead() }

    /// Whether FocusDock may send Apple Events to `bid` (needed to read and steer browser tabs).
    /// With `ask`, shows macOS's prompt if the user hasn't decided yet; that blocks, so call it off the main thread.
    static func automation(for bid: String, ask: Bool) -> Automation {
        let target = NSAppleEventDescriptor(bundleIdentifier: bid)
        guard let desc = target.aeDesc else { return .notRunning }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .notRunning   // procNotFound: the browser isn't running
        }
    }

    static func openFullDiskAccessSettings() { openSettings("Privacy_AllFiles") }
    static func openAutomationSettings() { openSettings("Privacy_Automation") }

    private static func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
