import SwiftUI

/// Иконка устройства, с которого пользователь сейчас онлайн (как «онлайн с iPhone» в VK).
/// Для веб/десктопа и оффлайна иконка не показывается (как и в VK — телефон только у мобильных).
struct OnlinePlatformIcon: View {
    let platform: User.OnlinePlatform
    var size: CGFloat = 11

    var body: some View {
        switch platform {
        case .iphone:
            // Логотип Apple () — глиф U+F8FF в системном шрифте, рисуется на ВСЕХ версиях iOS
            // (в отличие от SF-символа apple.logo, который только с iOS 16).
            Text(verbatim: "\u{F8FF}")
                .font(.system(size: size + 1))
                .foregroundColor(OVK.Palette.primary)
                .accessibilityLabel("онлайн с iPhone")
        default:
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size))
                    .foregroundColor(OVK.Palette.primary)
                    .accessibilityLabel(label)
            }
        }
    }

    private var symbol: String? {
        switch platform {
        case .android:
            if #available(iOS 16.1, *) { return "candybarphone" } else { return "iphone" }
        case .mobile:
            return "iphone"
        case .iphone, .web, .none:
            return nil
        }
    }

    private var label: String {
        switch platform {
        case .iphone: return "онлайн с iPhone"
        case .android: return "онлайн с Android"
        case .mobile: return "онлайн с телефона"
        case .web, .none: return "онлайн"
        }
    }
}
