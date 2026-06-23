import AppKit
import CoreImage

/// Renders arbitrary strings (typically proxy share links) into crisp QR-code images.
///
/// The generator uses CoreImage's `CIQRCodeGenerator`, which produces a tiny
/// 1-module-per-pixel image; that raw output is scaled up with a nearest-neighbour
/// affine transform so the rendered code stays sharp at the requested size rather
/// than being blurrily up-sampled by the view layer.
enum QRCodeGenerator {

    /// Render `string` to a crisp QR-code `NSImage` of approximately `size` points.
    ///
    /// - Parameters:
    ///   - string: The payload to encode (encoded as UTF-8).
    ///   - size: The desired output edge length, in points. Defaults to 220.
    /// - Returns: A square `NSImage`, or `nil` if `string` is empty or generation fails.
    static func image(from string: String, size: CGFloat = 220) -> NSImage? {
        guard !string.isEmpty else { return nil }

        let data = Data(string.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { return nil }

        // Scale the (small) generated image up to the target pixel size crisply.
        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = max(1, size / extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
