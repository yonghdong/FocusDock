import Foundation
import SQLite3

/// A notification another app posted, as recorded in macOS Notification Center's history.
struct HeldNotification: Equatable, Identifiable {
    let id: Int64
    var bundleID: String
    var title: String
    var subtitle: String
    var body: String

    /// Builds one from a record's `data` property list
    /// (`{"app": ..., "req": {"titl": ..., "subt": ..., "body": ...}}`). Nil if it carries no text.
    static func parse(id: Int64, bundleID: String, plist: [String: Any]) -> HeldNotification? {
        let req = plist["req"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String {
            (req[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let n = HeldNotification(id: id, bundleID: plist["app"] as? String ?? bundleID,
                                 title: text("titl"), subtitle: text("subt"), body: text("body"))
        return n.title.isEmpty && n.body.isEmpty ? nil : n
    }
}

/// Reads new entries from Notification Center's database. macOS has no public API for other
/// apps' notifications, so this needs Full Disk Access and relies on an undocumented schema.
final class NotificationFeed {
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    private let queue = DispatchQueue(label: "focusdock.notifications")
    private var db: OpaquePointer?
    private var lastID: Int64 = 0
    private var timer: Timer?
    /// False when the database can't be read (usually: no Full Disk Access).
    private(set) var isReadable = false

    /// Polls for notifications posted after this call; `onNew` runs on the main queue.
    func start(every interval: TimeInterval = 2, onNew: @escaping ([HeldNotification]) -> Void) {
        guard let max = open() else {
            NSLog("FocusDock: can't read Notification Center database; grant Full Disk Access to hold notifications")
            // Full Disk Access applies to a running app as soon as it's granted, so keep trying.
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                self?.start(every: interval, onNew: onNew)
            }
            return
        }
        isReadable = true
        lastID = max
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                let new = self.fetchNew()
                if !new.isEmpty { DispatchQueue.main.async { onNew(new) } }
            }
        }
    }

    /// Opens read-only and returns the newest record ID, or nil if the database can't be read.
    private func open() -> Int64? {
        guard let (handle, max) = Self.openReadable() else { return nil }
        db = handle
        return max
    }

    /// Whether the database can be read right now, i.e. Full Disk Access is granted.
    static func canRead() -> Bool {
        guard let (handle, _) = openReadable() else { return false }
        sqlite3_close(handle)
        return true
    }

    private static func openReadable() -> (OpaquePointer, Int64)? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        // Opening is lazy; the first real read is what fails without permission.
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, "SELECT IFNULL(MAX(rec_id), 0) FROM record", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_close(handle)
            return nil
        }
        return (handle, sqlite3_column_int64(stmt, 0))
    }

    private func fetchNew() -> [HeldNotification] {
        let sql = """
        SELECT r.rec_id, a.identifier, r.data FROM record r JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ? ORDER BY r.rec_id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastID)

        var out: [HeldNotification] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            lastID = max(lastID, id)
            let bid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let n = HeldNotification.parse(id: id, bundleID: bid, plist: plist) else { continue }
            out.append(n)
        }
        return out
    }
}
