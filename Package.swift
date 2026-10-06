// swift-tools-version:5.9
import PackageDescription

// Layers (bottom to top):
//   Diagnostics   logging + hex dumps (--debug)
//   HIDTransport  IOHIDManager / IOHIDDevice: discover devices, send and receive reports
//   HIDPP         HID++ 2.0 protocol on top of HIDTransport (features, REPROG_CONTROLS_V4, receiver)
//   Gestures      button state machine (no system dependencies)
//   Actions       keyboard shortcuts via CGEvent
//   Scrolling     wheel speed via a scroll event tap
//   Config        ~/.config/thumbd/config.json
//   thumbd        CLI + daemon that ties everything together
let package = Package(
    name: "thumbd",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Diagnostics"),
        .target(
            name: "HIDTransport",
            dependencies: ["Diagnostics"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "HIDPP", dependencies: ["HIDTransport", "Diagnostics"]),
        .target(name: "Gestures"),
        .target(
            name: "Actions",
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Carbon")]
        ),
        .target(name: "Scrolling", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "Config"),
        .executableTarget(
            name: "thumbd",
            dependencies: ["Diagnostics", "HIDTransport", "HIDPP", "Gestures", "Actions", "Scrolling", "Config"]
        ),
        // Unit tests as a plain executable (`swift run thumbd-tests` or ./scripts/test.sh)
        // rather than XCTest, so they also run where `swift test` can't (see Santa in the README).
        .executableTarget(
            name: "thumbd-tests",
            dependencies: ["Gestures", "Actions", "Scrolling", "Config"],
            path: "Tests/thumbd-tests"
        ),
    ]
)
