import UIKit

enum AvatarImage {
    /// Centre-crops to a square and encodes a 720×720 JPEG data URL.
    /// The server does the same crop, so the preview matches what it stores.
    static func jpegDataURL(from data: Data) throws -> String {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw ClientError.badResponse("这张图片无法解码，请换一张 JPG、PNG 或 GIF。")
        }
        let side: CGFloat = 720
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let jpeg = renderer.jpegData(withCompressionQuality: 0.88) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let scale = side / min(image.size.width, image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = CGRect(
                x: (side - drawn.width) / 2,
                y: (side - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            )
            image.draw(in: rect)
        }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }
}
