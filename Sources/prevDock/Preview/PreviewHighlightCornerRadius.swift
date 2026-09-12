import Cocoa

struct PreviewHighlightCornerRadiusKey: Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    let displayWidth: Int
    let displayHeight: Int
}

enum PreviewHighlightCornerRadius {
    private static let alphaThreshold: UInt8 = 32
    private static let maxSampleDimension = 768

    static func estimate(from image: CGImage, displayedSize: NSSize, padding: CGFloat, fallback: CGFloat) -> CGFloat {
        guard displayedSize.width > 0,
              displayedSize.height > 0,
              let sample = alphaSample(from: image) else {
            return fallback
        }

        let leftRadius = estimatedRadius(in: sample, fromLeft: true)
        let rightRadius = estimatedRadius(in: sample, fromLeft: false)
        let sampleRadius = max(leftRadius, rightRadius)
        guard sampleRadius > 1 else { return fallback }

        let displayScale = displayedSize.width / CGFloat(sample.width)
        let maxRadius = min(displayedSize.width, displayedSize.height) * 0.18 + padding
        let radius = CGFloat(sampleRadius) * displayScale + padding
        return clamp(radius, min: fallback, max: max(fallback, maxRadius))
    }

    private static func estimatedRadius(in sample: PreviewAlphaSample, fromLeft: Bool) -> Int {
        let scanWidth = min(max(1, sample.width / 3), 96)
        let scanHeight = min(max(1, sample.height / 3), 96)
        var maxTransparentRun = 0

        for yOffset in 0..<scanHeight {
            var transparentRun = 0
            for xOffset in 0..<scanWidth {
                let x = fromLeft ? xOffset : sample.width - 1 - xOffset
                if sample.alpha[yOffset * sample.width + x] > alphaThreshold {
                    break
                }
                transparentRun += 1
            }
            maxTransparentRun = max(maxTransparentRun, transparentRun)
        }
        return maxTransparentRun
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }

    private static func alphaSample(from image: CGImage) -> PreviewAlphaSample? {
        let size = sampleSize(for: image)
        let bytesPerRow = size.width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let didDraw = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: size.width,
                      height: size.height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            return true
        }
        guard didDraw else { return nil }

        var alpha = [UInt8](repeating: 0, count: size.width * size.height)
        for index in 0..<alpha.count {
            alpha[index] = rgba[index * 4 + 3]
        }
        return PreviewAlphaSample(width: size.width, height: size.height, alpha: alpha)
    }

    private static func sampleSize(for image: CGImage) -> (width: Int, height: Int) {
        let maxDimension = max(image.width, image.height)
        guard maxDimension > maxSampleDimension else {
            return (max(1, image.width), max(1, image.height))
        }

        let scale = CGFloat(maxSampleDimension) / CGFloat(maxDimension)
        return (
            max(1, Int((CGFloat(image.width) * scale).rounded())),
            max(1, Int((CGFloat(image.height) * scale).rounded()))
        )
    }
}

private struct PreviewAlphaSample {
    let width: Int
    let height: Int
    let alpha: [UInt8]
}
