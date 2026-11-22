import UIKit

/// Turns picked photos into request-ready JPEGs: at most 1600 px on the
/// long side, ~0.7 JPEG quality, metadata stripped (JPEG encoding drops
/// EXIF), and never more than 3 images per request. The sizing math is pure
/// so tests can pin it without constructing `UIImage`s.
enum AIImagePreparer {
    static let maxLongSide: CGFloat = 1_600
    static let jpegQuality: CGFloat = 0.7
    static let maxImages = 3

    /// The pixel size to render at: unchanged when already small enough,
    /// otherwise scaled down proportionally so the long side is `maxLongSide`.
    static func targetSize(
        for pixelSize: CGSize,
        maxLongSide: CGFloat = AIImagePreparer.maxLongSide
    ) -> CGSize {
        let width = pixelSize.width, height = pixelSize.height
        guard width > 0, height > 0 else { return .zero }
        let longSide = max(width, height)
        guard longSide > maxLongSide else { return pixelSize }
        let scale = maxLongSide / longSide
        return CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
    }

    /// Downscales one image and returns its JPEG payload. Nil when the image
    /// has no usable pixels.
    static func prepare(
        _ image: UIImage,
        maxLongSide: CGFloat = AIImagePreparer.maxLongSide,
        quality: CGFloat = AIImagePreparer.jpegQuality
    ) -> AIRequestImage? {
        let target = targetSize(for: pixelSize(of: image), maxLongSide: maxLongSide)
        guard target.width > 0, target.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: target)
        let data = renderer.jpegData(withCompressionQuality: quality) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard !data.isEmpty else { return nil }
        return AIRequestImage(jpeg: data)
    }

    /// Prepares up to `maxImages` images, dropping any that fail.
    static func prepareImages(
        _ images: [UIImage],
        maxImages: Int = AIImagePreparer.maxImages
    ) -> [AIRequestImage] {
        images.prefix(max(maxImages, 0)).compactMap { prepare($0) }
    }

    /// The true pixel dimensions — `UIImage.size` is in points, so multiply
    /// by `scale` (or trust the CGImage when there is one).
    private static func pixelSize(of image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
    }
}
