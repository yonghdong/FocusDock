import Foundation

struct InstalledApp: Hashable, Identifiable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String { bundleID }
}

/// Apps a user can open, for the setup window's app list.
enum InstalledApps {
    static var defaultFolders: [URL] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Top-level `.app` bundles in `folders`, sorted by name. Skips menu bar agents and
    /// background-only apps, which never come to the front.
    static func scan(_ folders: [URL] = defaultFolders, excluding: Set<String> = []) -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier,
                      !excluding.contains(bid), !seen.contains(bid) else { continue }
                let info = bundle.infoDictionary ?? [:]
                if isTrue(info["LSUIElement"]) || isTrue(info["LSBackgroundOnly"]) { continue }
                seen.insert(bid)
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                apps.append(InstalledApp(bundleID: bid, name: name, url: url))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // Info.plist booleans show up as Bool, NSNumber or "1"/"YES" strings.
    private static func isTrue(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let s as String: return ["1", "yes", "true"].contains(s.lowercased())
        default: return false
        }
    }
}
