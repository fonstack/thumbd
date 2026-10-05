import Actions
import Config
import Diagnostics
import Gestures

/// The shortcuts from the config, parsed and validated. Shared by `run` and `check-config`.
struct Bindings {
    enum Problem: Error, CustomStringConvertible {
        case unknownDirection(String)
        case badShortcut(String, Error)
        case duplicateButton(UInt16)
        case badThreshold(Int)

        var description: String {
            switch self {
            case .unknownDirection(let d): return "unknown gesture \"\(d)\" (use up, down, left, right)"
            case .badShortcut(let key, let error): return "\"\(key)\": \(error)"
            case .duplicateButton(let cid): return "\(hex16(cid)) is in both \"button\" and \"buttons\""
            case .badThreshold(let value): return "\"threshold\" must be greater than 0 (got \(value))"
            }
        }
    }

    let tap: KeyShortcut
    let swipes: [GestureButton.Direction: KeyShortcut]
    let extras: [UInt16: KeyShortcut]

    init(config: Config) throws {
        do {
            tap = try KeyShortcut(config.tap)
        } catch {
            throw Problem.badShortcut("tap", error)
        }
        var swipes: [GestureButton.Direction: KeyShortcut] = [:]
        for (name, text) in config.gestures {
            guard let direction = GestureButton.Direction(rawValue: name.lowercased()) else {
                throw Problem.unknownDirection(name)
            }
            do {
                swipes[direction] = try KeyShortcut(text)
            } catch {
                throw Problem.badShortcut("gestures.\(name)", error)
            }
        }
        self.swipes = swipes
        var extras: [UInt16: KeyShortcut] = [:]
        for (cid, text) in config.buttons {
            guard cid != config.button else { throw Problem.duplicateButton(cid) }
            do {
                extras[cid] = try KeyShortcut(text)
            } catch {
                throw Problem.badShortcut("buttons.\(hex16(cid))", error)
            }
        }
        self.extras = extras
        guard config.threshold > 0 else { throw Problem.badThreshold(config.threshold) }
    }

    var summary: String {
        let gestures = GestureButton.Direction.allCases.compactMap { d in swipes[d].map { "\(d.arrow) \($0)" } }
        let buttons = extras.keys.sorted().map { "\(hex16($0)) \(extras[$0]!)" }
        return (["tap \(tap)"] + gestures + buttons).joined(separator: ", ")
    }
}
