import AppKit
import SwiftUI

final class PageCoverModel: ObservableObject {
    @Published var host = ""
    @Published var modeName = ""
}

/// Blurs a browser window's page while its "belongs to another mode" card waits for Stay / Go,
/// so the site can't simply be used while ignoring the card. Tabs and the address bar stay usable.
final class PageCover {
    private let model = PageCoverModel()
    private lazy var panel: FloatingPanel<PageCoverView> = {
        let p = FloatingPanel { PageCoverView(model: model) }
        p.level = .floating   // over the browser, under the dock and cards (.statusBar)
        return p
    }()

    func show(frame: NSRect, host: String, modeName: String) {
        if model.host != host { model.host = host }
        if model.modeName != modeName { model.modeName = modeName }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    /// The page area of `bid`'s frontmost window in AppKit coordinates, or nil if it has none on screen.
    /// Window bounds don't need Screen Recording permission (only window titles and pixels do).
    static func pageFrame(of bid: String) -> NSRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        // Front to back; skip popups such as the address bar's suggestions.
        for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == pid
            && (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width > 300, bounds.height > 300 else { continue }
            let toolbar: CGFloat = bid == "com.apple.Safari" ? 80 : 88
            return appKitFrame(cgBounds: bounds, primaryHeight: primary.frame.height, topInset: toolbar)
        }
        return nil
    }

    /// CoreGraphics window bounds (top-left origin on the primary screen) to an AppKit frame
    /// (bottom-left origin), minus `topInset` points at the top for the tabs and toolbar.
    static func appKitFrame(cgBounds b: CGRect, primaryHeight: CGFloat, topInset: CGFloat) -> NSRect {
        NSRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: max(0, b.height - topInset))
    }
}

struct PageCoverView: View {
    @ObservedObject var model: PageCoverModel

    var body: some View {
        ZStack {
            Rectangle().fill(.thickMaterial)
            VStack(spacing: 8) {
                Image(systemName: "eye.slash").font(.system(size: 28, weight: .medium))
                Text("\(model.host) belongs to \(model.modeName)").font(.system(size: 15, weight: .semibold))
                Text("Stay focused, or switch from the card.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Swallow clicks and scrolls on the page; the panel never becomes key, so typing still reaches the browser.
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}
