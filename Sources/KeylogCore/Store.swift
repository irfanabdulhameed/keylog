import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String {
        switch self { case let .sqlite(message): "SQLite: \(message)" }
    }
}

/// A physical key pressed in an app. `app` is "" when per-app tracking is off.
public struct KeyUse: Hashable, Sendable {
    public let app: String
    public let key: UInt16

    public init(app: String, key: UInt16) {
        self.app = app
        self.key = key
    }
}

public struct AppUse: Equatable, Sendable {
    public var name: String
    public var keys = 0
    public var clicks = 0
    public var scrollMM = 0.0

    public init(name: String) { self.name = name }
}

/// Everything gathered in memory for one hour, written in a single transaction.
public struct HourFlush: Sendable {
    public var bucket: HourBucket
    public var counts = Counts()
    public var minutesMask: UInt64 = 0
    public var keys: [KeyUse: Int] = [:]
    public var apps: [String: AppUse] = [:]

    public init(bucket: HourBucket) { self.bucket = bucket }

    public var isEmpty: Bool { counts.isEmpty && minutesMask == 0 && keys.isEmpty && apps.isEmpty }
}

public struct HourRow: Equatable, Sendable {
    public let day: String
    public let hour: Int
    public let timeZone: String
    public let counts: Counts
    public let minutesMask: UInt64
}

/// The one SQLite file all counts live in. Every database call runs on one private
/// serial queue: writes go in the background, reads wait for their answer.
public final class Store: @unchecked Sendable {
    public let path: String
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let queue = DispatchQueue(label: "keylog.store")

    /// `~/Library/Application Support/Keylog/keylog.sqlite`.
    public static var defaultPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Keylog/keylog.sqlite").path
    }

    public init(path: String = Store.defaultPath) throws {
        self.path = path
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_busy_timeout(db, 2000)
        try exec(Self.schema)
        try migrate()
    }

    /// Brings files from older versions up to date.
    private func migrate() throws {
        let columns = query("PRAGMA table_info(hours)", []) { text($0, 1) }
        if !columns.contains("peak_cps") {
            try exec("ALTER TABLE hours ADD COLUMN peak_cps INTEGER NOT NULL DEFAULT 0")
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    static let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS hours (
            day TEXT NOT NULL, hour INTEGER NOT NULL, tz TEXT NOT NULL,
            letters INTEGER NOT NULL DEFAULT 0, numbers INTEGER NOT NULL DEFAULT 0,
            special INTEGER NOT NULL DEFAULT 0, space INTEGER NOT NULL DEFAULT 0,
            other INTEGER NOT NULL DEFAULT 0,
            clicks_left INTEGER NOT NULL DEFAULT 0, clicks_right INTEGER NOT NULL DEFAULT 0,
            clicks_middle INTEGER NOT NULL DEFAULT 0, clicks_other INTEGER NOT NULL DEFAULT 0,
            mouse_mm REAL NOT NULL DEFAULT 0, scroll_mm REAL NOT NULL DEFAULT 0,
            minutes_mask INTEGER NOT NULL DEFAULT 0, peak_kps INTEGER NOT NULL DEFAULT 0,
            peak_cps INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, hour)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS keys (
            day TEXT NOT NULL, app TEXT NOT NULL, key INTEGER NOT NULL, count INTEGER NOT NULL,
            PRIMARY KEY (day, app, key)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS apps (
            day TEXT NOT NULL, app TEXT NOT NULL, name TEXT NOT NULL,
            keys INTEGER NOT NULL DEFAULT 0, clicks INTEGER NOT NULL DEFAULT 0,
            scroll_mm REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (day, app)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT OR IGNORE INTO meta (key, value) VALUES ('schema', '1');
        """

    // MARK: Writing

    /// Adds an hour's counts to what is already stored for that hour.
    public func write(_ flush: HourFlush, wait: Bool = false) {
        guard !flush.isEmpty else { return }
        let work = { [self] in
            do {
                try exec("BEGIN")
                let b = flush.bucket, c = flush.counts
                try run("""
                    INSERT INTO hours (day, hour, tz, letters, numbers, special, space, other,
                        clicks_left, clicks_right, clicks_middle, clicks_other,
                        mouse_mm, scroll_mm, minutes_mask, peak_kps, peak_cps)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (day, hour) DO UPDATE SET
                        letters = letters + excluded.letters, numbers = numbers + excluded.numbers,
                        special = special + excluded.special, space = space + excluded.space,
                        other = other + excluded.other,
                        clicks_left = clicks_left + excluded.clicks_left,
                        clicks_right = clicks_right + excluded.clicks_right,
                        clicks_middle = clicks_middle + excluded.clicks_middle,
                        clicks_other = clicks_other + excluded.clicks_other,
                        mouse_mm = mouse_mm + excluded.mouse_mm,
                        scroll_mm = scroll_mm + excluded.scroll_mm,
                        minutes_mask = minutes_mask | excluded.minutes_mask,
                        peak_kps = max(peak_kps, excluded.peak_kps),
                        peak_cps = max(peak_cps, excluded.peak_cps)
                    """, [
                        .text(b.day), .int(b.hour), .text(b.timeZone),
                        .int(c.letters), .int(c.numbers), .int(c.special), .int(c.space), .int(c.other),
                        .int(c.clicksLeft), .int(c.clicksRight), .int(c.clicksMiddle), .int(c.clicksOther),
                        .real(c.mouseMM), .real(c.scrollMM), .int(Int(flush.minutesMask)), .int(c.peakKPS),
                        .int(c.peakCPS),
                    ])
                for (use, count) in flush.keys {
                    try run("""
                        INSERT INTO keys (day, app, key, count) VALUES (?, ?, ?, ?)
                        ON CONFLICT (day, app, key) DO UPDATE SET count = count + excluded.count
                        """, [.text(b.day), .text(use.app), .int(Int(use.key)), .int(count)])
                }
                for (app, use) in flush.apps {
                    try run("""
                        INSERT INTO apps (day, app, name, keys, clicks, scroll_mm) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT (day, app) DO UPDATE SET name = excluded.name,
                            keys = keys + excluded.keys, clicks = clicks + excluded.clicks,
                            scroll_mm = scroll_mm + excluded.scroll_mm
                        """, [.text(b.day), .text(app), .text(use.name), .int(use.keys), .int(use.clicks), .real(use.scrollMM)])
                }
                try run("INSERT OR IGNORE INTO meta (key, value) VALUES ('first_day', ?)", [.text(b.day)])
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                NSLog("Keylog: saving counts failed: \(error)")
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// Waits for every pending write to finish.
    public func sync() { queue.sync {} }

    // MARK: Reading

    /// Stored hours from `first` through `last` (inclusive "yyyy-MM-dd" days), oldest first.
    public func hours(from first: String, through last: String) -> [HourRow] {
        queue.sync {
            query("""
                SELECT day, hour, tz, letters, numbers, special, space, other,
                    clicks_left, clicks_right, clicks_middle, clicks_other,
                    mouse_mm, scroll_mm, minutes_mask, peak_kps, peak_cps
                FROM hours WHERE day BETWEEN ? AND ? ORDER BY day, hour
                """, [.text(first), .text(last)]) { s in
                var c = Counts()
                c.letters = int(s, 3); c.numbers = int(s, 4); c.special = int(s, 5)
                c.space = int(s, 6); c.other = int(s, 7)
                c.clicksLeft = int(s, 8); c.clicksRight = int(s, 9)
                c.clicksMiddle = int(s, 10); c.clicksOther = int(s, 11)
                c.mouseMM = sqlite3_column_double(s, 12)
                c.scrollMM = sqlite3_column_double(s, 13)
                let mask = UInt64(sqlite3_column_int64(s, 14))
                c.activeMinutes = mask.nonzeroBitCount
                c.peakKPS = int(s, 15)
                c.peakCPS = int(s, 16)
                return HourRow(day: text(s, 0), hour: int(s, 1), timeZone: text(s, 2), counts: c, minutesMask: mask)
            }
        }
    }

    public func totals(day: String) -> Counts {
        hours(from: day, through: day).reduce(into: Counts()) { $0.add($1.counts) }
    }

    /// Presses per physical key; `app` nil means every app.
    public func keyCounts(from first: String, through last: String, app: String? = nil) -> [UInt16: Int] {
        queue.sync {
            var sql = "SELECT key, sum(count) FROM keys WHERE day BETWEEN ? AND ?"
            var binds: [SQLValue] = [.text(first), .text(last)]
            if let app {
                sql += " AND app = ?"
                binds.append(.text(app))
            }
            let rows = query(sql + " GROUP BY key", binds) { s in (UInt16(int(s, 0)), int(s, 1)) }
            return Dictionary(uniqueKeysWithValues: rows)
        }
    }

    public func apps(from first: String, through last: String) -> [String: AppUse] {
        queue.sync {
            let rows = query("""
                SELECT app, max(name), sum(keys), sum(clicks), sum(scroll_mm)
                FROM apps WHERE day BETWEEN ? AND ? GROUP BY app
                """, [.text(first), .text(last)]) { s -> (String, AppUse) in
                var use = AppUse(name: text(s, 1))
                use.keys = int(s, 2)
                use.clicks = int(s, 3)
                use.scrollMM = sqlite3_column_double(s, 4)
                return (text(s, 0), use)
            }
            return Dictionary(uniqueKeysWithValues: rows)
        }
    }

    /// Every stored table, for a full backup.
    public func backup() -> [String: [[String: Any]]] {
        queue.sync {
            var tables: [String: [[String: Any]]] = [:]
            for table in ["hours", "keys", "apps", "meta"] {
                tables[table] = query("SELECT * FROM \(table)", []) { s in
                    var row: [String: Any] = [:]
                    for i in 0..<sqlite3_column_count(s) {
                        let name = String(cString: sqlite3_column_name(s, i))
                        switch sqlite3_column_type(s, i) {
                        case SQLITE_INTEGER: row[name] = sqlite3_column_int64(s, i)
                        case SQLITE_FLOAT: row[name] = sqlite3_column_double(s, i)
                        default: row[name] = text(s, i)
                        }
                    }
                    return row
                }
            }
            return tables
        }
    }

    /// Deletes one day's counts.
    public func deleteDay(_ day: String) {
        queue.sync {
            do {
                try exec("BEGIN")
                for table in ["hours", "keys", "apps"] {
                    try run("DELETE FROM \(table) WHERE day = ?", [.text(day)])
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                NSLog("Keylog: deleting a day failed: \(error)")
            }
        }
    }

    public enum ImportError: Error, LocalizedError {
        case notABackup
        public var errorDescription: String? { "This file isn't a Keylog backup." }
    }

    /// Restores a JSON backup made by Export. `replace` empties the file first;
    /// otherwise the backup's counts are added to what's here. Returns rows read.
    @discardableResult
    public func importBackup(_ data: Data, replace: Bool) throws -> Int {
        guard let backup = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (backup["format"] as? String)?.hasPrefix("keylog-backup-") == true,
              let hours = backup["hours"] as? [[String: Any]] else { throw ImportError.notABackup }
        let keys = backup["keys"] as? [[String: Any]] ?? []
        let apps = backup["apps"] as? [[String: Any]] ?? []
        let meta = backup["meta"] as? [[String: Any]] ?? []
        func int(_ row: [String: Any], _ key: String) -> Int { (row[key] as? NSNumber)?.intValue ?? 0 }
        func real(_ row: [String: Any], _ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
        func str(_ row: [String: Any], _ key: String) -> String { row[key] as? String ?? "" }

        return try queue.sync {
            try exec("BEGIN")
            do {
                if replace { try exec("DELETE FROM hours; DELETE FROM keys; DELETE FROM apps; DELETE FROM meta WHERE key = 'first_day';") }
                for row in hours {
                    try run("""
                        INSERT INTO hours (day, hour, tz, letters, numbers, special, space, other,
                            clicks_left, clicks_right, clicks_middle, clicks_other,
                            mouse_mm, scroll_mm, minutes_mask, peak_kps, peak_cps)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT (day, hour) DO UPDATE SET
                            letters = letters + excluded.letters, numbers = numbers + excluded.numbers,
                            special = special + excluded.special, space = space + excluded.space,
                            other = other + excluded.other,
                            clicks_left = clicks_left + excluded.clicks_left,
                            clicks_right = clicks_right + excluded.clicks_right,
                            clicks_middle = clicks_middle + excluded.clicks_middle,
                            clicks_other = clicks_other + excluded.clicks_other,
                            mouse_mm = mouse_mm + excluded.mouse_mm, scroll_mm = scroll_mm + excluded.scroll_mm,
                            minutes_mask = minutes_mask | excluded.minutes_mask,
                            peak_kps = max(peak_kps, excluded.peak_kps), peak_cps = max(peak_cps, excluded.peak_cps)
                        """, [
                            .text(str(row, "day")), .int(int(row, "hour")), .text(str(row, "tz")),
                            .int(int(row, "letters")), .int(int(row, "numbers")), .int(int(row, "special")),
                            .int(int(row, "space")), .int(int(row, "other")),
                            .int(int(row, "clicks_left")), .int(int(row, "clicks_right")),
                            .int(int(row, "clicks_middle")), .int(int(row, "clicks_other")),
                            .real(real(row, "mouse_mm")), .real(real(row, "scroll_mm")),
                            .int(int(row, "minutes_mask")), .int(int(row, "peak_kps")), .int(int(row, "peak_cps")),
                        ])
                }
                for row in keys {
                    try run("""
                        INSERT INTO keys (day, app, key, count) VALUES (?, ?, ?, ?)
                        ON CONFLICT (day, app, key) DO UPDATE SET count = count + excluded.count
                        """, [.text(str(row, "day")), .text(str(row, "app")), .int(int(row, "key")), .int(int(row, "count"))])
                }
                for row in apps {
                    try run("""
                        INSERT INTO apps (day, app, name, keys, clicks, scroll_mm) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT (day, app) DO UPDATE SET name = excluded.name,
                            keys = keys + excluded.keys, clicks = clicks + excluded.clicks,
                            scroll_mm = scroll_mm + excluded.scroll_mm
                        """, [.text(str(row, "day")), .text(str(row, "app")), .text(str(row, "name")),
                              .int(int(row, "keys")), .int(int(row, "clicks")), .real(real(row, "scroll_mm"))])
                }
                if let first = meta.first(where: { str($0, "key") == "first_day" }).map({ str($0, "value") }), !first.isEmpty {
                    try run("""
                        INSERT INTO meta (key, value) VALUES ('first_day', ?)
                        ON CONFLICT (key) DO UPDATE SET value = min(value, excluded.value)
                        """, [.text(first)])
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
            return hours.count + keys.count + apps.count
        }
    }

    /// Deletes every count. Settings are kept.
    public func deleteAll() {
        queue.sync {
            do {
                try exec("DELETE FROM hours; DELETE FROM keys; DELETE FROM apps; DELETE FROM meta WHERE key = 'first_day'; VACUUM;")
            } catch {
                NSLog("Keylog: deleting data failed: \(error)")
            }
        }
    }

    /// The first day anything was recorded.
    public func firstDay() -> String? {
        queue.sync {
            query("SELECT value FROM meta WHERE key = 'first_day'", []) { text($0, 0) }.first
        }
    }

    // MARK: SQLite plumbing (call only on `queue`)

    enum SQLValue {
        case int(Int), real(Double), text(String)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func prepared(_ sql: String, _ binds: [SQLValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        } else {
            var new: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &new, nil) == SQLITE_OK, let new else { throw error() }
            statements[sql] = new
            statement = new
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in binds.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let .int(v): sqlite3_bind_int64(statement, index, Int64(v))
            case let .real(v): sqlite3_bind_double(statement, index, v)
            case let .text(v): sqlite3_bind_text(statement, index, v, -1, transient)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ binds: [SQLValue]) throws {
        let statement = try prepared(sql, binds)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func query<T>(_ sql: String, _ binds: [SQLValue], _ row: (OpaquePointer) -> T) -> [T] {
        guard let statement = try? prepared(sql, binds) else { return [] }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(row(statement)) }
        return rows
    }

    private func error() -> StoreError { .sqlite(String(cString: sqlite3_errmsg(db))) }
}

private func int(_ s: OpaquePointer, _ column: Int32) -> Int { Int(sqlite3_column_int64(s, column)) }
private func text(_ s: OpaquePointer, _ column: Int32) -> String {
    sqlite3_column_text(s, column).map { String(cString: $0) } ?? ""
}
