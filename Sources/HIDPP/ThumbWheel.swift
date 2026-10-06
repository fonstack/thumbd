import Foundation
import Diagnostics

/// Feature THUMB_WHEEL (0x2150): the horizontal wheel under the thumb.
///   fn 0 getThumbwheelInfo · fn 1 getThumbwheelStatus · fn 2 setThumbwheelReporting
/// getThumbwheelStatus starts with the same two bytes that setThumbwheelReporting takes:
/// [divert, invertDirection] (as in Solaar's thumb-scroll-mode / thumb-scroll-invert).
/// Like button diversion, the setting is lost when the mouse resets.
public final class ThumbWheel {
    public struct Status: CustomStringConvertible {
        public let diverted: Bool
        public let inverted: Bool
        public var description: String { "divert=\(diverted ? 1 : 0) invert=\(inverted ? 1 : 0)" }
    }

    public let device: HIDPPDevice
    public let featureIndex: UInt8

    /// `nil` if the device has no thumb wheel.
    public init?(device: HIDPPDevice) throws {
        guard let index = try device.featureIndex(of: Feature.thumbWheel) else { return nil }
        self.device = device
        self.featureIndex = index
    }

    public func status() throws -> Status {
        let p = try device.request(featureIndex: featureIndex, function: 0x1)
        return Status(diverted: p[0] & 0x01 != 0, inverted: p[1] & 0x01 != 0)
    }

    /// Sets the scroll direction and leaves the diversion as it is.
    public func setInverted(_ inverted: Bool) throws {
        let current = try status()
        _ = try device.request(featureIndex: featureIndex, function: 0x2,
                               params: [current.diverted ? 0x01 : 0x00, inverted ? 0x01 : 0x00])
    }
}
