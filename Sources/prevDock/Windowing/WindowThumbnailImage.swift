import Cocoa

enum WindowThumbnailImage {
    static func downscaled(_ source: NSImage, maximumPixelDimension: Int) -> NSImage {
        guard maximumPixelDimension > 0,
              let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return source
        }
        let largestDimension = max(image.width, image.height)
        guard largestDimension > maximumPixelDimension else { return source }

        let scale = CGFloat(maximumPixelDimension) / CGFloat(largestDimension)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return source
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaledImage = context.makeImage() else { return source }
        return NSImage(cgImage: scaledImage, size: source.size)
    }

    static func hasUsableWindowAlpha(_ source: NSImage) -> Bool {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        let width = 12
        let height = 12
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var alphaTotal = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[index + 3]
            alphaTotal += Int(a)
        }
        return alphaTotal >= width * height * 8
    }
}
