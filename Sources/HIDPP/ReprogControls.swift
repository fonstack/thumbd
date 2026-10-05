import Foundation
import Diagnostics

/// Static information about a control (getCidInfo).
public struct ControlInfo {
    public let index: Int
    public let cid: UInt16
    public let taskID: UInt16
    /// flags (byte 4) | additionalFlags (byte 8) << 8
    public let flags: UInt16
    public let position: UInt8
    public let group: UInt8
    public let groupMask: UInt8

    public var isDivertable: Bool { flags & 0x0020 != 0 }
    public var supportsRawXY: Bool { flags & 0x0100 != 0 }
    public var name: String { ReprogControls.controlNames[cid] ?? "" }

    public var flagNames: [String] {
        let names: [(UInt16, String)] = [
            (0x0001, "mouse"), (0x0002, "fn"), (0x0004, "nonstd"), (0x0008, "fnSens"),
            (0x0010, "reprog"), (0x0020, "divert"), (0x0040, "persistDivert"), (0x0080, "virtual"),
            (0x0100, "rawXY"), (0x0200, "forceRawXY"), (0x0400, "analytics"),
        ]
        return names.filter { flags & $0.0 != 0 }.map(\.1)
    }
}

/// Current reporting state of a control (getCidReporting).
public struct ControlReporting: CustomStringConvertible {
    public let cid: UInt16
    public let flags: UInt8
    public let remap: UInt16

    public var isDiverted: Bool { flags & 0x01 != 0 }
    public var isPersistentlyDiverted: Bool { flags & 0x04 != 0 }
    public var isRawXYDiverted: Bool { flags & 0x10 != 0 }

    public var description: String {
        var s = "divert=\(isDiverted ? 1 : 0) rawXY=\(isRawXYDiverted ? 1 : 0)"
        if isPersistentlyDiverted { s += " persist=1" }
        if remap != 0 && remap != cid { s += " remap=\(hex16(remap))" }
        return s
    }
}

/// Feature REPROG_CONTROLS_V4 (0x1B04).
///   fn 0 getCount · fn 1 getCidInfo · fn 2 getCidReporting · fn 3 setCidReporting
/// Events (softwareID 0):
///   fn 0 divertedButtonsEvent: up to 4 pressed CIDs (BE); empty list = all released
///   fn 1 divertedRawXYEvent:   dx, dy as BE int16
public final class ReprogControls {
    public static let gestureButton: UInt16 = 0x00C3

    public let device: HIDPPDevice
    public let featureIndex: UInt8

    /// `nil` if the device doesn't have the feature.
    public init?(device: HIDPPDevice) throws {
        guard let index = try device.featureIndex(of: Feature.reprogControlsV4) else { return nil }
        self.device = device
        self.featureIndex = index
    }

    public func count() throws -> Int {
        Int(try device.request(featureIndex: featureIndex, function: 0x0)[0])
    }

    public func controlInfo(at index: Int) throws -> ControlInfo {
        let p = try device.request(featureIndex: featureIndex, function: 0x1, params: [UInt8(index)])
        return ControlInfo(index: index, cid: Self.be16(p, 0), taskID: Self.be16(p, 2),
                           flags: UInt16(p[8]) << 8 | UInt16(p[4]),
                           position: p[5], group: p[6], groupMask: p[7])
    }

    public func controls() throws -> [ControlInfo] {
        try (0..<count()).map(controlInfo(at:))
    }

    public func reporting(for cid: UInt16) throws -> ControlReporting {
        let p = try device.request(featureIndex: featureIndex, function: 0x2, params: Self.be(cid))
        return ControlReporting(cid: Self.be16(p, 0), flags: p[2], remap: Self.be16(p, 3))
    }

    /// setCidReporting: CID(2) + flags(1) + remap(2).
    /// Each flag comes with its "valid" bit; `nil` leaves that aspect unchanged.
    ///   bit0 divert · bit1 divert valid · bit4 rawXY · bit5 rawXY valid
    /// (plain divert = 0x03, divert + rawXY = 0x33, undo both = 0x22). remap 0 = no remapping.
    public func setReporting(for cid: UInt16, divert: Bool?, rawXY: Bool? = nil) throws {
        var flags: UInt8 = 0
        if let divert { flags |= 0x02 | (divert ? 0x01 : 0) }
        if let rawXY { flags |= 0x20 | (rawXY ? 0x10 : 0) }
        _ = try device.request(featureIndex: featureIndex, function: 0x3, params: Self.be(cid) + [flags, 0x00, 0x00])
    }

    public enum Event {
        case divertedButtons([UInt16])
        case rawXY(dx: Int16, dy: Int16)
    }

    /// Parses a report as an event of this feature (or `nil` if it isn't one).
    public func event(from report: HIDPPReport) -> Event? {
        guard report.featureIndex == featureIndex, report.softwareID == 0,
              report.deviceIndex == device.index else { return nil }
        let p = report.params
        switch report.function {
        case 0x0:
            let cids: [UInt16] = stride(from: 0, to: min(8, p.count - 1), by: 2).map { Self.be16(p, $0) }
            return .divertedButtons(cids.filter { $0 != 0 })
        case 0x1:
            return .rawXY(dx: Int16(bitPattern: Self.be16(p, 0)), dy: Int16(bitPattern: Self.be16(p, 2)))
        default:
            return nil
        }
    }

    private static func be(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    private static func be16(_ p: [UInt8], _ i: Int) -> UInt16 { UInt16(p[i]) << 8 | UInt16(p[i + 1]) }

    /// Names of the common CIDs on MX mice (Solaar's CONTROL table).
    public static let controlNames: [UInt16: String] = [
        0x0050: "Left Button",
        0x0051: "Right Button",
        0x0052: "Middle Button",
        0x0053: "Back Button",
        0x0056: "Forward Button",
        0x00C3: "Mouse Gesture Button",
        0x00C4: "Smart Shift",
    ]
}
