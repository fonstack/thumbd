import Diagnostics
import Foundation
import HIDPP
import HIDTransport

/// `thumbd list`: Logitech devices with an HID++ collection, their features and controls.
/// Only sends queries (get*); it doesn't change anything on the mouse.
enum ListCommand {
    static func run() -> Int32 {
        let hid = HIDManager(vendorID: 0x046D, usagePages: [0xFF00, 0xFF43],
                             acceptedReportIDs: HIDPPReport.reportIDs)
        let status = hid.start()
        // Let the HID run loop deliver the matching callbacks.
        Thread.sleep(forTimeInterval: 1.0)
        let devices = hid.devices

        if status != kIOReturnSuccess {
            print("IOHIDManagerOpen: \(describeIOReturn(status))\n")
        }
        guard !devices.isEmpty else {
            print("No Logitech device (VID 0x046D) with an HID++ collection (0xFF00/0xFF43) found.")
            print("Is it on and connected? Does your terminal have the Input Monitoring permission?")
            return 1
        }

        for (n, hidDevice) in devices.enumerated() {
            print("[\(n + 1)] \(hidDevice.product)")
            print(String(format: "    VID 0x%04X  PID 0x%04X  transport: %@  reports: in %d / out %d bytes",
                         hidDevice.vendorID, hidDevice.productID, hidDevice.transport,
                         hidDevice.maxInputReportSize, hidDevice.maxOutputReportSize))
            print("    collections (page/usage): \(hidDevice.usagePairs.map(\.description).joined(separator: " "))")

            let link = HIDPPLink(hid: hidDevice)
            let found = Discovery.discover(on: link)
            if found.isReceiver {
                print("    receiver: \(found.devices.count) HID++ 2.0 device(s) online")
            } else if found.devices.isEmpty {
                print("    doesn't answer as an HID++ 2.0 device")
            }
            for device in found.devices {
                describe(device)
            }
            link.close()
            print()
        }
        return 0
    }

    private static func describe(_ device: HIDPPDevice) {
        let indent = "    "
        do {
            let version = try device.protocolVersion()
            let name = (try? device.name()) ?? "?"
            print("\(indent)── index \(hex8(device.index)): \"\(name)\"  HID++ \(version.major).\(version.minor)")

            let features = try device.features()
            print("\(indent)   features (\(features.count)):")
            for f in features {
                let extra = f.typeFlags.isEmpty ? "" : "  [\(f.typeFlags.joined(separator: ","))]"
                print("\(indent)     \(hex8(f.index))  \(hex16(f.id))  \(pad(f.name, 24)) v\(f.version)\(extra)")
            }

            guard let reprog = try ReprogControls(device: device) else {
                print("\(indent)   (no REPROG_CONTROLS_V4)")
                return
            }
            let controls = try reprog.controls()
            print("\(indent)   REPROG_CONTROLS_V4 controls (index \(hex8(reprog.featureIndex)), \(controls.count)):")
            print("\(indent)     \(pad("CID", 7)) \(pad("TID", 7)) \(pad("name", 22)) \(pad("flags", 44)) state")
            for c in controls {
                var state = "—"
                if c.isDivertable {
                    state = (try? reprog.reporting(for: c.cid).description) ?? "?"
                }
                print("\(indent)     \(pad(hex16(c.cid), 7)) \(pad(hex16(c.taskID), 7)) \(pad(c.name, 22)) "
                      + "\(pad(c.flagNames.joined(separator: " "), 44)) \(state)")
            }
        } catch {
            print("\(indent)── index \(hex8(device.index)): error: \(error)")
        }
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
