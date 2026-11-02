import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

func formatCountdown(_ seconds: Double) -> String {
    let s = Int(ceil(seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: Dock

struct DockView: View {
    @ObservedObject var store: ModeStore
    @State private var running: Set<String> = []
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(store.config.modes) { mode in
                    modeButton(mode)
                }
                if store.pending != nil {
                    Button("Stay") { store.cancelPending() }
                        .buttonStyle(StayButtonStyle())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            Divider().frame(height: 34).opacity(0.4)
            HStack(spacing: 8) {
                // Apps in the config that aren't installed on this Mac would only be gray placeholders.
                ForEach(store.dockApps.filter(AppLauncher.isInstalled), id: \.self) { bid in
                    AppIconButton(bundleID: bid, running: running.contains(bid)) { store.setDockHidden(true, for: bid) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.currentID)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.pending?.modeID)
        .onAppear(perform: updateRunning)
        .onReceive(refresh) { _ in updateRunning() }
        .onChange(of: store.currentID) { _ in updateRunning() }
        .fixedSize()
    }

    private func updateRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    @ViewBuilder
    private func modeButton(_ mode: Mode) -> some View {
        let isCurrent = mode.id == store.currentID
        let pending = store.pending?.modeID == mode.id ? store.pending : nil
        let tint = Color(hex: mode.color)

        Button { store.request(mode.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol).font(.system(size: 13, weight: .semibold))
                if isCurrent || pending != nil {
                    Text(mode.name).font(.system(size: 13, weight: .semibold))
                }
                if let p = pending {
                    Text(formatCountdown(store.remaining(p)))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .opacity(0.85)
                }
            }
            .foregroundStyle(isCurrent || pending != nil ? Color.white : Color.primary.opacity(0.55))
            .padding(.horizontal, isCurrent || pending != nil ? 12 : 8)
            .frame(height: 34)
            .background {
                if isCurrent {
                    Capsule().fill(tint)
                } else if let p = pending {
                    // Fill drains as the countdown runs.
                    let progress = p.total > 0 ? 1 - store.remaining(p) / p.total : 1
                    Capsule().fill(tint.opacity(0.35))
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule().fill(tint).frame(width: geo.size.width * progress)
                            }
                        }
                        .clipShape(Capsule())
                } else {
                    Capsule().fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule())
            .overlay(alignment: .topTrailing) {
                // Notifications held for this mode.
                if !isCurrent, let count = store.held[mode.id], count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(tint))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isCurrent ? "\(mode.name) (current)" : "Switch to \(mode.name)")
    }
}

struct StayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(Color.white))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}

struct AppIconButton: View {
    let bundleID: String
    let running: Bool
    var hide: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        Button { AppLauncher.open(bundleID) } label: {
            VStack(spacing: 3) {
                Group {
                    if let icon = AppLauncher.icon(for: bundleID) {
                        Image(nsImage: icon).resizable()
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.3))
                    }
                }
                .frame(width: 40, height: 40)
                .scaleEffect(hovering ? 1.12 : 1, anchor: .bottom)
                Circle().fill(Color.primary.opacity(running ? 0.6 : 0)).frame(width: 4, height: 4)
            }
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(AppLauncher.name(for: bundleID))
        .contextMenu {
            // Still allowed in the mode; Setup > Apps shows it again.
            Button("Hide from Dock", action: hide)
        }
    }
}

// MARK: Prompt card

struct PromptCard: View {
    @ObservedObject var store: ModeStore
    private let maxNotes = 3

    var body: some View {
        if store.prompt != nil || !store.notes.isEmpty || store.starCard != nil {
            VStack(spacing: 8) {
                if store.notes.count > maxNotes {
                    Text("+\(store.notes.count - maxNotes) earlier")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                // Newest on top: the panel grows upward, so earlier cards keep their place.
                ForEach(store.notes.suffix(maxNotes).reversed()) { note in
                    card(note).transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let prompt = store.prompt {
                    card(prompt)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(prompt.id)
                }
                if store.starCard != nil {
                    starCard.transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(10)
        }
    }

    private func card(_ p: Prompt) -> some View {
        HStack(alignment: .top, spacing: 12) {
            subjectIcon(p.subject)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(p.subject.label).font(.system(size: 13, weight: .semibold))
                    Text("· " + headline(p)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                detail(p)
                buttons(p)
            }
        }
        .modifier(CardChrome())
    }

    private var starCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("FocusDock").font(.system(size: 13, weight: .semibold))
                    Text("· thanks for trying it").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                switch store.starCard {
                case .starring?:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Starring…").font(.system(size: 13))
                    }
                case .starred?:
                    Label("Starred. Thank you!", systemImage: "star.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                case .openedPage?:
                    Text("Opened GitHub in your browser. The ☆ Star button is at the top right of the page.")
                        .font(.system(size: 13))
                        .frame(width: 300, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    Text("If it helps you focus, a star on GitHub helps other people find it.")
                        .font(.system(size: 13))
                        .frame(width: 300, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Not now") { store.dismissStarCard() }.buttonStyle(.bordered).controlSize(.small)
                        Button {
                            store.starOnGitHub(openPage: { NSWorkspace.shared.open(ModeStore.gitHubURL) })
                        } label: {
                            Label("Star on GitHub", systemImage: "star.fill")
                        }
                        .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                        .help("Stars it with your GitHub CLI (gh) if you have it, or opens the page")
                    }
                }
            }
        }
        .modifier(CardChrome())
    }

    private func headline(_ p: Prompt) -> String {
        switch p.kind {
        case .checking: return "checking…"
        case .belongsTo(let id, _): return "belongs to \(store.mode(id)?.name ?? id)"
        case .fits: return "not in any mode"
        case .unknown: return "not in any mode"
        case .held(let info):
            guard case .notification(let n) = p.subject else { return "" }
            if info.asking { return [n.subtitle, AppLauncher.name(for: n.bundleID), "matters?"].filter { !$0.isEmpty }.joined(separator: " · ") }
            let heldFor = info.modeID.map { "held for \(store.mode($0)?.name ?? $0)" } ?? ""
            let parts = [n.subtitle, AppLauncher.name(for: n.bundleID), info.vip ? "VIP" : "", heldFor]
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private func detail(_ p: Prompt) -> some View {
        switch p.kind {
        case .checking:
            ProgressView().controlSize(.small)
        case .belongsTo(_, let reason):
            VStack(alignment: .leading, spacing: 3) {
                if let reason, !reason.isEmpty { sparkle(reason) }
                Text("Stay focused, or switch?").font(.system(size: 13))
            }
        case .fits(let id, let reason):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Fits \(store.mode(id)?.name ?? id)").font(.system(size: 13, weight: .semibold))
                if !reason.isEmpty { sparkle(reason) }
            }
        case .unknown(let reason):
            VStack(alignment: .leading, spacing: 3) {
                if let reason, !reason.isEmpty { sparkle(reason) }
                Text("Doesn't fit \(store.current.name). Stay focused?").font(.system(size: 13))
            }
        case .held(let info):
            VStack(alignment: .leading, spacing: 3) {
                if case .notification(let n) = p.subject, !n.body.isEmpty {
                    Text(n.body)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .frame(width: 320, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if info.asking {
                    Text("Should messages like this reach you while you focus? FocusDock will remember.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if info.urgent {
                    sparkle("Time-sensitive" + (info.reason.isEmpty ? "" : " · \(info.reason)"))
                }
            }
        }
    }

    private func sparkle(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkle").font(.system(size: 10))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(Color.purple)
    }

    @ViewBuilder
    private func buttons(_ p: Prompt) -> some View {
        switch p.kind {
        case .belongsTo(let id, _):
            HStack(spacing: 8) {
                Button("Stay") { store.stay() }.buttonStyle(.bordered).controlSize(.small)
                if store.canBelongHere(p.subject, owner: id) {
                    Button("Belongs in \(store.current.name)") { store.moveHere() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("The classifier guessed wrong: move it to \(store.current.name)")
                }
                goButton(id)
            }
        case .held(let info) where info.asking:
            HStack(spacing: 8) {
                Button("Not important") { store.answer(p.id, important: false) }.buttonStyle(.bordered).controlSize(.small)
                Button("Important") { store.answer(p.id, important: true) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .held(let info):
            HStack(spacing: 8) {
                Button("Later") { store.dismissNote(p.id) }.buttonStyle(.bordered).controlSize(.small)
                if let id = info.modeID {
                    goButton(id) { store.goFromNote(p.id) }
                } else if case .notification(let n) = p.subject {
                    Button("Open \(AppLauncher.name(for: n.bundleID))") {
                        store.dismissNote(p.id)
                        AppLauncher.open(n.bundleID)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                if !info.vip, case .notification(let n) = p.subject {
                    Spacer(minLength: 4)
                    Button { store.addVIP(n.title); store.dismissNote(p.id) } label: { Image(systemName: "star") }
                        .buttonStyle(.borderless)
                        .help("VIP: always show \(n.title), from any app and in any mode")
                    Button { store.notImportant(p.id) } label: { Image(systemName: "hand.thumbsdown") }
                        .buttonStyle(.borderless)
                        .help("Not important: notifications like this won't get a card")
                }
            }
        case .unknown:
            HStack(spacing: 8) {
                Button("Stay") { store.stay() }.buttonStyle(.bordered).controlSize(.small)
                // Not for something that was in Social: that takes Setup and the wait.
                if store.canAllowHere(p.subject) {
                    Button("Allow in \(store.current.name)") { store.allowHere() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: store.current.color))
                        .controlSize(.small)
                }
            }
        default:
            EmptyView()
        }
    }

    private func goButton(_ id: String, action: (() -> Void)? = nil) -> some View {
        let mode = store.mode(id)
        let wait = Int(store.current.exit.delay(to: id))
        return Button {
            if let action { action() } else { store.goTo(id) }
        } label: {
            Label("Go to \(mode?.name ?? id)" + (wait > 0 ? " (\(wait)s wait)" : ""),
                  systemImage: mode?.symbol ?? "arrow.right")
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(hex: mode?.color ?? "#888888"))
        .controlSize(.small)
    }

    @ViewBuilder
    private func subjectIcon(_ s: Subject) -> some View {
        switch s {
        case .app(let bid, _): appIcon(bid)
        case .notification(let n): appIcon(n.bundleID)
        case .site:
            Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary).padding(3)
        }
    }

    @ViewBuilder
    private func appIcon(_ bid: String) -> some View {
        if let icon = AppLauncher.icon(for: bid) { Image(nsImage: icon).resizable() }
        else { Image(systemName: "app").resizable().scaledToFit() }
    }
}

/// The look every card above the dock shares.
private struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(minWidth: 300, alignment: .leading)
            .fixedSize()
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            )
    }
}
