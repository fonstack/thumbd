/// HID++ 2.0 feature IDs (names as in Solaar). Only a few are used; the rest just make
/// `thumbd list` readable.
public enum Feature {
    public static let root: UInt16 = 0x0000
    public static let featureSet: UInt16 = 0x0001
    public static let deviceName: UInt16 = 0x0005
    public static let reprogControlsV4: UInt16 = 0x1B04
    public static let wirelessDeviceStatus: UInt16 = 0x1D4B

    public static func name(_ id: UInt16) -> String { names[id] ?? "?" }

    static let names: [UInt16: String] = [
        0x0000: "ROOT",
        0x0001: "FEATURE_SET",
        0x0002: "FEATURE_INFO",
        0x0003: "DEVICE_FW_VERSION",
        0x0005: "DEVICE_NAME",
        0x0007: "DEVICE_FRIENDLY_NAME",
        0x0020: "CONFIG_CHANGE",
        0x00C2: "DFUCONTROL_SIGNED",
        0x00D0: "DFU",
        0x1000: "BATTERY_STATUS",
        0x1001: "BATTERY_VOLTAGE",
        0x1004: "UNIFIED_BATTERY",
        0x1802: "DEVICE_RESET",
        0x1814: "CHANGE_HOST",
        0x1815: "HOSTS_INFO",
        0x1B04: "REPROG_CONTROLS_V4",
        0x1D4B: "WIRELESS_DEVICE_STATUS",
        0x1E00: "ENABLE_HIDDEN_FEATURES",
        0x2110: "SMART_SHIFT",
        0x2111: "SMART_SHIFT_ENHANCED",
        0x2121: "HIRES_WHEEL",
        0x2150: "THUMB_WHEEL",
        0x2201: "ADJUSTABLE_DPI",
        0x2205: "POINTER_SPEED",
    ]
}
