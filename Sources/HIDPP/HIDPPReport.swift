import Foundation
import Diagnostics
import HIDTransport

/// A raw HID++ report.
///
/// HID++ 2.0:  [reportID][devIndex][featureIndex][(function << 4) | softwareID][params…]
/// HID++ 1.0:  [reportID][devIndex][subID][address][params…]   (receiver registers)
public struct HIDPPReport: CustomStringConvertible {
    public static let shortID: UInt8 = 0x10      // 7 bytes
    public static let longID: UInt8 = 0x11       // 20 bytes
    public static let veryLongID: UInt8 = 0x12   // 64 bytes
    public static let reportIDs: Set<UInt8> = [shortID, longID, veryLongID]

    public static let shortLength = 7
    public static let longLength = 20

    public let bytes: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= 5, Self.reportIDs.contains(bytes[0]) else { return nil }
        self.bytes = bytes
    }

    public var reportID: UInt8 { bytes[0] }
    public var deviceIndex: UInt8 { bytes[1] }
    /// Feature index (2.0) or sub-ID (1.0).
    public var featureIndex: UInt8 { bytes[2] }
    public var function: UInt8 { bytes[3] >> 4 }
    /// 0 for spontaneous device events; our ID in responses.
    public var softwareID: UInt8 { bytes[3] & 0x0F }
    public var params: [UInt8] { Array(bytes.dropFirst(4)) }

    /// HID++ 2.0 error: [id][dev][0xFF][featIdx][func|sw][code]
    public var isError20: Bool { featureIndex == 0xFF }
    /// HID++ 1.0 error: [id][dev][0x8F][subID][address][code]
    public var isError10: Bool { featureIndex == 0x8F }

    public var description: String { bytes.hexString }

    public static func long(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8,
                            softwareID: UInt8, params: [UInt8] = []) -> [UInt8] {
        precondition(function < 16 && softwareID < 16 && params.count <= longLength - 4)
        var report = [longID, deviceIndex, featureIndex, (function << 4) | softwareID] + params
        report += [UInt8](repeating: 0, count: longLength - report.count)
        return report
    }

    public static func short(deviceIndex: UInt8, subID: UInt8, address: UInt8, params: [UInt8] = []) -> [UInt8] {
        precondition(params.count <= shortLength - 4)
        var report = [shortID, deviceIndex, subID, address] + params
        report += [UInt8](repeating: 0, count: shortLength - report.count)
        return report
    }
}

public enum HIDPPError: Error, CustomStringConvertible {
    case sendFailed(IOReturn)
    case timeout
    case disconnected
    case hidpp20(UInt8)
    case hidpp10(UInt8)
    case featureNotSupported(UInt16)
    case badResponse(String)

    public var description: String {
        switch self {
        case .sendFailed(let code): return "send failed: \(describeIOReturn(code))"
        case .timeout: return "no response (timeout)"
        case .disconnected: return "device disconnected"
        case .hidpp20(let code): return "HID++ 2.0 error \(hex8(code)) \(Self.names20[code] ?? "")"
        case .hidpp10(let code): return "HID++ 1.0 error \(hex8(code)) \(Self.names10[code] ?? "")"
        case .featureNotSupported(let id): return "feature \(hex16(id)) not supported"
        case .badResponse(let why): return "unexpected response: \(why)"
        }
    }

    static let names20: [UInt8: String] = [
        0x01: "Unknown", 0x02: "InvalidArgument", 0x03: "OutOfRange", 0x04: "HWError",
        0x05: "LogitechInternal", 0x06: "InvalidFeatureIndex", 0x07: "InvalidFunctionID",
        0x08: "Busy", 0x09: "Unsupported",
    ]
    static let names10: [UInt8: String] = [
        0x01: "InvalidSubID", 0x02: "InvalidAddress", 0x03: "InvalidValue", 0x04: "ConnectFail",
        0x05: "TooManyDevices", 0x06: "AlreadyExists", 0x07: "Busy", 0x08: "UnknownDevice",
        0x09: "ResourceError", 0x0A: "RequestUnavailable", 0x0B: "InvalidParamValue", 0x0C: "WrongPinCode",
    ]
}
