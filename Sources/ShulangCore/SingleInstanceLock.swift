import Foundation
import Darwin

/// Keeps a process-wide lock for as long as the app can modify shared history.
public final class SingleInstanceLock {
    private let descriptor: Int32

    public init?(directory: URL) {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        let path = directory.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
