import AppKit

/// Central color palette for the dark, terminal-like theme.
enum Palette {
    static let canvas        = srgb(0x21, 0x20, 0x29)   // #212029 (matches the sidebar)
    static let sidebarTint   = srgb(0x21, 0x20, 0x29)   // #212029
    static let projectFrame  = srgb(0x71, 0x6C, 0x90)   // #716C90
    static let projectFill   = srgb(0x27, 0x26, 0x34)   // folder body/tab fill
    static let projectStroke         = srgb(0x34, 0x33, 0x45)   // folder border (default)
    static let projectStrokeSelected = srgb(0x5E, 0x5C, 0x7D)   // folder border (selected)
    static let projectTabText = srgb(0xB4, 0xB0, 0xC6, 0.85)  // muted name on the tab
    static let projectEditorFill = srgb(0x2C, 0x2A, 0x36)    // rename field box

    static let panelBody          = srgb(0x14, 0x14, 0x14)   // window chrome background
    static let panelBorder        = srgb(0x38, 0x38, 0x38)   // window border (default)
    static let panelBorderSelected = srgb(0x5B, 0x59, 0x59)  // window border (selected)
    static let panelTitleBar      = srgb(0x38, 0x36, 0x4A)   // (unused since the title-bar band was removed)
    static let panelTitleText     = srgb(0xE0, 0xDF, 0xEA)   // rename field editor text
    static let panelHeaderText         = srgb(0x5B, 0x59, 0x59)   // window panel header title (default)
    static let panelHeaderTextSelected = srgb(0x92, 0x8F, 0x8F)   // window panel header title (selected)

    static let tabBarBackground = srgb(0x1A, 0x19, 0x20)   // browser tab strip
    static let tabActiveFill    = srgb(0x2C, 0x2A, 0x36)   // active browser tab chip

    static let dockFill   = srgb(0x1E, 0x1D, 0x26)            // floating dock background
    static let dockBorder = srgb(0x3A, 0x39, 0x47)           // floating dock border / divider
    static let dockIcon   = srgb(0xC9, 0xC6, 0xD6)           // dock icon stroke
    static let dockHover  = NSColor(white: 1.0, alpha: 0.10) // dock button hover highlight

    static let editorBackground = srgb(0x24, 0x23, 0x30)

    static let gridDot      = NSColor(white: 1.0, alpha: 0.06)
    static let sidebarText  = NSColor(white: 0.90, alpha: 1.0)

    /// 16 preconfigured project accent colors (index stored per project).
    static let projectColors: [NSColor] = [
        srgb(0xE0, 0x57, 0x5C), srgb(0xE0, 0x7A, 0x42), srgb(0xDF, 0xA5, 0x3A), srgb(0xD3, 0xC4, 0x4A),
        srgb(0x9F, 0xCB, 0x45), srgb(0x55, 0xC2, 0x6E), srgb(0x3F, 0xBF, 0xA8), srgb(0x45, 0xB6, 0xD6),
        srgb(0x4E, 0x92, 0xE0), srgb(0x5B, 0x6E, 0xE5), srgb(0x7B, 0x7B, 0xE8), srgb(0x9E, 0x63, 0xE0),
        srgb(0xB9, 0x5F, 0xD6), srgb(0xD8, 0x5F, 0xB0), srgb(0xE0, 0x60, 0x8C), srgb(0x8A, 0x90, 0xA6),
    ]

    /// Mix `base` a little toward a project color (used to tint folder fill/stroke).
    static func tinted(_ base: NSColor, with color: NSColor?) -> NSColor {
        guard let color else { return base }
        return base.blended(withFraction: 0.08, of: color) ?? base
    }

    private static func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
}
