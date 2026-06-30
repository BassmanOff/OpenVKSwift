import SwiftUI

/// Полноэкранный просмотр фотографий с листанием (открывается тапом по фото).
struct PhotoViewer: View {
    let photos: [Photo]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.offset) { i, photo in
                    CachedImage(url: photo.bestURL, contentMode: .fit) {
                        ProgressView().tint(.white)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Circle())
            }
            .padding()
        }
    }
}
