import Foundation

/// Makes sure only one `thumbd run` is active per user: two instances would both divert the
/// buttons and every press would fire its shortcut twice.
///
/// Uses flock(2), so the lock goes away with the process even if it crashes.
enum InstanceLock {
    enum Result {
        case acquired
        /// Another instance holds the lock (its PID, if it could be read).
        case heldBy(pid_t?)
    }

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/thumbd.lock").path

    /// Kept open (and locked) until the process exits.
    private static var heldDescriptor: Int32 = -1

    static func acquire() -> Result {
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        // If the lock file can't even be created, don't block startup over it.
        guard fd >= 0 else { return .acquired }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            var buffer = [UInt8](repeating: 0, count: 16)
            let count = pread(fd, &buffer, buffer.count, 0)
            close(fd)
            let text = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
            return .heldBy(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        ftruncate(fd, 0)
        let pid = Array("\(getpid())\n".utf8)
        _ = pwrite(fd, pid, pid.count, 0)
        heldDescriptor = fd
        return .acquired
    }
}
