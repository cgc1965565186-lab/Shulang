import Foundation
import Darwin
import CryptoKit

/// Metadata-only fingerprint for explicitly reviewed directories. Never follows symbolic links.
enum DirectoryFingerprint {
    struct Capture {
        let digest: String
        let logicalBytes: Int64
    }

    static func capture(_ path: String) -> Capture? {
        var hasher = SHA256()
        var total: Int64 = 0
        let fileManager = FileManager.default
        func same(_ first: stat, _ second: stat) -> Bool {
            first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_mode == second.st_mode &&
            first.st_size == second.st_size && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec &&
            first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
            first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
        }
        func walk(_ full: String, relative: String) throws {
            var before = stat()
            guard lstat(full, &before) == 0 else { throw CocoaError(.fileReadUnknown) }
            let fields = "\(relative.utf8.count):\(relative)\0\(before.st_dev):\(before.st_ino):\(before.st_mode):\(before.st_size):\(before.st_mtimespec.tv_sec):\(before.st_mtimespec.tv_nsec):\(before.st_ctimespec.tv_sec):\(before.st_ctimespec.tv_nsec)\n"
            hasher.update(data: Data(fields.utf8))
            if (before.st_mode & S_IFMT) == S_IFREG {
                let (sum, overflow) = total.addingReportingOverflow(max(0, Int64(before.st_size)))
                guard !overflow else { throw CocoaError(.fileReadTooLarge) }
                total = sum
            } else if (before.st_mode & S_IFMT) == S_IFDIR {
                let children = try fileManager.contentsOfDirectory(atPath: full).sorted()
                for child in children {
                    try walk((full as NSString).appendingPathComponent(child), relative: relative + "/" + child)
                }
            }
            var after = stat()
            guard lstat(full, &after) == 0, same(before, after) else { throw CocoaError(.fileReadUnknown) }
        }
        do {
            try walk(path, relative: "")
            return Capture(digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(), logicalBytes: total)
        } catch { return nil }
    }
}
