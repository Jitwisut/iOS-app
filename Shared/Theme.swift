import SwiftUI

/// Night-glow design tokens: deep navy sky, warm amber for light, cyan for location.
enum Theme {
    static let amber = Color(red: 1.00, green: 0.71, blue: 0.28)       // #FFB547
    static let amberDeep = Color(red: 1.00, green: 0.54, blue: 0.24)   // #FF8A3D
    static let cyan = Color(red: 0.35, green: 0.85, blue: 1.00)        // #5AD8FF
    static let mint = Color(red: 0.20, green: 0.83, blue: 0.60)        // #34D399
    static let danger = Color(red: 1.00, green: 0.42, blue: 0.42)      // #FF6B6B

    static let night0 = Color(red: 0.047, green: 0.075, blue: 0.153)   // #0C1327
    static let night1 = Color(red: 0.027, green: 0.039, blue: 0.082)   // #070A15
    static let night2 = Color(red: 0.012, green: 0.016, blue: 0.035)   // #030409

    static let textSecondary = Color.white.opacity(0.66)
    static let textTertiary = Color.white.opacity(0.48)
    static let hairline = Color.white.opacity(0.10)

    static let warmGradient = LinearGradient(
        colors: [amber, amberDeep], startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let cardRadius: CGFloat = 28
}

extension Font {
    /// Rounded digits for big numbers. SF Rounded has no Thai glyphs, so use it only for numerals/units.
    static func numeric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

extension Animation {
    static let snappySpring = Animation.spring(response: 0.38, dampingFraction: 0.78)
    static let softSpring = Animation.spring(response: 0.6, dampingFraction: 0.85)
}
