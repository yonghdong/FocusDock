import SwiftUI
import AppKit

/// A change that would let a distraction into a focus mode, held until the wait is over.
struct PendingChange: Equatable {
    let kind: LearnedItem.Kind
    let value: String
    let label: String
    let modes: Set<String>
    let readyAt: Date
}

struct BrowserAccess: Identifiable, Equatable {
    let bundleID: String
    let name: String
    var status: Permissions.Automation

    var id: String { bundleID }
}

/// State behind the setup window: permissions, the Do Not Disturb shortcuts, and which modes list which apps.
final class SetupModel: ObservableObject {
    let store: ModeStore
    private let classifier: Classifier

    @Published var notificationsReadable = false
    @Published var browsers: [BrowserAccess] = []
    @Published var appleModel: (ok: Bool, text: String) = (false, "")
    @Published var openAtLogin = LoginItem.State.unavailable
    @Published var shortcutsInstalled = false
    @Published var shortcutsBusy = false
    @Published var shortcutsError: String?
    @Published var apps: [InstalledApp] = []
    /// Placed by Suggest and not touched by hand since.
    @Published var suggested: Set<String> = []
    @Published var suggesting = false
    @Published var suggestProgress = (done: 0, total: 0)
    @Published var search = ""
    @Published var newVIP = ""
    @Published var pendingChange: PendingChange?
    @Published var siteSearch = ""
    @Published var newSite = ""
    @Published var newSiteMode = ""
    @Published var profileDraft = ""
    /// Asks Claude to fold new reactions into the notes now (wired to FocusGuard by the app).
    var onUpdateProfile: () -> Void = {}
    var memoryCount: () -> Int = { 0 }
    var clearMemory: () -> Void = {}

    func clearReactionMemory() {
        clearMemory()
        objectWillChange.send()
    }

    init(store: ModeStore, classifier: Classifier) {
        self.store = store
        self.classifier = classifier
    }

    var modes: [Mode] { store.config.modes }

    // MARK: At launch

    /// Setup opens by itself on the first launch, and once per build while Full Disk Access is missing:
    /// each update is a new app to macOS and loses it. Once per build, so someone who leaves it off
    /// isn't asked at every login.
    static func opensAtLaunch(firstLaunch: Bool, canReadNotifications: Bool, build: String, lastOpenedBuild: String?) -> Bool {
        firstLaunch || (!canReadNotifications && lastOpenedBuild != build)
    }

    /// Changes with every build or update (the executable's date).
    static var buildStamp: String {
        let date = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }?.contentModificationDate
        return date.map { String(Int($0.timeIntervalSince1970)) } ?? ""
    }

    // MARK: Permissions

    /// Whether undecided notifications may go to Claude (only if the user chose so).
    var usesClaude: Bool {
        Classifier.triageOrder(store.config.classifier, claudeCodeInstalled: claudeCodePath != nil).contains("claudeCode")
    }

    func refresh() {
        if usesClaude { checkClaude() }   // the check itself is a request to Anthropic, so only when on
        notificationsReadable = Permissions.canReadNotifications
        appleModel = Classifier.appleModelStatus
        openAtLogin = LoginItem.state
        let config = store.config
        DispatchQueue.global(qos: .userInitiated).async {
            let browsers = config.browsers.compactMap { bid -> BrowserAccess? in
                guard AppLauncher.url(for: bid) != nil else { return nil }
                return BrowserAccess(bundleID: bid, name: AppLauncher.name(for: bid),
                                     status: Permissions.automation(for: bid, ask: false))
            }
            let installed = FocusShortcuts.installed()
            DispatchQueue.main.async {
                self.browsers = browsers
                self.shortcutsInstalled = installed
            }
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        LoginItem.setWanted(on)
        openAtLogin = LoginItem.state
    }

    /// Shows macOS's "FocusDock wants to control …" prompt (or the settings page if already denied).
    func allowAutomation(_ browser: BrowserAccess) {
        switch browser.status {
        case .denied: Permissions.openAutomationSettings()
        case .notRunning: AppLauncher.open(browser.bundleID, activate: false)
        default:
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Permissions.automation(for: browser.bundleID, ask: true)
                DispatchQueue.main.async { self.refresh() }
            }
        }
        // Launching takes a moment; look again once it's up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
    }

    // MARK: Do Not Disturb

    func installShortcuts() {
        shortcutsBusy = true
        shortcutsError = nil
        FocusShortcuts.install { error in
            self.shortcutsBusy = false
            self.shortcutsError = error
            // The user still has to press Add in Shortcuts; check back for a while.
            for delay in [3.0, 6, 10, 15, 25, 40] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.refresh() }
            }
        }
    }

    /// Stops switching Focus with modes and turns Do Not Disturb off once.
    func stopUsingDoNotDisturb() {
        store.setFocusShortcuts(on: [])
        FocusShortcuts.run(FocusShortcuts.offName)
        objectWillChange.send()
    }

    func hidesBanners(in modeID: String) -> Bool {
        store.config.mode(modeID)?.shortcut == FocusShortcuts.onName
    }

    func setHidesBanners(_ on: Bool, in modeID: String) {
        var ids = Set(modes.filter { hidesBanners(in: $0.id) }.map(\.id))
        if on { ids.insert(modeID) } else { ids.remove(modeID) }
        store.setFocusShortcuts(on: ids)
        FocusShortcuts.run(store.current.shortcut)   // match the mode we're in now
        objectWillChange.send()
    }

    // MARK: Apps

    func loadApps() {
        let skip = Set(store.config.alwaysAllowed + [Bundle.main.bundleIdentifier ?? "com.focusdock.app"])
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = InstalledApps.scan(excluding: skip)
            DispatchQueue.main.async { self.apps = apps }
        }
    }

    var visibleApps: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    func isBrowser(_ bid: String) -> Bool { store.config.browsers.contains(bid) }

    func modeIDs(of bid: String) -> Set<String> {
        Set(modes.filter { $0.apps.contains(bid) }.map(\.id))
    }

    func toggle(_ bid: String, in modeID: String) {
        var ids = modeIDs(of: bid)
        if ids.contains(modeID) { ids.remove(modeID) } else { ids.insert(modeID) }
        change(.app, bid, label: AppLauncher.name(for: bid), to: ids)
        suggested.remove(bid)
    }

    // MARK: Changes that could loosen focus

    /// Applies a mode change, or holds it behind the wait when it would let a distraction into a
    /// focus mode (the same wait as going to Social, so this is never the easier way there).
    func change(_ kind: LearnedItem.Kind, _ value: String, label: String, to modes: Set<String>) {
        if store.config.needsWait(kind, value, newModes: modes) {
            pendingChange = PendingChange(kind: kind, value: value, label: label, modes: modes,
                                          readyAt: Date().addingTimeInterval(store.config.correctionWait))
        } else {
            store.setModes(modes, for: kind, value)
            objectWillChange.send()
        }
    }

    func confirmPending() {
        guard let p = pendingChange, Date() >= p.readyAt else { return }
        store.setModes(p.modes, for: p.kind, p.value)
        pendingChange = nil
    }

    func cancelPending() { pendingChange = nil }

    /// The focus modes a pending change would add, by name.
    func pendingModeNames(_ p: PendingChange) -> String {
        let added = p.modes.subtracting(store.config.modeIDs(listing: p.kind, p.value))
        return modes.filter { added.contains($0.id) }.map(\.name).joined(separator: " and ")
    }

    // MARK: Sites

    var visibleSites: [String] {
        let all = Set(modes.flatMap(\.domains)).sorted()
        let q = siteSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.contains(q) }
    }

    func siteModeIDs(_ domain: String) -> Set<String> { store.config.modeIDs(listing: .site, domain) }

    func toggleSite(_ domain: String, in modeID: String) {
        var ids = siteModeIDs(domain)
        if ids.contains(modeID) { ids.remove(modeID) } else { ids.insert(modeID) }
        change(.site, domain, label: domain, to: ids)
    }

    /// Taking a site out can't loosen anything (one from Social stays a distraction).
    func removeSite(_ domain: String) {
        store.setModes([], for: .site, domain)
        objectWillChange.send()
    }

    func addSite() {
        guard let domain = Self.domain(from: newSite) else { return }
        let mode = newSiteMode.isEmpty ? (modes.first?.id ?? "") : newSiteMode
        change(.site, domain, label: domain, to: siteModeIDs(domain).union([mode]))
        newSite = ""
    }

    /// "https://www.KLMS.kaist.ac.kr/course?id=1" -> "klms.kaist.ac.kr". Nil if it doesn't look like a host.
    static func domain(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        s = String(s.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" })
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s.contains(".") && !s.contains(" ") && !s.hasPrefix(".") && !s.hasSuffix(".") ? s : nil
    }

    func isDockHidden(_ bid: String) -> Bool { store.config.dockHidden.contains(bid) }

    func toggleDockHidden(_ bid: String) {
        store.setDockHidden(!isDockHidden(bid), for: bid)
        objectWillChange.send()
    }

    // MARK: Notifications

    var vips: [String] { store.config.vips }

    func addVIP() {
        store.addVIP(newVIP)
        newVIP = ""
        objectWillChange.send()
    }

    func removeVIP(_ name: String) {
        store.removeVIP(name)
        objectWillChange.send()
    }

    /// Newest first.
    var examples: [NotificationExample] { store.config.notificationExamples.reversed() }

    func setExample(_ e: NotificationExample, important: Bool) {
        store.setExample(e.id, important: important)
        objectWillChange.send()
    }

    func forget(_ e: NotificationExample) {
        store.forgetExample(e.id)
        objectWillChange.send()
    }

    func clearExamples() {
        store.clearExamples()
        objectWillChange.send()
    }

    // MARK: Notes (Claude)

    var claudeCodePath: String? { ClaudeCode.executable }
    @Published var claudeStatus: ClaudeCode.Status?

    /// Opens Terminal running `claude`, where a first run walks through signing in.
    func signInToClaude() {
        let exe = (claudeCodePath ?? "claude").replacingOccurrences(of: "\"", with: "\\\"")
        // Single quotes for the shell, in case the path has spaces.
        let src = "tell application \"Terminal\"\nactivate\ndo script \"'\(exe)'\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&error)
        if let error { NSLog("FocusDock: couldn't open Terminal for sign-in: \(error)") }
    }

    /// Pings Claude Code once per window (a tiny Haiku request) to tell "installed" from "working".
    func checkClaude(force: Bool = false) {
        guard force || claudeStatus == nil else { return }
        claudeStatus = nil
        Task {
            let status = await ClaudeCode.check()
            await MainActor.run { self.claudeStatus = status }
        }
    }

    var triageProvider: String {
        get { store.config.classifier.triageProvider }
        set { store.setTriageProvider(newValue); objectWillChange.send() }
    }

    var profile: String { store.config.notificationProfile }
    var pendingCount: Int { store.pendingExamples.count }
    var profileEdited: Bool { profileDraft != profile }

    func loadProfile() { profileDraft = profile }

    func saveProfile() {
        store.setProfile(profileDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        profileDraft = profile
    }

    func updateProfileNow() {
        onUpdateProfile()
        // Claude takes a few seconds; pick up the new notes when they land.
        for delay in [3.0, 6, 10, 20] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !self.profileEdited || self.profileDraft.isEmpty { self.loadProfile() }
                self.objectWillChange.send()
            }
        }
    }

    var quietNotes: [QuietNote] { store.quietNotes }

    func shouldHaveShown(_ q: QuietNote) {
        store.shouldHaveShown(q.id)
        objectWillChange.send()
    }

    /// Asks the classifier about every app that isn't in a mode yet and places it.
    func suggest() {
        let todo = apps.filter { modeIDs(of: $0.bundleID).isEmpty && !isBrowser($0.bundleID) }
        guard !todo.isEmpty, !suggesting else { return }
        suggesting = true
        suggestProgress = (0, todo.count)
        let modes = store.config.modes, config = store.config.classifier, names = Classifier.appNames(for: modes)
        Task {
            for app in todo {
                let result = await classifier.classify(.app(bundleID: app.bundleID, name: app.name), modes: modes,
                                                       config: config, appNames: names)
                await MainActor.run {
                    self.suggestProgress.done += 1
                    if let id = result?.modeID, self.modeIDs(of: app.bundleID).isEmpty,
                       !self.store.config.needsWait(.app, app.bundleID, newModes: [id]) {
                        self.store.setModes([id], forApp: app.bundleID)
                        self.suggested.insert(app.bundleID)
                    }
                }
            }
            await MainActor.run { self.suggesting = false }
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var downloader: ModelDownloader

    var close: () -> Void = {}

    enum Tab: String, CaseIterable, Identifiable {
        case permissions = "Permissions", focus = "Do Not Disturb", apps = "Apps", sites = "Sites",
             notifications = "Notifications", claude = "Claude (optional)"
        var id: Self { self }
    }

    // A segmented control rather than TabView: on macOS 26 TabView moves its tabs into the window's
    // toolbar, where at this width they all collapse behind a » button.
    @State private var tab = Tab.permissions

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Group {
                switch tab {
                case .permissions: permissions
                case .focus: focus
                case .apps: appsTab
                case .sites: sitesTab
                case .notifications: notificationsTab
                case .claude: claudeTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HStack {
                Text("Everything here can be changed later from the menu bar: Setup…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 540)
        .onAppear { model.refresh(); model.loadApps() }
    }

    // MARK: Claude

    private var claudeTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Optional: ask Claude when unsure").font(.system(size: 15, weight: .semibold))
            Text("By default every notification is judged on this Mac (your reactions and built-in examples), and when they can't tell, FocusDock asks you. Nothing is sent anywhere. If you turn this on under Notifications, the ones it can't settle go to Claude Haiku through your Claude Code instead of a question.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.usesClaude {
                Text("Off: Who decides is set to This Mac only.").font(.system(size: 12, weight: .semibold))
            }
            row(ok: model.claudeStatus == .ready, title: "Claude Code", detail: claudeDetail) {
                switch model.claudeStatus {
                case nil where !model.usesClaude:
                    Button("Check") { model.checkClaude(force: true) }
                case nil:
                    ProgressView().controlSize(.small)
                case .notInstalled?:
                    Button("Install Claude Code") {
                        if let url = URL(string: "https://claude.com/claude-code") { NSWorkspace.shared.open(url) }
                    }
                case .failing?:
                    Button("Sign In") { model.signInToClaude() }
                case .ready?:
                    EmptyView()
                }
            }
            if model.claudeStatus != .ready && model.usesClaude {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Install Claude Code if you haven't.")
                    Text("2. Run `claude` once in Terminal and sign in (Sign In does this for you).")
                    Text("3. Come back and press Check Again.")
                }
                .font(.system(size: 12))
                Button("Check Again") { model.checkClaude(force: true) }.disabled(model.claudeStatus == nil)
            }
            Divider()
            Text("When it's on, the text of notifications the Mac couldn't settle, and the notes, are sent to Anthropic under your Claude account.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(8)
    }

    // MARK: Permissions

    private var permissions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                row(ok: model.notificationsReadable, title: "Notifications (Full Disk Access)",
                    detail: "Reads other apps' notifications so ones for another mode can wait, and urgent ones show up as cards.") {
                    Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                }
                if !model.notificationsReadable {
                    // macOS never lists FocusDock there by itself, so it has to be added by hand.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Click Open Settings.")
                        Text("2. Click + under the list, enter your password, and choose FocusDock in Applications.")
                        Text("3. Make sure its switch is on. FocusDock notices within a few seconds.")
                        Text("After an update, or if an older FocusDock is already in the list, remove it with − first, then add it again with +.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
                }
                ForEach(model.browsers) { b in
                    row(ok: b.status == .allowed, title: "\(b.name) (Automation)", detail: automationDetail(b.status)) {
                        if b.status != .allowed {
                            Button(automationButton(b.status)) { model.allowAutomation(b) }
                        }
                    }
                }
                row(ok: model.appleModel.ok, title: "Apple Intelligence (optional)",
                    detail: model.appleModel.text + ". FocusDock sorts new apps and sites with its own model; Apple's is the fallback until that model is downloaded.") {
                    EmptyView()
                }
                if model.openAtLogin != .unavailable {
                    row(ok: model.openAtLogin == .on, title: "Open at login", detail: openAtLoginDetail) {
                        switch model.openAtLogin {
                        case .on: Button("Turn Off") { model.setOpenAtLogin(false) }
                        case .off: Button("Turn On") { model.setOpenAtLogin(true) }
                        case .needsApproval: Button("Open Settings") { LoginItem.openSettings() }
                        case .unavailable: EmptyView()
                        }
                    }
                }
                Button("Check Again") { model.refresh() }.padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var claudeDetail: String {
        switch model.claudeStatus {
        case nil: return model.usesClaude ? "Checking Claude Code…" : "Not checked (it sends a tiny request to Anthropic)."
        case .ready?: return "Ready: Haiku decides which notifications matter. Nothing else to set up."
        case .failing?: return "Installed, but it didn't answer. It probably needs you to sign in once."
        case .notInstalled?: return "Not installed yet."
        }
    }

    private var openAtLoginDetail: String {
        switch model.openAtLogin {
        case .on: return "FocusDock starts when you log in, so the dock is there whenever your Mac starts."
        case .needsApproval: return "Turned off in System Settings. Turn FocusDock on under Login Items to start it at login."
        default: return "Off: start FocusDock yourself after logging in."
        }
    }

    private func automationDetail(_ s: Permissions.Automation) -> String {
        switch s {
        case .allowed: return "Can read the current tab and send it back on Stay."
        case .denied: return "Denied. Turn FocusDock on under Automation in System Settings."
        case .notAsked: return "Needed to read the current tab and send it back on Stay."
        case .notRunning: return "Open the browser once so macOS can ask."
        }
    }

    private func automationButton(_ s: Permissions.Automation) -> String {
        switch s {
        case .denied: return "Open Settings"
        case .notRunning: return "Open Browser"
        default: return "Allow"
        }
    }

    // MARK: Do Not Disturb

    private var focus: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("macOS only lets apps change Focus through Shortcuts. FocusDock makes two shortcuts on this Mac (Do Not Disturb on / off); Shortcuts asks you to add each one.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            row(ok: model.shortcutsInstalled, title: "\(FocusShortcuts.onName) / \(FocusShortcuts.offName)",
                detail: model.shortcutsError ?? (model.shortcutsInstalled ? "Added to Shortcuts." : "Not added yet.")) {
                if model.shortcutsBusy {
                    ProgressView().controlSize(.small)
                } else if !model.shortcutsInstalled {
                    Button("Create Shortcuts") { model.installShortcuts() }
                } else {
                    Button("Recreate") { model.installShortcuts() }
                        .help("Make them again; Shortcuts offers to replace the old ones")
                }
            }
            if model.shortcutsInstalled {
                HStack(spacing: 8) {
                    Button("Stop Using Do Not Disturb") { model.stopUsingDoNotDisturb() }
                    Button("Open in Shortcuts") { FocusShortcuts.view(FocusShortcuts.onName) }
                        .help("Shortcuts can only be deleted in the Shortcuts app")
                }
                .controlSize(.small)
            }
            Divider()
            Text("Hide banners (Do Not Disturb) in").font(.system(size: 13, weight: .semibold))
            ForEach(model.modes) { mode in
                Toggle(isOn: Binding(get: { model.hidesBanners(in: mode.id) },
                                     set: { model.setHidesBanners($0, in: mode.id) })) {
                    Label(mode.name, systemImage: mode.symbol)
                }
                .toggleStyle(.checkbox)
                .disabled(!model.shortcutsInstalled)
            }
            Text("Notifications from another mode's apps still reach you as FocusDock cards when they're urgent.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
    }

    // MARK: Apps

    private var appsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            pendingBanner
            HStack {
                TextField("Search apps", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                if model.suggesting {
                    ProgressView(value: Double(model.suggestProgress.done), total: Double(max(model.suggestProgress.total, 1)))
                        .frame(width: 120)
                    Text("\(model.suggestProgress.done)/\(model.suggestProgress.total)").font(.system(size: 11).monospacedDigit())
                } else {
                    Button { model.suggest() } label: { Label("Suggest for unplaced apps", systemImage: "sparkles") }
                        .disabled(!model.appleModel.ok && model.store.config.classifier.provider == "apple")
                }
            }
            List(model.visibleApps) { app in
                HStack(spacing: 10) {
                    Group {
                        if let icon = AppLauncher.icon(for: app.bundleID) { Image(nsImage: icon).resizable() }
                        else { Image(systemName: "app").resizable() }
                    }
                    .frame(width: 22, height: 22)
                    Text(app.name)
                    if model.suggested.contains(app.bundleID) {
                        Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(Color.purple)
                    }
                    Spacer()
                    if model.isBrowser(app.bundleID) {
                        Text("every mode, judged by tab").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        let ids = model.modeIDs(of: app.bundleID)
                        ForEach(model.modes) { mode in modeChip(mode, on: ids.contains(mode.id)) { model.toggle(app.bundleID, in: mode.id) } }
                    }
                    let hidden = model.isDockHidden(app.bundleID)
                    Button { model.toggleDockHidden(app.bundleID) } label: {
                        Image(systemName: hidden ? "eye.slash" : "eye")
                            .foregroundStyle(hidden ? Color.secondary : Color.primary)
                            .frame(width: 22)
                    }
                    .buttonStyle(.plain)
                    .help(hidden ? "Hidden from the dock (still allowed in its modes)" : "Shown in the dock")
                }
                .padding(.vertical, 2)
            }
        }
        .padding(8)
    }

    // MARK: Sites

    private var sitesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            pendingBanner
            HStack {
                TextField("Search sites", text: $model.siteSearch).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Spacer()
                TextField("Add a site, e.g. canvas.instructure.com", text: $model.newSite)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    .onSubmit { model.addSite() }
                Picker("", selection: $model.newSiteMode) {
                    ForEach(model.modes) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 110)
                .onAppear { if model.newSiteMode.isEmpty { model.newSiteMode = model.modes.first?.id ?? "" } }
                Button("Add") { model.addSite() }.disabled(SetupModel.domain(from: model.newSite) == nil)
            }
            List(model.visibleSites, id: \.self) { domain in
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text(domain)
                    Spacer()
                    let ids = model.siteModeIDs(domain)
                    ForEach(model.modes) { mode in modeChip(mode, on: ids.contains(mode.id)) { model.toggleSite(domain, in: mode.id) } }
                    Button { model.removeSite(domain) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Remove from every mode")
                }
                .padding(.vertical, 2)
            }
            Text("Subdomains are included. Letting a Social site (or one that used to be) into Study or Research takes the same wait as going to Social.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(8)
    }

    /// Shown while a change that loosens focus waits out its countdown.
    @ViewBuilder
    private var pendingBanner: some View {
        if let p = model.pendingChange {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(ceil(p.readyAt.timeIntervalSince(ctx.date))))
                HStack(spacing: 8) {
                    Image(systemName: "hourglass").foregroundStyle(Color.orange)
                    Text("Allowing \(p.label) in \(model.pendingModeNames(p)) makes it usable while you focus, so it takes the Social wait.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel") { model.cancelPending() }.controlSize(.small)
                    Button(left > 0 ? "Allow in \(formatCountdown(Double(left)))" : "Allow") { model.confirmPending() }
                        .controlSize(.small).disabled(left > 0)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
        }
    }

    // MARK: Notifications

    private var notificationsTab: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who decides").font(.system(size: 13, weight: .semibold))
            Picker("", selection: Binding(get: { model.triageProvider }, set: { model.triageProvider = $0; model.refresh() })) {
                Text("This Mac only").tag("local")
                Text("Ask Claude when unsure").tag("auto")
                Text("Off").tag("off")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460)
            Text(model.usesClaude
                 ? "Your reactions, built-in examples and the on-device model decide first, all on this Mac. Only what they can't settle goes to Claude Haiku, with the notes below."
                 : "Everything is decided on this Mac from your reactions and built-in examples. When those can't tell, the card asks you, and your answer is remembered. Nothing is sent anywhere.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Text("Local memory").font(.system(size: 13, weight: .semibold))
            localMemory
            Divider()
            HStack {
                Text("Notes on what matters").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.profileEdited {
                    Button("Save") { model.saveProfile() }.controlSize(.small)
                }
                Button(model.pendingCount > 0 ? "Update from \(model.pendingCount) new reactions" : "Up to date") { model.updateProfileNow() }
                    .controlSize(.small)
                    .disabled(model.pendingCount == 0 || !model.usesClaude)
            }
            Text("Only used when Claude is on. Like a CLAUDE.md for your notifications: Claude rewrites it from your reactions every 5 new ones and keeps it to 12 lines. You can edit it.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.profileDraft)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                .onAppear { model.loadProfile() }
            Divider()

            Text("VIPs").font(.system(size: 13, weight: .semibold))
            Text("Notifications from these people always get a card, from any app and in any mode. A name matches when it appears in the sender or chat name.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Name, e.g. 엄마 or Maya Chen", text: $model.newVIP)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    .onSubmit { model.addVIP() }
                Button("Add") { model.addVIP() }.disabled(model.newVIP.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !model.vips.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.vips, id: \.self) { name in
                        HStack {
                            Image(systemName: "star.fill").foregroundStyle(Color.yellow).font(.system(size: 11))
                            Text(name)
                            Spacer()
                            Button { model.removeVIP(name) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }
                .frame(maxWidth: 360)
            }
            Divider()
            HStack {
                Text("What matters to you").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.examples.isEmpty { Button("Clear All") { model.clearExamples() }.controlSize(.small) }
            }
            Text("Cards start lenient. Your reactions become examples the on-device classifier follows for similar notifications: 👎 on a card means not important, Go to means important. One per sender is kept (the newest), and the newest 12 are used.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.examples.isEmpty {
                Text("No reactions yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                List(model.examples) { e in
                    HStack(spacing: 8) {
                        Button { model.setExample(e, important: !e.important) } label: {
                            Image(systemName: e.important ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                                .foregroundStyle(e.important ? Color.green : Color.secondary)
                        }
                        .buttonStyle(.borderless).help(e.important ? "Important (click to flip)" : "Not important (click to flip)")
                        Text("\(e.sender) · \(e.app)").font(.system(size: 12, weight: .semibold))
                        Text(e.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button { model.forget(e) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                    }
                }
                .frame(minHeight: 120)
            }
            if !model.quietNotes.isEmpty {
                Text("Held without a card (since FocusDock started)").font(.system(size: 13, weight: .semibold))
                List(model.quietNotes) { q in
                    HStack(spacing: 8) {
                        Text(q.notification.title).font(.system(size: 12, weight: .semibold))
                        Text(q.notification.body).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Should have shown") { model.shouldHaveShown(q) }.controlSize(.small)
                    }
                }
                .frame(minHeight: 100)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        }
    }

    /// The embedding model: download state, and how many reactions it remembers.
    @ViewBuilder
    private var localMemory: some View {
        if downloader.isReady {
            HStack(alignment: .top) {
                Text("EmbeddingGemma is ready. \(model.memoryCount()) reactions remembered. A notification that clearly matches them is decided on this Mac, without asking Claude.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Clear Memory") { model.clearReactionMemory() }.controlSize(.small).disabled(model.memoryCount() == 0)
            }
        } else if let p = downloader.progress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p).frame(maxWidth: 320)
                Text("Downloading EmbeddingGemma (318 MB, once): \(Int(p * 100))%").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if let error = downloader.error {
            HStack {
                Text(error).font(.system(size: 12)).foregroundStyle(Color.orange)
                Button("Retry") { downloader.start() }.controlSize(.small)
            }
        } else if EmbeddingService.serverURL == nil {
            Text("The embedding server isn't in this build, so reactions are only used by the classifier.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            HStack {
                Text("Remembers your reactions with a small on-device model so look-alikes are decided locally.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Download (318 MB)") { downloader.start() }.controlSize(.small)
            }
        }
    }

    private func modeChip(_ mode: Mode, on: Bool, action: @escaping () -> Void) -> some View {
        let tint = Color(hex: mode.color)
        return Button(action: action) {
            Image(systemName: mode.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.secondary)
                .frame(width: 26, height: 22)
                .background(Capsule().fill(on ? tint : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(on ? "In \(mode.name)" : "Add to \(mode.name)")
    }

    // MARK: Shared

    private func row<Trailing: View>(ok: Bool, title: String, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
    }
}
