import Foundation
import CoreServices

public enum DirectoryEventsError: LocalizedError {
    case cannotCreate, cannotStart, ignoredRoot, eventsLost
    public var errorDescription: String? {
        switch self {
        case .cannotCreate: return "无法创建目录变化监听"
        case .cannotStart: return "无法启动目录变化监听"
        case .ignoredRoot: return "应用数据目录不启用变化监听"
        case .eventsLost: return "变化记录不可靠，必须重新全量扫描"
        }
    }
}

private final class DirectoryEventsHandler {
    let callback: @Sendable (InvalidationDecision) -> Void
    let root: URL
    init(root: URL, callback: @escaping @Sendable (InvalidationDecision) -> Void) {
        self.root = root
        self.callback = callback
    }
}

private final class InvalidationHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func markFailed() { lock.lock(); failed = true; lock.unlock() }
    var isReliable: Bool { lock.lock(); defer { lock.unlock() }; return !failed }
}

/// Monitors changes only while running; the caller must perform a full scan on a fresh launch.
public final class DirectoryEvents: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.shulang.filesystem-events")

    public init(root: URL, onChange: @escaping @Sendable (InvalidationDecision) -> Void) throws {
        let handler = Unmanaged.passRetained(DirectoryEventsHandler(root: root, callback: onChange))
        var context = FSEventStreamContext(version: 0, info: handler.toOpaque(), retain: nil, release: { pointer in
            if let pointer { Unmanaged<DirectoryEventsHandler>.fromOpaque(pointer).release() }
        }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<DirectoryEventsHandler>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self)
            guard paths.count == count else { handler.callback(.fullRescan); return }
            var events: [(path: String, flags: UInt32)] = []
            for index in 0..<count {
                guard let path = paths[index] as? String else { handler.callback(.fullRescan); return }
                events.append((path, flags[index]))
            }
            handler.callback(InvalidationPlanner.decide(root: handler.root, events: events))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                                 [root.path] as CFArray,
                                                 FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else {
            handler.release()
            throw DirectoryEventsError.cannotCreate
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            throw DirectoryEventsError.cannotStart
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    public func flush() async {
        await Task.detached { [self] in
            if let stream { FSEventStreamFlushSync(stream) }
        }.value
    }
}

/// Connects live event hints to durable invalidations; it never marks a snapshot current.
public final class SnapshotInvalidationTracker: @unchecked Sendable {
    private let monitor: DirectoryEvents
    private let health: InvalidationHealth

    public init(root: URL, sessionID: UUID, store: SnapshotStore, ignoredDirectories: [URL] = [],
                onUpdate: @escaping @Sendable (InvalidationDecision) -> Void = { _ in },
                onFailure: @escaping @Sendable (String) -> Void) throws {
        let base = root.standardizedFileURL
        let ignored = ignoredDirectories.map { $0.standardizedFileURL.path }
        guard !ignored.contains(where: { base.path == $0 || base.path.hasPrefix($0 + "/") }) else {
            throw DirectoryEventsError.ignoredRoot
        }
        let health = InvalidationHealth()
        self.health = health
        monitor = try DirectoryEvents(root: base) { decision in
            do {
                switch decision {
                case .fullRescan:
                    try store.markInvalidated(sessionID: sessionID, path: base.path)
                case .directories(let paths):
                    let filtered = paths.filter { path in
                        !ignored.contains { path == $0 || path.hasPrefix($0 + "/") }
                    }
                    guard !filtered.isEmpty else { return }
                    for path in filtered { try store.markInvalidated(sessionID: sessionID, path: path) }
                    onUpdate(.directories(filtered))
                    return
                }
                onUpdate(decision)
            } catch {
                health.markFailed()
                onFailure(error.localizedDescription)
            }
        }
    }

    public func flush() async { await monitor.flush() }
    public var isReliable: Bool { health.isReliable }
}
