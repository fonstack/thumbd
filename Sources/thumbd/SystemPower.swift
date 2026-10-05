import Foundation
import IOKit
import IOKit.pwr_mgt

/// Calls `onWake` after the Mac wakes from sleep.
///
/// Registering for power notifications obliges us to answer the "can I sleep?" and "going
/// to sleep" messages: an unanswered one delays system sleep by 30 s. Both are always
/// allowed straight away, on a private queue so a busy daemon can't hold sleep up.
final class SystemPower {
    private let onWake: () -> Void
    private let queue = DispatchQueue(label: "thumbd.power")
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?

    init?(onWake: @escaping () -> Void) {
        self.onWake = onWake
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, message, argument in
            guard let refcon else { return }
            Unmanaged<SystemPower>.fromOpaque(refcon).takeUnretainedValue().handle(message, argument)
        }, &notifier)
        guard rootPort != 0, let port else { return nil }
        IONotificationPortSetDispatchQueue(port, queue)
    }

    private func handle(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch message {
        case Self.canSystemSleep, Self.systemWillSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }

    // IOMessage.h defines these with the iokit_common_msg() macro, which Swift doesn't
    // import: iokit_common_msg(n) = 0xE0000000 | n.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300
}
