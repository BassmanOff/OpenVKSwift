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
        case .android:
            // Голова Android-робота, нарисованная Path-ом: SF-символа Android не существует,
            // а candybarphone (iOS 16.1+) выглядит как «просто телефон» и не отличим от .mobile.
            AndroidHeadGlyph(size: size, color: OVK.Palette.primary)
                .accessibilityLabel("онлайн с Android")
        case .mobile:
            Image(systemName: "iphone")
                .font(.system(size: size))
                .foregroundColor(OVK.Palette.primary)
                .accessibilityLabel("онлайн с телефона")
        case .web, .none:
            EmptyView()
        }
    }
}

/// Голова Android-робота: купол с двумя антеннами и глазами.
/// Рисуется вручную (Path), поэтому работает на любой версии iOS и в любом размере.
private struct AndroidHeadGlyph: View {
    var size: CGFloat
    var color: Color

    var body: some View {
        let w = size * 1.2
        let h = size
        let r = size * 0.6          // радиус купола
        let cx = w / 2
        ZStack {
            // Купол (верхняя полуокружность с плоским низом).
            Path { p in
                p.addArc(
                    center: CGPoint(x: cx, y: h),
                    radius: r,
                    startAngle: .degrees(180),
                    endAngle: .degrees(0),
                    clockwise: false
                )
                p.closeSubpath()
            }
            .fill(color)

            // Антенны.
            Path { p in
                p.move(to: CGPoint(x: cx - r * 0.55, y: h - r * 0.75))
                p.addLine(to: CGPoint(x: cx - r * 0.85, y: h - r * 1.35))
                p.move(to: CGPoint(x: cx + r * 0.55, y: h - r * 0.75))
                p.addLine(to: CGPoint(x: cx + r * 0.85, y: h - r * 1.35))
            }
            .stroke(color, style: StrokeStyle(lineWidth: max(1, size * 0.1), lineCap: .round))

            // Глаза (цветом карточки — «вырезаны» из купола).
            Circle()
                .fill(OVK.Palette.card)
                .frame(width: size * 0.16, height: size * 0.16)
                .position(x: cx - r * 0.38, y: h - r * 0.42)
            Circle()
                .fill(OVK.Palette.card)
                .frame(width: size * 0.16, height: size * 0.16)
                .position(x: cx + r * 0.38, y: h - r * 0.42)
        }
        .frame(width: w, height: h)
    }
}
