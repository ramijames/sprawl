import AppKit

/// Central color palette for the dark, terminal-like theme.
enum Palette {
    static let canvas        = srgb(0x21, 0x20, 0x29)   // #212029 (matches the sidebar)
    static let sidebarTint   = srgb(0x21, 0x20, 0x29)   // #212029
    static let projectFrame  = srgb(0x71, 0x6C, 0x90)   // #716C90

    static let panelBody      = srgb(0x29, 0x28, 0x3A)
    static let panelTitleBar  = srgb(0x38, 0x36, 0x4A)
    static let panelBorder    = srgb(0x5A, 0x56, 0x70)
    static let panelTitleText = srgb(0xE0, 0xDF, 0xEA)

    static let editorBackground = srgb(0x24, 0x23, 0x30)

    static let gridDot      = NSColor(white: 1.0, alpha: 0.06)
    static let sidebarText  = NSColor(white: 0.90, alpha: 1.0)

    private static func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
}
