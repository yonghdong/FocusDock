import AppKit
import Combine

/// How an app that just came to the front is treated.
enum AppVerdict: Equatable {
    /// FocusDock itself and always-allowed apps.
    case ignore
    /// Judged by its active tab instead.
    case browser
    case allowed
    /// Belongs to another mode (mode ID).
    case otherMode(String)
    /// In no mode; ask the classifier.
    case unknown
}

/// Watches what the user opens (apps and browser tabs) and raises prompts
/// when it falls outside the current mode. Also applies mode-entry effects.
final class FocusGuard: NSObject {
    private let store: ModeStore
    /// Also used by Setup's Suggest, so there's one embedding server.
    let classifier: Classifier
    private let browser = BrowserBridge()
    private let feed = NotificationFeed()
    private let cover = PageCover()
    private let embeddings: EmbeddingService
    /// Past reactions with their embeddings, for deciding look-alikes on this Mac.
    let memory = ReactionMemory()
    let downloader = ModelDownloader()

    private var lastAllowedApp: NSRunningApplication?
    private var lastAppByMode: [String: String] = [:]   // mode ID -> bundle ID to bring forward on entry
    private var blockedAt = Date.distantPast
    private var lastAllowedURL: [String: String] = [:]   // browser bundle ID -> URL
    private var lastSeenHost: [String: String] = [:]     // browser bundle ID -> host
    private var pollTimer: Timer?
    private var polling = false
    /// The other mode's site being blurred, kept through a pending switch to that mode.
    private var coverTarget: (host: String, browser: String, modeID: String)?
    private var storeSub: AnyCancellable?
    /// Sender key -> when a question card was last shown, so one chatty chat doesn't keep asking.
    private var askedAt: [String: Date] = [:]
    private var updatingProfile = false

    init(store: ModeStore) {
        self.store = store
        let embeddings = EmbeddingService()
        self.embeddings = embeddings
        classifier = Classifier(matcher: ModeMatcher(embeddings: embeddings))
        super.init()
        store.onStay = { [weak self] in self?.stay($0) }
        store.onActivate = { [weak self] in self?.modeActivated($0) }
        store.onReaction = { [weak self] n, important in
            self?.updateProfile()
            self?.memorize(n, important: important)
        }
        store.onForget = { [weak self] kind, value in self?.classifier.forget(kind, value) }
        store.onMovedHere = { [weak self] subject in self?.movedHere(subject) }
        // objectWillChange fires before the change lands; look on the next runloop pass.
        storeSub = store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateCover() }
    }

    private var config: AppConfig { store.config }
    private var selfID: String { Bundle.main.bundleIdentifier ?? "com.focusdock.app" }
    /// False until Full Disk Access lets us read Notification Center's history.
    var notificationsReadable: Bool { feed.isReadable }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Twice a second so the card shows up soon after a tab lands on another mode's site.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollBrowser()
        }
        feed.start { [weak self] in self?.notificationsArrived($0) }
        updateProfile()   // catch up on reactions from before this launch
        // First run: fetch the embedding model in the background (once, 318 MB).
        EmbeddingService.cleanUpLeftover()
        if EmbeddingService.serverURL != nil { downloader.start() }
    }

    func shutdown() { embeddings.stop() }

    // MARK: Notifications

    private func notificationsArrived(_ notifications: [HeldNotification]) {
        for n in notifications {
            let vip = Self.isVIP(n, vips: config.vips)
            let modeID = Self.holdingMode(for: n.bundleID, current: store.current, config: config, selfID: selfID)
            // Apps of the current mode (or of none) notify as usual, except VIPs, who always get a card.
            guard vip || modeID != nil else { continue }
            triageAndPrompt(n, modeID: modeID, vip: vip)
        }
    }

    private func triageAndPrompt(_ n: HeldNotification, modeID: String?, vip: Bool) {
        let cfg = config.classifier
        let appName = AppLauncher.name(for: n.bundleID)
        let examples = Array(config.notificationExamples.suffix(12).reversed())   // newest first
        let profile = config.notificationProfile, pending = store.pendingExamples
        let reactions = memory.items
        Task { [weak self] in
            guard let self else { return }
            // Rules, then the user's own reactions and the built-in examples (all on this Mac), then a
            // model only if the user chose one (Claude). Whatever is still undecided gets asked about.
            var triage: Triage?
            if var rule = Classifier.mealInvite(n) {
                rule.source = "rule"
                triage = rule
            } else if !vip, let remembered = await self.memoryVerdict(n, reactions: reactions) {
                triage = remembered
            } else if !vip {
                triage = await self.classifier.triage(n, appName: appName, config: cfg, examples: examples,
                                                      profile: profile, pending: pending)
            }
            let verdict = triage
            await MainActor.run {
                let heldFor = modeID == self.store.currentID ? nil : modeID   // mode switched meanwhile
                let key = n.bundleID.lowercased() + "|" + n.title
                let canAsk = cfg.triageProvider != "off" && Date().timeIntervalSince(self.askedAt[key] ?? .distantPast) > 1800
                let asking = !vip && verdict == nil && canAsk
                let urgent = verdict?.urgent ?? false
                // Bundle ID and verdict only; never the notification text.
                NSLog("FocusDock: notification #\(n.id) from \(n.bundleID) for \(modeID ?? "-"), urgent: \(urgent), vip: \(vip), by: \(asking ? "ask" : verdict?.source ?? "none")")
                if asking {
                    self.askedAt[key] = Date()
                    self.store.ask(Prompt(subject: .notification(n),
                                          kind: .held(HeldInfo(modeID: heldFor, reason: "", urgent: false, vip: false, asking: true))))
                    return
                }
                guard urgent || vip else {
                    self.store.rememberQuiet(n, reason: verdict?.reason ?? "")
                    return
                }
                if let heldFor { self.store.hold(for: heldFor) }
                let info = HeldInfo(modeID: heldFor, reason: verdict?.reason ?? "", urgent: urgent, vip: vip)
                self.store.showHeld(Prompt(subject: .notification(n), kind: .held(info)))
            }
        }
    }

    // MARK: Apps

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bid = app.bundleIdentifier,
              app.activationPolicy == .regular else { return }
        defer { updateCover() }
        let subject = Subject.app(bundleID: bid, name: app.localizedName ?? bid)

        switch Self.verdict(for: bid, current: store.current, config: config, selfID: selfID) {
        case .ignore:
            return
        case .browser:
            // Browsers are judged by the tab, not the app.
            allowed(app)
            lastSeenHost[bid] = nil
            pollBrowser()
        case .allowed:
            allowed(app)
            // Landing back here right after a block is our own doing; keep that block's card up.
            if case .app = store.prompt?.subject, Date().timeIntervalSince(blockedAt) > 1 { store.dismissPrompt() }
        case .otherMode(let owner):
            // Cmd+Tab, Spotlight or the system Dock can still bring it up, so send it straight back.
            // The card offers the real (delayed) switch; this app comes forward once it lands.
            block(app)
            lastAppByMode[owner] = bid
            store.show(Prompt(subject: subject, kind: .belongsTo(modeID: owner, reason: nil)))
        case .unknown:
            classifyAndPrompt(subject)
        }
    }

    private func block(_ app: NSRunningApplication) {
        blockedAt = Date()
        app.hide()
        lastAllowedApp?.activate(options: [])
        // An app still finishing its own activation can ignore the first hide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let bid = app.bundleIdentifier,
                  !self.store.current.apps.contains(bid), !app.isHidden else { return }
            self.blockedAt = Date()
            app.hide()
        }
    }

    private func allowed(_ app: NSRunningApplication) {
        lastAllowedApp = app
        lastAppByMode[store.currentID] = app.bundleIdentifier
    }

    /// Decides when the notification is clearly like one side of the user's past reactions or, more
    /// strictly, of the built-in examples; nil sends it on to a model.
    private func memoryVerdict(_ n: HeldNotification, reactions: [Reaction]) async -> Triage? {
        guard embeddings.isAvailable,
              let v = await embeddings.embed(ReactionMemory.text(sender: n.title, body: n.body)) else { return nil }
        let seeds = await seedReactions()
        if let d = ReactionMemory.decideFromReactions(v, reactions: reactions, seeds: seeds) {
            return Triage(urgent: d.important, reason: "like \(d.nearest.sender): \(d.nearest.text.prefix(24))", source: "memory")
        }
        if let d = ReactionMemory.decide(v, among: seeds, minMargin: ReactionMemory.seedMargin) {
            return Triage(urgent: d.important, reason: "", source: "defaults")
        }
        return nil
    }

    private var seedCache: [Reaction] = []

    /// The built-in examples, embedded once per launch (24 short texts, well under a second).
    private func seedReactions() async -> [Reaction] {
        let cached = await MainActor.run { seedCache }
        if !cached.isEmpty { return cached }
        var out: [Reaction] = []
        for s in ReactionMemory.seeds {
            guard let v = await embeddings.embed(ReactionMemory.text(sender: s.sender, body: s.body)) else { return [] }
            out.append(Reaction(app: "", sender: s.sender, text: s.body, important: s.important, vector: v))
        }
        let embedded = out
        await MainActor.run { seedCache = embedded }
        return embedded
    }

    /// Adds a reaction to the memory once it's embedded (quietly skipped until the model is there).
    private func memorize(_ n: HeldNotification, important: Bool) {
        let app = AppLauncher.name(for: n.bundleID)
        Task { [weak self] in
            guard let self, let v = await self.embeddings.embed(ReactionMemory.text(sender: n.title, body: n.body)) else { return }
            await MainActor.run {
                self.memory.add(Reaction(app: app, sender: n.title, text: String(n.body.prefix(200)), important: important, vector: v))
            }
        }
    }

    /// Folds new reactions into the notes once a handful have piled up (or now, with `force`).
    func updateProfile(force: Bool = false) {
        let pending = store.pendingExamples
        // The notes only exist for Claude; with it off, nothing is sent anywhere.
        let usesClaude = Classifier.triageOrder(store.config.classifier, claudeCodeInstalled: ClaudeCode.executable != nil)
            .contains("claudeCode")
        guard usesClaude, !updatingProfile, let newest = pending.map(\.date).max(),
              force || pending.count >= 5 else { return }
        updatingProfile = true
        let current = store.config.notificationProfile
        Task { [weak self] in
            guard let self else { return }
            let text = await self.classifier.updatedProfile(current: current, reactions: pending)
            await MainActor.run {
                self.updatingProfile = false
                if let text { self.store.applyProfileUpdate(text, through: newest) }
            }
        }
    }

    // MARK: Decisions (pure, unit tested)

    static func verdict(for bid: String, current: Mode, config: AppConfig, selfID: String) -> AppVerdict {
        if bid == selfID || config.alwaysAllowed.contains(bid) { return .ignore }
        if config.browsers.contains(bid) { return .browser }
        if current.apps.contains(bid) { return .allowed }
        if let owner = config.modeOwning(bundleID: bid) { return .otherMode(owner.id) }
        return .unknown
    }

    /// A VIP name appears in the sender or chat name (title or subtitle), or as the sender at the start
    /// of the body ("Name: message", as Slack writes channel messages), ignoring case. Any app.
    static func isVIP(_ n: HeldNotification, vips: [String]) -> Bool {
        let fields = [n.title, n.subtitle, bodySender(n.body)]
        return vips.contains { name in
            !name.isEmpty && fields.contains { $0.localizedCaseInsensitiveContains(name) }
        }
    }

    /// "Maya Chen: can you…" -> "Maya Chen". Only a short prefix counts, so a VIP merely mentioned
    /// in someone else's message doesn't.
    static func bodySender(_ body: String) -> String {
        guard let colon = body.firstIndex(of: ":") else { return "" }
        let prefix = body[..<colon].trimmingCharacters(in: .whitespaces)
        return prefix.count <= 30 && !prefix.contains("\n") ? prefix : ""
    }

    /// The mode a notification from `bid` is held for: an app owned by another mode. Nil shows it as usual.
    static func holdingMode(for bid: String, current: Mode, config: AppConfig, selfID: String) -> String? {
        // Notification Center stores some bundle IDs lowercased.
        func has(_ ids: [String]) -> Bool { ids.contains { $0.caseInsensitiveCompare(bid) == .orderedSame } }
        guard !has([selfID]), !has(current.apps), !has(config.alwaysAllowed) else { return nil }
        return config.modes.first { has($0.apps) }?.id
    }

    /// The app to put in front when entering `mode`: the one last used there, else its first running app.
    static func appToFront(for mode: Mode, last: String?, running: Set<String>) -> String? {
        if let last, mode.apps.contains(last), running.contains(last) { return last }
        return mode.apps.first(where: running.contains)
    }

    // MARK: Browser tabs

    private func pollBrowser() {
        guard !polling,
              let front = NSWorkspace.shared.frontmostApplication,
              let bid = front.bundleIdentifier,
              config.browsers.contains(bid) else { return }
        polling = true
        browser.activeTab(bid) { [weak self] tab in
            guard let self else { return }
            self.polling = false
            defer { self.updateCover() }   // also follows the window when it moves
            guard let tab,
                  let url = URL(string: tab.url),
                  let scheme = url.scheme, scheme.hasPrefix("http"),
                  let rawHost = url.host else { return }   // new tab page, chrome://, file:// etc.
            let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
            if self.lastSeenHost[bid] == host {
                if self.store.current.domains.contains(where: { AppConfig.host(host, matches: $0) }) {
                    self.lastAllowedURL[bid] = tab.url
                }
                return
            }
            self.lastSeenHost[bid] = host
            self.handleSite(host: host, title: tab.title, url: tab.url, browserID: bid)
        }
    }

    private func handleSite(host: String, title: String, url: String, browserID: String) {
        if store.current.domains.contains(where: { AppConfig.host(host, matches: $0) }) {
            lastAllowedURL[browserID] = url
            if case .site = store.prompt?.subject { store.dismissPrompt() }
            return
        }
        let subject = Subject.site(host: host, title: title, browserID: browserID)
        if let owner = config.modeOwning(host: host) {
            // Unlike apps, the page stays open: the card asks, and Stay sends the tab back.
            store.show(Prompt(subject: subject, kind: .belongsTo(modeID: owner.id, reason: nil)))
        } else {
            classifyAndPrompt(subject)
        }
    }

    /// Blurs the page while a "belongs to another mode" card for it is up (and through the wait
    /// after Go), but only while that browser is in front and still on that site.
    private func updateCover() {
        if let p = store.prompt, case .belongsTo(let modeID, _) = p.kind, case .site(let host, _, let bid) = p.subject {
            coverTarget = (host, bid, modeID)
        } else if let t = coverTarget, store.pending?.modeID != t.modeID {
            coverTarget = nil   // Stay, the mode was entered, or the card went away
        }
        guard let t = coverTarget,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == t.browser,
              lastSeenHost[t.browser] == t.host,
              let frame = PageCover.pageFrame(of: t.browser) else {
            cover.hide()
            return
        }
        cover.show(frame: frame, host: t.host, modeName: store.mode(t.modeID)?.name ?? t.modeID)
    }

    /// Back to the last allowed page, or close the tab when there is none.
    private func sendBack(_ bid: String) {
        if let url = lastAllowedURL[bid] { browser.setURL(bid, url) } else { browser.closeTab(bid) }
        lastSeenHost[bid] = nil
    }

    // MARK: Classification

    private func classifyAndPrompt(_ subject: Subject) {
        if config.classifier.provider == "off" {
            store.show(Prompt(subject: subject, kind: .unknown(reason: nil)))
            return
        }
        store.show(Prompt(subject: subject, kind: .checking))
        let modes = config.modes, cfg = config.classifier, names = Classifier.appNames(for: modes)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.classifier.classify(subject, modes: modes, config: cfg, appNames: names)
            await MainActor.run { self.applyClassification(result, for: subject) }
        }
    }

    private func applyClassification(_ result: Classification?, for subject: Subject) {
        // Ignore stale results (user already moved on).
        guard store.prompt?.subject == subject else { return }
        guard let result else {
            store.show(Prompt(subject: subject, kind: .unknown(reason: nil)))
            return
        }
        guard let modeID = result.modeID else {
            store.show(Prompt(subject: subject, kind: .unknown(reason: result.reason)))
            return
        }
        // Something that was in Social never slips into a focus mode on the classifier's say-so.
        if !config.isGuarded(modeID), let guarded = config.guardedModeIDs.first, Self.isDistraction(subject, config) {
            store.show(Prompt(subject: subject, kind: .belongsTo(modeID: guarded, reason: result.reason)))
            return
        }
        // Remember the verdict so the next visit is instant.
        store.learn(subject, into: modeID)
        if modeID == store.currentID {
            // Don't reset lastSeenHost here: the next poll would re-run handleSite and dismiss
            // this toast right away. The same-host poll path records lastAllowedURL instead.
            store.show(Prompt(subject: subject, kind: .fits(modeID: modeID, reason: result.reason)),
                       autoDismissAfter: 4)
        } else {
            store.show(Prompt(subject: subject, kind: .belongsTo(modeID: modeID, reason: result.reason)))
        }
    }

    // MARK: Actions

    static func isDistraction(_ subject: Subject, _ config: AppConfig) -> Bool {
        switch subject {
        case .app(let bid, _): return config.isDistraction(.app, bid)
        case .site(let host, _, _): return config.isDistraction(.site, host)
        case .notification: return false
        }
    }

    /// "Belongs here" moved the card's subject into this mode: let it through now.
    private func movedHere(_ subject: Subject) {
        switch subject {
        case .app(let bid, _): AppLauncher.open(bid)   // it was hidden when it got blocked
        case .site(_, _, let bid): lastSeenHost[bid] = nil   // next poll sees it as allowed
        case .notification: break
        }
    }

    private func stay(_ subject: Subject) {
        switch subject {
        case .app(let bid, _):
            NSRunningApplication.runningApplications(withBundleIdentifier: bid).forEach { $0.hide() }
            lastAllowedApp?.activate(options: [])
        case .site(_, _, let bid):
            sendBack(bid)
        case .notification:
            break
        }
    }

    private func modeActivated(_ mode: Mode) {
        lastSeenHost.removeAll()
        lastAllowedURL.removeAll()

        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // Show this mode's apps again; they were hidden when another mode was entered.
        for app in running where app.isHidden {
            if let bid = app.bundleIdentifier, mode.apps.contains(bid) { app.unhide() }
        }
        if config.hideOtherAppsOnEnter {
            let others = running.filter { app in
                guard let bid = app.bundleIdentifier else { return false }
                return bid != selfID && !mode.apps.contains(bid) && !config.alwaysAllowed.contains(bid)
            }
            others.forEach { $0.hide() }
            // The app that was in front (usually the one you were working in) can ignore the first hide.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.store.currentID == mode.id else { return }
                for app in others where !app.isHidden && !app.isTerminated {
                    if !app.hide() { NSLog("FocusDock: couldn't hide \(app.bundleIdentifier ?? "?") on entering \(mode.id)") }
                }
            }
        }
        if config.launchAppsOnEnter {
            for bid in mode.apps where NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
                AppLauncher.open(bid, activate: false)
            }
        }
        // Launch Services activation; NSRunningApplication.activate is easily declined for a background app.
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        if let front = Self.appToFront(for: mode, last: lastAppByMode[mode.id], running: runningIDs) {
            AppLauncher.open(front, activate: true)
        }
        FocusShortcuts.run(mode.shortcut)
        // Re-check whatever is in front right now against the new mode.
        pollBrowser()
    }
}

enum AppLauncher {
    private static var urlCache: [String: URL] = [:]

    static func url(for bid: String) -> URL? {
        if let cached = urlCache[bid] { return cached }
        // Misses aren't cached, so an app installed later shows up in the dock.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
        urlCache[bid] = url
        return url
    }

    static func isInstalled(_ bid: String) -> Bool { url(for: bid) != nil }

    static func open(_ bid: String, activate: Bool = true) {
        guard let url = url(for: bid) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = activate
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
    }

    private static var iconCache: [String: NSImage] = [:]

    static func icon(for bid: String) -> NSImage? {
        if let cached = iconCache[bid] { return cached }
        guard let url = url(for: bid) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bid] = img
        return img
    }

    static func name(for bid: String) -> String {
        guard let url = url(for: bid) else { return bid }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
