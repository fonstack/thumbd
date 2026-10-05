import Foundation
import IOKit.hid
import Diagnostics

/// Discovers HID devices by vendor ID + usage page and delivers their input reports.
///
/// Runs its own run loop on a dedicated thread ("thumbd.hid"): connect/disconnect and
/// report callbacks arrive on that thread. That lets other threads make synchronous HID++
/// requests (waiting for the response) without blocking delivery.
public final class HIDManager {
    public var onDeviceAdded: ((HIDDevice) -> Void)?
    public var onDeviceRemoved: ((HIDDevice) -> Void)?

    private let manager: IOHIDManager
    private let acceptedReportIDs: Set<UInt8>
    private let lock = NSLock()
    private var byRef: [ObjectIdentifier: HIDDevice] = [:]
    private var thread: Thread?

    /// - Parameters:
    ///   - usagePages: matched against *any* collection of the device (DeviceUsagePairs),
    ///     not only the primary one.
    ///   - acceptedReportIDs: only these input reports are delivered; the rest (e.g. normal
    ///     mouse movement) are dropped without being copied.
    public init(vendorID: Int, usagePages: [Int], acceptedReportIDs: Set<UInt8>) {
        self.acceptedReportIDs = acceptedReportIDs
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = usagePages.map { page -> [String: Int] in
            [kIOHIDVendorIDKey: vendorID, kIOHIDDeviceUsagePageKey: page]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDManager>.fromOpaque(context).takeUnretainedValue().matched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDManager>.fromOpaque(context).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, reportID, report, length in
            guard let context, let sender else { return }
            let manager = Unmanaged<HIDManager>.fromOpaque(context).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            manager.received(from: device, reportID: UInt8(truncatingIfNeeded: reportID), report: report, length: length)
        }, context)
    }

    /// Starts the HID thread, opens the manager (non-exclusive: the mouse keeps working
    /// normally) and returns the result of IOHIDManagerOpen.
    @discardableResult
    public func start() -> IOReturn {
        let ready = DispatchSemaphore(value: 0)
        var result = kIOReturnSuccess
        let thread = Thread { [manager] in
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            ready.signal()
            while true {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 3600, false)
            }
        }
        thread.name = "thumbd.hid"
        thread.start()
        self.thread = thread
        ready.wait()
        return result
    }

    /// Currently matched devices, in a stable order.
    public var devices: [HIDDevice] {
        lock.lock()
        defer { lock.unlock() }
        return byRef.values.sorted { $0.registryID < $1.registryID }
    }

    private func matched(_ ref: IOHIDDevice) {
        let device = HIDDevice(ref: ref)
        lock.lock()
        byRef[ObjectIdentifier(ref)] = device
        lock.unlock()
        Log.debug("HID matched: \(device) collections \(device.usagePairs)")
        onDeviceAdded?(device)
    }

    private func removed(_ ref: IOHIDDevice) {
        lock.lock()
        let device = byRef.removeValue(forKey: ObjectIdentifier(ref))
        lock.unlock()
        guard let device else { return }
        device.onInputReport = nil
        onDeviceRemoved?(device)
    }

    private func received(from ref: IOHIDDevice, reportID: UInt8, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard acceptedReportIDs.contains(reportID), length > 0 else { return }
        lock.lock()
        let device = byRef[ObjectIdentifier(ref)]
        lock.unlock()
        guard let device else { return }
        var bytes = Array(UnsafeBufferPointer(start: report, count: length))
        // IOKit includes the report ID as the first byte of numbered reports; normalize just
        // in case some transport doesn't.
        if bytes.first != reportID { bytes.insert(reportID, at: 0) }
        device.deliver(bytes)
    }
}
