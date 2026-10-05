import Actions
import Carbon.HIToolbox
import Config
import CoreGraphics
import Foundation
import Gestures

// Minimal harness: `test` groups checks, `expect` records a failure without stopping.

var failures = 0
var checks = 0
var currentTest = ""

func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    do {
        try body()
    } catch {
        failures += 1
        print("✗ \(name): unexpected error: \(error)")
    }
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "", line: UInt = #line) {
    checks += 1
    do {
        if try condition() { return }
        print("✗ \(currentTest) (line \(line)) \(message)")
    } catch {
        print("✗ \(currentTest) (line \(line)) \(message): threw \(error)")
    }
    failures += 1
}

func expectThrows(_ body: () throws -> Void, _ message: String = "", line: UInt = #line) {
    checks += 1
    do {
        try body()
        failures += 1
        print("✗ \(currentTest) (line \(line)) expected an error. \(message)")
    } catch {}
}

func decode(_ json: String) throws -> Config {
    try JSONDecoder().decode(Config.self, from: Data(json.utf8))
}

// MARK: GestureButton

let gesture: UInt16 = 0x00C3

test("press and release without moving is a tap") {
    let b = GestureButton(cid: gesture, threshold: 50)
    expect(b.update(pressedControls: [gesture]) == nil)
    expect(b.isPressed)
    expect(b.update(pressedControls: []) == .tap)
    expect(!b.isPressed)
}

test("movement below the threshold is still a tap") {
    let b = GestureButton(cid: gesture, threshold: 50)
    _ = b.update(pressedControls: [gesture])
    expect(b.move(dx: 20, dy: 10) == nil)
    expect(b.move(dx: -5, dy: 15) == nil)
    expect(b.update(pressedControls: []) == .tap)
}

test("crossing the threshold fires the swipe once, and no tap on release") {
    let b = GestureButton(cid: gesture, threshold: 50)
    _ = b.update(pressedControls: [gesture])
    expect(b.move(dx: 30, dy: 0) == nil)
    expect(b.move(dx: 25, dy: 0) == .swipe(.right))
    expect(b.move(dx: 100, dy: 0) == nil, "only one gesture per press")
    expect(b.update(pressedControls: []) == nil)
}

test("directions follow the HID convention (positive y = down)") {
    let cases: [(Int, Int, GestureButton.Direction)] = [
        (60, 0, .right), (-60, 0, .left), (0, 60, .down), (0, -60, .up),
    ]
    for (dx, dy, direction) in cases {
        let b = GestureButton(cid: gesture, threshold: 50)
        _ = b.update(pressedControls: [gesture])
        expect(b.move(dx: dx, dy: dy) == .swipe(direction), "\(dx),\(dy) → \(direction)")
    }
}

test("the dominant axis wins") {
    let b = GestureButton(cid: gesture, threshold: 50)
    _ = b.update(pressedControls: [gesture])
    expect(b.move(dx: 40, dy: 60) == .swipe(.down))
}

test("movement is ignored while the button isn't held") {
    let b = GestureButton(cid: gesture, threshold: 50)
    expect(b.move(dx: 500, dy: 0) == nil)
    _ = b.update(pressedControls: [gesture])
    expect(b.update(pressedControls: []) == .tap)
}

test("each press starts from zero") {
    let b = GestureButton(cid: gesture, threshold: 50)
    _ = b.update(pressedControls: [gesture])
    _ = b.move(dx: 40, dy: 0)
    _ = b.update(pressedControls: [])
    _ = b.update(pressedControls: [gesture])
    expect(b.move(dx: 40, dy: 0) == nil, "40 from the previous press must not carry over")
}

test("other CIDs don't press the button") {
    let b = GestureButton(cid: gesture, threshold: 50)
    expect(b.update(pressedControls: [0x00C4]) == nil)
    expect(!b.isPressed)
    _ = b.update(pressedControls: [0x00C4, gesture])
    expect(b.isPressed)
    expect(b.update(pressedControls: [0x00C4]) == .tap)
}

test("reset forgets a press in progress") {
    let b = GestureButton(cid: gesture, threshold: 50)
    _ = b.update(pressedControls: [gesture])
    b.reset()
    expect(!b.isPressed)
    expect(b.update(pressedControls: []) == nil)
}

// MARK: KeyShortcut

test("named modifiers and F-keys") {
    let s = try KeyShortcut("ctrl+alt+cmd+f1")
    expect(s.keyCode == CGKeyCode(kVK_F1))
    expect(s.flags.contains(.maskControl) && s.flags.contains(.maskAlternate) && s.flags.contains(.maskCommand))
    expect(!s.flags.contains(.maskShift))
    expect(s.description == "⌃⌥⌘F1", s.description)
}

test("symbol modifiers parse like named ones") {
    let named = try KeyShortcut("ctrl+alt+cmd+f1")
    let symbols = try KeyShortcut("⌃⌥⌘F1")
    expect(named.keyCode == symbols.keyCode)
    expect(named.flags == symbols.flags)
}

test("F-keys, arrows and navigation keys get fn automatically") {
    for text in ["f5", "ctrl+left", "right", "home", "pagedown", "forwarddelete"] {
        expect(try KeyShortcut(text).flags.contains(.maskSecondaryFn), text)
    }
    for text in ["a", "cmd+space", "return", "esc"] {
        expect(!(try KeyShortcut(text).flags.contains(.maskSecondaryFn)), text)
    }
    expect(try KeyShortcut("ctrl+left").description == "⌃LEFT", "fn isn't shown for keys that always have it")
}

test("explicit fn on other keys is kept and shown") {
    let s = try KeyShortcut("fn+a")
    expect(s.flags.contains(.maskSecondaryFn))
    expect(s.description == "fn A", s.description)
}

test("parsing is case-insensitive and tolerates spaces") {
    let s = try KeyShortcut(" CTRL + Shift + F12 ")
    expect(s.keyCode == CGKeyCode(kVK_F12))
    expect(s.flags.contains(.maskControl) && s.flags.contains(.maskShift))
}

test("letters and punctuation map to the right key codes") {
    expect(try KeyShortcut("cmd+a").keyCode == CGKeyCode(kVK_ANSI_A))
    expect(try KeyShortcut("cmd+[").keyCode == CGKeyCode(kVK_ANSI_LeftBracket))
    expect(try KeyShortcut("cmd+space").keyCode == CGKeyCode(kVK_Space))
}

test("invalid shortcuts are rejected") {
    expectThrows({ _ = try KeyShortcut("") })
    expectThrows({ _ = try KeyShortcut("ctrl+") })
    expectThrows({ _ = try KeyShortcut("hyper+a") }, "unknown modifier")
    expectThrows({ _ = try KeyShortcut("ctrl+banana") }, "unknown key")
}

// MARK: Config

test("an empty config gets the defaults") {
    let c = try decode("{}")
    expect(c.tap == "ctrl+alt+cmd+f1")
    expect(c.button == 0x00C3)
    expect(c.threshold == 50)
    expect(c.gestures.isEmpty && c.buttons.isEmpty && c.devices.isEmpty)
}

test("the default config file decodes") {
    let c = try decode(Config.defaultJSON)
    expect(c.gestures.count == 4)
    expect(Config.unknownKeys(in: Data(Config.defaultJSON.utf8)).isEmpty)
}

test("button CIDs accept hex strings, decimal strings and numbers") {
    expect(try decode(#"{"button": "0x00C4"}"#).button == 0x00C4)
    expect(try decode(#"{"button": "0xc4"}"#).button == 0x00C4)
    expect(try decode(#"{"button": 196}"#).button == 0x00C4)
    expect(try decode(#"{"button": "196"}"#).button == 196)
    expectThrows({ _ = try decode(#"{"button": "0xZZ"}"#) })
    expectThrows({ _ = try decode(#"{"button": 70000}"#) })
}

test("extra buttons are keyed by CID") {
    let c = try decode(#"{"buttons": {"0x00C4": "f12", "83": "cmd+["}}"#)
    expect(c.buttons == [0x00C4: "f12", 83: "cmd+["])
    expectThrows({ _ = try decode(#"{"buttons": {"smart shift": "f12"}}"#) })
}

test("unknown top-level keys are reported") {
    let data = Data(#"{"tap": "f1", "gesture": {}, "treshold": 10}"#.utf8)
    expect(Config.unknownKeys(in: data) == ["gesture", "treshold"])
}

test("readable errors for malformed JSON and wrong types") {
    do {
        _ = try decode(#"{"tap": "f1""#)
        expect(false, "an unclosed object should fail")
    } catch {
        expect(describeConfigError(error).hasPrefix("invalid JSON"), describeConfigError(error))
    }
    do {
        _ = try decode(#"{"threshold": "lots"}"#)
        expect(false, "a string threshold should fail")
    } catch {
        expect(describeConfigError(error).hasPrefix("\"threshold\""), describeConfigError(error))
    }
}

test("the devices filter matches part of the name, ignoring case") {
    expect(try decode("{}").accepts(deviceName: "Wireless Mouse MX Master 3"))
    let c = try decode(#"{"devices": ["mx master"]}"#)
    expect(c.accepts(deviceName: "Wireless Mouse MX Master 3"))
    expect(!c.accepts(deviceName: "MX Anywhere 2S"))
}

print(failures == 0 ? "✓ \(checks) checks passed" : "✗ \(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
