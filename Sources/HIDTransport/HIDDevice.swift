import Foundation
import IOKit
import IOKit.hid
import Diagnostics

public struct UsagePair: Hashable, CustomStringConvertible {
    public let page: Int
    public let usage: Int
    public var description: String { String(format: "0x%04X/0x%04X", page, usage) }
}

/// Wrapper around an IOHIDDevice opened by `HIDManager`.
public final class HIDDevice: CustomStringConvertible {
    public let ref: IOHIDDevice
    /// Stable IORegistry ID; used as a key for as long as the device exists.
    public let registryID: UInt64
    public let vendorID: Int
    public let productID: Int
    public let product: String
    public let transport: String
    public let serialNumber: String
    public let usagePairs: [UsagePair]
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int

    private let handlerLock = NSLock()
    private var inputHandler: (([UInt8]) -> Void)?

    /// Called on the HID thread for every accepted input report (first byte = report ID).
    public var onInputReport: (([UInt8]) -> Void)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return inputHandler }
        set { handlerLock.lock(); inputHandler = newValue; handlerLock.unlock() }
    }

    init(ref: IOHIDDevice) {
        self.ref = ref
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(ref), &entryID)
        registryID = entryID
        vendorID = Self.property(ref, kIOHIDVendorIDKey) ?? 0
        productID = Self.property(ref, kIOHIDProductIDKey) ?? 0
        product = Self.property(ref, kIOHIDProductKey) ?? "?"
        transport = Self.property(ref, kIOHIDTransportKey) ?? "?"
        serialNumber = Self.property(ref, kIOHIDSerialNumberKey) ?? ""
        maxInputReportSize = Self.property(ref, kIOHIDMaxInputReportSizeKey) ?? 0
        maxOutputReportSize = Self.property(ref, kIOHIDMaxOutputReportSizeKey) ?? 0
        let pairs: [[String: Any]] = Self.property(ref, kIOHIDDeviceUsagePairsKey) ?? []
        usagePairs = pairs.compactMap { pair in
            guard let page = pair[kIOHIDDeviceUsagePageKey] as? Int else { return nil }
            return UsagePair(page: page, usage: pair[kIOHIDDeviceUsageKey] as? Int ?? 0)
        }
    }

    public var isUSB: Bool { transport == "USB" }
    public var isBluetooth: Bool { transport.localizedCaseInsensitiveContains("bluetooth") }

    /// Short tag for log lines: the PID in hex.
    public var tag: String { String(format: "[%04X]", productID) }

    public var description: String {
        String(format: "%@ (VID 0x%04X, PID 0x%04X, %@)", product, vendorID, productID, transport)
    }

    /// Sends an output report. `report[0]` must be the report ID and is included in the data,
    /// the same way hidapi does it on macOS for numbered reports.
    public func send(_ report: [UInt8]) -> IOReturn {
        guard let reportID = report.first, reportID != 0 else { return kIOReturnBadArgument }
        Log.hex("→", report, tag: tag)
        return report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(ref, kIOHIDReportTypeOutput, CFIndex(reportID), buffer.baseAddress!, buffer.count)
        }
    }

    func deliver(_ report: [UInt8]) {
        Log.hex("←", report, tag: tag)
        onInputReport?(report)
    }

    private static func property<T>(_ ref: IOHIDDevice, _ key: String) -> T? {
        IOHIDDeviceGetProperty(ref, key as CFString) as? T
    }
}

public func describeIOReturn(_ code: IOReturn) -> String {
    let hex = String(format: "0x%08X", UInt32(bitPattern: code))
    switch code {
    case kIOReturnSuccess: return "OK"
    case kIOReturnNotPermitted: return "\(hex) (not permitted: Input Monitoring permission missing)"
    case kIOReturnNotPrivileged: return "\(hex) (not privileged)"
    case kIOReturnExclusiveAccess: return "\(hex) (another process has exclusive access)"
    case kIOReturnNoDevice: return "\(hex) (device disconnected)"
    case kIOReturnNotOpen: return "\(hex) (device not open)"
    default: return hex
    }
}
