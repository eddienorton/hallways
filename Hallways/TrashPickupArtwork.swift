import SwiftUI

/// SVG Repo CC0 artwork; original SVGs and source details are in TrashArtwork.
/// Rasterized once through the existing SVG parser, then reused by each particle.
enum TrashPickupArtwork: CaseIterable {
    case bananaPeel, sodaCan, trashCan

    /// Resolve the two small cached rasters before the first pickup animation.
    /// No scene, camera, or audio work; repeated calls reuse the same images.
    static func prepareForGameplay() {
        _ = peelImage
        _ = canImage
    }

    var image: Image {
        switch self {
        case .bananaPeel: return Image(uiImage: Self.peelImage).renderingMode(.template)
        case .sodaCan: return Image(uiImage: Self.canImage).renderingMode(.template)
        case .trashCan: return Image(systemName: "trash.fill")
        }
    }

    var color: Color {
        switch self {
        case .bananaPeel: return .yellow
        case .sodaCan: return Color(red: 0.55, green: 0.8, blue: 1)
        case .trashCan: return .white
        }
    }

    private static func render(_ data: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).image { context in
            context.cgContext.scaleBy(x: 0.25, y: 0.25)
            UIColor.white.setFill()
            SVGPathParser.parse(data).fill()
        }
    }

    private static let peelImage = render("M487.212,381.438c-71,8.859-161.718-62.219-161.718-194.875c0-101.594-58.031-124.406-58.031-124.406V16.531 h-22.922v45.625c0,0-58.047,26.969-58.047,124.406c0,132.656-90.703,203.734-161.703,194.875 c-33.188-4.125-24.891,8.297-20.75,24.875c4.156,16.594,42.391,48.813,103.656,37.313c47.031-8.813,81.469-40.531,102.031-74.5 c-5.547,49.063-6,126.344,46.281,126.344c52.266,0,51.813-77.313,46.266-126.344c20.547,33.969,55,65.688,102.016,74.5 c61.281,11.5,99.5-20.719,103.656-37.313C512.103,389.734,520.399,377.313,487.212,381.438z")
    private static let canImage = render("M171 42l-20 48h210l-20-48H171zm-19.45 65.55v296.9h208.9v-296.9h-208.9zM151 422l20 48h170l20-48H151z")
}
