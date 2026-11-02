import Foundation

/// Reads and steers the active tab of supported browsers through AppleScript.
/// First use triggers macOS's "FocusDock wants to control Chrome" Automation prompt.
final class BrowserBridge {
    private let queue = DispatchQueue(label: "focusdock.applescript")

    private static func isSafari(_ bid: String) -> Bool { bid == "com.apple.Safari" }

    private static func tabRef(_ bid: String) -> String {
        isSafari(bid) ? "current tab of front window" : "active tab of front window"
    }

    private static func titleProp(_ bid: String) -> String { isSafari(bid) ? "name" : "title" }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Calls back on the main queue with (url, title), or nil if no window / no permission.
    func activeTab(_ bid: String, completion: @escaping ((url: String, title: String)?) -> Void) {
        let src = """
        tell application id "\(bid)"
            if (count of windows) = 0 then return ""
            set t to \(Self.tabRef(bid))
            return (URL of t) & linefeed & (\(Self.titleProp(bid)) of t)
        end tell
        """
        run(src) { out in
            guard let out, !out.isEmpty else { completion(nil); return }
            let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let url = parts.first.map(String.init) ?? ""
            let title = parts.count > 1 ? String(parts[1]) : ""
            completion(url.isEmpty ? nil : (url, title))
        }
    }

    func setURL(_ bid: String, _ url: String) {
        run("tell application id \"\(bid)\" to set URL of \(Self.tabRef(bid)) to \"\(Self.escape(url))\"") { _ in }
    }

    func closeTab(_ bid: String) {
        run("tell application id \"\(bid)\" to close \(Self.tabRef(bid))") { _ in }
    }

    private func run(_ source: String, completion: @escaping (String?) -> Void) {
        queue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let err, (err["NSAppleScriptErrorNumber"] as? Int) != -1728 {
                // -1743 = not authorized; user must allow in System Settings > Privacy > Automation
                NSLog("FocusDock AppleScript: \(err)")
            }
            let s = result?.stringValue
            DispatchQueue.main.async { completion(s) }
        }
    }
}
