import Foundation

/// Colour palette as 0xRRGGBB values so the core stays UI-framework free.
public struct Theme: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isDark: Bool
    public var background: UInt32
    public var text: UInt32
    public var dim: UInt32
    public var accent: UInt32
    public var error: UInt32
    public var success: UInt32
    public var codeBackground: UInt32
    /// Phosphor-style glow behind text.
    public var glow: Bool

    public static let minimalDark = Theme(
        id: "dark", name: "Minimal Dark", isDark: true,
        background: 0x0D0E11, text: 0xE4E4E7, dim: 0x7C7F88, accent: 0xD9825F,
        error: 0xF0717A, success: 0x7FD38B, codeBackground: 0x17191E, glow: false)

    public static let crtGreen = Theme(
        id: "crt-green", name: "CRT Green", isDark: true,
        background: 0x020A04, text: 0x4AF07A, dim: 0x24914A, accent: 0xB6FFC8,
        error: 0xFF6B5E, success: 0x4AF07A, codeBackground: 0x06180B, glow: true)

    public static let crtAmber = Theme(
        id: "crt-amber", name: "CRT Amber", isDark: true,
        background: 0x0B0700, text: 0xFFB43C, dim: 0xA06A14, accent: 0xFFE2A8,
        error: 0xFF6B5E, success: 0xFFB43C, codeBackground: 0x1A1103, glow: true)

    public static let light = Theme(
        id: "light", name: "Paper Light", isDark: false,
        background: 0xFAF9F6, text: 0x1F2328, dim: 0x7A7F87, accent: 0xB4532A,
        error: 0xC62839, success: 0x1E7F3C, codeBackground: 0xEFEDE7, glow: false)

    public static let all: [Theme] = [.minimalDark, .crtGreen, .crtAmber, .light]

    public static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .minimalDark
    }
}
