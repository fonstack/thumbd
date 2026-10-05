import Foundation

/// Minimal thread-safe logging to stdout with timestamps.
/// With `debugEnabled` it also dumps every HID++ report sent/received as hex.
public enum Log {
    public static var debugEnabled = false

    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ message: @autoclosure () -> String) { emit(" ", message()) }
    public static func warn(_ message: @autoclosure () -> String) { emit("!", message()) }
    public static func error(_ message: @autoclosure () -> String) { emit("✗", message()) }

    public static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        emit("·", message())
    }

    /// `direction` is "→" (host → device) or "←" (device → host).
    public static func hex(_ direction: String, _ bytes: [UInt8], tag: String) {
        guard debugEnabled else { return }
        emit(direction, "\(tag) \(bytes.hexString)")
    }

    /// When stdout is a regular file (the LaunchAgent log), empties it at startup if it has
    /// grown past `maxBytes`. Normal operation only logs connections, diversions and
    /// errors, so this is a safety net rather than routine rotation.
    public static func trimLogFileIfNeeded(maxBytes: Int64 = 5_000_000) {
        var out = stat()
        guard fstat(STDOUT_FILENO, &out) == 0, (out.st_mode & S_IFMT) == S_IFREG,
              Int64(out.st_size) > maxBytes else { return }
        ftruncate(STDOUT_FILENO, 0)
        // Without O_APPEND the file offsets would stay at the old end and leave a hole.
        lseek(STDOUT_FILENO, 0, SEEK_SET)
        var err = stat()
        if fstat(STDERR_FILENO, &err) == 0, err.st_dev == out.st_dev, err.st_ino == out.st_ino {
            lseek(STDERR_FILENO, 0, SEEK_SET)
        }
        info("Log truncated (it had grown to \(Int64(out.st_size) / 1_000_000) MB)")
    }

    private static func emit(_ marker: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        fputs("\(formatter.string(from: Date())) \(marker) \(message)\n", stdout)
        fflush(stdout)
    }
}

public extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

public func hex16(_ value: UInt16) -> String { String(format: "0x%04X", value) }
public func hex8(_ value: UInt8) -> String { String(format: "0x%02X", value) }
