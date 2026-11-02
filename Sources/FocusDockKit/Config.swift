import Foundation

/// Rules for leaving a mode: how long you must wait before the switch lands.
/// The wait can't be shortened, only cancelled.
struct ExitRule: Codable, Hashable {
    var defaultDelay: Double
    var delays: [String: Double] = [:]

    func delay(to modeID: String) -> Double { delays[modeID] ?? defaultDelay }
}

struct Mode: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// SF Symbol name
    var symbol: String
    /// Hex color, e.g. "#E8912D"
    var color: String
    /// One line used by the classifier to decide what fits this mode.
    var purpose: String
    /// Bundle identifiers shown in the dock and allowed while in this mode.
    var apps: [String]
    /// Domains that belong to this mode (suffix match, "x.com" matches "mobile.x.com").
    var domains: [String]
    var exit: ExitRule
    /// Optional macOS Shortcut to run when the mode becomes active
    /// (e.g. one that turns on a matching macOS Focus, which is what actually holds notifications).
    var shortcut: String?
}

struct ClassifierConfig: Codable, Hashable {
    /// Sorts new apps and sites: "local" (EmbeddingGemma on this Mac), "jev" (TypeSafe), "apple"
    /// (on-device, macOS 26+), "claude", "auto" (local > jev > apple > claude), "off"
    var provider: String = "local"
    var typesafeAPIKey: String = ""
    var typesafeModel: String = "jev-latest"
    /// Below this Jev confidence the item is treated as "not in any mode".
    var minConfidence: Double = 0.5
    var anthropicAPIKey: String = ""
    var anthropicModel: String = "claude-haiku-5-5"
    /// For notifications that the rules and the reaction memory leave undecided: "local" (the on-device
    /// model; nothing leaves the Mac), "auto" (Claude Code if installed, else on-device), "claudeCode",
    /// any of the providers above, or "off". Local by default: notification text is private.
    var triageProvider: String = "local"

    init() {}

    // Tolerant decoding so older/partial config files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? provider
        typesafeAPIKey = try c.decodeIfPresent(String.self, forKey: .typesafeAPIKey) ?? ""
        typesafeModel = try c.decodeIfPresent(String.self, forKey: .typesafeModel) ?? typesafeModel
        minConfidence = try c.decodeIfPresent(Double.self, forKey: .minConfidence) ?? minConfidence
        anthropicAPIKey = try c.decodeIfPresent(String.self, forKey: .anthropicAPIKey) ?? ""
        anthropicModel = try c.decodeIfPresent(String.self, forKey: .anthropicModel) ?? anthropicModel
        triageProvider = try c.decodeIfPresent(String.self, forKey: .triageProvider) ?? triageProvider
    }
}

/// A reaction to a notification card, given back to the classifier as an example of what matters
/// to this user. Kept short, and only in config.json on this Mac.
struct NotificationExample: Codable, Hashable, Identifiable {
    var app: String
    var sender: String
    /// The notification text, at most 80 characters.
    var text: String
    /// What the classifier said about it at the time; it becomes the example's reason.
    var reason: String
    var important: Bool
    var date: Date

    var id: String { "\(app)|\(sender)|\(text)" }
}

/// An app or site the classifier (or "Allow in") added to a mode, kept so it can be undone.
struct LearnedItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case app, site }
    var kind: Kind
    /// Bundle ID or domain.
    var value: String
    var modeID: String
    var date: Date

    var id: String { "\(kind.rawValue):\(value):\(modeID)" }
}

struct AppConfig: Codable {
    var modes: [Mode]
    /// Apps that never trigger a prompt (bundle IDs).
    var alwaysAllowed: [String]
    /// Browsers whose active tab URL is watched.
    var browsers: [String]
    var hideOtherAppsOnEnter: Bool
    var launchAppsOnEnter: Bool
    var classifier: ClassifierConfig
    /// Most recent last.
    var learned: [LearnedItem] = []
    /// Allowed in their modes but not shown in the dock (bundle IDs).
    var dockHidden: [String] = []
    /// Most recent last. The newest ones go into the classifier's instructions.
    var notificationExamples: [NotificationExample] = []
    /// Short notes on what matters to the user, like a CLAUDE.md, kept up to date from reactions by Claude.
    var notificationProfile: String = ""
    /// Reactions after this aren't in the notes yet.
    var profileUpdatedAt: Date = .distantPast
    /// Names whose notifications always get a card, from any app and in any mode.
    var vips: [String] = []
    /// Apps and sites taken out of a guarded mode (Social). They stay distractions, so leaving
    /// Social doesn't make them easier to use in a focus mode than going to Social itself.
    var distractions: [String] = []

    func mode(_ id: String) -> Mode? { modes.first { $0.id == id } }

    func modeOwning(bundleID: String) -> Mode? {
        modes.first { $0.apps.contains(bundleID) }
    }

    func modeOwning(host: String) -> Mode? {
        modes.first { m in m.domains.contains { Self.host(host, matches: $0) } }
    }

    static func host(_ host: String, matches domain: String) -> Bool {
        let h = host.lowercased(), d = domain.lowercased()
        return h == d || h.hasSuffix("." + d)
    }

    // MARK: Guarded modes and corrections

    /// A mode some other mode makes you wait to enter (Social). What's in it is a distraction.
    func isGuarded(_ modeID: String) -> Bool { Self.isGuarded(modeID, in: modes) }

    var guardedModeIDs: [String] { Self.guardedModeIDs(in: modes) }

    static func isGuarded(_ modeID: String, in modes: [Mode]) -> Bool {
        modes.contains { $0.id != modeID && $0.exit.delay(to: modeID) > 0 }
    }

    static func guardedModeIDs(in modes: [Mode]) -> [String] { modes.map(\.id).filter { isGuarded($0, in: modes) } }

    /// Loosening a correction takes as long as the longest wait into a guarded mode.
    var correctionWait: Double {
        modes.flatMap { from in guardedModeIDs.filter { $0 != from.id }.map { from.exit.delay(to: $0) } }.max() ?? 0
    }

    /// Modes listing exactly this app (bundle ID) or site (domain).
    func modeIDs(listing kind: LearnedItem.Kind, _ value: String) -> Set<String> {
        Set(modes.filter { (kind == .app ? $0.apps : $0.domains).contains(value) }.map(\.id))
    }

    /// In a guarded mode now, or taken out of one. A site counts if its host falls under such a domain.
    func isDistraction(_ kind: LearnedItem.Kind, _ value: String) -> Bool {
        let guarded = modes.filter { isGuarded($0.id) }
        switch kind {
        case .app:
            return distractions.contains(value) || guarded.contains { $0.apps.contains(value) }
        case .site:
            let domains = distractions + guarded.flatMap(\.domains)
            return domains.contains { Self.host(value, matches: $0) }
        }
    }

    /// Giving `value` exactly `newModes` would let a distraction into a focus mode: that takes the wait.
    /// Everything else (into Social, between focus modes, taking things out) is immediate.
    func needsWait(_ kind: LearnedItem.Kind, _ value: String, newModes: Set<String>) -> Bool {
        let added = newModes.subtracting(modeIDs(listing: kind, value))
        return isDistraction(kind, value) && added.contains { !isGuarded($0) }
    }
}

// In an extension so the memberwise initializer stays.
extension AppConfig {
    // Tolerant decoding: fields added after the first release may be missing from a user's file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modes = try c.decode([Mode].self, forKey: .modes)
        alwaysAllowed = try c.decode([String].self, forKey: .alwaysAllowed)
        browsers = try c.decode([String].self, forKey: .browsers)
        hideOtherAppsOnEnter = try c.decode(Bool.self, forKey: .hideOtherAppsOnEnter)
        launchAppsOnEnter = try c.decode(Bool.self, forKey: .launchAppsOnEnter)
        classifier = try c.decode(ClassifierConfig.self, forKey: .classifier)
        learned = try c.decodeIfPresent([LearnedItem].self, forKey: .learned) ?? []
        dockHidden = try c.decodeIfPresent([String].self, forKey: .dockHidden) ?? []
        notificationExamples = try c.decodeIfPresent([NotificationExample].self, forKey: .notificationExamples) ?? []
        notificationProfile = try c.decodeIfPresent(String.self, forKey: .notificationProfile) ?? ""
        profileUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .profileUpdatedAt) ?? .distantPast
        vips = try c.decodeIfPresent([String].self, forKey: .vips) ?? []
        distractions = try c.decodeIfPresent([String].self, forKey: .distractions) ?? []
    }
}

enum ConfigStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FocusDock", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load(from url: URL = fileURL) -> AppConfig {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: url) else {
            let cfg = defaultConfig
            save(cfg, to: url)
            return cfg
        }
        do { return try JSONDecoder().decode(AppConfig.self, from: data) }
        catch {
            // Leave the user's file alone so a typo can be fixed and reloaded. Also keep a copy,
            // since a later save (e.g. learn) would write the in-memory defaults over it.
            NSLog("FocusDock: config parse error, using defaults (file kept as config.invalid.json): \(error)")
            let backup = url.deletingPathExtension().appendingPathExtension("invalid.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return defaultConfig
        }
    }

    static func save(_ cfg: AppConfig, to url: URL = fileURL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(cfg) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static let defaultConfig = AppConfig(
        modes: [
            Mode(id: "study", name: "Study", symbol: "book.fill", color: "#E8912D",
                 purpose: "Study: classes and lectures, coursework and assignments, reading textbooks and course material, exam prep, taking notes",
                 apps: ["com.google.Chrome", "notion.id", "com.apple.Notes", "com.anthropic.claudefordesktop",
                        "com.apple.Preview", "com.goodnotesapp.x", "net.ankiweb.dtop"],
                 domains: ["docs.google.com", "notion.so", "claude.ai", "overleaf.com", "arxiv.org", "wikipedia.org",
                           "coursera.org", "edx.org", "khanacademy.org", "klms.kaist.ac.kr"],
                 exit: ExitRule(defaultDelay: 0, delays: ["social": 30])),
            Mode(id: "research", name: "Research", symbol: "flask.fill", color: "#2F7CF6",
                 purpose: "Research: reading and searching papers, experiments and data analysis, programming, ML and lab tools, technical documentation, writing papers",
                 apps: ["com.google.Chrome", "dev.zed.Zed", "com.apple.Terminal", "com.mitchellh.ghostty",
                        "com.microsoft.VSCode", "com.github.GitHubClient", "com.apple.dt.Xcode",
                        "com.anthropic.claudefordesktop", "org.zotero.zotero", "net.sourceforge.skim-app.skim",
                        "com.apple.Preview", "com.mathworks.matlab", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
                        "com.todesktop.230313mzl4w4u92"],
                 domains: ["github.com", "stackoverflow.com", "docs.python.org", "claude.ai", "arxiv.org",
                           "scholar.google.com", "semanticscholar.org", "openreview.net", "overleaf.com",
                           "huggingface.co", "wandb.ai", "pytorch.org", "developer.apple.com", "calendar.google.com"],
                 exit: ExitRule(defaultDelay: 0, delays: ["social": 15])),
            Mode(id: "social", name: "Social", symbol: "bubble.left.and.bubble.right.fill", color: "#E5484D",
                 purpose: "Messaging, social media, chat, news feeds, video",
                 apps: ["com.google.Chrome", "com.tinyspeck.slackmacgap", "com.apple.MobileSMS",
                        "com.hnc.Discord", "com.kakao.KakaoTalkMac"],
                 domains: ["x.com", "twitter.com", "instagram.com", "youtube.com", "reddit.com",
                           "facebook.com", "slack.com", "news.ycombinator.com"],
                 exit: ExitRule(defaultDelay: 0)),
        ],
        alwaysAllowed: ["com.apple.finder", "com.apple.systempreferences", "com.apple.SystemPreferences",
                        "com.apple.ActivityMonitor", "com.apple.Spotlight", "com.focusdock.app",
                        "com.apple.loginwindow", "com.apple.dock",
                        // Opened by FocusDock's own setup (Do Not Disturb shortcuts); never a mode's app.
                        "com.apple.shortcuts"],
        browsers: ["com.google.Chrome", "com.apple.Safari", "com.brave.Browser",
                   "com.microsoft.edgemac", "company.thebrowser.Browser"],
        hideOtherAppsOnEnter: true,
        launchAppsOnEnter: false,
        classifier: ClassifierConfig()
    )
}
