import Foundation
import CoreGraphics

public enum MascotKind: String, Codable, CaseIterable { case clawd, cat, robot }
public enum MascotColorMode: String, Codable { case accent, custom }
public struct MascotColorPreference: Codable, Equatable {
    public var mode: MascotColorMode = .accent
    public var hex = "D97757"
    public init(mode: MascotColorMode = .accent, hex: String = "D97757") { self.mode = mode; self.hex = hex }
}

/// sRGB math shared by rendering and contrast tests. User input is stored separately, unmodified.
public struct SRGBColor: Equatable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = min(1, max(0, r)); self.g = min(1, max(0, g)); self.b = min(1, max(0, b)) }
    public init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let n = raw.count == 6 ? UInt64(raw, radix: 16) ?? 0xD97757 : 0xD97757
        r = Double((n >> 16) & 255) / 255; g = Double((n >> 8) & 255) / 255; b = Double(n & 255) / 255
    }
    public var hex: String { String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
    public static let black = Self(hex: "000000"), white = Self(hex: "FFFFFF")
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    public func contrast(with other: Self) -> Double { (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05) }
    public func mixed(with other: Self, amount: Double) -> Self {
        let t = min(1, max(0, amount))
        return Self(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }
    public var ink: Self { contrast(with: .black) >= contrast(with: .white) ? .black : .white }
    public func readable(on background: Self, ratio: Double = 4.5) -> Self {
        guard contrast(with: background) < ratio else { return self }
        let destination = background.ink
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let t = (low + high) / 2
            if mixed(with: destination, amount: t).contrast(with: background) >= ratio { high = t } else { low = t }
        }
        return mixed(with: destination, amount: high)
    }
}

public struct ThemeColors {
    public var canvas: SRGBColor, content: SRGBColor, primary: SRGBColor, secondary: SRGBColor, accent: SRGBColor, accentFill: SRGBColor, onAccent: SRGBColor
    /// `black` implies a dark appearance with true-black surfaces (matching the hardware notch).
    public init(dark: Bool, black: Bool = false, accentHex: String) {
        let dark = dark || black
        canvas = SRGBColor(hex: black ? "000000" : (dark ? "202020" : "F5F5F5"))
        content = SRGBColor(hex: black ? "0A0A0A" : (dark ? "292929" : "FFFFFF"))
        primary = SRGBColor(hex: dark ? "F2F2F2" : "242424")
        secondary = SRGBColor(hex: dark ? "B8B8B8" : "626262")
        // Account for native grouped controls as well as the main content surfaces.
        accentFill = SRGBColor(hex: accentHex)
        accent = accentFill.readable(on: SRGBColor(hex: black ? "1F1F1F" : (dark ? "353535" : "EBEBEB")))
        onAccent = accentFill.ink
    }
}

public extension Preferences {
    var selectedMascotColor: MascotColorPreference { mascotColors[mascot.rawValue] ?? .init() }
    var mascotHex: String { selectedMascotColor.mode == .accent ? accentHex : selectedMascotColor.hex }
}

/// The exact body rectangles are also used by Canvas, so transparent gaps remain click-through.
public enum MascotSilhouette {
    public static func body(_ kind: MascotKind) -> [CGRect] {
        switch kind {
        case .clawd: return [CGRect(x: 7,y: 9,width: 18,height: 13), CGRect(x: 4,y: 12,width: 3,height: 8), CGRect(x: 25,y: 12,width: 3,height: 8), CGRect(x: 6,y: 22,width: 4,height: 4), CGRect(x: 12,y: 22,width: 3,height: 5), CGRect(x: 18,y: 22,width: 3,height: 5), CGRect(x: 24,y: 21,width: 3,height: 5)]
        case .cat: return [CGRect(x: 8,y: 10,width: 16,height: 11), CGRect(x: 8,y: 5,width: 4,height: 5), CGRect(x: 20,y: 5,width: 4,height: 5), CGRect(x: 10,y: 21,width: 12,height: 5), CGRect(x: 9,y: 26,width: 5,height: 2), CGRect(x: 19,y: 26,width: 5,height: 2), CGRect(x: 23,y: 21,width: 5,height: 3), CGRect(x: 26,y: 15,width: 3,height: 6)]
        case .robot: return [CGRect(x: 8,y: 8,width: 16,height: 12), CGRect(x: 15,y: 4,width: 2,height: 4), CGRect(x: 14,y: 3,width: 4,height: 2), CGRect(x: 10,y: 21,width: 12,height: 5), CGRect(x: 5,y: 14,width: 3,height: 9), CGRect(x: 24,y: 14,width: 3,height: 9), CGRect(x: 10,y: 27,width: 4,height: 2), CGRect(x: 18,y: 27,width: 4,height: 2)]
        }
    }
    private static let outlines: [MascotKind: CGPath] = Dictionary(uniqueKeysWithValues: MascotKind.allCases.map { kind in
        let regions = body(kind), path = CGMutablePath()
        func occupied(_ x: Int, _ y: Int) -> Bool { regions.contains { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) } }
        func edge(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) {
            path.move(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x + dx, y: y + dy))
        }
        for y in 0..<32 { for x in 0..<32 where occupied(x, y) {
            if !occupied(x, y - 1) { edge(x, y, 1, 0) }
            if !occupied(x, y + 1) { edge(x, y + 1, 1, 0) }
            if !occupied(x - 1, y) { edge(x, y, 0, 1) }
            if !occupied(x + 1, y) { edge(x + 1, y, 0, 1) }
        } }
        return (kind, path.copy()!)
    })
    public static func outline(_ kind: MascotKind) -> CGPath { outlines[kind]! }
    public static func contains(point: CGPoint, size: CGSize, kind: MascotKind, pose: ClawdPose) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let p = CGPoint(x: point.x / size.width * 32, y: point.y / size.height * 32)
        var regions = body(kind)
        if [.question, .permission, .failed].contains(pose) { regions.append(CGRect(x: 20,y: 0,width: 11,height: 13)) }
        if pose == .plan { regions.append(CGRect(x: 20,y: 18,width: 9,height: 14)) }
        if pose == .working { regions.append(CGRect(x: 6,y: 21,width: 20,height: 9)) }
        if pose == .permission { regions.append(CGRect(x: 27,y: 8,width: 3,height: 7)) }
        if pose == .celebration { regions += [CGRect(x: 3,y: 8,width: 3,height: 6), CGRect(x: 26,y: 7,width: 3,height: 7)] }
        // Account for the small vertical bob/jump, without making a rectangular input window.
        let offsets: [Double] = pose == .celebration ? [0, 1, 2, 3] : ([.working, .idle].contains(pose) ? [-1, 0, 1] : [0])
        return offsets.contains { dy in regions.contains { $0.contains(CGPoint(x: p.x, y: p.y + dy)) } }
    }
}

extension Preferences {
    /// Explicit user recovery, never a migration that overrides an intentional hidden preference.
    public mutating func showDesktopMascot(resetPosition: Bool = false) {
        mascotHidden = false
        if companionVisibility == .island { companionVisibility = .both }
        if resetPosition { mascotPlacement = .init() }
    }
}
