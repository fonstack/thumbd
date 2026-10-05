import Foundation

/// ~/.config/thumbd/config.json
///
/// {
///   "tap": "ctrl+alt+cmd+f1",   shortcut for pressing and releasing the button without moving
///   "gestures": {               shortcuts for holding the button and moving (up/down/left/right);
///     "up": "ctrl+alt+cmd+f2"   empty = no gestures (the cursor doesn't freeze while held)
///   },
///   "threshold": 50,            movement (raw sensor units) needed to count as a gesture
///   "button": "0x00C3",         CID to divert (gesture button on the MX Master 3)
///   "buttons": {                other buttons: CID → shortcut on press (no gestures)
///     "0x00C4": "f12"
///   },
///   "devices": []               names (or part of them) as shown by `thumbd list`; empty = all compatible
/// }
public struct Config {
    public var tap: String
    public var gestures: [String: String]
    public var threshold: Int
    public var button: UInt16
    public var buttons: [UInt16: String]
    public var devices: [String]

    public static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/thumbd/config.json")

    public static let defaultJSON = """
    {
      "tap": "ctrl+alt+cmd+f1",
      "gestures": {
        "up": "ctrl+alt+cmd+f2",
        "down": "ctrl+alt+cmd+f3",
        "left": "ctrl+alt+cmd+f4",
        "right": "ctrl+alt+cmd+f5"
      },
      "threshold": 50,
      "button": "0x00C3",
      "buttons": {},
      "devices": []
    }

    """

    public func accepts(deviceName: String) -> Bool {
        devices.isEmpty || devices.contains { deviceName.localizedCaseInsensitiveContains($0) }
    }

    /// Loads the configuration; if the file doesn't exist it's created with the defaults.
    /// Also returns whether it was created, and any top-level keys thumbd doesn't know.
    public static func load(from url: URL = defaultPath) throws -> (config: Config, created: Bool, unknownKeys: [String]) {
        var created = false
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try defaultJSON.write(to: url, atomically: true, encoding: .utf8)
            created = true
        }
        let data = try Data(contentsOf: url)
        return (try JSONDecoder().decode(Config.self, from: data), created, unknownKeys(in: data))
    }

    /// Top-level keys thumbd doesn't know. Usually typos ("gesture" for "gestures"), which
    /// the decoder would otherwise ignore without a word.
    public static func unknownKeys(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let known = Set(Keys.allCases.map(\.rawValue))
        return object.keys.filter { !known.contains($0) }.sorted()
    }
}

/// A readable description of an error thrown by `Config.load` (instead of Swift's verbose
/// `DecodingError` dump).
public func describeConfigError(_ error: Error) -> String {
    switch error {
    case DecodingError.dataCorrupted(let context):
        if let underlying = context.underlyingError as NSError?,
           let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
            return "invalid JSON: \(detail)"
        }
        return "invalid JSON: \(context.debugDescription)"
    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return "\"\(path)\": \(context.debugDescription)"
    default:
        return "\(error)"
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case invalidButton(String)

    public var description: String {
        switch self {
        case .invalidButton(let v): return "invalid button CID: \(v) (use e.g. \"0x00C3\" or 195)"
        }
    }
}

extension Config: Decodable {
    enum Keys: String, CodingKey, CaseIterable { case tap, gestures, threshold, button, buttons, devices }

    /// "0x00C4" (hex) or "196" (decimal).
    static func parseCID(_ text: String) -> UInt16? {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.hasPrefix("0x") ? UInt16(lower.dropFirst(2), radix: 16) : UInt16(lower)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        tap = try c.decodeIfPresent(String.self, forKey: .tap) ?? "ctrl+alt+cmd+f1"
        gestures = try c.decodeIfPresent([String: String].self, forKey: .gestures) ?? [:]
        threshold = try c.decodeIfPresent(Int.self, forKey: .threshold) ?? 50
        devices = try c.decodeIfPresent([String].self, forKey: .devices) ?? []
        if let number = try? c.decode(Int.self, forKey: .button) {
            guard let cid = UInt16(exactly: number) else { throw ConfigError.invalidButton("\(number)") }
            button = cid
        } else if let text = try c.decodeIfPresent(String.self, forKey: .button) {
            guard let cid = Self.parseCID(text) else { throw ConfigError.invalidButton(text) }
            button = cid
        } else {
            button = 0x00C3
        }
        buttons = [:]
        for (key, shortcut) in try c.decodeIfPresent([String: String].self, forKey: .buttons) ?? [:] {
            guard let cid = Self.parseCID(key) else { throw ConfigError.invalidButton(key) }
            buttons[cid] = shortcut
        }
    }
}
