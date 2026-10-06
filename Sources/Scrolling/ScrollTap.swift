import CoreGraphics
import Foundation

/// Scales mouse-wheel scrolling system-wide with an event tap.
///
/// Only line-based ("non-continuous") scroll events are touched. Those come from mouse
/// wheels; trackpads and the Magic Mouse send continuous ones, which pass through unchanged.
/// macOS doesn't say which mouse a scroll event came from, so this applies to every wheel
/// mouse, not only the MX Master. Modifying events needs the Accessibility permission.
///
/// The tap lives in this process: if thumbd stops, scrolling simply goes back to normal.
public final class ScrollTap {
    private let verticalFactor: Double
    private let horizontalFactor: Double
    private var verticalLines: ScrollScaler
    private var verticalPoints: ScrollScaler
    private var horizontalLines: ScrollScaler
    private var horizontalPoints: ScrollScaler
    private var port: CFMachPort?

    /// `nil` if macOS refuses the tap (usually: no Accessibility permission).
    public init?(vertical: Double, horizontal: Double) {
        verticalFactor = vertical
        horizontalFactor = horizontal
        verticalLines = ScrollScaler(factor: vertical)
        verticalPoints = ScrollScaler(factor: vertical)
        horizontalLines = ScrollScaler(factor: horizontal)
        horizontalPoints = ScrollScaler(factor: horizontal)

        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<ScrollTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port

        // Its own thread and run loop, so scrolling never waits on HID++ requests.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            while true {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 3600, false)
            }
        }
        thread.name = "thumbd.scroll"
        thread.start()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            // macOS disables a tap that answers too slowly; turn it back on.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .scrollWheel where event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0:
            scale(event, factor: verticalFactor, lines: .scrollWheelEventDeltaAxis1,
                  points: .scrollWheelEventPointDeltaAxis1, fixed: .scrollWheelEventFixedPtDeltaAxis1,
                  lineScaler: &verticalLines, pointScaler: &verticalPoints)
            scale(event, factor: horizontalFactor, lines: .scrollWheelEventDeltaAxis2,
                  points: .scrollWheelEventPointDeltaAxis2, fixed: .scrollWheelEventFixedPtDeltaAxis2,
                  lineScaler: &horizontalLines, pointScaler: &horizontalPoints)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Apps read different fields (whole lines, pixels or fixed-point lines), so all three
    /// are scaled together.
    private func scale(_ event: CGEvent, factor: Double, lines: CGEventField, points: CGEventField,
                       fixed: CGEventField, lineScaler: inout ScrollScaler, pointScaler: inout ScrollScaler) {
        guard factor != 1 else { return }
        event.setIntegerValueField(lines, value: lineScaler.scale(event.getIntegerValueField(lines)))
        event.setIntegerValueField(points, value: pointScaler.scale(event.getIntegerValueField(points)))
        event.setDoubleValueField(fixed, value: event.getDoubleValueField(fixed) * factor)
    }
}
