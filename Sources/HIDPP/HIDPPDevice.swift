import Foundation
import Diagnostics
import HIDTransport

/// One concrete HID++ 2.0 device: a link + a device index
/// (0xFF = direct Bluetooth/USB connection, 0x01–0x06 = behind a receiver).
///
/// Feature indexes are discovered with ROOT.getFeature and cached; they are never assumed.
public final class HIDPPDevice {
    /// Nibble that identifies our requests. Spontaneous events carry 0.
    public static let softwareID: UInt8 = 0x1
    public static let directIndex: UInt8 = 0xFF

    public let link: HIDPPLink
    public let index: UInt8
    public var timeout: TimeInterval = 2.0
    private var featureIndexes: [UInt16: UInt8] = [Feature.root: 0x00]

    public init(link: HIDPPLink, index: UInt8) {
        self.link = link
        self.index = index
    }

    /// Raw request to a feature index. Returns the 16 parameter bytes of the response.
    public func request(featureIndex: UInt8, function: UInt8, params: [UInt8] = []) throws -> [UInt8] {
        let report = HIDPPReport.long(deviceIndex: index, featureIndex: featureIndex, function: function,
                                      softwareID: Self.softwareID, params: params)
        return try link.request(report, timeout: timeout).params
    }

    /// Request to a feature by its ID (resolves the index if needed).
    public func call(_ feature: UInt16, function: UInt8, params: [UInt8] = []) throws -> [UInt8] {
        guard let featureIndex = try featureIndex(of: feature) else { throw HIDPPError.featureNotSupported(feature) }
        return try request(featureIndex: featureIndex, function: function, params: params)
    }

    // MARK: ROOT (0x0000), always at index 0

    /// ROOT function 1 (ping/getProtocolVersion). The third byte is echoed back.
    public func protocolVersion() throws -> (major: UInt8, minor: UInt8) {
        let mark: UInt8 = 0x5A
        let p = try request(featureIndex: 0x00, function: 0x1, params: [0x00, 0x00, mark])
        guard p[2] == mark else { throw HIDPPError.badResponse("ping returned \(hex8(p[2]))") }
        return (p[0], p[1])
    }

    /// ROOT function 0 (getFeature): feature ID → index. `nil` if the device doesn't have it.
    public func featureIndex(of feature: UInt16) throws -> UInt8? {
        if let cached = featureIndexes[feature] { return cached }
        let p = try request(featureIndex: 0x00, function: 0x0, params: [UInt8(feature >> 8), UInt8(feature & 0xFF)])
        guard p[0] != 0 else { return nil }
        featureIndexes[feature] = p[0]
        return p[0]
    }

    // MARK: FEATURE_SET (0x0001)

    public struct FeatureEntry {
        public let index: UInt8
        public let id: UInt16
        public let type: UInt8
        public let version: UInt8
        public var name: String { Feature.name(id) }
        public var typeFlags: [String] {
            var flags: [String] = []
            if type & 0x80 != 0 { flags.append("obsolete") }
            if type & 0x40 != 0 { flags.append("hidden") }
            if type & 0x20 != 0 { flags.append("internal") }
            return flags
        }
    }

    /// Lists every feature (getCount doesn't include ROOT, which sits at index 0).
    public func features() throws -> [FeatureEntry] {
        let count = Int(try call(Feature.featureSet, function: 0x0)[0])
        var entries = [FeatureEntry(index: 0, id: Feature.root, type: 0, version: 0)]
        for i in stride(from: 1, through: count, by: 1) {
            let p = try call(Feature.featureSet, function: 0x1, params: [UInt8(i)])
            let id = UInt16(p[0]) << 8 | UInt16(p[1])
            entries.append(FeatureEntry(index: UInt8(i), id: id, type: p[2], version: p[3]))
            featureIndexes[id] = UInt8(i)
        }
        return entries
    }

    // MARK: DEVICE_NAME (0x0005)

    public func name() throws -> String {
        let length = Int(try call(Feature.deviceName, function: 0x0)[0])
        var bytes: [UInt8] = []
        while bytes.count < length {
            let chunk = try call(Feature.deviceName, function: 0x1, params: [UInt8(bytes.count)])
            let take = chunk.prefix(length - bytes.count)
            if take.isEmpty { break }
            bytes += take
        }
        return String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self)
    }
}
