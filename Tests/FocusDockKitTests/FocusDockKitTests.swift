import Foundation
import Testing
@testable import FocusDockKit

// Swift Testing (not XCTest) so `swift test` also runs with Command Line Tools only.

@Suite struct ConfigTests {
    @Test func hostMatchingIncludesSubdomainsOnly() {
        #expect(AppConfig.host("x.com", matches: "x.com"))
        #expect(AppConfig.host("mobile.x.com", matches: "x.com"))
        #expect(AppConfig.host("Docs.Google.com", matches: "docs.google.com"))
        #expect(!AppConfig.host("notx.com", matches: "x.com"))
        #expect(!AppConfig.host("x.com.evil.io", matches: "x.com"))
    }

    @Test func oldConfigWithPerPressStillDecodes() throws {
        let json = #"{"defaultDelay": 0, "delays": {"social": 30}, "perPress": 5}"#
        let rule = try JSONDecoder().decode(ExitRule.self, from: Data(json.utf8))
        #expect(rule.delay(to: "social") == 30)
    }

    @Test func modeOwnership() {
        let cfg = ConfigStore.defaultConfig
        #expect(cfg.modeOwning(host: "www.youtube.com")?.id == "social")
        #expect(cfg.modeOwning(host: "github.com")?.id == "research")
        #expect(cfg.modeOwning(host: "tidepool.dev") == nil)
        #expect(cfg.modeOwning(bundleID: "dev.zed.Zed")?.id == "research")
    }

    @Test func exitDelayPerTarget() throws {
        let study = try #require(ConfigStore.defaultConfig.mode("study"))
        #expect(study.exit.delay(to: "social") == 30)
        #expect(study.exit.delay(to: "research") == 0)
        let research = try #require(ConfigStore.defaultConfig.mode("research"))
        #expect(research.exit.delay(to: "social") == 15)
    }

    @Test func defaultConfigRoundTrips() throws {
        let data = try JSONEncoder().encode(ConfigStore.defaultConfig)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(back.modes == ConfigStore.defaultConfig.modes)
        #expect(back.classifier == ConfigStore.defaultConfig.classifier)
    }

    @Test func configFromBeforeLearnedStillLoads() throws {
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConfigStore.defaultConfig)) as? [String: Any])
        for key in ["learned", "dockHidden", "notificationExamples", "vips", "notificationProfile", "profileUpdatedAt", "distractions"] { obj[key] = nil }
        let cfg = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(cfg.learned.isEmpty && cfg.dockHidden.isEmpty && cfg.notificationExamples.isEmpty && cfg.vips.isEmpty)
        #expect(cfg.modes == ConfigStore.defaultConfig.modes)
    }

    @Test func socialIsTheGuardedModeAndLooseningTakesItsWait() {
        let cfg = ConfigStore.defaultConfig
        #expect(cfg.guardedModeIDs == ["social"])
        #expect(cfg.correctionWait == 30)
        #expect(cfg.needsWait(.app, "com.tinyspeck.slackmacgap", newModes: ["social", "study"]))   // Slack while studying
        #expect(cfg.needsWait(.site, "x.com", newModes: ["research"]))
        #expect(!cfg.needsWait(.site, "x.com", newModes: []))                    // taking it out of Social
        #expect(!cfg.needsWait(.site, "github.com", newModes: ["study"]))        // between focus modes
        #expect(!cfg.needsWait(.site, "arxiv.org", newModes: ["study", "research", "social"]))
        #expect(cfg.isDistraction(.site, "mobile.x.com"))
    }

    @Test func papersOpenInBothFocusModes() {
        let cfg = ConfigStore.defaultConfig
        #expect(cfg.modeIDs(listing: .site, "arxiv.org") == ["study", "research"])
        #expect(cfg.modeIDs(listing: .site, "overleaf.com") == ["study", "research"])
    }

    @Test func setupOpensWhenThereIsSomethingToSetUp() {
        #expect(SetupModel.opensAtLaunch(firstLaunch: true, canReadNotifications: true, build: "2", lastOpenedBuild: nil))
        #expect(!SetupModel.opensAtLaunch(firstLaunch: false, canReadNotifications: true, build: "2", lastOpenedBuild: "1"))
        // An update dropped Full Disk Access: once for this build, not at every login after.
        #expect(SetupModel.opensAtLaunch(firstLaunch: false, canReadNotifications: false, build: "2", lastOpenedBuild: "1"))
        #expect(!SetupModel.opensAtLaunch(firstLaunch: false, canReadNotifications: false, build: "2", lastOpenedBuild: "2"))
    }

    @Test func starCardShowsUntilAnsweredOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "focusdock.tests.\(UUID().uuidString)"))
        let s = ModeStore(config: ConfigStore.defaultConfig)
        #expect(s.starCard == nil)
        s.showStarCardIfNew(defaults)
        #expect(s.starCard == .asking)
        s.dismissStarCard(defaults)                       // Not now
        #expect(s.starCard == nil)
        s.showStarCardIfNew(defaults)                     // next launch
        #expect(s.starCard == nil)
    }

    @Test func starsWithGitHubCLIOrOpensThePage() throws {
        let defaults = try #require(UserDefaults(suiteName: "focusdock.tests.\(UUID().uuidString)"))
        let s = ModeStore(config: ConfigStore.defaultConfig)
        var opened = 0
        s.showStarCardIfNew(defaults)
        s.starOnGitHub(openPage: { opened += 1 }, star: { $0(true) }, defaults: defaults)    // gh signed in
        #expect(s.starCard == .starred && opened == 0)
        #expect(defaults.bool(forKey: ModeStore.starCardKey))
        s.starOnGitHub(openPage: { opened += 1 }, star: { $0(false) }, defaults: defaults)   // no gh
        #expect(s.starCard == .openedPage && opened == 1)
    }

    @Test func opensAtLoginUnlessTurnedOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "focusdock.tests.\(UUID().uuidString)"))
        #expect(LoginItem.isWanted(defaults))                                  // on by default
        #expect(LoginItem.shouldRegister(wanted: true, state: .off))           // first launch, or dropped by an update
        #expect(!LoginItem.shouldRegister(wanted: true, state: .on))
        #expect(!LoginItem.shouldRegister(wanted: true, state: .needsApproval)) // turned off in System Settings
        #expect(!LoginItem.shouldRegister(wanted: true, state: .unavailable))  // swift run
        defaults.set(false, forKey: LoginItem.wantedKey)
        #expect(!LoginItem.isWanted(defaults))
        #expect(!LoginItem.shouldRegister(wanted: false, state: .off))
    }

    @Test func classifierConfigToleratesMissingKeys() throws {
        let c = try JSONDecoder().decode(ClassifierConfig.self, from: Data(#"{"provider":"apple"}"#.utf8))
        #expect(c.provider == "apple")
        #expect(c.typesafeModel == "jev-latest")
        #expect(c.minConfidence == 0.5)
        #expect(c.triageProvider == "local")
    }
}

@Suite struct ConfigStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusDockTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    @Test func missingFileWritesDefaults() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cfg = ConfigStore.load(from: url)
        #expect(cfg.modes == ConfigStore.defaultConfig.modes)
        let back = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        #expect(back.modes == ConfigStore.defaultConfig.modes)
    }

    @Test func unparseableFileIsKeptNotOverwritten() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data(#"{"modes": [ {"id": "study",, } ]"#.utf8)
        try broken.write(to: url)

        let cfg = ConfigStore.load(from: url)
        #expect(cfg.modes == ConfigStore.defaultConfig.modes)
        #expect(try Data(contentsOf: url) == broken)
        let backup = url.deletingLastPathComponent().appendingPathComponent("config.invalid.json")
        #expect(try Data(contentsOf: backup) == broken)
    }
}

/// ModeStore touches UserDefaults and schedules a main-runloop timer, so run serially on the main actor.
@MainActor @Suite(.serialized) final class ModeStoreTests {
    private var store: ModeStore
    private var activated: [String] = []
    /// Saves go here, never to the user's real config.json.
    private let configURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FocusDockTests-\(UUID().uuidString).json")

    init() {
        UserDefaults.standard.removeObject(forKey: "currentMode")
        store = ModeStore(config: ConfigStore.defaultConfig, configURL: configURL)
        store.activate("study")
        activated = []
        store.onActivate = { [unowned self] in self.activated.append($0.id) }
    }

    deinit {
        UserDefaults.standard.removeObject(forKey: "currentMode")
        try? FileManager.default.removeItem(at: configURL)
    }

    @Test func learnedItemsAreRecordedAndCanBeUndone() throws {
        store.learn(.app(bundleID: "com.google.antigravity-ide", name: "Antigravity"), into: "research")
        store.learn(.site(host: "www.tidepool.dev", title: "", browserID: ""), into: "research")
        #expect(store.config.mode("research")?.apps.contains("com.google.antigravity-ide") == true)
        #expect(store.config.mode("research")?.domains.contains("tidepool.dev") == true)
        #expect(store.config.learned.map(\.value) == ["com.google.antigravity-ide", "tidepool.dev"])

        store.unlearn(try #require(store.config.learned.first))
        #expect(store.config.mode("research")?.apps.contains("com.google.antigravity-ide") == false)
        #expect(store.config.learned.map(\.value) == ["tidepool.dev"])
        // Persisted to the injected file.
        let saved = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configURL))
        #expect(saved.learned.map(\.value) == ["tidepool.dev"])
    }

    @Test func learningSomethingAlreadyThereRecordsNothing() {
        store.learn(.app(bundleID: "dev.zed.Zed", name: "Zed"), into: "research")
        #expect(store.config.learned.isEmpty)
    }

    @Test func setupPlacesAnAppInExactlyTheChosenModes() {
        store.learn(.app(bundleID: "md.obsidian", name: "Obsidian"), into: "research")
        store.setModes(["study", "research"], forApp: "md.obsidian")
        #expect(store.config.mode("study")?.apps.contains("md.obsidian") == true)
        #expect(store.config.mode("research")?.apps.contains("md.obsidian") == true)
        #expect(store.config.learned.isEmpty)   // chosen by hand now
        store.setModes([], forApp: "md.obsidian")
        #expect(store.config.modeOwning(bundleID: "md.obsidian") == nil)
    }

    @Test func doNotDisturbShortcutsFollowTheChosenModes() {
        store.setFocusShortcuts(on: ["study", "research"])
        #expect(store.config.mode("study")?.shortcut == FocusShortcuts.onName)
        #expect(store.config.mode("research")?.shortcut == FocusShortcuts.onName)
        #expect(store.config.mode("social")?.shortcut == FocusShortcuts.offName)
        store.setFocusShortcuts(on: [])
        #expect(store.config.modes.allSatisfy { $0.shortcut == nil })
    }

    @Test func requestStartsCountdownInsteadOfSwitching() {
        store.request("social")
        #expect(store.currentID == "study")
        #expect(store.pending?.modeID == "social")
        #expect(store.pending?.total == 30)
        #expect(activated.isEmpty)
    }

    @Test func countdownStartsAtFullDelay() throws {
        store.request("social")
        let p = try #require(store.pending)
        // A stale `now` made this briefly exceed total: negative progress width and "0:31".
        #expect(store.remaining(p) <= p.total)
        #expect(formatCountdown(store.remaining(p)) == "0:30")
    }

    @Test func extraPressesDoNotShortenWait() throws {
        store.request("social")
        let before = try #require(store.pending?.deadline)
        for _ in 0..<10 { store.request("social") }   // pressing Social again and again
        #expect(store.pending?.deadline == before)
        #expect(store.currentID == "study")
        #expect(activated.isEmpty)
    }

    @Test func stayCancels() {
        store.request("social")
        store.cancelPending()
        #expect(store.pending == nil)
        #expect(store.currentID == "study")
    }

    @Test func pressingCurrentModeCancels() {
        store.request("social")
        store.request("study")
        #expect(store.pending == nil)
    }

    @Test func focusModesSwitchInstantlyOnlySocialWaits() {
        store.request("research")
        #expect(store.currentID == "research")
        #expect(store.pending == nil)
        store.request("study")
        #expect(store.currentID == "study")
        store.request("social")
        #expect(store.pending?.modeID == "social")
        #expect(activated == ["research", "study"])
    }

    @Test func instantTargetWhilePendingSwitchesAndClearsCountdown() {
        store.request("social")
        store.request("research")
        #expect(store.currentID == "research")
        #expect(store.pending == nil)
    }

    @Test func requestingDifferentTargetRestartsCountdown() {
        var cfg = ConfigStore.defaultConfig
        cfg.modes[0].exit.delays["research"] = 20   // study -> research waits in this config
        let s = ModeStore(config: cfg)
        s.activate("study")
        s.request("social")
        s.request("research")
        #expect(s.pending?.modeID == "research")
        #expect(s.pending?.total == 20)
    }

    @Test func zeroDelaySwitchesInstantly() {
        store.activate("social")
        store.request("study")   // social has defaultDelay 0
        #expect(store.currentID == "study")
    }

    @Test func stayOnPromptCallsHandlerAndDismisses() {
        var stayed: Subject?
        store.onStay = { stayed = $0 }
        let s = Subject.site(host: "x.com", title: "Home", browserID: "com.google.Chrome")
        store.show(Prompt(subject: s, kind: .belongsTo(modeID: "social", reason: nil)))
        store.stay()
        #expect(stayed == s)
        #expect(store.prompt == nil)
    }

    @Test func heldNotificationsCountUntilThatModeIsEntered() {
        store.hold(for: "social")
        store.hold(for: "social")
        store.hold(for: "research")
        #expect(store.held == ["social": 2, "research": 1])
        store.request("research")   // instant
        #expect(store.held == ["social": 2])
    }

    private func heldCard(_ title: String, for modeID: String = "social") -> Prompt {
        let n = HeldNotification(id: Int64(title.count), bundleID: "com.tinyspeck.slackmacgap", title: title, subtitle: "", body: "")
        return Prompt(subject: .notification(n), kind: .held(HeldInfo(modeID: modeID, reason: "", urgent: true, vip: false)))
    }

    private func askCard(_ title: String) -> Prompt {
        let n = HeldNotification(id: Int64(title.count), bundleID: "com.kakao.KakaoTalkMac", title: title, subtitle: "", body: "hi")
        return Prompt(subject: .notification(n), kind: .held(HeldInfo(modeID: "social", reason: "", urgent: false, vip: false, asking: true)))
    }

    @Test func answeringAQuestionCardRemembersIt() {
        let yes = askCard("엄마"), no = askCard("단톡방")
        store.ask(yes); store.ask(no)
        store.answer(yes.id, important: true)
        store.answer(no.id, important: false)
        #expect(store.config.notificationExamples.map(\.important) == [true, false])
        // "Important" stays up as a regular card and counts; "not important" is gone.
        #expect(store.notes.count == 1)
        if case .held(let info)? = store.notes.first?.kind { #expect(!info.asking && info.urgent) }
        #expect(store.held["social"] == 1)
    }

    @Test func unansweredQuestionsGoAwayWithoutCounting() async throws {
        store.askSeconds = 0.05
        store.ask(askCard("Sam"))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(store.notes.isEmpty && store.held.isEmpty && store.config.notificationExamples.isEmpty)
    }

    @Test func reactionsBecomeExamples() throws {
        let a = heldCard("Jin"), b = heldCard("Maya")
        store.hold(for: "social"); store.hold(for: "social")
        store.showHeld(a); store.showHeld(b)
        store.notImportant(a.id)
        store.goFromNote(b.id)
        let ex = store.config.notificationExamples
        #expect(ex.map(\.sender) == ["Jin", "Maya"])
        #expect(ex.map(\.important) == [false, true])
        #expect(store.notes.isEmpty && store.held["social"] == nil)
        #expect(store.pending?.modeID == "social")
        let saved = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configURL))
        #expect(saved.notificationExamples.count == 2)
    }

    @Test func aMissedOneCanBeMarkedImportant() throws {
        let n = HeldNotification(id: 7, bundleID: "com.kakao.KakaoTalkMac", title: "엄마", subtitle: "", body: "언제 와?")
        store.rememberQuiet(n, reason: "asks when you're coming")
        let q = try #require(store.quietNotes.first)
        store.shouldHaveShown(q.id)
        #expect(store.quietNotes.isEmpty)
        #expect(store.config.notificationExamples.last?.important == true)
        #expect(store.config.notificationExamples.last?.reason == "asks when you're coming")
    }

    @Test func notesCoverReactionsUpToTheirUpdate() {
        var reactions = 0
        store.onReaction = { _, _ in reactions += 1 }
        let n = HeldNotification(id: 1, bundleID: "x.y", title: "엄마", subtitle: "", body: "언제 와?")
        store.remember(n, reason: "asks", important: true)
        #expect(reactions == 1)
        #expect(store.pendingExamples.count == 1)
        store.applyProfileUpdate("- Messages from 엄마 matter.", through: store.config.notificationExamples[0].date)
        #expect(store.pendingExamples.isEmpty)
        #expect(store.config.notificationProfile == "- Messages from 엄마 matter.")
        store.remember(HeldNotification(id: 2, bundleID: "x.y", title: "Jin", subtitle: "", body: "lol"), reason: "", important: false)
        #expect(store.pendingExamples.map(\.sender) == ["Jin"])
    }

    @Test func leavingSocialStillDoesNotLetItIntoAFocusMode() {
        var forgotten: [String] = []
        store.onForget = { _, value in forgotten.append(value) }
        store.setModes([], for: .site, "x.com")   // immediate
        #expect(store.config.modeOwning(host: "x.com") == nil)
        #expect(store.config.distractions == ["x.com"])
        #expect(forgotten == ["x.com"])
        #expect(store.config.needsWait(.site, "x.com", newModes: ["study"]))
        // Its card in Study offers no "Allow in Study".
        #expect(!store.canAllowHere(.site(host: "x.com", title: "", browserID: "")))
        #expect(store.canAllowHere(.site(host: "tidepool.dev", title: "", browserID: "")))
    }

    @Test func belongsHereFixesAClassifierGuessBetweenFocusModes() {
        store.learn(.site(host: "klms.kaist.ac.kr", title: "", browserID: ""), into: "research")
        let site = Subject.site(host: "klms.kaist.ac.kr", title: "KLMS", browserID: "com.google.Chrome")
        var moved: Subject?
        store.onMovedHere = { moved = $0 }
        store.show(Prompt(subject: site, kind: .belongsTo(modeID: "research", reason: nil)))
        #expect(store.canBelongHere(site, owner: "research"))
        store.moveHere()
        #expect(store.config.modeIDs(listing: .site, "klms.kaist.ac.kr") == ["study"])
        #expect(store.config.learned.isEmpty && store.prompt == nil && moved == site)
        // Not offered for defaults (not a guess) or for anything in Social.
        #expect(!store.canBelongHere(.site(host: "github.com", title: "", browserID: ""), owner: "research"))
        store.learn(.site(host: "twitch.tv", title: "", browserID: ""), into: "social")
        #expect(!store.canBelongHere(.site(host: "twitch.tv", title: "", browserID: ""), owner: "social"))
    }

    @Test func learnedItemsMoveBetweenFocusModesButNotOutOfSocial() throws {
        store.learn(.app(bundleID: "com.google.antigravity-ide", name: "Antigravity"), into: "research")
        store.learn(.site(host: "twitch.tv", title: "", browserID: ""), into: "social")
        let app = try #require(store.config.learned.first { $0.kind == .app })
        let site = try #require(store.config.learned.first { $0.kind == .site })
        #expect(!store.needsWait(app, to: "study"))
        #expect(store.needsWait(site, to: "study"))
        store.move(app, to: "study")
        #expect(store.config.modeIDs(listing: .app, "com.google.antigravity-ide") == ["study"])
        store.unlearn(site)   // always allowed; it stays a distraction
        #expect(store.config.isDistraction(.site, "twitch.tv"))
    }

    @Test func examplesKeepTheNewestPerSenderAndAreCapped() {
        let a = HeldNotification(id: 1, bundleID: "x.y", title: "동기", subtitle: "", body: "ㅋㅋㅋ")
        let b = HeldNotification(id: 2, bundleID: "x.y", title: "동기", subtitle: "", body: "오늘 경기 봤냐")
        store.remember(a, reason: "banter", important: false)
        store.remember(b, reason: "banter", important: false)
        #expect(store.config.notificationExamples.map(\.text) == ["오늘 경기 봤냐"])
        store.remember(a, reason: "banter", important: true)   // changed mind
        #expect(store.config.notificationExamples.map(\.important) == [true])
        for i in 0..<40 {
            store.remember(HeldNotification(id: Int64(i), bundleID: "x.y", title: "S\(i)", subtitle: "", body: "t"), reason: "", important: true)
        }
        #expect(store.config.notificationExamples.count == 30)
        #expect(store.config.notificationExamples.last?.sender == "S39")
        #expect(store.config.notificationExamples.last?.reason == "needs your attention")   // filled in when empty
    }

    @Test func vipsAreAddedOnceAndRemoved() {
        store.addVIP(" 엄마 ")
        store.addVIP("엄마")
        #expect(store.config.vips == ["엄마"])
        store.removeVIP("엄마")
        #expect(store.config.vips.isEmpty)
    }

    @Test func hiddenAppsStayAllowedButLeaveTheDock() {
        store.activate("research")
        store.setDockHidden(true, for: "dev.zed.Zed")
        #expect(!store.dockApps.contains("dev.zed.Zed"))
        #expect(store.current.apps.contains("dev.zed.Zed"))
        store.setDockHidden(false, for: "dev.zed.Zed")
        #expect(store.dockApps.contains("dev.zed.Zed"))
    }

    @Test func notificationCardsStackAndAreDismissedOneByOne() {
        let a = heldCard("A"), b = heldCard("BB")
        for _ in 0..<2 { store.hold(for: "social") }
        store.showHeld(a)
        store.showHeld(b)
        #expect(store.notes.map(\.id) == [a.id, b.id])
        store.dismissNote(a.id)   // Later on the first one
        #expect(store.notes.map(\.id) == [b.id])
        #expect(store.held["social"] == 1)
        store.dismissNote(b.id)
        #expect(store.held["social"] == nil)
    }

    @Test func appPromptDoesNotHideNotificationCards() {
        let a = heldCard("A")
        store.showHeld(a)
        store.show(Prompt(subject: .app(bundleID: "us.zoom.xos", name: "Zoom"), kind: .unknown(reason: nil)))
        store.stay()
        #expect(store.prompt == nil)
        #expect(store.notes.map(\.id) == [a.id])
    }

    @Test func goingToTheModeDropsItsCards() {
        store.showHeld(heldCard("A"))
        store.showHeld(heldCard("BB"))
        store.showHeld(heldCard("CCC", for: "research"))
        store.goTo("social")
        #expect(store.notes.map { $0.subject.label } == ["CCC"])   // only the other mode's card is left
        #expect(store.pending?.modeID == "social")
        store.request("research")   // instant: entering research clears its cards too
        #expect(store.notes.isEmpty)
    }

    @Test func goToFromPromptStartsCountdown() {
        let s = Subject.app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        store.show(Prompt(subject: s, kind: .belongsTo(modeID: "social", reason: nil)))
        store.goTo("social")
        #expect(store.prompt == nil)
        #expect(store.pending?.modeID == "social")
    }

    @Test func goToDuringCountdownKeepsTheWait() throws {
        store.request("social")
        let before = try #require(store.pending?.deadline)
        let s = Subject.app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        store.show(Prompt(subject: s, kind: .belongsTo(modeID: "social", reason: nil)))
        store.goTo("social")
        #expect(store.pending?.deadline == before)
    }
}

@Suite struct FocusGuardDecisionTests {
    let cfg = ConfigStore.defaultConfig
    var research: Mode { cfg.mode("research")! }

    private func verdict(_ bid: String) -> AppVerdict {
        FocusGuard.verdict(for: bid, current: research, config: cfg, selfID: "com.focusdock.app")
    }

    @Test func appVerdicts() {
        #expect(verdict("com.focusdock.app") == .ignore)
        #expect(verdict("com.apple.finder") == .ignore)
        #expect(verdict("com.google.Chrome") == .browser)   // in every mode, but judged by the tab
        #expect(verdict("dev.zed.Zed") == .allowed)
        #expect(verdict("com.tinyspeck.slackmacgap") == .otherMode("social"))
        #expect(verdict("notion.id") == .otherMode("study"))
        #expect(verdict("us.zoom.xos") == .unknown)
    }

    @Test func notificationsAreHeldOnlyForAppsOfOtherModes() {
        func mode(_ bid: String) -> String? {
            FocusGuard.holdingMode(for: bid, current: research, config: cfg, selfID: "com.focusdock.app")
        }
        #expect(mode("com.tinyspeck.slackmacgap") == "social")
        #expect(mode("com.kakao.kakaotalkmac") == "social")   // lowercased as Notification Center stores it
        #expect(mode("notion.id") == "study")
        #expect(mode("com.google.Chrome") == nil)       // part of the current mode
        #expect(mode("us.zoom.xos") == nil)             // in no mode: shown as usual
        #expect(mode("com.focusdock.app") == nil)
    }

    @Test func vipMatchesSenderOrChatName() {
        func n(_ title: String, _ subtitle: String = "") -> HeldNotification {
            HeldNotification(id: 1, bundleID: "com.kakao.KakaoTalkMac", title: title, subtitle: subtitle, body: "hi")
        }
        #expect(FocusGuard.isVIP(n("엄마"), vips: ["엄마"]))
        #expect(FocusGuard.isVIP(n("#launch", "Maya Chen"), vips: ["maya chen"]))
        #expect(!FocusGuard.isVIP(n("팀장님"), vips: ["엄마"]))
        #expect(!FocusGuard.isVIP(n("엄마"), vips: [""]))
        // Slack channel messages put the sender at the start of the body.
        let channel = HeldNotification(id: 2, bundleID: "com.tinyspeck.slackmacgap", title: "#launch", subtitle: "Acme",
                                       body: "Maya Chen: can you sign off?")
        #expect(FocusGuard.isVIP(channel, vips: ["Maya"]))
        // Merely mentioned in someone else's message: not the sender.
        let mention = HeldNotification(id: 3, bundleID: "com.tinyspeck.slackmacgap", title: "#launch", subtitle: "Acme",
                                       body: "Jin: did Maya see this? note: later")
        #expect(!FocusGuard.isVIP(mention, vips: ["Maya"]))
    }

    @Test func appToFrontPrefersLastUsedThenModeOrder() {
        let running: Set<String> = ["com.microsoft.VSCode", "com.apple.Terminal", "com.tinyspeck.slackmacgap"]
        #expect(FocusGuard.appToFront(for: research, last: "com.microsoft.VSCode", running: running) == "com.microsoft.VSCode")
        // Not running, or not part of this mode: fall back to the mode's own order (Terminal before VS Code).
        #expect(FocusGuard.appToFront(for: research, last: "dev.zed.Zed", running: running) == "com.apple.Terminal")
        #expect(FocusGuard.appToFront(for: research, last: "com.tinyspeck.slackmacgap", running: running) == "com.apple.Terminal")
        #expect(FocusGuard.appToFront(for: research, last: nil, running: ["com.tinyspeck.slackmacgap"]) == nil)
    }
}

@Suite struct InstalledAppsTests {
    private func makeApp(_ dir: URL, _ name: String, _ info: [String: Any]) throws {
        let contents = dir.appendingPathComponent("\(name).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    @Test func listsRegularAppsAndSkipsAgents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FocusDockApps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeApp(dir, "Zeta", ["CFBundleIdentifier": "test.zeta", "CFBundleName": "Zeta"])
        try makeApp(dir, "Alpha", ["CFBundleIdentifier": "test.alpha", "CFBundleName": "Alpha"])
        try makeApp(dir, "MenuThing", ["CFBundleIdentifier": "test.menu", "LSUIElement": true])
        try makeApp(dir, "Hidden", ["CFBundleIdentifier": "test.hidden"])
        let apps = InstalledApps.scan([dir], excluding: ["test.hidden"])
        #expect(apps.map(\.bundleID) == ["test.alpha", "test.zeta"])
    }
}

@Suite struct FocusShortcutsTests {
    @Test func buildsASetFocusShortcut() throws {
        for enable in [true, false] {
            let wf = FocusShortcuts.workflow(enable: enable)
            #expect(try PropertyListSerialization.data(fromPropertyList: wf, format: .binary, options: 0).count > 0)
            let action = try #require((wf["WFWorkflowActions"] as? [[String: Any]])?.first)
            #expect(action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.dnd.set")
            // Exactly what Shortcuts saves for "Set Focus: Do Not Disturb on/off".
            #expect(action["WFWorkflowActionParameters"] as? [String: Int] == ["Enabled": enable ? 1 : 0])
        }
    }
}

@Suite struct ReactionMemoryTests {
    private func unit(_ v: [Float]) -> [Float] { let n = sqrt(v.reduce(0) { $0 + $1 * $1 }); return v.map { $0 / n } }
    private func r(_ sender: String, _ important: Bool, _ v: [Float]) -> Reaction {
        Reaction(app: "KakaoTalk", sender: sender, text: sender, important: important, vector: unit(v))
    }

    @Test func decidesOnlyWhenClearlyCloserToOneSide() {
        let items = [r("엄마", true, [1, 0, 0]), r("동기", false, [0, 1, 0])]
        let mom = ReactionMemory.decide(unit([0.9, 0.1, 0]), among: items)
        #expect(mom?.important == true && mom?.nearest.sender == "엄마")
        #expect(ReactionMemory.decide(unit([0.1, 0.9, 0]), among: items)?.important == false)
        #expect(ReactionMemory.decide(unit([1, 1, 0]), among: items) == nil)          // equally close: ask a model
        #expect(ReactionMemory.decide(unit([0, 0, 1]), among: items) == nil)          // like neither
    }

    @Test func builtInExamplesCoverBothKindsAndBothLanguages() {
        let s = ReactionMemory.seeds
        let hangul = { (t: String) in t.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
        #expect(s.contains { $0.important } && s.contains { !$0.important })
        #expect(s.contains { hangul($0.body) } && s.contains { !hangul($0.body) })
        #expect(ReactionMemory.seedMargin > ReactionMemory.minMargin)   // generic examples decide more cautiously
        let items = [Reaction(app: "", sender: "a", text: "a", important: true, vector: [1, 0]),
                     Reaction(app: "", sender: "b", text: "b", important: false, vector: [0, 1])]
        let v: [Float] = [0.75, 0.66]   // margin about 0.09: enough for reactions, not for examples
        #expect(ReactionMemory.decide(v, among: items) != nil)
        #expect(ReactionMemory.decide(v, among: items, minMargin: ReactionMemory.seedMargin) == nil)
    }

    @Test func aSingleAnswerAlreadyCountsWithExamplesAsTheOtherSide() {
        let kim = r("Kim", false, [1, 0, 0])
        let seeds = [r("Manager", true, [0, 1, 0]), r("Store", false, [0, 0, 1])]
        // Like Kim's message: decided by that reaction, with an example standing in for "important".
        #expect(ReactionMemory.decideFromReactions(unit([0.9, 0.2, 0]), reactions: [kim], seeds: seeds)?.nearest == kim)
        // Closest to an example instead: not the user's reaction, so this stage doesn't decide.
        #expect(ReactionMemory.decideFromReactions(unit([0.1, 0.9, 0]), reactions: [kim], seeds: seeds) == nil)
        #expect(ReactionMemory.decideFromReactions(unit([1, 0, 0]), reactions: [], seeds: seeds) == nil)
    }

    @Test func needsReactionsOfBothKinds() {
        #expect(ReactionMemory.decide(unit([1, 0]), among: [r("동기", false, [1, 0])]) == nil)
    }

    @Test func storesVectorsCompactlyAndKeepsTheNewestAnswer() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reactions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let m = ReactionMemory(url: url)
        m.add(r("엄마", true, [0.6, 0.8]))
        m.add(r("엄마", false, [0.6, 0.8]))   // same message, changed mind
        let reloaded = ReactionMemory(url: url)
        #expect(reloaded.items.count == 1 && reloaded.items[0].important == false)
        #expect(reloaded.items[0].vector == [0.6, 0.8])
        for i in 0..<(ReactionMemory.capacity + 5) { m.add(r("s\(i)", true, [1, 0])) }
        #expect(m.items.count == ReactionMemory.capacity)
    }

    @Test func readsBothEmbeddingResponseShapes() {
        let nested = Data(#"[{"index": 0, "embedding": [[3, 4]]}]"#.utf8)
        let flat = Data(#"{"embedding": [3, 4]}"#.utf8)
        #expect(EmbeddingService.parseEmbedding(nested) == [0.6, 0.8])
        #expect(EmbeddingService.parseEmbedding(flat) == [0.6, 0.8])
        #expect(EmbeddingService.parseEmbedding(Data("{}".utf8)) == nil)
        #expect(EmbeddingService.prompt("엄마: 언제 와?") == "task: sentence similarity | query: 엄마: 언제 와?")
    }

    @Test func downloadedServerIsClearedToRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("llama-server")
        try Data("x".utf8).write(to: file)
        let flag = "0081;00000000;Safari;"
        #expect(setxattr(file.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0) == 0)
        EmbeddingService.clearQuarantine(in: dir)
        #expect(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
    }

    @Test func hashesFilesForTheDownloadCheck() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(EmbeddingModel.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct SiteInputTests {
    @Test func turnsWhateverIsPastedIntoADomain() {
        #expect(SetupModel.domain(from: "https://www.KLMS.kaist.ac.kr/course?id=1") == "klms.kaist.ac.kr")
        #expect(SetupModel.domain(from: " calendar.google.com ") == "calendar.google.com")
        #expect(SetupModel.domain(from: "localhost:3000") == nil)
        #expect(SetupModel.domain(from: "not a site") == nil)
    }
}

@Suite struct PageCoverTests {
    @Test func convertsWindowBoundsAndLeavesTheToolbarUncovered() {
        // CoreGraphics: top-left origin. A window 50pt below the top of a 1440pt-tall primary screen.
        let f = PageCover.appKitFrame(cgBounds: CGRect(x: 100, y: 50, width: 800, height: 600),
                                      primaryHeight: 1440, topInset: 88)
        #expect(f == NSRect(x: 100, y: 790, width: 800, height: 512))
    }
}

@Suite struct NotificationTests {
    @Test func parsesNotificationCenterRecord() {
        let plist: [String: Any] = [
            "app": "com.tinyspeck.slackmacgap",
            "req": ["titl": "Maya Chen", "subt": " #launch ", "body": "can you sign off on the launch post? it goes out at 3"],
        ]
        let n = HeldNotification.parse(id: 42, bundleID: "ignored.when.app.key.present", plist: plist)
        #expect(n == HeldNotification(id: 42, bundleID: "com.tinyspeck.slackmacgap", title: "Maya Chen",
                                      subtitle: "#launch", body: "can you sign off on the launch post? it goes out at 3"))
    }

    @Test func recordWithoutTextIsSkipped() {
        #expect(HeldNotification.parse(id: 1, bundleID: "a.b", plist: ["app": "a.b"]) == nil)
        #expect(HeldNotification.parse(id: 1, bundleID: "a.b", plist: ["req": ["titl": "  "]]) == nil)
        #expect(HeldNotification.parse(id: 1, bundleID: "a.b", plist: ["req": ["body": "hi"]])?.bundleID == "a.b")
    }

    @Test func parsesTriage() {
        #expect(Classifier.parseTriage(#"{"urgent": true, "reason": "needs your answer before 3pm"}"#)
                == Triage(urgent: true, reason: "needs your answer before 3pm"))
        #expect(Classifier.parseTriage("```json\n{\"urgent\": false, \"reason\": \"FYI\"}\n```")?.urgent == false)
        #expect(Classifier.parseTriage(#"{"urgent": "yes"}"#) == nil)
        // Echoing an example's reason or saying "unclear" means the message wasn't understood.
        #expect(Classifier.parseTriage(#"{"reason": "review needed before 5pm deploy", "urgent": true}"#)?.urgent == false)
        #expect(Classifier.parseTriage(#"{"reason": "unclear", "urgent": true}"#)?.urgent == false)
        #expect(Classifier.parseTriage("not json") == nil)
    }

    @Test func mealInvitesForTodayAreTimeSensitive() {
        func rule(_ body: String) -> String? {
            Classifier.mealInvite(HeldNotification(id: 1, bundleID: "com.kakao.KakaoTalkMac", title: "수진", subtitle: "", body: body))?.reason
        }
        #expect(rule("점심 먹으러 가자") == "lunch invite")
        #expect(rule("저녁 먹으러 갈 사람?") == "dinner invite")
        #expect(rule("lunch in 10? we're heading down") == "lunch invite")
        #expect(rule("내일 점심 뭐 먹을래?") == nil)        // another day
        #expect(rule("다음주에 밥 한번 먹자") == nil)
        #expect(rule("저녁은 먹었니?") == nil)              // asking, not inviting
        #expect(rule("회의 10분 뒤 시작합니다") == nil)
    }

    @Test func reactionsAreWrittenAsExamplesInTheInstructions() {
        #expect(Classifier.triageInstructions(with: []) == Classifier.triageInstructions)
        let e = NotificationExample(app: "KakaoTalk", sender: "동기", text: #"그거 "레전드""#, reason: "group chat banter",
                                    important: false, date: Date())
        let ins = Classifier.triageInstructions(with: [e])
        #expect(ins.hasPrefix(Classifier.triageInstructions))
        // Double quotes inside the text become single quotes so the example stays well formed.
        #expect(ins.hasSuffix(#"same answer: "동기: 그거 '레전드'" -> {"reason": "group chat banter", "urgent": false}."#))
    }

    @Test func echoingAUsersExampleTakesItsAnswer() {
        let mom = NotificationExample(app: "KakaoTalk", sender: "엄마", text: "언제 와?", reason: "asks when you're coming",
                                      important: true, date: Date())
        // Like the user's example: same answer, even if the model said otherwise.
        #expect(Classifier.parseTriage(#"{"reason": "asks when you're coming", "urgent": false}"#, examples: [mom])?.urgent == true)
        // A built-in example echoed back still means "not understood".
        #expect(Classifier.parseTriage(#"{"reason": "chatter", "urgent": true}"#, examples: [mom])?.urgent == false)
    }

    @Test func localByDefaultAndClaudeOnlyWhenChosen() {
        var c = ClassifierConfig()
        #expect(Classifier.triageOrder(c, claudeCodeInstalled: true).isEmpty)   // no model: the user is asked
        c.triageProvider = "auto"
        #expect(Classifier.triageOrder(c, claudeCodeInstalled: true) == ["claudeCode", "apple"])
        #expect(Classifier.triageOrder(c, claudeCodeInstalled: false) == ["apple"])
        c.triageProvider = "apple"
        #expect(Classifier.triageOrder(c, claudeCodeInstalled: true) == ["apple"])
        c.triageProvider = "off"
        #expect(Classifier.triageOrder(c, claudeCodeInstalled: true).isEmpty)
    }

    @Test func claudeGetsTheNotesAndNewReactions() {
        let e = NotificationExample(app: "KakaoTalk", sender: "동기", text: "ㅋㅋ", reason: "banter", important: false, date: Date())
        let s = Classifier.triageSystem(profile: "- Messages from 엄마 matter.", pending: [e])
        #expect(s.hasPrefix(Classifier.triageInstructions))
        #expect(s.contains("follow it over the general rules above):\n- Messages from 엄마 matter."))
        #expect(s.hasSuffix("not in those notes yet:\n- 동기 (KakaoTalk): \"ㅋㅋ\" -> not important"))
        #expect(Classifier.triageSystem(profile: "  ", pending: []) == Classifier.triageInstructions)
    }

    @Test func notesFromClaudeAreTrimmedToBulletLines() {
        let raw = "Here are the notes:\n- A matters\n\n- B doesn't\nThanks"
        #expect(Classifier.cleanProfile(raw) == "- A matters\n- B doesn't")
        #expect(Classifier.cleanProfile((1...20).map { "- rule \($0)" }.joined(separator: "\n"))?.split(separator: "\n").count == 12)
        #expect(Classifier.cleanProfile("no bullets") == nil)
        #expect(Classifier.profilePrompt(current: "", reactions: []).hasPrefix("Current notes:\n(none yet)"))
    }

    @Test func readsClaudeCodeJSONOutput() {
        #expect(ClaudeCode.result(fromJSON: Data(#"{"is_error": false, "result": "{\"urgent\": true}"}"#.utf8)) == #"{"urgent": true}"#)
        #expect(ClaudeCode.result(fromJSON: Data(#"{"is_error": true, "result": "Not logged in"}"#.utf8)) == nil)
        #expect(ClaudeCode.result(fromJSON: Data("not json".utf8)) == nil)
    }

    @Test func triagePromptSkipsEmptyFields() {
        let n = HeldNotification(id: 1, bundleID: "com.tinyspeck.slackmacgap", title: "Maya Chen", subtitle: "", body: "ping")
        #expect(Classifier.triagePrompt(n, appName: "Slack") == "Notification from Slack\nTitle: Maya Chen\nBody: ping")
    }
}

@Suite struct ClassifierParsingTests {
    let ids: Set<String> = ["study", "research", "social"]

    @Test func parsesCleanJSON() {
        let c = Classifier.parseLLM(#"{"mode":"research","reason":"API docs for an incident tool"}"#, validIDs: ids)
        #expect(c?.modeID == "research")
        #expect(c?.reason == "API docs for an incident tool")
    }

    @Test func instructionsGiveNoReasonToCopy() {
        // The on-device model echoes any example reason for similar items.
        #expect(!Classifier.instructions.contains("e.g."))
        #expect(!Classifier.instructions.contains("incident tool"))
    }

    @Test func parsesJSONWrappedInProse() {
        let c = Classifier.parseLLM("Sure:\n```json\n{\"mode\": \"social\", \"reason\": \"feed\"}\n```", validIDs: ids)
        #expect(c?.modeID == "social")
    }

    @Test func nullAndUnknownModesBecomeNil() {
        #expect(Classifier.parseLLM(#"{"mode":null,"reason":"x"}"#, validIDs: ids)?.modeID == nil)
        #expect(Classifier.parseLLM(#"{"mode":"gaming","reason":"x"}"#, validIDs: ids)?.modeID == nil)
    }

    @Test func garbageReturnsNil() {
        #expect(Classifier.parseLLM("no json here", validIDs: ids) == nil)
    }

    @Test func offProviderReturnsNil() async {
        var cfg = ClassifierConfig(); cfg.provider = "off"
        let r = await Classifier().classify(.site(host: "a.com", title: "", browserID: ""),
                                            modes: ConfigStore.defaultConfig.modes, config: cfg)
        #expect(r == nil)
    }
}

@Suite struct ModeMatcherTests {
    let modes = ConfigStore.defaultConfig.modes

    func unit(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / n }
    }

    @Test func textOfSitesAndApps() {
        #expect(ModeMatcher.text(for: .site(host: "kaggle.com", title: "Kaggle", browserID: "")) == "kaggle.com | Kaggle")
        #expect(ModeMatcher.text(for: .site(host: "kaggle.com", title: "", browserID: "")) == "kaggle.com")
        #expect(ModeMatcher.text(for: .app(bundleID: "com.docker.docker", name: "Docker")) == "Docker (Mac app)")
    }

    @Test func examplesSkipWhatSeveralModesShare() {
        let a = ModeMatcher.anchors(modes: modes, appNames: [:])
        let texts = Set(a.map(\.text))
        #expect(a.contains(ModeMatcher.Anchor(modeID: "research", kind: .site, text: "github.com")))
        #expect(a.contains(ModeMatcher.Anchor(modeID: "social", kind: .app, text: "Slack (Mac app)")))
        // Chrome and Preview are in more than one mode, arXiv in Study and Research.
        #expect(!texts.contains("Google Chrome (Mac app)"))
        #expect(!texts.contains("Preview (Mac app)"))
        #expect(!texts.contains("arxiv.org"))
        #expect(a.filter { $0.kind == .purpose }.count == 3)
        #expect(a.contains { $0.modeID == ModeMatcher.none })
    }

    @Test func installedNamesWinAndUnknownAppsAreLeftOut() {
        var gym = modes[0]
        gym.id = "gym"
        gym.apps = ["com.example.trainer", "com.example.unnamed"]
        gym.domains = []
        let a = ModeMatcher.anchors(modes: [gym], appNames: ["com.example.trainer": "Trainer"])
        #expect(a.filter { $0.kind == .app }.map(\.text) == ["Trainer (Mac app)"])
        // Built-in examples only exist for the default mode ids.
        #expect(!a.contains { $0.modeID == "gym" && $0.kind == .seed })
    }

    func anchor(_ mode: String, _ kind: ModeMatcher.Anchor.Kind, _ text: String, _ v: [Float]) -> (ModeMatcher.Anchor, [Float]) {
        (ModeMatcher.Anchor(modeID: mode, kind: kind, text: text), unit(v))
    }

    var space: [(ModeMatcher.Anchor, [Float])] {
        [anchor("research", .site, "github.com", [1, 0, 0, 0]), anchor("research", .seed, "code repository", [1, 0.05, 0, 0]),
         anchor("study", .site, "coursera.org", [0, 1, 0, 0]), anchor("study", .seed, "lecture notes app", [0.05, 1, 0, 0]),
         anchor("social", .site, "x.com", [0, 0, 1, 0]), anchor("social", .seed, "social media feed", [0, 0.05, 1, 0]),
         anchor(ModeMatcher.none, .seed, "online banking", [0, 0, 0, 1]), anchor(ModeMatcher.none, .seed, "email inbox", [0, 0, 0.05, 1])]
    }

    @Test func joinsTheClearlyClosestMode() {
        let c = ModeMatcher.decide(unit([1, 0, 0, 0]), anchors: space, guarded: ["social"])
        #expect(c.modeID == "research")
        #expect(c.reason == "like github.com")
    }

    @Test func asksWhenTwoModesAreAlmostTied() {
        let c = ModeMatcher.decide(unit([1, 1, 0, 0]), anchors: space, guarded: ["social"])
        #expect(c.modeID == nil)
        #expect(c.reason.isEmpty)
    }

    @Test func socialNeedsAClearerWin() {
        // Closer to Social than to Study, but only a little (about 0.02): not enough to block it.
        let close = ModeMatcher.decide(unit([0, 1, 1, 0]), anchors: space, guarded: ["social"])
        #expect(close.modeID == nil)
        // The same lead is enough for a mode that isn't guarded.
        let sameLead = ModeMatcher.decide(unit([0, 1, 1, 0]), anchors: space, guarded: [])
        #expect(sameLead.modeID == "social")
        #expect(ModeMatcher.decide(unit([0, 0.2, 1, 0]), anchors: space, guarded: ["social"]).modeID == "social")
    }

    @Test func noModeExamplesKeepLoginAndBankingOut() {
        let c = ModeMatcher.decide(unit([0, 0, 0, 1]), anchors: space, guarded: ["social"])
        #expect(c.modeID == nil)
        #expect(c.reason == "online banking")
    }

    @Test func localIsTheDefaultAndFallsBackToApple() {
        #expect(ClassifierConfig().provider == "local")
        #expect(Classifier.order("local") == ["local", "apple"])
        #expect(Classifier.order("auto") == ["local", "jev", "apple", "claude"])
        #expect(Classifier.order("apple") == ["apple"])
        #expect(Classifier.order("off").isEmpty)
        // A config that already picked a provider keeps it.
        let cfg = try? JSONDecoder().decode(ClassifierConfig.self, from: Data(#"{"provider": "apple"}"#.utf8))
        #expect(cfg?.provider == "apple")
    }
}

private let gemmaLive = ProcessInfo.processInfo.environment["GEMMA_LIVE"] == "1"

/// Runs the 70-item eval through the real model and llama-server. Opt in with GEMMA_LIVE=1
/// (needs the downloaded model, and llama-server from Homebrew outside the app bundle).
@Suite(.enabled(if: gemmaLive, "GEMMA_LIVE not set"))
struct ModeMatcherLiveTests {
    static let cases: [(Subject, Set<String>)] = [
        (.site(host: "paperswithcode.com", title: "Papers with Code", browserID: ""), ["research"]),
        (.site(host: "colab.research.google.com", title: "Google Colab", browserID: ""), ["research"]),
        (.site(host: "kaggle.com", title: "Kaggle: Your Machine Learning and Data Science Community", browserID: ""), ["research"]),
        (.site(host: "docs.docker.com", title: "Docker Docs", browserID: ""), ["research"]),
        (.site(host: "numpy.org", title: "NumPy documentation", browserID: ""), ["research"]),
        (.site(host: "ieeexplore.ieee.org", title: "IEEE Xplore", browserID: ""), ["research", "study"]),
        (.site(host: "bibliothek.kit.edu", title: "KIT-Bibliothek", browserID: ""), ["research", "study"]),
        (.site(host: "library.stanford.edu", title: "Stanford Libraries", browserID: ""), ["research", "study"]),
        (.app(bundleID: "com.docker.docker", name: "Docker"), ["research"]),
        (.app(bundleID: "com.googlecode.iterm2", name: "iTerm"), ["research"]),
        (.app(bundleID: "com.postmanlabs.mac", name: "Postman"), ["research"]),
        (.app(bundleID: "md.obsidian", name: "Obsidian"), ["research", "study"]),
        (.site(host: "quizlet.com", title: "Quizlet", browserID: ""), ["study"]),
        (.site(host: "canvas.instructure.com", title: "Dashboard", browserID: ""), ["study"]),
        (.site(host: "chegg.com", title: "Chegg", browserID: ""), ["study"]),
        (.site(host: "desmos.com", title: "Desmos | Graphing Calculator", browserID: ""), ["study"]),
        (.site(host: "wolframalpha.com", title: "Wolfram|Alpha", browserID: ""), ["research", "study"]),
        (.site(host: "duolingo.com", title: "Duolingo", browserID: ""), ["study"]),
        (.app(bundleID: "net.ankiweb.dtop", name: "Anki"), ["study"]),
        (.site(host: "tiktok.com", title: "TikTok", browserID: ""), ["social"]),
        (.site(host: "twitch.tv", title: "Twitch", browserID: ""), ["social"]),
        (.site(host: "netflix.com", title: "Netflix", browserID: ""), ["none", "social"]),
        (.site(host: "threads.net", title: "Threads", browserID: ""), ["social"]),
        (.site(host: "cnn.com", title: "CNN - Breaking News", browserID: ""), ["social"]),
        (.site(host: "9gag.com", title: "9GAG", browserID: ""), ["social"]),
        (.site(host: "news.naver.com", title: "네이버 뉴스", browserID: ""), ["social"]),
        (.app(bundleID: "ru.keepcoder.Telegram", name: "Telegram"), ["social"]),
        (.app(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"), ["social"]),
        (.site(host: "linkedin.com", title: "Feed | LinkedIn", browserID: ""), ["social"]),
        (.site(host: "sso.kaist.ac.kr", title: "KAIST Single Sign On", browserID: ""), ["none", "research", "study"]),
        (.site(host: "portal.kaist.ac.kr", title: "KAIST Portal", browserID: ""), ["none", "research", "study"]),
        (.site(host: "login.microsoftonline.com", title: "Sign in to your account", browserID: ""), ["none", "research", "study"]),
        (.site(host: "mail.google.com", title: "Inbox - Gmail", browserID: ""), ["none", "research", "study"]),
        (.site(host: "amazon.com", title: "Amazon.com", browserID: ""), ["none", "social"]),
        (.site(host: "coupang.com", title: "쿠팡!", browserID: ""), ["none", "social"]),
        (.site(host: "weather.com", title: "Weather Forecast", browserID: ""), ["none"]),
        (.app(bundleID: "com.spotify.client", name: "Spotify"), ["none", "social"]),
        (.site(host: "chase.com", title: "Chase Bank", browserID: ""), ["none"]),
        (.site(host: "drive.google.com", title: "My Drive - Google Drive", browserID: ""), ["none", "research", "study"]),
        (.site(host: "zoom.us", title: "Zoom", browserID: ""), ["none", "research", "social", "study"]),
        (.site(host: "matplotlib.org", title: "Matplotlib documentation", browserID: ""), ["research"]),
        (.site(host: "scikit-learn.org", title: "scikit-learn: machine learning in Python", browserID: ""), ["research"]),
        (.site(host: "console.aws.amazon.com", title: "AWS Management Console", browserID: ""), ["research"]),
        (.site(host: "nature.com", title: "Nature", browserID: ""), ["research", "study"]),
        (.site(host: "sciencedirect.com", title: "ScienceDirect", browserID: ""), ["research", "study"]),
        (.app(bundleID: "com.tinyapp.TablePlus", name: "TablePlus"), ["research"]),
        (.app(bundleID: "com.DanPristupov.Fork", name: "Fork"), ["research"]),
        (.app(bundleID: "ai.elementlabs.lmstudio", name: "LM Studio"), ["research"]),
        (.app(bundleID: "com.gingerlabs.Notability", name: "Notability"), ["study"]),
        (.site(host: "classroom.google.com", title: "Google Classroom", browserID: ""), ["study"]),
        (.site(host: "ocw.mit.edu", title: "MIT OpenCourseWare", browserID: ""), ["study"]),
        (.site(host: "brilliant.org", title: "Brilliant", browserID: ""), ["study"]),
        (.site(host: "studocu.com", title: "Studocu", browserID: ""), ["study"]),
        (.site(host: "mathway.com", title: "Mathway | Math Problem Solver", browserID: ""), ["study"]),
        (.app(bundleID: "jp.naver.line.mac", name: "LINE"), ["social"]),
        (.app(bundleID: "org.whispersystems.signal-desktop", name: "Signal"), ["social"]),
        (.site(host: "pinterest.com", title: "Pinterest", browserID: ""), ["social"]),
        (.site(host: "bilibili.com", title: "哔哩哔哩", browserID: ""), ["social"]),
        (.site(host: "nytimes.com", title: "The New York Times", browserID: ""), ["social"]),
        (.site(host: "dcinside.com", title: "디시인사이드", browserID: ""), ["social"]),
        (.site(host: "everytime.kr", title: "에브리타임", browserID: ""), ["social"]),
        (.site(host: "tumblr.com", title: "Tumblr", browserID: ""), ["social"]),
        (.site(host: "booking.com", title: "Booking.com", browserID: ""), ["none"]),
        (.site(host: "paypal.com", title: "PayPal", browserID: ""), ["none"]),
        (.app(bundleID: "com.1password.1password", name: "1Password"), ["none"]),
        (.site(host: "toss.im", title: "토스", browserID: ""), ["none"]),
        (.site(host: "uber.com", title: "Uber", browserID: ""), ["none"]),
        (.site(host: "accounts.google.com", title: "Sign in - Google Accounts", browserID: ""), ["none", "research", "study"]),
        (.site(host: "outlook.office.com", title: "Mail - Outlook", browserID: ""), ["none", "research", "study"]),
        (.site(host: "ebay.com", title: "eBay", browserID: ""), ["none", "social"]),
    ]

    @Test func sortsAtLeastAsWellAsTheEval() async throws {
        let embeddings = EmbeddingService()
        defer { embeddings.stop() }
        let matcher = ModeMatcher(embeddings: embeddings)
        try #require(matcher.isAvailable, "model or llama-server missing")
        let modes = ConfigStore.defaultConfig.modes
        var right = 0, asked = 0, wrongFocus = 0, wrongSocial = 0
        for (subject, want) in Self.cases {
            let c = try #require(await matcher.classify(subject, modes: modes, appNames: [:]))
            let got = c.modeID ?? "none"
            if want.contains(got) { right += 1 } else if got == "none" { asked += 1 }
            else if got == "social" { wrongSocial += 1 } else { wrongFocus += 1 }
        }
        print("ModeMatcher eval: right \(right), asked \(asked), wrong focus mode \(wrongFocus), wrongly Social \(wrongSocial)")
        #expect(right >= 54)
        #expect(wrongSocial <= 1)
    }
}

private let typesafeKey = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? ""

/// Hits the real TypeSafe API. Runs only when TYPESAFE_API_KEY is set.
@Suite(.enabled(if: !typesafeKey.isEmpty, "TYPESAFE_API_KEY not set"))
struct JevLiveTests {
    @Test func jevClassifiesObviousSites() async throws {
        var cfg = ClassifierConfig()
        cfg.provider = "jev"
        cfg.typesafeAPIKey = typesafeKey
        let modes = ConfigStore.defaultConfig.modes

        let social = await Classifier().classify(
            .site(host: "tiktok.com", title: "For You | TikTok", browserID: ""), modes: modes, config: cfg)
        #expect(social != nil, "Jev call failed; check key / endpoint / response shape in Console logs")
        #expect(social?.modeID == "social")
        #expect(social?.confidence != nil)

        let research = await Classifier().classify(
            .site(host: "tidepool.dev", title: "Webhooks · Tidepool Docs · API reference", browserID: ""),
            modes: modes, config: cfg)
        #expect(research?.modeID == "research")
    }
}
