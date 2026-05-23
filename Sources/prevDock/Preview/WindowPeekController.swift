import Cocoa
import QuartzCore

final class WindowPeekController {
    static let shared = WindowPeekController()

    private static let peekLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
    private static let dimmingLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 2)

    private let panel: NSPanel
    private let imageView = WindowPeekImageView()
    private var dimmingPanels = [NSPanel]()
    private var liveRefreshWorkItem: DispatchWorkItem?
    private var currentWindowID: CGWindowID?
    private var currentPreview: WindowPreview?
    private var isLiveRefreshActive = false
    private var isLiveRefreshCaptureInFlight = false
    private var liveRefreshGeneration = 0
    private var liveImageUpdateHandler: ((CGWindowID, NSImage) -> Void)?

    var isShowingLivePreview: Bool {
        isLiveRefreshActive && currentWindowID != nil
    }

    private init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = Self.peekLevel
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let container = NSView()

        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        panel.contentView = container
    }

    func setLiveImageUpdateHandler(_ handler: @escaping (CGWindowID, NSImage) -> Void) {
        liveImageUpdateHandler = handler
    }

    func show(preview: WindowPreview) {
        if preview.isFullscreen {
            hide()
            return
        }

        guard !preview.isMinimized,
              preview.bounds.width >= 80,
              preview.bounds.height >= 60 else {
            hide(windowID: preview.windowID)
            return
        }

        let frame = LivePreviewCadence.appKitFrame(fromWindowBounds: preview.bounds)
        guard frame.width >= 80, frame.height >= 60 else { return }

        let windowChanged = currentWindowID != preview.windowID
        let needsOrdering = currentWindowID != preview.windowID ||
            !panel.isVisible ||
            dimmingPanels.contains { !$0.isVisible }
        if windowChanged {
            stopLiveRefresh()
            if preview.image == nil {
                clearVisiblePeek()
            }
        }
        currentWindowID = preview.windowID
        currentPreview = preview
        if let image = preview.image {
            show(image: image, frame: frame, windowID: preview.windowID, orderFront: needsOrdering)
        }

        startLiveRefreshIfNeeded()
    }

    func hide(windowID: CGWindowID? = nil) {
        if let windowID, currentWindowID != windowID {
            return
        }
        guard currentWindowID != nil || panel.isVisible || dimmingPanels.contains(where: \.isVisible) else {
            return
        }
        stopLiveRefresh()
        currentWindowID = nil
        currentPreview = nil
        performWithoutAnimation {
            hideDimmingPanels()
            panel.orderOut(nil)
        }
    }

    private func startLiveRefreshIfNeeded() {
        guard !isLiveRefreshActive else { return }
        isLiveRefreshActive = true
        refreshCurrentPreview()
    }

    private func stopLiveRefresh() {
        isLiveRefreshActive = false
        isLiveRefreshCaptureInFlight = false
        liveRefreshGeneration += 1
        liveRefreshWorkItem?.cancel()
        liveRefreshWorkItem = nil
    }

    private func refreshCurrentPreview() {
        guard isLiveRefreshActive,
              !isLiveRefreshCaptureInFlight,
              let preview = currentPreview,
              currentWindowID == preview.windowID else {
            return
        }

        let generation = liveRefreshGeneration
        isLiveRefreshCaptureInFlight = true
        WindowInventory.captureFreshThumbnail(for: preview) { [weak self] image in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.isLiveRefreshCaptureInFlight = false
                guard self.isLiveRefreshActive,
                      self.liveRefreshGeneration == generation,
                      self.currentWindowID == preview.windowID else {
                    return
                }
                if let image {
                    self.show(
                        image: image,
                        frame: LivePreviewCadence.appKitFrame(fromWindowBounds: preview.bounds),
                        windowID: preview.windowID,
                        orderFront: false
                    )
                    self.liveImageUpdateHandler?(preview.windowID, image)
                }
                self.scheduleNextLiveRefresh(for: preview)
            }
        }
    }

    private func scheduleNextLiveRefresh(for preview: WindowPreview) {
        liveRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshCurrentPreview()
        }
        liveRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + LivePreviewCadence.interval(forWindowBounds: preview.bounds),
            execute: item
        )
    }

    private func show(image: NSImage, frame: NSRect, windowID: CGWindowID, orderFront: Bool) {
        performWithoutAnimation {
            imageView.update(image: image, windowID: windowID)
            syncDimmingPanels(orderFront: orderFront)
            if frameNeedsUpdate(panel.frame, frame) {
                panel.setFrame(frame, display: false, animate: false)
            }
            if orderFront || !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
    }

    private func syncDimmingPanels(orderFront: Bool) {
        let screens = NSScreen.screens
        var shouldOrderFront = orderFront
        if dimmingPanels.count != screens.count {
            dimmingPanels.forEach { $0.orderOut(nil) }
            dimmingPanels = screens.map { _ in makeDimmingPanel() }
            shouldOrderFront = true
        }

        for (screen, dimmingPanel) in zip(screens, dimmingPanels) {
            if frameNeedsUpdate(dimmingPanel.frame, screen.frame) {
                dimmingPanel.setFrame(screen.frame, display: false, animate: false)
            }
            if shouldOrderFront || !dimmingPanel.isVisible {
                dimmingPanel.orderFrontRegardless()
            }
        }
    }

    private func frameNeedsUpdate(_ current: NSRect, _ next: NSRect) -> Bool {
        abs(current.minX - next.minX) > 0.5 ||
            abs(current.minY - next.minY) > 0.5 ||
            abs(current.width - next.width) > 0.5 ||
            abs(current.height - next.height) > 0.5
    }

    private func hideDimmingPanels() {
        dimmingPanels.forEach { $0.orderOut(nil) }
    }

    private func clearVisiblePeek() {
        performWithoutAnimation {
            imageView.clear()
            hideDimmingPanels()
            panel.orderOut(nil)
        }
    }

    private func makeDimmingPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.dimmingLevel
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let dimmingView = NSView()
        dimmingView.wantsLayer = true
        dimmingView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        panel.contentView = dimmingView
        return panel
    }

    private func performWithoutAnimation(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            updates()
        }
        CATransaction.commit()
    }

}

private final class WindowPeekImageView: NSView {
    private static let outlineWidth: CGFloat = 2
    private static let outlineColor = PrevDockColors.highlight(alpha: 0.9)

    private var image: NSImage?
    private var windowID: CGWindowID?
    private var cachedOutline: CachedWindowPeekOutline?

    override var isFlipped: Bool {
        true
    }

    func update(image: NSImage, windowID: CGWindowID) {
        if self.windowID != windowID {
            cachedOutline = nil
        }
        self.windowID = windowID
        self.image = image
        needsDisplay = true
    }

    func clear() {
        image = nil
        windowID = nil
        cachedOutline = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image else { return }

        image.draw(
            in: bounds,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        drawOutline(for: image)
    }

    private func drawOutline(for image: NSImage) {
        guard let outline = outlineImage(for: image) else {
            drawFallbackOutline()
            return
        }
        outline.draw(
            in: bounds,
            from: NSRect(origin: .zero, size: outline.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func outlineImage(for image: NSImage) -> NSImage? {
        guard bounds.width > 0,
              bounds.height > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let borderPixels = borderPixels(for: cgImage)
        let key = WindowPeekOutlineKey(
            windowID: windowID,
            width: cgImage.width,
            height: cgImage.height,
            borderPixels: borderPixels
        )
        if let cachedOutline, cachedOutline.key == key {
            return cachedOutline.image
        }

        guard let outline = WindowPeekOutlineFactory.makeOutline(
            from: cgImage,
            borderPixels: borderPixels,
            color: Self.outlineColor
        ) else {
            return nil
        }

        let image = NSImage(cgImage: outline, size: image.size)
        cachedOutline = CachedWindowPeekOutline(key: key, image: image)
        return image
    }

    private func borderPixels(for image: CGImage) -> Int {
        let scaleX = CGFloat(image.width) / max(bounds.width, 1)
        let scaleY = CGFloat(image.height) / max(bounds.height, 1)
        return max(1, Int((Self.outlineWidth * max(scaleX, scaleY)).rounded(.up)))
    }

    private func drawFallbackOutline() {
        let rect = bounds.insetBy(dx: Self.outlineWidth / 2, dy: Self.outlineWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.lineWidth = Self.outlineWidth
        Self.outlineColor.setStroke()
        path.stroke()
    }
}

private struct CachedWindowPeekOutline {
    let key: WindowPeekOutlineKey
    let image: NSImage
}

private struct WindowPeekOutlineKey: Equatable {
    let windowID: CGWindowID?
    let width: Int
    let height: Int
    let borderPixels: Int
}

private enum WindowPeekOutlineFactory {
    private static let alphaThreshold: UInt8 = 32

    static func makeOutline(from image: CGImage, borderPixels: Int, color: NSColor) -> CGImage? {
        guard image.width > 0,
              image.height > 0,
              let alpha = alphaBytes(from: image) else {
            return nil
        }

        let color = RGBAColor(color)
        let width = image.width
        let height = image.height
        var output = [UInt8](repeating: 0, count: width * height * 4)
        paintOutline(alpha: alpha, output: &output, width: width, height: height, borderPixels: borderPixels, color: color)
        return makeImage(bytes: output, width: width, height: height)
    }

    private static func alphaBytes(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let didDraw = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in 0..<alpha.count {
            alpha[index] = rgba[index * 4 + 3]
        }
        return alpha
    }

    private static func paintOutline(
        alpha: [UInt8],
        output: inout [UInt8],
        width: Int,
        height: Int,
        borderPixels: Int,
        color: RGBAColor
    ) {
        let radiusSquared = borderPixels * borderPixels
        for y in 0..<height {
            for x in 0..<width where isEdgePixel(x: x, y: y, width: width, height: height, alpha: alpha) {
                paintEdgePixel(
                    x: x,
                    y: y,
                    alpha: alpha,
                    output: &output,
                    width: width,
                    height: height,
                    borderPixels: borderPixels,
                    radiusSquared: radiusSquared,
                    color: color
                )
            }
        }
    }

    private static func paintEdgePixel(
        x: Int,
        y: Int,
        alpha: [UInt8],
        output: inout [UInt8],
        width: Int,
        height: Int,
        borderPixels: Int,
        radiusSquared: Int,
        color: RGBAColor
    ) {
        let minY = max(0, y - borderPixels)
        let maxY = min(height - 1, y + borderPixels)
        let minX = max(0, x - borderPixels)
        let maxX = min(width - 1, x + borderPixels)

        for targetY in minY...maxY {
            for targetX in minX...maxX {
                let dx = targetX - x
                let dy = targetY - y
                guard dx * dx + dy * dy <= radiusSquared else { continue }
                paintIfInside(x: targetX, y: targetY, alpha: alpha, output: &output, width: width, color: color)
            }
        }
    }

    private static func paintIfInside(
        x: Int,
        y: Int,
        alpha: [UInt8],
        output: inout [UInt8],
        width: Int,
        color: RGBAColor
    ) {
        let pixelIndex = y * width + x
        let sourceAlpha = alpha[pixelIndex]
        guard sourceAlpha > alphaThreshold else { return }

        let outputAlpha = UInt8((UInt16(sourceAlpha) * UInt16(color.alpha)) / 255)
        let outputIndex = pixelIndex * 4
        guard outputAlpha > output[outputIndex + 3] else { return }

        output[outputIndex] = UInt8((UInt16(color.red) * UInt16(outputAlpha)) / 255)
        output[outputIndex + 1] = UInt8((UInt16(color.green) * UInt16(outputAlpha)) / 255)
        output[outputIndex + 2] = UInt8((UInt16(color.blue) * UInt16(outputAlpha)) / 255)
        output[outputIndex + 3] = outputAlpha
    }

    private static func isEdgePixel(x: Int, y: Int, width: Int, height: Int, alpha: [UInt8]) -> Bool {
        let index = y * width + x
        guard alpha[index] > alphaThreshold else { return false }
        if x == 0 || y == 0 || x == width - 1 || y == height - 1 { return true }
        return alpha[index - 1] <= alphaThreshold ||
            alpha[index + 1] <= alphaThreshold ||
            alpha[index - width] <= alphaThreshold ||
            alpha[index + width] <= alphaThreshold
    }

    private static func makeImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

private struct RGBAColor {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(_ color: NSColor) {
        let color = color.usingColorSpace(.deviceRGB) ?? NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
        red = Self.byte(color.redComponent)
        green = Self.byte(color.greenComponent)
        blue = Self.byte(color.blueComponent)
        alpha = Self.byte(color.alphaComponent)
    }

    private static func byte(_ component: CGFloat) -> UInt8 {
        UInt8(max(0, min(255, (component * 255).rounded())))
    }
}
