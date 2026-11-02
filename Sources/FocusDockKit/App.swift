import AppKit
import SwiftUI
import Combine

/// Borderless floating panel that never steals focus from the app you're working in.
final class FloatingPanel<Content: View>: NSPanel {
    private let hosting: NSHostingView<Content>

    init(@ViewBuilder content: () -> Content) {
        hosting = NSHostingView(rootView: content())
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        contentView = hosting
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var fittingSize: NSSize { hosting.fittingSize }
}

public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public override init() { super.init() }

    private var store: ModeStore!
    private var guardian: FocusGuard!
    private var dock: FloatingPanel<DockView>!
    private var promptPanel: FloatingPanel<PromptCard>!
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    private var setupWindow: NSWindow?
    private var sigterm: DispatchSourceSignal?
    private var setupModel: SetupModel?

    /// Gap between the bottom of the screen's visible frame and the dock.
    private let bottomInset: CGFloat = 10

    public func applicationDidFinishLaunching(_ notification: Notification) {
        store = ModeStore(config: ConfigStore.load())
        guardian = FocusGuard(store: store)

        dock = FloatingPanel { DockView(store: store) }
        promptPanel = FloatingPanel { PromptCard(store: store) }

        setupStatusItem()

        // Re-layout whenever state changes (next runloop so SwiftUI has updated sizes).
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout(); self?.updateStatusItem() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &bag)
        // SwiftUI resizes a panel to its new content (keeping the origin) after layout() may have
        // measured the old size, which leaves it off-center. Re-center whenever that happens.
        for panel in [dock, promptPanel] as [NSWindow] {
            NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel)
                .sink { [weak self] _ in self?.layout() }
                .store(in: &bag)
        }

        layout()
        dock.orderFrontRegardless()
        updateStatusItem()
        guardian.start()

        // `kill`/`pkill` should quit properly too, so the embedding server is stopped with us.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        sigterm = term

        LoginItem.sync()
        // Once, after the dock has settled: a card suggesting a GitHub star.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.store.showStarCardIfNew() }

        let defaults = UserDefaults.standard, build = SetupModel.buildStamp
        if SetupModel.opensAtLaunch(firstLaunch: !defaults.bool(forKey: "setupShown"),
                                    canReadNotifications: Permissions.canReadNotifications,
                                    build: build, lastOpenedBuild: defaults.string(forKey: "setupOpenedForBuild")) {
            defaults.set(true, forKey: "setupShown")
            defaults.set(build, forKey: "setupOpenedForBuild")
            showSetup()
        }
    }

    @objc func showSetup() {
        if setupWindow == nil {
            let model = SetupModel(store: store, classifier: guardian.classifier)
            model.onUpdateProfile = { [weak self] in self?.guardian.updateProfile(force: true) }
            model.memoryCount = { [weak self] in self?.guardian.memory.items.count ?? 0 }
            model.clearMemory = { [weak self] in self?.guardian.memory.clear() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "FocusDock Setup"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(model: model, downloader: guardian.downloader,
                                                                   close: { [weak window] in window?.close() }))
            window.center()
            setupWindow = window
            setupModel = model
        } else {
            setupModel?.refresh()
        }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        setupWindow?.makeKeyAndOrderFront(nil)
        // Opened at login, macOS may not let FocusDock become active; the window still comes to the front.
        setupWindow?.orderFrontRegardless()
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame

        let ds = dock.fittingSize
        let dockFrame = NSRect(x: vf.midX - ds.width / 2, y: vf.minY + bottomInset,
                               width: ds.width, height: ds.height)
        if dock.frame != dockFrame { dock.setFrame(dockFrame, display: true) }

        if store.prompt == nil && store.notes.isEmpty && store.starCard == nil {
            if promptPanel.isVisible { promptPanel.orderOut(nil) }
        } else {
            let ps = promptPanel.fittingSize
            let frame = NSRect(x: vf.midX - ps.width / 2, y: dockFrame.maxY + 2,
                               width: ps.width, height: ps.height)
            if promptPanel.frame != frame { promptPanel.setFrame(frame, display: true) }
            promptPanel.orderFrontRegardless()
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
    }

    private func updateStatusItem() {
        // objectWillChange fires before the value changes; read on next tick.
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            let mode = self.store.current
            button.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.name)
            button.imagePosition = .imageLeading
            if let p = self.store.pending, let target = self.store.mode(p.modeID) {
                button.title = " \(mode.name) → \(target.name) \(formatCountdown(self.store.remaining(p)))"
            } else {
                button.title = " \(mode.name)"
            }
            let key = "\(self.store.currentID)|\(self.store.pending?.modeID ?? "")|\(self.store.config.modes.map(\.id))|\(self.guardian.notificationsReadable)|\(self.store.config.learned.map(\.id))"
            if key != self.menuKey { self.menuKey = key; self.rebuildMenu() }
        }
    }
    private var menuKey = ""
    private var loginMenuItem: NSMenuItem?

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        for mode in store.config.modes {
            let item = NSMenuItem(title: mode.name, action: #selector(menuSwitch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id
            item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
            item.state = mode.id == store.currentID ? .on : .off
            menu.addItem(item)
        }
        if store.pending != nil {
            let stay = NSMenuItem(title: "Stay (cancel switch)", action: #selector(menuStay), keyEquivalent: "")
            stay.target = self
            menu.addItem(stay)
        }
        menu.addItem(.separator())
        if !store.config.learned.isEmpty {
            let learned = NSMenuItem(title: "Recently Learned", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let hint = NSMenuItem(title: "Fix the classifier's guesses", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
            for item in store.config.learned.suffix(12).reversed() {
                let name = item.kind == .app ? AppLauncher.name(for: item.value) : item.value
                let entry = NSMenuItem(title: "\(name) → \(store.mode(item.modeID)?.name ?? item.modeID)",
                                       action: nil, keyEquivalent: "")
                let actions = NSMenu()
                for mode in store.config.modes where mode.id != item.modeID {
                    // Letting a distraction into a focus mode takes Setup and the wait, not a menu click.
                    let wait = store.needsWait(item, to: mode.id)
                    let move = NSMenuItem(title: "Move to \(mode.name)" + (wait ? " (in Setup, after a wait)" : ""),
                                          action: wait ? nil : #selector(moveLearned(_:)), keyEquivalent: "")
                    move.target = self
                    move.representedObject = [item.id, mode.id]
                    actions.addItem(move)
                }
                actions.addItem(.separator())
                let remove = NSMenuItem(title: "Remove", action: #selector(unlearn(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = item.id
                actions.addItem(remove)
                entry.submenu = actions
                sub.addItem(entry)
            }
            learned.submenu = sub
            menu.addItem(learned)
        }
        add(menu, "Setup…", #selector(showSetup), "")
        let classifier = NSMenuItem(title: "Classifier: \(store.config.classifier.provider)", action: nil, keyEquivalent: "")
        classifier.isEnabled = false
        menu.addItem(classifier)
        if guardian.notificationsReadable {
            let notes = NSMenuItem(title: "Notifications: holding", action: nil, keyEquivalent: "")
            notes.isEnabled = false
            menu.addItem(notes)
        } else {
            add(menu, "Notifications: needs Full Disk Access…", #selector(openFullDiskAccess), "")
        }
        add(menu, "Edit Config…", #selector(editConfig), ",")
        add(menu, "Reload Config", #selector(reloadConfig), "r")
        if LoginItem.state != .unavailable {
            let login = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
            login.target = self
            loginMenuItem = login
            menu.addItem(login)
        }
        menu.addItem(.separator())
        add(menu, "Quit FocusDock", #selector(quit), "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    /// Setup can change it too, so the check mark is read when the menu opens.
    public func menuWillOpen(_ menu: NSMenu) {
        loginMenuItem?.state = LoginItem.state == .on ? .on : .off
    }

    @objc private func toggleOpenAtLogin() {
        switch LoginItem.state {
        case .on: LoginItem.setWanted(false)
        case .needsApproval: LoginItem.openSettings()
        case .off, .unavailable: LoginItem.setWanted(true)
        }
    }

    @objc private func menuSwitch(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { store.request(id) }
    }
    @objc private func menuStay() { store.cancelPending() }
    @objc private func moveLearned(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String], ids.count == 2,
              let item = store.config.learned.first(where: { $0.id == ids[0] }),
              !store.needsWait(item, to: ids[1]) else { return }
        store.move(item, to: ids[1])
    }
    @objc private func unlearn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = store.config.learned.first(where: { $0.id == id }) else { return }
        store.unlearn(item)
    }
    @objc private func editConfig() { NSWorkspace.shared.open(ConfigStore.fileURL) }
    @objc private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func reloadConfig() { store.reloadConfig() }
    @objc private func quit() { NSApp.terminate(nil) }

    public func applicationWillTerminate(_ notification: Notification) {
        guardian?.shutdown()   // don't leave the embedding server running
    }
}
