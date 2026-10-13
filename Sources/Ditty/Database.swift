import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Clip {
    var id: Int64
    var date: Date
    var text: String
    var dontAutoDelete: Bool
    var isGroup: Bool
    var parentID: Int64
    var quickPasteText: String
    var isSticky: Bool
    var hasImage: Bool
    var lastPasteDate: Date?
}

struct ClipFormat {
    static let text = "public.utf8-plain-text"
    static let rtf = "public.rtf"
    static let html = "public.html"
    static let png = "public.png"
    static let files = "ditty.file-urls"

    var type: String
    var data: Data
}

enum StickyMode { case top, last, none }

/// SQLite store. The schema follows Ditto's: a Main row per clip and a Data row per clipboard format.
final class Database {
    static let rootID: Int64 = -1

    let path: String
    private var db: OpaquePointer?

    init(path: String) {
        self.path = path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if sqlite3_open(path, &db) != SQLITE_OK {
            NSLog("Ditty: could not open database at \(path)")
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS Main(
                lID INTEGER PRIMARY KEY AUTOINCREMENT,
                lDate INTEGER,
                mText TEXT,
                lShortCut INTEGER DEFAULT 0,
                lDontAutoDelete INTEGER DEFAULT 0,
                CRC INTEGER,
                bIsGroup INTEGER DEFAULT 0,
                lParentID INTEGER DEFAULT -1,
                QuickPasteText TEXT DEFAULT '',
                clipOrder REAL,
                stickyClipOrder REAL,
                lastPasteDate INTEGER);
            CREATE TABLE IF NOT EXISTS Data(
                lID INTEGER PRIMARY KEY AUTOINCREMENT,
                lParentID INTEGER,
                strClipBoardFormat TEXT,
                ooData BLOB);
            CREATE INDEX IF NOT EXISTS Main_Order ON Main(clipOrder DESC);
            CREATE INDEX IF NOT EXISTS Main_CRC ON Main(CRC);
            CREATE INDEX IF NOT EXISTS Main_Parent ON Main(lParentID);
            CREATE INDEX IF NOT EXISTS Data_Parent ON Data(lParentID, strClipBoardFormat);
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: - Low level

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            NSLog("Ditty: SQL error: \(err.map { String(cString: $0) } ?? "?") in \(sql)")
            sqlite3_free(err)
        }
    }

    private func run(_ sql: String, _ args: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("Ditty: prepare failed: \(String(cString: sqlite3_errmsg(db))) in \(sql)")
            return
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case let v as Int64: sqlite3_bind_int64(stmt, n, v)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Bool: sqlite3_bind_int64(stmt, n, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, n, v)
            case let v as String: sqlite3_bind_text(stmt, n, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                if v.isEmpty {
                    sqlite3_bind_zeroblob(stmt, n, 0)
                } else {
                    _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
                }
            default: sqlite3_bind_null(stmt, n)
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row?(stmt) }
    }

    private func scalar(_ sql: String, _ args: [Any?] = []) -> Double? {
        var result: Double?
        run(sql, args) { s in
            if sqlite3_column_type(s, 0) != SQLITE_NULL { result = sqlite3_column_double(s, 0) }
        }
        return result
    }

    private static func string(_ s: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(s, col).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ s: OpaquePointer, _ col: Int32) -> Data {
        guard let p = sqlite3_column_blob(s, col) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, col)))
    }

    private static let now = { Int64(Date().timeIntervalSince1970) }

    // MARK: - Reading

    private static let clipColumns = """
        lID, lDate, substr(mText, 1, 2000), lDontAutoDelete, bIsGroup, lParentID, QuickPasteText,
        stickyClipOrder IS NOT NULL,
        EXISTS(SELECT 1 FROM Data d WHERE d.lParentID = Main.lID AND d.strClipBoardFormat = 'public.png'),
        lastPasteDate
        """
    private static let listOrder = "ORDER BY (stickyClipOrder IS NULL), stickyClipOrder DESC, clipOrder DESC"

    private static func clip(_ s: OpaquePointer) -> Clip {
        Clip(id: sqlite3_column_int64(s, 0),
             date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 1))),
             text: string(s, 2),
             dontAutoDelete: sqlite3_column_int64(s, 3) != 0,
             isGroup: sqlite3_column_int64(s, 4) != 0,
             parentID: sqlite3_column_int64(s, 5),
             quickPasteText: string(s, 6),
             isSticky: sqlite3_column_int64(s, 7) != 0,
             hasImage: sqlite3_column_int64(s, 8) != 0,
             lastPasteDate: sqlite3_column_type(s, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 9))))
    }

    /// Clips in a group, or (when searching) every clip matching the text.
    func fetch(parent: Int64, search: String) -> [Clip] {
        var clips: [Clip] = []
        if search.isEmpty {
            run("SELECT \(Self.clipColumns) FROM Main WHERE lParentID = ? \(Self.listOrder) LIMIT 5000", [parent]) { clips.append(Self.clip($0)) }
        } else {
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            run("""
                SELECT \(Self.clipColumns) FROM Main
                WHERE bIsGroup = 0 AND (mText LIKE ? ESCAPE '\\' OR QuickPasteText LIKE ? ESCAPE '\\')
                \(Self.listOrder) LIMIT 1000
                """, [pattern, pattern]) { clips.append(Self.clip($0)) }
        }
        return clips
    }

    func groups() -> [Clip] {
        var clips: [Clip] = []
        run("SELECT \(Self.clipColumns) FROM Main WHERE bIsGroup = 1 ORDER BY mText COLLATE NOCASE") { clips.append(Self.clip($0)) }
        return clips
    }

    func clip(_ id: Int64) -> Clip? {
        var clip: Clip?
        run("SELECT \(Self.clipColumns) FROM Main WHERE lID = ?", [id]) { clip = Self.clip($0) }
        return clip
    }

    func formats(_ id: Int64) -> [ClipFormat] {
        var result: [ClipFormat] = []
        run("SELECT strClipBoardFormat, ooData FROM Data WHERE lParentID = ? ORDER BY lID", [id]) {
            result.append(ClipFormat(type: Self.string($0, 0), data: Self.blob($0, 1)))
        }
        return result
    }

    func formatSizes(_ id: Int64) -> [(type: String, bytes: Int)] {
        var result: [(String, Int)] = []
        run("SELECT strClipBoardFormat, length(ooData) FROM Data WHERE lParentID = ? ORDER BY lID", [id]) {
            result.append((Self.string($0, 0), Int(sqlite3_column_int64($0, 1))))
        }
        return result
    }

    func data(_ id: Int64, format: String) -> Data? {
        var result: Data?
        run("SELECT ooData FROM Data WHERE lParentID = ? AND strClipBoardFormat = ? LIMIT 1", [id, format]) { result = Self.blob($0, 0) }
        return result
    }

    func fullText(_ id: Int64) -> String {
        if let d = data(id, format: ClipFormat.text), let s = String(data: d, encoding: .utf8) { return s }
        var text = ""
        run("SELECT mText FROM Main WHERE lID = ?", [id]) { text = Self.string($0, 0) }
        return text
    }

    var clipCount: Int { Int(scalar("SELECT COUNT(*) FROM Main WHERE bIsGroup = 0") ?? 0) }

    // MARK: - Writing

    private func nextOrder() -> Double { (scalar("SELECT MAX(clipOrder) FROM Main") ?? 0) + 1 }

    /// Saves a copy. A clip identical to an existing one is moved back to the top instead of duplicated.
    @discardableResult
    func addClip(text: String, formats: [ClipFormat], crc: Int64) -> Int64 {
        var existing: Int64?
        run("SELECT lID FROM Main WHERE CRC = ? AND bIsGroup = 0 LIMIT 1", [crc]) { existing = sqlite3_column_int64($0, 0) }
        if let existing {
            run("UPDATE Main SET clipOrder = ?, lDate = ? WHERE lID = ?", [nextOrder(), Self.now(), existing])
            return existing
        }
        exec("BEGIN")
        run("INSERT INTO Main(lDate, mText, CRC, clipOrder) VALUES(?, ?, ?, ?)", [Self.now(), text, crc, nextOrder()])
        let id = sqlite3_last_insert_rowid(db)
        for f in formats {
            run("INSERT INTO Data(lParentID, strClipBoardFormat, ooData) VALUES(?, ?, ?)", [id, f.type, f.data])
        }
        exec("COMMIT")
        return id
    }

    @discardableResult
    func createGroup(name: String, parent: Int64) -> Int64 {
        run("INSERT INTO Main(lDate, mText, bIsGroup, lParentID, lDontAutoDelete, clipOrder) VALUES(?, ?, 1, ?, 1, ?)",
            [Self.now(), name, parent, nextOrder()])
        return sqlite3_last_insert_rowid(db)
    }

    /// Deleting a group keeps its clips, moving them back to the main list.
    func delete(_ ids: [Int64]) {
        exec("BEGIN")
        for id in ids {
            run("UPDATE Main SET lParentID = -1 WHERE lParentID = ?", [id])
            run("DELETE FROM Data WHERE lParentID = ?", [id])
            run("DELETE FROM Main WHERE lID = ?", [id])
        }
        exec("COMMIT")
    }

    private static let disposable = "bIsGroup = 0 AND lDontAutoDelete = 0 AND lParentID = -1 AND stickyClipOrder IS NULL"

    /// Removes every clip that is not protected (sticky, never-auto-delete, or filed in a group).
    func deleteAllDisposable() {
        exec("DELETE FROM Data WHERE lParentID IN (SELECT lID FROM Main WHERE \(Self.disposable))")
        exec("DELETE FROM Main WHERE \(Self.disposable)")
        exec("VACUUM")
    }

    func trim(maxEntries: Int?, expireDays: Int?) {
        var doomed: [Int64] = []
        if let maxEntries {
            run("SELECT lID FROM Main WHERE \(Self.disposable) ORDER BY clipOrder DESC LIMIT -1 OFFSET ?", [maxEntries]) {
                doomed.append(sqlite3_column_int64($0, 0))
            }
        }
        if let expireDays {
            let cutoff = Self.now() - Int64(expireDays) * 86400
            run("SELECT lID FROM Main WHERE \(Self.disposable) AND lDate < ?", [cutoff]) { doomed.append(sqlite3_column_int64($0, 0)) }
        }
        if !doomed.isEmpty { delete(doomed) }
    }

    func setSticky(_ id: Int64, _ mode: StickyMode) {
        switch mode {
        case .top:
            run("UPDATE Main SET stickyClipOrder = ? WHERE lID = ?", [(scalar("SELECT MAX(stickyClipOrder) FROM Main") ?? 0) + 1, id])
        case .last:
            run("UPDATE Main SET stickyClipOrder = ? WHERE lID = ?", [(scalar("SELECT MIN(stickyClipOrder) FROM Main") ?? 0) - 1, id])
        case .none:
            run("UPDATE Main SET stickyClipOrder = NULL WHERE lID = ?", [id])
        }
    }

    func setDontAutoDelete(_ id: Int64, _ value: Bool) {
        run("UPDATE Main SET lDontAutoDelete = ? WHERE lID = ?", [value, id])
    }

    private func isInside(_ id: Int64, group: Int64) -> Bool {
        var current = id
        for _ in 0..<100 where current != Self.rootID {
            if current == group { return true }
            current = clip(current)?.parentID ?? Self.rootID
        }
        return false
    }

    /// Moves clips into a group. A group is never moved into itself or one of its own subgroups.
    func setParent(_ ids: [Int64], _ parent: Int64) {
        for id in ids where !isInside(parent, group: id) {
            run("UPDATE Main SET lParentID = ? WHERE lID = ?", [parent, id])
        }
    }

    func moveToTop(_ id: Int64) {
        run("UPDATE Main SET clipOrder = ? WHERE lID = ?", [nextOrder(), id])
    }

    func markPasted(_ id: Int64, bumpOrder: Bool) {
        run("UPDATE Main SET lastPasteDate = ? WHERE lID = ?", [Self.now(), id])
        if bumpOrder { moveToTop(id) }
    }

    func rename(_ id: Int64, _ name: String) {
        run("UPDATE Main SET mText = ? WHERE lID = ?", [name, id])
    }

    func setQuickPasteText(_ id: Int64, _ text: String) {
        run("UPDATE Main SET QuickPasteText = ? WHERE lID = ?", [text, id])
    }

    /// Replaces a clip's content with edited plain text, dropping its rich formats so paste matches the edit.
    func replaceText(_ id: Int64, _ text: String) {
        exec("BEGIN")
        run("UPDATE Main SET mText = ?, CRC = ? WHERE lID = ?", [text, Self.crc(Data(text.utf8)), id])
        run("DELETE FROM Data WHERE lParentID = ?", [id])
        run("INSERT INTO Data(lParentID, strClipBoardFormat, ooData) VALUES(?, ?, ?)", [id, ClipFormat.text, Data(text.utf8)])
        exec("COMMIT")
    }

    /// FNV-1a, used the way Ditto uses its CRC column: to spot a copy that is already saved.
    static func crc(_ data: Data) -> Int64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return Int64(bitPattern: h)
    }
}
