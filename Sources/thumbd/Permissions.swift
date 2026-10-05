import CoreGraphics
import Foundation
import IOKit.hid

/// TCC permissions thumbd needs:
///  - Input Monitoring (ListenEvent): open the mouse with IOHIDManager. Over BLE the
///    MX Master 3 exposes a keyboard collection, so macOS protects it as a keyboard.
///  - Accessibility (PostEvent): post synthetic keystrokes with CGEventPost.
///
/// They're granted to the "responsible process": if you start thumbd from a terminal, to the
/// terminal app; if launchd starts it, to the binary itself.
enum Permissions {
    enum Status: String {
        case granted
        case denied
        case unknown = "not decided"
    }

    static var inputMonitoring: Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static var postEvents: Status { CGPreflightPostEventAccess() ? .granted : .denied }

    @discardableResult
    static func requestPostEvents() -> Bool {
        CGRequestPostEventAccess()
    }

    static let inputMonitoringPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}
