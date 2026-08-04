import SwiftUI

/// The brief's palette and type, carried over from the printed page.
/// Everything is warm, hand-sketched, and low-contrast; nothing is a button,
/// badge, or filled label.
enum Theme {
    static let background = Color(hex: 0xFCFCFB)
    static let wash = Color(hex: 0xF9F9F7)
    static let ink = Color(hex: 0x2E2C27)
    static let inkSoft = Color(hex: 0x6B6A63)
    static let inkGrey = Color(hex: 0xB4B3A8)
    static let hairline = Color(hex: 0xE4E3DC)
    static let bandEdge = Color(hex: 0xE1E1DF)
    /// Rationed to one accent across the whole drawing.
    static let clay = Color(hex: 0xC6613F)

    /// Fraunces on the headline only. Drop `Fraunces-SemiBold.ttf` into
    /// `MorningBrief/Resources/Fonts/` and add it to `UIAppFonts` to get the
    /// real face; until then this resolves to the system serif, which is a
    /// clean fallback rather than a broken one.
    static let headline = Font.custom(
        "Fraunces-SemiBold",
        size: 34,
        relativeTo: .largeTitle
    )

    static let dayLine = Font.system(.subheadline, design: .default).weight(.regular)
    static let sectionHeading = Font.system(.subheadline, design: .default).weight(.semibold)
    static let actRange = Font.system(.footnote, design: .default).weight(.bold)
    static let body = Font.system(.callout, design: .default)
    static let caption = Font.system(.caption, design: .default)
    static let numeral = Font.system(.caption2, design: .default).weight(.regular)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
