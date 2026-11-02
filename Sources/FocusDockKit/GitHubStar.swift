import Foundation

/// Stars FocusDock's repository through the GitHub CLI when `gh` is installed and signed in. GitHub has
/// no link that stars a repository, and FocusDock keeps no GitHub login of its own. Runs only when the
/// person presses Star on GitHub; without `gh` the page opens instead.
enum GitHubStar {
    static let repo = "yonghdong/FocusDock"

    /// Where Homebrew and the official installer put it. GUI apps don't get the shell's PATH.
    static var executable: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Calls back on the main queue: true once the repository is starred.
    static func star(_ done: @escaping (Bool) -> Void) {
        guard let gh = executable else { done(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gh)
            p.arguments = ["api", "--method", "PUT", "/user/starred/\(repo)", "--silent"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            var starred = false
            if (try? p.run()) != nil {
                let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
                p.waitUntilExit()
                watchdog.cancel()
                starred = p.terminationReason == .exit && p.terminationStatus == 0
            }
            if !starred { NSLog("FocusDock: gh couldn't star the repository (exit \(p.terminationStatus)); opening the page") }
            DispatchQueue.main.async { done(starred) }
        }
    }
}
