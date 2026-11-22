import Foundation
import CoreGraphics

public enum ImageCrop {
    /// Center crop for live-view zoom. Zoom is an integer factor (1, 2, 4).
    public static func centerCrop(_ image: CGImage, zoom: Int) -> CGImage? {
        guard zoom > 1 else { return image }
        let width = max(1, image.width / zoom)
        let height = max(1, image.height / zoom)
        let rect = CGRect(x: (image.width - width) / 2,
                          y: (image.height - height) / 2,
                          width: width,
                          height: height)
        return image.cropping(to: rect)
    }
}
