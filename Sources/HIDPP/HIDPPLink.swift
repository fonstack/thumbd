import Foundation
import Diagnostics
import HIDTransport

/// HID++ channel over one IOHIDDevice. A single link can serve several logical devices
/// (indexes 1–6 behind a receiver), so it serializes requests: only one is in flight at a
/// time.
///
/// `request` is synchronous and must NOT be called from the HID thread (that thread delivers
/// the response). Anything that isn't the response to the current request goes to
/// `onNotification`.
public final class HIDPPLink {
    public let hid: HIDDevice

    private let requestLock = NSLock()
    private let stateLock = NSLock()
    private var pending: Pending?
    private var closed = false
    private var notificationHandler: ((HIDPPReport) -> Void)?

    /// Called on the HID thread with device events (and late responses).
    public var onNotification: ((HIDPPReport) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return notificationHandler }
        set { stateLock.lock(); notificationHandler = newValue; stateLock.unlock() }
    }

    public init(hid: HIDDevice) {
        self.hid = hid
        hid.onInputReport = { [weak self] bytes in self?.received(bytes) }
    }

    public func close() {
        stateLock.lock()
        closed = true
        let inFlight = pending
        notificationHandler = nil
        stateLock.unlock()
        hid.onInputReport = nil
        inFlight?.finish(.failure(.disconnected))
    }

    /// Sends `report` and waits for its matching response (or error).
    /// A response matches the request when devIndex and bytes 2–3 are equal
    /// (featureIndex + function/softwareID in 2.0; subID + register in 1.0).
    public func request(_ report: [UInt8], timeout: TimeInterval = 2.0) throws -> HIDPPReport {
        requestLock.lock()
        defer { requestLock.unlock() }

        let waiter = Pending(deviceIndex: report[1], b2: report[2], b3: report[3])
        stateLock.lock()
        if closed { stateLock.unlock(); throw HIDPPError.disconnected }
        pending = waiter
        stateLock.unlock()
        defer {
            stateLock.lock()
            pending = nil
            stateLock.unlock()
        }

        let status = hid.send(report)
        guard status == kIOReturnSuccess else { throw HIDPPError.sendFailed(status) }
        guard waiter.semaphore.wait(timeout: .now() + timeout) == .success else { throw HIDPPError.timeout }

        let response = try waiter.result!.get()
        if response.isError20 { throw HIDPPError.hidpp20(response.bytes[5]) }
        if response.isError10 { throw HIDPPError.hidpp10(response.bytes[5]) }
        return response
    }

    private func received(_ bytes: [UInt8]) {
        guard let report = HIDPPReport(bytes) else { return }
        stateLock.lock()
        let waiter = pending
        let handler = notificationHandler
        stateLock.unlock()
        if let waiter, waiter.matches(report) {
            waiter.finish(.success(report))
        } else {
            handler?(report)
        }
    }
}

private final class Pending {
    let deviceIndex: UInt8
    let b2: UInt8
    let b3: UInt8
    let semaphore = DispatchSemaphore(value: 0)
    private(set) var result: Result<HIDPPReport, HIDPPError>?
    private var done = false
    private let lock = NSLock()

    init(deviceIndex: UInt8, b2: UInt8, b3: UInt8) {
        self.deviceIndex = deviceIndex
        self.b2 = b2
        self.b3 = b3
    }

    func matches(_ r: HIDPPReport) -> Bool {
        guard r.deviceIndex == deviceIndex else { return false }
        if r.bytes[2] == b2 && r.bytes[3] == b3 { return true }
        if (r.isError20 || r.isError10) && r.bytes[3] == b2 && r.bytes[4] == b3 { return true }
        return false
    }

    func finish(_ result: Result<HIDPPReport, HIDPPError>) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        self.result = result
        semaphore.signal()
    }
}
