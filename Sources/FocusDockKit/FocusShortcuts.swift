import AppKit

/// Turns Do Not Disturb on and off through two Shortcuts, since macOS has no public API for
/// third-party apps to change Focus. FocusDock builds and signs them on the user's own Mac
/// (a signed file carries its signer's identity, so none ships in the repo) and Shortcuts asks
/// the user to add each one.
enum FocusShortcuts {
    static let onName = "FocusDock DND On"
    static let offName = "FocusDock DND Off"

    /// A shortcut with a single "Set Focus" action turning Do Not Disturb on or off until changed.
    /// Only "Enabled": that's what Shortcuts itself saves for Do Not Disturb (the default Focus), and
    /// naming the mode explicitly ("FocusModes") makes macOS 26 report that it doesn't exist.
    static func workflow(enable: Bool) -> [String: Any] {
        [
            "WFWorkflowActions": [[
                "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
                "WFWorkflowActionParameters": ["Enabled": enable ? 1 : 0],
            ]],
            "WFWorkflowClientVersion": "2607.0.2",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59446],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowOutputContentItemClasses": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFWorkflowHasShortcutInputVariables": false,
        ]
    }

    /// Opens a shortcut in the Shortcuts app (where it can be deleted; nothing else can).
    static func view(_ name: String) { _ = shell(["view", name]) }

    /// Whether both shortcuts are in the user's library. Runs `shortcuts list`; call off the main thread.
    static func installed() -> Bool {
        let names = Set(shell(["list"]).split(separator: "\n").map(String.init))
        return names.contains(onName) && names.contains(offName)
    }

    /// Builds, signs and opens both shortcuts. Completion runs on the main queue with an error message, if any.
    static func install(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FocusDockShortcuts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var signed: [URL] = []
            for (name, enable) in [(onName, true), (offName, false)] {
                let unsigned = dir.appendingPathComponent("\(name).unsigned.shortcut")
                let output = dir.appendingPathComponent("\(name).shortcut")
                try? FileManager.default.removeItem(at: output)
                guard let data = try? PropertyListSerialization.data(
                        fromPropertyList: workflow(enable: enable), format: .binary, options: 0),
                      (try? data.write(to: unsigned)) != nil else {
                    DispatchQueue.main.async { completion("Couldn't write the shortcut file.") }
                    return
                }
                _ = shell(["sign", "--mode", "anyone", "--input", unsigned.path, "--output", output.path])
                guard FileManager.default.fileExists(atPath: output.path) else {
                    DispatchQueue.main.async { completion("Signing failed. Are you signed in to iCloud?") }
                    return
                }
                signed.append(output)
            }
            DispatchQueue.main.async {
                signed.forEach { NSWorkspace.shared.open($0) }
                completion(nil)
            }
        }
    }

    /// Runs a shortcut by name without waiting for it.
    static func run(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", name]
        try? p.run()
        // Now and then a run never exits even though Focus changed; don't let those pile up.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if p.isRunning { p.terminate() } }
    }

    private static func shell(_ args: [String]) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: out, encoding: .utf8) ?? ""
    }
}
