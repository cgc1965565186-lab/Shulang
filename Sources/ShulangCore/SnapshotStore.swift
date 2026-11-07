import Foundation
import SQLite3

public enum SnapshotStoreError: LocalizedError {
    case database(String)
    case oversizedSnapshot
    public var errorDescription: String? {
        switch self {
        case .database(let message): return "快照数据库错误：\(message)"
        case .oversizedSnapshot: return "快照超过数据库单条记录的大小限制"
        }
    }
}

public struct InvalidationBatch: Sendable {
    public let sessionID: UUID
    public let paths: [String]
    public let through: Int64
}

/// Local metadata store. Change events are hints; callers must rescan before treating them as current.
public final class SnapshotStore: @unchecked Sendable {
    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let lock = NSRecursiveLock()

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let handle { sqlite3_close(handle) }
            throw SnapshotStoreError.database(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try enableWAL()
            try exec("CREATE TABLE IF NOT EXISTS snapshots (session TEXT NOT NULL, revision INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(session, revision))")
            try exec("CREATE TABLE IF NOT EXISTS invalidations (session TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY(session, path))")
            try exec("CREATE TABLE IF NOT EXISTS change_events (seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, path TEXT NOT NULL)")
            try exec("BEGIN IMMEDIATE")
            do {
                try exec("INSERT INTO change_events(session, path) SELECT session, path FROM invalidations")
                try exec("DELETE FROM invalidations")
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func enableWAL() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0),
              String(cString: value).lowercased() == "wal" else {
            throw SnapshotStoreError.database("无法启用 WAL 模式")
        }
    }

    private func failure() -> SnapshotStoreError { .database(String(cString: sqlite3_errmsg(db))) }

    public func save(_ snapshot: ScanSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Int(Int32.max) else { throw SnapshotStoreError.oversizedSnapshot }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO snapshots(session, revision, payload) VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, snapshot.sessionID.uuidString, -1, transient)
        sqlite3_bind_int64(statement, 2, Int64(snapshot.revision))
        let status = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    public func load(sessionID: UUID, revision: Int) throws -> ScanSnapshot? {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM snapshots WHERE session = ? AND revision = ?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transient)
        sqlite3_bind_int64(statement, 2, Int64(revision))
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try JSONDecoder().decode(ScanSnapshot.self, from: data)
    }

    public func latestRevision(sessionID: UUID) throws -> Int? {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(revision) FROM snapshots WHERE session = ?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func markInvalidated(sessionID: UUID, path: String) throws {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO change_events(session, path) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, path, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    public func invalidatedPaths(sessionID: UUID) throws -> [String] {
        try pendingInvalidations(sessionID: sessionID).paths
    }

    public func pendingInvalidations(sessionID: UUID) throws -> InvalidationBatch {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT seq, path FROM change_events WHERE session = ? ORDER BY seq", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID.uuidString, -1, transient)
        var result = Set<String>()
        var through: Int64 = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return InvalidationBatch(sessionID: sessionID, paths: result.sorted(), through: through) }
            guard status == SQLITE_ROW, let path = sqlite3_column_text(statement, 1) else { throw failure() }
            through = sqlite3_column_int64(statement, 0)
            result.insert(String(cString: path))
        }
    }

    /// Commits the new revision and acknowledges only events captured before rescanning.
    public func commit(_ snapshot: ScanSnapshot, acknowledging batch: InvalidationBatch) throws {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.sessionID == batch.sessionID else { throw SnapshotStoreError.database("快照与失效记录不属于同一会话") }
        try exec("BEGIN IMMEDIATE")
        do {
            try save(snapshot)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM change_events WHERE session = ? AND seq <= ?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, snapshot.sessionID.uuidString, -1, transient)
            sqlite3_bind_int64(statement, 2, batch.through)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
