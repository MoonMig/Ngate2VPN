import SwiftUI
import AppKit

// MARK: - Theme

/// Builds an NSColor that picks between two RGBA values based on the active
/// NSAppearance. Wrapping it in Color(...) makes it a SwiftUI dynamic colour,
/// so views automatically restyle when the user toggles theme.
func dyn(
    _ darkR: Double, _ darkG: Double, _ darkB: Double, _ darkA: Double,
    _ lightR: Double, _ lightG: Double, _ lightB: Double, _ lightA: Double
) -> Color {
    Color(NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
        if isDark {
            return NSColor(red: darkR, green: darkG, blue: darkB, alpha: darkA)
        } else {
            return NSColor(red: lightR, green: lightG, blue: lightB, alpha: lightA)
        }
    })
}

// MARK: - Design Tokens
// Each token has a dark and a light variant. The light palette mimics OS X
// system gray windows: warm-white surfaces, subtle borders, dark text.

enum DS {
    // Surfaces
    static let bg        = dyn(0.07, 0.07, 0.10, 1,   0.96, 0.96, 0.97, 1)
    static let surface   = dyn(0.12, 0.12, 0.16, 1,   1.00, 1.00, 1.00, 1)
    static let surfaceHi = dyn(0.18, 0.18, 0.23, 1,   0.92, 0.92, 0.94, 1)
    static let border    = dyn(1, 1, 1, 0.08,         0, 0, 0, 0.10)

    // Accent — same blue both modes (Apple-style system blue)
    static let accent    = dyn(0.20, 0.60, 1.00, 1,   0.00, 0.48, 1.00, 1)
    static let accentDim = dyn(0.20, 0.60, 1.00, 0.15,  0.00, 0.48, 1.00, 0.10)

    // Status colours
    static let green     = dyn(0.13, 0.85, 0.55, 1,   0.20, 0.72, 0.42, 1)
    static let orange    = dyn(1.00, 0.62, 0.18, 1,   0.95, 0.55, 0.10, 1)
    static let red       = dyn(1.00, 0.33, 0.33, 1,   0.85, 0.20, 0.20, 1)
    static let muted     = dyn(0.40, 0.40, 0.48, 1,   0.60, 0.60, 0.65, 1)

    // Text — primary, secondary, tertiary
    static let pri  = dyn(1, 1, 1, 1.00,    0, 0, 0, 0.92)
    static let sec  = dyn(1, 1, 1, 0.50,    0, 0, 0, 0.55)
    static let ter  = dyn(1, 1, 1, 0.25,    0, 0, 0, 0.30)

    static let r: CGFloat  = 10
    static let rL: CGFloat = 14
}
