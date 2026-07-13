import SwiftUI

/// Палитра в стиле ВКонтакте 2015–2016.
enum OVK {
    enum Palette {
        static let primary       = Color(hex: 0x5181B8) // фирменный синий VK
        static let primaryDark   = Color(hex: 0x4A76A8)
        static let background     = Color(hex: 0xEDEEF0)
        static let card           = Color.white
        static let separator      = Color(hex: 0xDCE1E6)
        static let textPrimary    = Color(hex: 0x000000)
        static let textSecondary  = Color(hex: 0x656A73)
        static let link           = Color(hex: 0x2A5885)
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
