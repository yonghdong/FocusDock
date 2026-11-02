import Foundation

/// Runs Claude through the user's Claude Code CLI (`claude -p`), so FocusDock needs no API key of its
/// own: it uses whatever account Claude Code is signed in with. (`--bare` would start faster but only
/// accepts an API key, so it isn't used.)
enum ClaudeCode {
    /// Where `claude` usually lives. GUI apps don't get the login shell's PATH, so look directly.
    static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                "\(home)/.claude/local/claude"]
    }

    static var executable: String? {
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        lock.lock(); defer { lock.unlock() }
        if shellLookup == nil { shellLookup = .some(lookupInLoginShell()) }
        return shellLookup ?? nil
    }

    private static let lock = NSLock()
    private static var shellLookup: String??   // nil until looked up once

    /// npm, nvm, volta and the like install it where only the user's shell knows to look.
    private static func lookupInLoginShell() -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v claude"]   // -i too: nvm usually loads from .zshrc
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        // rc files may print things first; the path is the last line.
        let path = String(data: data, encoding: .utf8)?.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    enum Status: Equatable { case notInstalled, ready, failing }

    /// Installed and actually answering (signed in). Sends one tiny request.
    static func check() async -> Status {
        guard executable != nil else { return .notInstalled }
        return await ask(system: "Reply with exactly: ok", prompt: "ping", timeout: 30) == nil ? .failing : .ready
    }

    /// An empty folder to run in, so no project's CLAUDE.md gets pulled in.
    private static var workDir: URL {
        let dir = ConfigStore.directory.appendingPathComponent("claude-run", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One headless turn with no tools, MCP servers or saved session. Nil if Claude Code is missing,
    /// fails, or takes longer than `timeout`.
    static func ask(system: String, prompt: String, model: String = "haiku", timeout: TimeInterval = 60) async -> String? {
        guard let exe = executable else { return nil }
        let args = ["-p", "--model", model, "--system-prompt", system, "--tools", "", "--strict-mcp-config",
                    "--no-session-persistence", "--output-format", "json", prompt]
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process(), out = Pipe()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                // An npm-installed claude runs on node, found via PATH, which a GUI app doesn't have.
                var env = ProcessInfo.processInfo.environment
                let dir = (exe as NSString).deletingLastPathComponent
                env["PATH"] = [dir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: ":")
                p.environment = env
                p.currentDirectoryURL = workDir
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: nil); return }
                let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                watchdog.cancel()
                let text = result(fromJSON: data)
                if text == nil { NSLog("FocusDock: Claude Code call failed (exit \(p.terminationStatus))") }
                cont.resume(returning: text)
            }
        }
    }

    /// The reply text from `--output-format json`, or nil for an error result.
    static func result(fromJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["is_error"] as? Bool != true,
              let text = obj["result"] as? String else { return nil }
        return text
    }
}
