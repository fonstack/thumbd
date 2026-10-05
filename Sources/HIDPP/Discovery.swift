import Foundation
import Diagnostics
import HIDTransport

/// Finds the HID++ 2.0 devices reachable through a link.
public enum Discovery {
    public struct Result {
        public let devices: [HIDPPDevice]
        public let isReceiver: Bool
    }

    /// 1. Tries the direct connection (index 0xFF) with ROOT.ping, with retries because a
    ///    freshly connected Bluetooth device can take a moment to answer.
    /// 2. If there's no direct HID++ 2.0 device and the transport is USB, treats it as a
    ///    Unifying/Bolt receiver and pings indexes 1–6.
    public static func discover(on link: HIDPPLink, attempts: Int = 3) -> Result {
        let direct = HIDPPDevice(link: link, index: HIDPPDevice.directIndex)
        for attempt in 1...attempts {
            do {
                let version = try direct.protocolVersion()
                Log.debug("\(link.hid.tag) index 0xFF answers HID++ \(version.major).\(version.minor)")
                if version.major >= 2 { return Result(devices: [direct], isReceiver: false) }
                break
            } catch HIDPPError.hidpp10(let code) {
                // It answers, but as HID++ 1.0 (typical of a receiver).
                Log.debug("\(link.hid.tag) index 0xFF: HID++ 1.0 (error \(hex8(code)))")
                break
            } catch {
                Log.debug("\(link.hid.tag) ping 0xFF attempt \(attempt): \(error)")
                if attempt < attempts { Thread.sleep(forTimeInterval: 0.5) }
            }
        }

        guard link.hid.isUSB else { return Result(devices: [], isReceiver: false) }

        var found: [HIDPPDevice] = []
        for index in UInt8(1)...6 {
            let device = HIDPPDevice(link: link, index: index)
            device.timeout = 1.0
            do {
                let version = try device.protocolVersion()
                Log.debug("\(link.hid.tag) index \(index) answers HID++ \(version.major).\(version.minor)")
                if version.major >= 2 {
                    device.timeout = 2.0
                    found.append(device)
                }
            } catch {
                Log.debug("\(link.hid.tag) index \(index): \(error)")
            }
        }
        return Result(devices: found, isReceiver: true)
    }
}

/// HID++ 1.0 registers of the Unifying/Bolt receiver.
/// NOTE: this path follows Solaar but hasn't been tested with real hardware.
public enum Receiver {
    /// Sets the "wireless notifications" flag (0x000100) in register 0x00 so the receiver
    /// sends 0x41 notifications when a paired device connects or disconnects.
    /// Read-modify-write so the other flags stay untouched (e.g. "software present", which
    /// changes how some keyboards report).
    public static func enableConnectionNotifications(on link: HIDPPLink) throws {
        let current = try link.request(HIDPPReport.short(deviceIndex: 0xFF, subID: 0x81, address: 0x00))
        var flags = Array(current.params.prefix(3))
        guard flags[1] & 0x01 == 0 else { return }
        flags[1] |= 0x01
        _ = try link.request(HIDPPReport.short(deviceIndex: 0xFF, subID: 0x80, address: 0x00, params: flags))
    }

    public struct ConnectionEvent {
        public let index: UInt8
        public let linkEstablished: Bool
    }

    /// 0x41 notification: [0x10][idx][0x41][protocol][flags…]; flags bit 6 = link NOT established.
    public static func connectionEvent(from report: HIDPPReport) -> ConnectionEvent? {
        guard report.reportID == HIDPPReport.shortID, report.featureIndex == 0x41,
              (1...6).contains(report.deviceIndex) else { return nil }
        return ConnectionEvent(index: report.deviceIndex, linkEstablished: report.bytes[4] & 0x40 == 0)
    }
}
