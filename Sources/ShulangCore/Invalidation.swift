import Foundation
import CoreServices

public enum InvalidationDecision: Equatable, Sendable {
    case directories([String])
    case fullRescan
}

public enum InvalidationPlanner {
    /// FSEvents are invalidation hints only. Event loss or root/volume changes require a full scan.
    public static func decide(root: URL, events: [(path: String, flags: UInt32)]) -> InvalidationDecision {
        let base = root.standardizedFileURL.path
        let fullFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped |
                               kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped |
                               kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        var paths = Set<String>()
        for event in events {
            if event.flags & fullFlags != 0 { return .fullRescan }
            let path = URL(fileURLWithPath: event.path).standardizedFileURL.path
            guard path == base || path.hasPrefix(base == "/" ? "/" : base + "/") else { return .fullRescan }
            paths.insert(path)
        }
        // Keeping descendants avoids losing events unless the caller rescans recursively.
        return .directories(paths.sorted())
    }
}
