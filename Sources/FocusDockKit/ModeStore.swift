import AppKit
import Combine

struct PendingSwitch: Equatable {
    var modeID: String
    var deadline: Date
    var total: Double
}

/// Something the user opened that is outside the current mode.
enum Subject: Equatable {
    case app(bundleID: String, name: String)
    case site(host: String, title: String, browserID: String)
    /// A notification from an app of another mode.
    case notification(HeldNotification)

    var label: String {
        switch self {
        case .app(_, let name): return name
        case .site(let host, _, _): return host
        case .notification(let n): return n.title.isEmpty ? n.bundleID : n.title
        }
    }
}

enum PromptKind: Equatable {
    /// Classifier is thinking.
    case checking
    /// Belongs to another mode. `reason` is set when it came from the classifier.
    case belongsTo(modeID: String, reason: String?)
    /// Classifier says it fits the current mode; auto-allowed.
    case fits(modeID: String, reason: String)
    /// Not in any mode and the classifier could not place it (or is off).
    case unknown(reason: String?)
    /// A notification card: held for another mode, or from a VIP.
    case held(HeldInfo)
}

/// A notification held without a card, kept so a missed one can be marked (in memory only).
struct QuietNote: Identifiable {
    let id = UUID()
    let notification: HeldNotification
    let reason: String
}

struct HeldInfo: Equatable {
    /// The mode the app belongs to when that isn't the current one ("held for …"); nil otherwise.
    var modeID: String?
    var reason: String
    var urgent: Bool
    var vip: Bool
    /// Nothing on this Mac could settle it, so the card asks the user (and remembers the answer).
    var asking = false
}

struct Prompt: Equatable, Identifiable {
    let id = UUID()
    var subject: Subject
    var kind: PromptKind
}

final class ModeStore: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var currentID: String
    @Published private(set) var pending: PendingSwitch?
    @Published private(set) var prompt: Prompt?
    @Published private(set) var now = Date()
    /// Unread time-sensitive notifications per mode (mode ID -> count), until read via Later or the mode is entered.
    @Published private(set) var held: [String: Int] = [:] {
        didSet { if held != oldValue { NSLog("FocusDock: badge counts \(held.sorted { $0.key < $1.key })") } }
    }
    /// Notification cards, oldest first. Shown stacked, separately from `prompt`.
    @Published private(set) var notes: [Prompt] = []
    /// Held without a card, newest first.
    @Published private(set) var quietNotes: [QuietNote] = []

    /// Called after a mode becomes active.
    var onActivate: ((Mode) -> Void)?
    /// Called when the user chooses "Stay" on a prompt.
    var onStay: ((Subject) -> Void)?
    /// Called after a reaction to a notification is remembered: the notification, and whether it mattered.
    var onReaction: ((HeldNotification, Bool) -> Void)?
    /// Called when an app or site is moved or taken out, so a cached verdict about it is dropped.
    var onForget: ((LearnedItem.Kind, String) -> Void)?
    /// Called when "Belongs here" puts the subject of a card into the current mode.
    var onMovedHere: ((Subject) -> Void)?

    private var timer: Timer?
    private var promptDismissWork: DispatchWorkItem?
    /// Where config changes are saved; tests point this at a temporary file.
    let configURL: URL

    init(config: AppConfig, configURL: URL = ConfigStore.fileURL) {
        self.config = config
        self.configURL = configURL
        let saved = UserDefaults.standard.string(forKey: "currentMode")
        self.currentID = config.mode(saved ?? "")?.id ?? config.modes.first?.id ?? "study"
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    var current: Mode { config.mode(currentID) ?? config.modes[0] }

    func mode(_ id: String) -> Mode? { config.mode(id) }

    // MARK: Config

    func reloadConfig() {
        config = ConfigStore.load(from: configURL)
        if config.mode(currentID) == nil, let first = config.modes.first { currentID = first.id }
    }

    /// Adds a domain or app to a mode, records it as learned (so it can be undone) and persists it.
    func learn(_ subject: Subject, into modeID: String) {
        guard let idx = config.modes.firstIndex(where: { $0.id == modeID }) else { return }
        let item: LearnedItem
        switch subject {
        case .app(let bid, _):
            guard !config.modes[idx].apps.contains(bid) else { return }
            config.modes[idx].apps.append(bid)
            item = LearnedItem(kind: .app, value: bid, modeID: modeID, date: Date())
        case .site(let host, _, _):
            let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            guard !config.modes[idx].domains.contains(h) else { return }
            config.modes[idx].domains.append(h)
            item = LearnedItem(kind: .site, value: h, modeID: modeID, date: Date())
        case .notification:
            return
        }
        config.learned.removeAll { $0.id == item.id }
        config.learned.append(item)
        if config.learned.count > 50 { config.learned.removeFirst(config.learned.count - 50) }
        save()
    }

    /// Takes a learned app or site back out of its mode (always allowed: it can't loosen anything).
    func unlearn(_ item: LearnedItem) {
        var ids = config.modeIDs(listing: item.kind, item.value)
        ids.remove(item.modeID)
        setModes(ids, for: item.kind, item.value)
    }

    /// Moves a learned app or site to another mode. Callers check `needsWait` first.
    func move(_ item: LearnedItem, to modeID: String) {
        var ids = config.modeIDs(listing: item.kind, item.value)
        ids.remove(item.modeID)
        ids.insert(modeID)
        setModes(ids, for: item.kind, item.value)
    }

    func needsWait(_ item: LearnedItem, to modeID: String) -> Bool {
        var ids = config.modeIDs(listing: item.kind, item.value)
        ids.remove(item.modeID)
        ids.insert(modeID)
        return config.needsWait(item.kind, item.value, newModes: ids)
    }

    /// Setup: lists `bid` in exactly these modes. A choice made here is no longer "learned".
    func setModes(_ modeIDs: Set<String>, forApp bid: String) { setModes(modeIDs, for: .app, bid) }

    /// Lists an app or site in exactly these modes. Callers check `config.needsWait` for anything that
    /// could loosen focus; taking something out of a guarded mode is remembered as a distraction.
    func setModes(_ modeIDs: Set<String>, for kind: LearnedItem.Kind, _ value: String) {
        for i in config.modes.indices {
            let id = config.modes[i].id
            let has = (kind == .app ? config.modes[i].apps : config.modes[i].domains).contains(value)
            if modeIDs.contains(id), !has {
                if kind == .app { config.modes[i].apps.append(value) } else { config.modes[i].domains.append(value) }
            }
            if !modeIDs.contains(id), has {
                if kind == .app { config.modes[i].apps.removeAll { $0 == value } }
                else { config.modes[i].domains.removeAll { $0 == value } }
                if config.isGuarded(id), !config.distractions.contains(value) { config.distractions.append(value) }
            }
        }
        config.learned.removeAll { $0.kind == kind && $0.value == value }
        save()
        onForget?(kind, value)
    }

    // MARK: Correcting a card

    private func item(of subject: Subject) -> (LearnedItem.Kind, String)? {
        switch subject {
        case .app(let bid, _): return (.app, bid)
        case .site(let host, _, _): return (.site, host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        case .notification: return nil
        }
    }

    /// Whether to offer "Belongs here" on a "belongs to `owner`" card: only to undo the classifier's
    /// guess between focus modes, never to pull something out of Social.
    func canBelongHere(_ subject: Subject, owner: String) -> Bool {
        guard let (kind, value) = item(of: subject), !config.isGuarded(owner), owner != currentID,
              !config.isDistraction(kind, value) else { return false }
        return config.learned.contains { $0.kind == kind && $0.modeID == owner
            && (kind == .app ? $0.value == value : AppConfig.host(value, matches: $0.value)) }
    }

    /// "Belongs here" on the card: the classifier put it in the wrong focus mode.
    func moveHere() {
        guard let p = prompt, case .belongsTo(let owner, _) = p.kind, canBelongHere(p.subject, owner: owner),
              let (kind, value) = item(of: p.subject) else { return }
        let learnedValue = config.learned.first { $0.kind == kind && $0.modeID == owner
            && (kind == .app ? $0.value == value : AppConfig.host(value, matches: $0.value)) }?.value ?? value
        var ids = config.modeIDs(listing: kind, learnedValue)
        ids.remove(owner)
        ids.insert(currentID)
        setModes(ids, for: kind, learnedValue)
        dismissPrompt()
        onMovedHere?(p.subject)
    }

    /// Setup: Do Not Disturb on in these modes and off in the others. Empty leaves Focus alone.
    func setFocusShortcuts(on modeIDs: Set<String>) {
        for i in config.modes.indices {
            config.modes[i].shortcut = modeIDs.isEmpty ? nil
                : modeIDs.contains(config.modes[i].id) ? FocusShortcuts.onName : FocusShortcuts.offName
        }
        save()
    }

    private func save() { ConfigStore.save(config, to: configURL) }

    func hold(for modeID: String) { held[modeID, default: 0] += 1 }

    // MARK: Switching

    /// Press on a mode. The first press starts the exit countdown; pressing it again while the
    /// countdown runs does nothing (the wait can't be shortened). Pressing the current mode cancels.
    func request(_ id: String) {
        if id == currentID { cancelPending(); return }
        if let p = pending, p.modeID == id { return }
        let delay = current.exit.delay(to: id)
        if delay <= 0 { activate(id); return }
        // Refresh `now` too, or remaining() can briefly exceed total (stale tick).
        now = Date()
        pending = PendingSwitch(modeID: id, deadline: now.addingTimeInterval(delay), total: delay)
    }

    func cancelPending() { pending = nil }

    func activate(_ id: String) {
        guard let mode = config.mode(id) else { return }
        pending = nil
        // They're in Notification Center now that this mode is active.
        held[id] = nil
        dropNotes(for: id)
        dismissPrompt()
        currentID = id
        UserDefaults.standard.set(id, forKey: "currentMode")
        onActivate?(mode)
    }

    func remaining(_ p: PendingSwitch) -> Double { max(0, p.deadline.timeIntervalSince(now)) }

    private func tick() {
        // `now` only drives the countdown; publishing it while idle re-renders the dock 4x a second.
        guard let p = pending else { return }
        now = Date()
        if p.deadline <= now { activate(p.modeID) }
    }

    // MARK: Prompts

    func show(_ prompt: Prompt, autoDismissAfter: Double? = nil) {
        promptDismissWork?.cancel()
        self.prompt = prompt
        if let t = autoDismissAfter {
            let id = prompt.id
            let work = DispatchWorkItem { [weak self] in
                if self?.prompt?.id == id { self?.prompt = nil }
            }
            promptDismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: work)
        }
    }

    func dismissPrompt() {
        promptDismissWork?.cancel()
        prompt = nil
    }

    // MARK: Star card

    static let gitHubURL = URL(string: "https://github.com/yonghdong/FocusDock")!
    static let starCardKey = "starCardAnswered"

    enum StarCard: Equatable { case asking, starring, starred, openedPage }

    /// A card above the dock suggesting a GitHub star, shown until it's answered once.
    @Published private(set) var starCard: StarCard?

    func showStarCardIfNew(_ defaults: UserDefaults = .standard) {
        if !defaults.bool(forKey: Self.starCardKey) { starCard = .asking }
    }

    func dismissStarCard(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Self.starCardKey)
        starCard = nil
    }

    /// Stars the repository with `star` (the GitHub CLI), or opens the page when that can't. The card
    /// then says thanks, or where the page's Star button is, and goes away after `linger` seconds.
    func starOnGitHub(openPage: @escaping () -> Void,
                      star: @escaping (@escaping (Bool) -> Void) -> Void = GitHubStar.star,
                      defaults: UserDefaults = .standard, linger: Double = 5) {
        defaults.set(true, forKey: Self.starCardKey)
        starCard = .starring
        star { [weak self] starred in
            guard let self else { return }
            if !starred { openPage() }
            let shown: StarCard = starred ? .starred : .openedPage
            self.starCard = shown
            DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
                if self?.starCard == shown { self?.starCard = nil }
            }
        }
    }

    /// Adds a notification card to the stack; earlier ones stay up until handled.
    func showHeld(_ note: Prompt) { notes.append(note) }

    /// How long an unanswered question card stays up.
    var askSeconds: Double = 20

    /// A card asking whether notifications like this one matter. It goes away unanswered after
    /// `askSeconds` and doesn't count on the mode button until answered "important".
    func ask(_ note: Prompt) {
        notes.append(note)
        let id = note.id
        DispatchQueue.main.asyncAfter(deadline: .now() + askSeconds) { [weak self] in
            guard let self, let p = self.notes.first(where: { $0.id == id }),
                  case .held(let info) = p.kind, info.asking else { return }
            self.notes.removeAll { $0.id == id }
        }
    }

    /// The answer to a question card becomes a reaction, so look-alikes are decided on the Mac next time.
    /// "Important" turns it into a regular card (Later / Go to); "not important" closes it.
    func answer(_ id: UUID, important: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }), case .notification(let n) = notes[i].subject,
              case .held(var info) = notes[i].kind, info.asking else { return }
        remember(n, reason: "", important: important)
        guard important else {
            notes.remove(at: i)
            return
        }
        info.asking = false
        info.urgent = true
        notes[i] = Prompt(subject: notes[i].subject, kind: .held(info))
        if let modeID = info.modeID { hold(for: modeID) }
    }

    /// Later: the card has been read, so it no longer counts as waiting on the mode button.
    func dismissNote(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        if case .held(let info) = note.kind, let modeID = info.modeID, let count = held[modeID] {
            held[modeID] = count > 1 ? count - 1 : nil
        }
    }

    private func dropNotes(for modeID: String) {
        notes.removeAll { if case .held(let info) = $0.kind { return info.modeID == modeID } else { return false } }
    }

    // MARK: Learning from reactions

    private func note(_ id: UUID) -> (HeldNotification, HeldInfo)? {
        guard let p = notes.first(where: { $0.id == id }),
              case .notification(let n) = p.subject, case .held(let info) = p.kind else { return nil }
        return (n, info)
    }

    /// Keeps a reaction as an example for the classifier. One per sender (app + sender or chat), newest
    /// wins: that keeps the list as short as the number of people, and a changed mind replaces the old
    /// answer. (The on-device model can't be trusted to compress the list itself.)
    func remember(_ n: HeldNotification, reason: String, important: Bool) {
        let example = NotificationExample(
            app: AppLauncher.name(for: n.bundleID), sender: n.title, text: String(n.body.prefix(80)),
            reason: reason.isEmpty ? (important ? "needs your attention" : "not needed now") : reason,
            important: important, date: Date())
        config.notificationExamples.removeAll { $0.app == example.app && $0.sender == example.sender }
        config.notificationExamples.append(example)
        if config.notificationExamples.count > 30 {
            config.notificationExamples.removeFirst(config.notificationExamples.count - 30)
        }
        save()
        onReaction?(n, important)
    }

    /// Reactions not folded into the notes yet, oldest first.
    var pendingExamples: [NotificationExample] {
        config.notificationExamples.filter { $0.date > config.profileUpdatedAt }
    }

    /// The user edited the notes by hand.
    func setProfile(_ text: String) {
        config.notificationProfile = text
        save()
    }

    /// Claude rewrote the notes to include every reaction up to `date`.
    func applyProfileUpdate(_ text: String, through date: Date) {
        config.notificationProfile = text
        config.profileUpdatedAt = date
        save()
    }

    func setTriageProvider(_ provider: String) {
        config.classifier.triageProvider = provider
        save()
    }

    /// 👎 on a card: not needed. Similar ones stay quiet from now on.
    func notImportant(_ id: UUID) {
        if let (n, info) = note(id) { remember(n, reason: info.reason, important: false) }
        dismissNote(id)
    }

    /// "Go to …" on a card: it mattered. Similar ones keep getting a card; then the switch starts.
    func goFromNote(_ id: UUID) {
        guard let (n, info) = note(id) else { return }
        remember(n, reason: info.reason, important: true)
        dismissNote(id)
        if let modeID = info.modeID { goTo(modeID) }
    }

    func rememberQuiet(_ n: HeldNotification, reason: String) {
        quietNotes.insert(QuietNote(notification: n, reason: reason), at: 0)
        if quietNotes.count > 20 { quietNotes.removeLast(quietNotes.count - 20) }
    }

    /// "Should have shown" on a quietly held one: similar ones get a card from now on.
    func shouldHaveShown(_ id: UUID) {
        guard let q = quietNotes.first(where: { $0.id == id }) else { return }
        remember(q.notification, reason: q.reason, important: true)
        quietNotes.removeAll { $0.id == id }
    }

    func setExample(_ id: String, important: Bool) {
        guard let i = config.notificationExamples.firstIndex(where: { $0.id == id }) else { return }
        config.notificationExamples[i].important = important
        save()
    }

    func forgetExample(_ id: String) {
        config.notificationExamples.removeAll { $0.id == id }
        save()
    }

    func clearExamples() {
        config.notificationExamples = []
        save()
    }

    func addVIP(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !config.vips.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { return }
        config.vips.append(n)
        save()
    }

    func removeVIP(_ name: String) {
        config.vips.removeAll { $0 == name }
        save()
    }

    // MARK: Dock

    /// The current mode's apps that should show in the dock (installed or not; the view checks that).
    var dockApps: [String] { current.apps.filter { !config.dockHidden.contains($0) } }

    func setDockHidden(_ hidden: Bool, for bid: String) {
        config.dockHidden.removeAll { $0 == bid }
        if hidden { config.dockHidden.append(bid) }
        save()
    }

    func stay() {
        guard let p = prompt else { return }
        dismissPrompt()
        onStay?(p.subject)
    }

    func goTo(_ modeID: String) {
        dropNotes(for: modeID)   // headed there anyway
        dismissPrompt()
        request(modeID)
    }

    /// Offered on "doesn't fit" cards, but never for a distraction (that takes Setup and the wait).
    func canAllowHere(_ subject: Subject) -> Bool {
        guard let (kind, value) = item(of: subject) else { return false }
        return config.isGuarded(currentID) || !config.isDistraction(kind, value)
    }

    func allowHere() {
        guard let p = prompt, canAllowHere(p.subject) else { return }
        learn(p.subject, into: currentID)
        dismissPrompt()
    }
}
