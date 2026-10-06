import Actions
import Config
import Diagnostics
import Foundation
import Gestures
import HIDPP
import HIDTransport
import Scrolling

/// Ties the layers together: discovers devices, diverts the buttons every time one appears
/// and turns their events into keyboard shortcuts.
///
/// Diversion is re-applied on every signal we get (the IOHIDDevice appearing, the receiver's
/// 0x41, WIRELESS_DEVICE_STATUS) and, as a safety net for the cases that send none, by a
/// periodic health check and right after the Mac wakes up.
///
/// Threads: HID callbacks arrive on "thumbd.hid"; all daemon state lives on the serial
/// `queue`, which is also where the synchronous HID++ requests are made.
final class Daemon {
    /// How often to check that the buttons are still diverted (one HID++ request per device)
    /// and to retry devices whose setup failed.
    private static let healthCheckInterval: TimeInterval = 60

    private struct Key: Hashable {
        let registryID: UInt64
        let index: UInt8
    }

    private final class Managed {
        let device: HIDPPDevice
        let name: String
        let reprog: ReprogControls
        let wirelessStatusIndex: UInt8?
        let button: GestureButton
        /// Whether the main button was diverted with rawXY (gestures configured and supported).
        let rawXY: Bool
        /// Extra buttons diverted on this device, and the ones currently pressed.
        let extraButtons: [UInt16]
        var pressedExtras: Set<UInt16> = []
        /// Set when the thumb wheel's direction was applied, so it can be restored on exit.
        let thumbWheel: ThumbWheel?

        init(device: HIDPPDevice, name: String, reprog: ReprogControls, wirelessStatusIndex: UInt8?,
             button: GestureButton, rawXY: Bool, extraButtons: [UInt16], thumbWheel: ThumbWheel?) {
            self.device = device
            self.name = name
            self.reprog = reprog
            self.wirelessStatusIndex = wirelessStatusIndex
            self.button = button
            self.rawXY = rawXY
            self.extraButtons = extraButtons
            self.thumbWheel = thumbWheel
        }
    }

    private final class LinkState {
        let link: HIDPPLink
        var isReceiver = false
        init(link: HIDPPLink) { self.link = link }
    }

    /// Result of trying to set up one device.
    private enum Outcome {
        case managed
        /// Not something thumbd can drive (no REPROG_CONTROLS_V4, no such button, filtered out…).
        case incompatible
        /// An error (timeout, device busy…): worth retrying later.
        case failed
    }

    private let config: Config
    private let bindings: Bindings
    private let hid = HIDManager(vendorID: 0x046D, usagePages: [0xFF00, 0xFF43],
                                 acceptedReportIDs: HIDPPReport.reportIDs)
    private let queue = DispatchQueue(label: "thumbd.work")
    private var links: [UInt64: LinkState] = [:]
    private var managed: [Key: Managed] = [:]
    /// Devices whose setup failed with an error; the health check retries them.
    private var retry: [Key: HIDPPDevice] = [:]
    private var signalSources: [DispatchSourceSignal] = []
    private var healthTimer: DispatchSourceTimer?
    private var power: SystemPower?
    private var scrollTap: ScrollTap?

    init(config: Config, bindings: Bindings) {
        self.config = config
        self.bindings = bindings
    }

    func run() -> Never {
        installSignalHandlers()
        hid.onDeviceAdded = { [weak self] device in self?.queue.async { self?.attach(device) } }
        hid.onDeviceRemoved = { [weak self] device in self?.queue.async { self?.detach(device) } }
        let status = hid.start()
        if status != kIOReturnSuccess {
            Log.warn("IOHIDManagerOpen: \(describeIOReturn(status))")
        }
        startHealthChecks()
        if config.scroll.changesSpeed {
            scrollTap = ScrollTap(vertical: config.scroll.verticalSpeed, horizontal: config.scroll.horizontalSpeed)
            if scrollTap == nil {
                Log.warn("couldn't create the scroll event tap (Accessibility permission?); wheel speed unchanged")
            }
        }
        Log.info("thumbd running: button \(hex16(config.button)): \(bindings.summary). Waiting for Logitech devices…")
        dispatchMain()
    }

    // MARK: Connect / disconnect

    private func attach(_ hidDevice: HIDDevice) {
        Log.info("HID connected: \(hidDevice)")
        let link = HIDPPLink(hid: hidDevice)
        let state = LinkState(link: link)
        let registryID = hidDevice.registryID
        links[registryID] = state
        link.onNotification = { [weak self] report in
            self?.queue.async { self?.handle(report, from: registryID) }
        }

        let found = Discovery.discover(on: link)
        state.isReceiver = found.isReceiver
        if found.isReceiver {
            Log.info("  it's a receiver; \(found.devices.count) HID++ 2.0 device(s) online")
            do {
                try Receiver.enableConnectionNotifications(on: link)
            } catch {
                Log.warn("  couldn't enable the receiver's connection notifications: \(error)")
            }
        } else if found.devices.isEmpty {
            // Matched by the HID++ usage page but not answering (yet), e.g. still waking up.
            Log.info("  no HID++ 2.0 answer yet; the health check will retry it")
            let direct = HIDPPDevice(link: link, index: HIDPPDevice.directIndex)
            retry[Key(registryID: registryID, index: direct.index)] = direct
        }
        for device in found.devices {
            configure(device)
        }
    }

    private func detach(_ hidDevice: HIDDevice) {
        guard let state = links.removeValue(forKey: hidDevice.registryID) else { return }
        state.link.close()
        for key in managed.keys where key.registryID == hidDevice.registryID {
            if let m = managed.removeValue(forKey: key) {
                Log.info("\(m.name): disconnected")
            }
        }
        for key in retry.keys where key.registryID == hidDevice.registryID {
            retry[key] = nil
        }
        Log.debug("HID disconnected: \(hidDevice)")
    }

    /// Checks that the device has the buttons and diverts them. Called on every connection,
    /// because diversion isn't persistent (it's lost when the mouse turns off or reconnects).
    /// A failure is remembered so the health check retries it.
    @discardableResult
    private func configure(_ device: HIDPPDevice) -> Outcome {
        let key = Key(registryID: device.link.hid.registryID, index: device.index)
        let outcome = setUp(device, key: key)
        retry[key] = outcome == .failed ? device : nil
        return outcome
    }

    private func setUp(_ device: HIDPPDevice, key: Key) -> Outcome {
        let cid = config.button
        do {
            var name = "device #\(hex8(device.index))"
            do {
                name = try device.name()
            } catch {
                // Without a name the "devices" filter can't be applied: retry later.
                if !config.devices.isEmpty { throw error }
            }
            guard config.accepts(deviceName: name) else {
                Log.info("  \(name): ignored (not in the config's \"devices\")")
                return .incompatible
            }
            guard let reprog = try ReprogControls(device: device) else {
                Log.info("  \(name): no REPROG_CONTROLS_V4 (0x1B04)")
                return .incompatible
            }
            let controls = try reprog.controls()
            guard let control = controls.first(where: { $0.cid == cid }) else {
                Log.info("  \(name): has no control \(hex16(cid)) (see `thumbd list`)")
                return .incompatible
            }
            guard control.isDivertable else {
                Log.warn("  \(name): control \(hex16(cid)) can't be diverted")
                return .incompatible
            }
            // rawXY: while the button is held, the mouse sends us its movement instead of
            // moving the cursor. Only requested when gestures are configured.
            var rawXY = !bindings.swipes.isEmpty
            if rawXY && !control.supportsRawXY {
                Log.warn("  \(name): control \(hex16(cid)) doesn't support rawXY; tap only")
                rawXY = false
            }
            try reprog.setReporting(for: cid, divert: true, rawXY: rawXY)
            let reporting = try reprog.reporting(for: cid)
            if !reporting.isDiverted {
                Log.warn("  \(name): the mouse accepted the request but reports \(reporting)")
            }
            var extraButtons: [UInt16] = []
            for extra in bindings.extras.keys.sorted() {
                guard let info = controls.first(where: { $0.cid == extra }), info.isDivertable else {
                    Log.warn("  \(name): control \(hex16(extra)) doesn't exist or can't be diverted")
                    continue
                }
                try reprog.setReporting(for: extra, divert: true)
                extraButtons.append(extra)
            }
            let thumbWheel = applyThumbWheelDirection(device, name: name)
            let wirelessStatus = try? device.featureIndex(of: Feature.wirelessDeviceStatus)
            managed[key] = Managed(device: device, name: name, reprog: reprog,
                                   wirelessStatusIndex: wirelessStatus,
                                   button: GestureButton(cid: cid, threshold: config.threshold),
                                   rawXY: rawXY, extraButtons: extraButtons, thumbWheel: thumbWheel)
            Log.info("✓ \(name): button \(hex16(cid)) diverted (\(reporting)): \(bindings.summary)")
            return .managed
        } catch {
            Log.error("  error configuring device #\(hex8(device.index)): \(error) (will retry)")
            return .failed
        }
    }

    /// Sets the thumb wheel's direction from the config. Applied even when it's `false`, so
    /// turning the option off takes effect without a mouse reset. A problem here only costs
    /// the direction setting, so it's logged and setup carries on.
    private func applyThumbWheelDirection(_ device: HIDPPDevice, name: String) -> ThumbWheel? {
        do {
            guard let wheel = try ThumbWheel(device: device) else { return nil }
            try wheel.setInverted(config.scroll.invertHorizontal)
            return wheel
        } catch {
            Log.warn("  \(name): couldn't set the thumb wheel direction: \(error)")
            return nil
        }
    }

    // MARK: Health check

    private func startHealthChecks() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.healthCheckInterval, repeating: Self.healthCheckInterval,
                       leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.healthCheck(reason: "periodic check") }
        timer.resume()
        healthTimer = timer

        // Bluetooth takes a few seconds to reconnect after waking, so check twice.
        power = SystemPower { [weak self] in
            guard let self else { return }
            Log.debug("system woke up")
            for delay in [3.0, 15.0] {
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.healthCheck(reason: "after wake")
                }
            }
        }
        if power == nil {
            Log.warn("couldn't register for wake notifications; relying on the periodic check")
        }
    }

    /// Re-diverts devices that silently lost their configuration, and retries devices whose
    /// setup failed. Quiet unless it actually has to fix something. The thumb wheel direction
    /// is lost together with the diversion, so re-configuring restores it too.
    private func healthCheck(reason: String) {
        for m in managed.values {
            let timeout = m.device.timeout
            m.device.timeout = 1.0
            defer { m.device.timeout = timeout }
            do {
                // One request: if the device reset, every diversion is gone together.
                let reporting = try m.reprog.reporting(for: config.button)
                guard !reporting.isDiverted || (m.rawXY && !reporting.isRawXYDiverted) else { continue }
                Log.info("\(m.name): diversion lost (\(reporting)) [\(reason)]; diverting again")
                m.button.reset()
                m.pressedExtras = []
                configure(m.device)
            } catch {
                // Usually the mouse is asleep; it'll get re-diverted when it reconnects.
                Log.debug("\(m.name): health check got no answer: \(error)")
            }
        }

        for (key, device) in retry {
            guard links[key.registryID] != nil else {
                retry[key] = nil
                continue
            }
            device.timeout = 1.0
            do {
                _ = try device.protocolVersion()
            } catch {
                Log.debug("retry #\(hex8(device.index)) [\(reason)]: \(error)")
                continue
            }
            device.timeout = 2.0
            Log.info("Retrying device #\(hex8(device.index)) [\(reason)]")
            configure(device)
        }
    }

    // MARK: Events

    private func handle(_ report: HIDPPReport, from registryID: UInt64) {
        guard let state = links[registryID] else { return }

        if state.isReceiver, let event = Receiver.connectionEvent(from: report) {
            let key = Key(registryID: registryID, index: event.index)
            if event.linkEstablished {
                Log.info("Receiver: device #\(event.index) connected")
                // Give the device a moment to finish booting before talking to it.
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.reprobe(registryID: registryID, index: event.index)
                }
            } else if let m = managed.removeValue(forKey: key) {
                Log.info("\(m.name): disconnected from the receiver")
            }
            return
        }

        guard report.softwareID == 0,
              let m = managed[Key(registryID: registryID, index: report.deviceIndex)] else { return }

        if let event = m.reprog.event(from: report) {
            switch event {
            case .divertedButtons(let cids):
                Log.debug("diverted buttons pressed: \(cids.map(hex16))")
                if let output = m.button.update(pressedControls: cids) {
                    perform(output, on: m)
                }
                // Extra buttons: shortcut on press (falling edge), not on release.
                let pressed = Set(cids).intersection(m.extraButtons)
                for cid in pressed.subtracting(m.pressedExtras).sorted() {
                    if let shortcut = bindings.extras[cid] {
                        fire(shortcut, because: "\(m.name): button \(hex16(cid))")
                    }
                }
                m.pressedExtras = pressed
            case .rawXY(let dx, let dy):
                if let output = m.button.move(dx: Int(dx), dy: Int(dy)) {
                    perform(output, on: m)
                }
            }
        } else if report.featureIndex == m.wirelessStatusIndex, report.function == 0 {
            // WIRELESS_DEVICE_STATUS: the mouse reports that it reconnected/restarted without
            // the IOHIDDevice going away; divert again.
            Log.info("\(m.name): reconnection notice (\(report.params.prefix(3).hexString)); diverting again")
            m.button.reset()
            m.pressedExtras = []
            configure(m.device)
        }
    }

    private func reprobe(registryID: UInt64, index: UInt8) {
        guard let state = links[registryID] else { return }
        let device = HIDPPDevice(link: state.link, index: index)
        for attempt in 1...3 {
            do {
                _ = try device.protocolVersion()
                configure(device)
                return
            } catch {
                Log.debug("ping to #\(index) attempt \(attempt): \(error)")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        Log.warn("Receiver: device #\(index) doesn't respond; the health check will retry it")
        retry[Key(registryID: registryID, index: index)] = device
    }

    private func perform(_ output: GestureButton.Output, on m: Managed) {
        switch output {
        case .tap:
            fire(bindings.tap, because: "\(m.name): tap")
        case .swipe(let direction):
            guard let shortcut = bindings.swipes[direction] else {
                Log.debug("\(m.name): gesture \(direction.arrow) has no shortcut configured")
                return
            }
            fire(shortcut, because: "\(m.name): gesture \(direction.arrow)")
        }
    }

    /// Actions are logged only with --debug, so the LaunchAgent log doesn't grow with use.
    private func fire(_ shortcut: KeyShortcut, because reason: String) {
        if Permissions.postEvents != .granted {
            Log.warn("no Accessibility permission: macOS will drop the shortcut \(shortcut)")
        }
        Log.debug("\(reason) → \(shortcut)")
        shortcut.post()
    }

    // MARK: Clean exit

    /// On exit (Ctrl-C, `launchctl bootout`…) restores the buttons to their normal behavior.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdown() {
        Log.info("Exiting; restoring the buttons' original behavior…")
        healthTimer?.cancel()
        for m in managed.values {
            m.device.timeout = 1.0
            do {
                try m.reprog.setReporting(for: config.button, divert: false, rawXY: false)
                for cid in m.extraButtons {
                    try m.reprog.setReporting(for: cid, divert: false)
                }
                if config.scroll.invertHorizontal {
                    try m.thumbWheel?.setInverted(false)
                }
            } catch {
                Log.warn("\(m.name): couldn't undo the diversion: \(error)")
            }
        }
        exit(0)
    }
}
