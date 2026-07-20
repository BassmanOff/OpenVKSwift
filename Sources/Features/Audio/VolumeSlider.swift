import SwiftUI
import MediaPlayer

/// Системная громкость: MPVolumeView синхронизируется и с аппаратными кнопками.
/// Нейтральный серый трек с белой системной «шайбой» — как в референсе VK iOS 7-10
/// (синий там только у скраббера, см. docs/vk-player-spec.md).
struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = UIColor(OVK.Palette.textSecondary.opacity(0.5))
            slider.maximumTrackTintColor = UIColor(OVK.Palette.textSecondary.opacity(0.25))
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) { }
}
