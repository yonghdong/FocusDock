import Foundation

/// Sorts a new app or site into a mode with EmbeddingGemma: it joins the mode whose apps, sites and
/// description it's clearly most similar to, or no mode. No generative model, so it runs on any
/// Apple Silicon Mac, and it gets better as the modes' lists grow.
/// From the 70-item eval: 56 right, 9 asked, 5 in the wrong focus mode, none wrongly put in Social
/// (Apple's on-device model on the same items: 49, 5, 10 and 6).
final class ModeMatcher {
    /// A mode's score is the mean similarity of its `k` closest examples.
    static let k = 2
    /// The best mode must beat the runner-up by this much, or FocusDock asks instead.
    static let minMargin: Float = 0.005
    /// A guarded mode (Social) blocks what lands in it, and undoing that takes a wait: be surer.
    static let guardedMargin: Float = 0.03
    /// The group of examples for things that fit no mode.
    static let none = "none"

    /// Built-in examples for the default modes and for things that fit no mode (login pages, mail,
    /// shopping...), so those aren't pulled into whichever mode happens to be closest.
    static let seeds: [String: [String]] = [
        "study": ["online course lecture videos", "homework assignment submission", "flashcards for exam prep",
                  "university course syllabus and grades", "math practice problems", "language learning lessons",
                  "textbook solutions", "lecture notes app"],
        "research": ["machine learning experiment tracking", "API reference documentation", "code repository",
                     "scientific journal articles", "dataset download", "cloud GPU console", "terminal emulator",
                     "database client", "programming library docs"],
        "social": ["social media feed", "chat messenger app", "online community forum", "breaking news headlines",
                   "video streaming site", "memes and funny pictures", "photo sharing app", "live streaming games"],
        none: ["sign in to your account", "single sign-on login page", "email inbox", "online banking",
               "online shopping store", "weather forecast", "maps and directions", "travel booking", "food delivery",
               "password manager", "payment and money transfer", "music player"],
    ]

    struct Anchor: Hashable {
        enum Kind: Hashable { case purpose, site, app, seed }
        let modeID: String
        let kind: Kind
        let text: String
    }

    /// What gets embedded for a new app or site, e.g. "kaggle.com | Kaggle: ..." or "Docker (Mac app)".
    static func text(for subject: Subject) -> String? {
        switch subject {
        case .app(_, let name): return appText(name)
        case .site(let host, let title, _): return title.isEmpty ? host : "\(host) | \(title)"
        case .notification: return nil
        }
    }

    static func appText(_ name: String) -> String { "\(name) (Mac app)" }

    /// Names of the default modes' apps, so they still count as examples when they aren't installed.
    static let knownNames: [String: String] = [
        "com.google.Chrome": "Google Chrome", "notion.id": "Notion", "com.apple.Notes": "Notes",
        "com.anthropic.claudefordesktop": "Claude", "com.apple.Preview": "Preview", "com.goodnotesapp.x": "GoodNotes",
        "net.ankiweb.dtop": "Anki", "dev.zed.Zed": "Zed", "com.apple.Terminal": "Terminal",
        "com.mitchellh.ghostty": "Ghostty", "com.microsoft.VSCode": "Visual Studio Code",
        "com.github.GitHubClient": "GitHub Desktop", "com.apple.dt.Xcode": "Xcode", "org.zotero.zotero": "Zotero",
        "net.sourceforge.skim-app.skim": "Skim", "com.mathworks.matlab": "MATLAB", "com.jetbrains.pycharm": "PyCharm",
        "com.jetbrains.pycharm.ce": "PyCharm CE", "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.tinyspeck.slackmacgap": "Slack", "com.apple.MobileSMS": "Messages", "com.hnc.Discord": "Discord",
        "com.kakao.KakaoTalkMac": "KakaoTalk",
    ]

    /// Each mode's description, the sites and apps listed in that mode only (Chrome, listed in every
    /// mode, tells nothing apart), the built-in examples for the default mode ids, and the no-mode group.
    /// `appNames` has the installed apps' names; an app with no known name is left out.
    static func anchors(modes: [Mode], appNames: [String: String]) -> [Anchor] {
        var siteCount: [String: Int] = [:], appCount: [String: Int] = [:]
        for m in modes {
            Set(m.domains).forEach { siteCount[$0, default: 0] += 1 }
            Set(m.apps).forEach { appCount[$0, default: 0] += 1 }
        }
        var out: [Anchor] = []
        for m in modes {
            out.append(Anchor(modeID: m.id, kind: .purpose, text: m.purpose))
            out += m.domains.filter { siteCount[$0] == 1 }.map { Anchor(modeID: m.id, kind: .site, text: $0) }
            out += m.apps.filter { appCount[$0] == 1 }.compactMap { bid in
                (appNames[bid] ?? knownNames[bid]).map { Anchor(modeID: m.id, kind: .app, text: appText($0)) }
            }
            out += (seeds[m.id] ?? []).map { Anchor(modeID: m.id, kind: .seed, text: $0) }
        }
        out += (seeds[none] ?? []).map { Anchor(modeID: none, kind: .seed, text: $0) }
        return out
    }

    /// The verdict for unit vector `v`. A nil mode means it fits none, or FocusDock isn't sure; the
    /// reason is the closest example ("like github.com", "online banking"), empty when unsure.
    static func decide(_ v: [Float], anchors: [(Anchor, [Float])], guarded: Set<String>) -> Classification {
        func cos(_ a: [Float]) -> Float { zip(v, a).reduce(0) { $0 + $1.0 * $1.1 } }
        var byMode: [String: [(Anchor, Float)]] = [:]
        for (a, vec) in anchors { byMode[a.modeID, default: []].append((a, cos(vec))) }
        let ranked = byMode.map { id, scored -> (id: String, score: Float, nearest: Anchor) in
            let top = scored.sorted { $0.1 > $1.1 }
            let best = top.prefix(k)
            return (id, best.map(\.1).reduce(0, +) / Float(best.count), top[0].0)
        }.sorted { $0.score > $1.score }
        guard let first = ranked.first else { return Classification(modeID: nil, reason: "") }
        let margin = first.score - (ranked.count > 1 ? ranked[1].score : 0)
        let needed = guarded.contains(first.id) ? guardedMargin : minMargin
        guard margin >= needed else { return Classification(modeID: nil, reason: "") }
        let reason: String
        switch first.nearest.kind {
        case .purpose: reason = ""
        case .seed: reason = first.nearest.text
        case .site: reason = "like \(first.nearest.text)"
        case .app: reason = "like \(first.nearest.text.replacingOccurrences(of: " (Mac app)", with: ""))"
        }
        return Classification(modeID: first.id == none ? nil : first.id, reason: reason)
    }

    private let embeddings: EmbeddingService
    private var vectors: [String: [Float]] = [:]
    private let lock = NSLock()

    init(embeddings: EmbeddingService) {
        self.embeddings = embeddings
    }

    var isAvailable: Bool { embeddings.isAvailable }

    /// Nil when the model or server isn't available, so the caller can fall back to another classifier.
    /// `appNames` maps the modes' bundle IDs to display names (looked up on the main thread).
    func classify(_ subject: Subject, modes: [Mode], appNames: [String: String]) async -> Classification? {
        guard isAvailable, let text = Self.text(for: subject), let v = await embeddings.embed(text) else { return nil }
        var pairs: [(Anchor, [Float])] = []
        for a in Self.anchors(modes: modes, appNames: appNames) {
            if let vec = vector(for: a.text) { pairs.append((a, vec)); continue }
            // The first verdict embeds every example (about 90, a second or two); later ones reuse them.
            guard let vec = await embeddings.embed(a.text) else { return nil }
            store(vec, for: a.text)
            pairs.append((a, vec))
        }
        return Self.decide(v, anchors: pairs, guarded: Set(AppConfig.guardedModeIDs(in: modes)))
    }

    // NSLock can't be used directly from async code; keep locking in sync helpers.
    private func vector(for text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        return vectors[text]
    }

    private func store(_ vector: [Float], for text: String) {
        lock.lock(); defer { lock.unlock() }
        vectors[text] = vector
    }
}
