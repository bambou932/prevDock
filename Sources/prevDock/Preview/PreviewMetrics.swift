import Cocoa

private extension PreviewWindowHeight {
    var scale: CGFloat {
        switch self {
        case .extraSmall:
            return 0.80
        case .small:
            return 0.90
        case .regular:
            return 1.00
        case .large:
            return 1.15
        case .extraLarge:
            return 1.30
        }
    }
}

enum PreviewMetrics {
    static let maxImageWidth: CGFloat = 520
    static let minimumReadableImageHeight: CGFloat = 96
    static let minAspectRatio: CGFloat = 0.30
    static let maxAspectRatio: CGFloat = 3.15
    static let panelPadding: CGFloat = 6
    static let cardContentPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 0
    static let maxVisiblePreviewRows = 3
    static let peekDelay: TimeInterval = 0
    static let cardHoverExitGrace: TimeInterval = 0.045
    static let scrollBarHeight: CGFloat = ceil(NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy))
    static let desktopGroupLabelHorizontalPadding: CGFloat = 14
    static let desktopGroupLabelTextSlack: CGFloat = 12
    static let desktopGroupHeaderSpacing: CGFloat = 4
    static let desktopGroupPadding: CGFloat = 5
    static let desktopGroupSpacing: CGFloat = 8

    static var minimumCardWidth: CGFloat {
        PreviewCardChromeLayout.minimumCardWidth(
            contentStyle: contentStyle,
            contentPadding: cardContentPadding
        )
    }

    static var desktopGroupLabelHeight: CGFloat {
        desktopGroupLabelHeight(for: PrevDockSettings.previewContentSize)
    }

    static var desktopGroupLabelFont: NSFont {
        desktopGroupLabelFont(for: PrevDockSettings.previewContentSize)
    }

    static var cardVerticalChrome: CGFloat {
        contentStyle.cardVerticalChrome
    }

    static var titleFontSize: CGFloat {
        contentStyle.titleFontSize
    }

    static var statusFontSize: CGFloat {
        contentStyle.statusFontSize
    }

    static var appIconSize: CGFloat {
        contentStyle.appIconSize
    }

    static func imageHeight(
        anchoredTo anchor: CGRect,
        windowHeight: PreviewWindowHeight = PrevDockSettings.previewWindowHeight
    ) -> CGFloat {
        let screen = ScreenGeometry.screen(containing: anchor) ?? NSScreen.main
        let screenHeight = screen?.frame.height ?? 1080
        let baseHeight = clamp(screenHeight * 0.15, min: 128, max: 260)
        let scaledHeight = baseHeight * windowHeight.scale
        return clamp(scaledHeight, min: minimumReadableImageHeight, max: 338)
    }

    static func cardVerticalChrome(for contentSize: PreviewContentSize) -> CGFloat {
        contentSize.style.cardVerticalChrome
    }

    static func desktopGroupLabelHeight(for contentSize: PreviewContentSize) -> CGFloat {
        max(18, ceil(contentSize.style.titleFontSize + 6))
    }

    static func desktopGroupLabelFont(for contentSize: PreviewContentSize) -> NSFont {
        .systemFont(ofSize: contentSize.style.titleFontSize, weight: .medium)
    }

    private static var contentStyle: PreviewContentStyle {
        PrevDockSettings.previewContentSize.style
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }
}

enum PreviewLayoutViews {
    static func makePreviewRow(views: [NSView] = []) -> NSStackView {
        PreviewPresentationLayout.makePreviewRow(views: views, spacing: PreviewMetrics.rowSpacing)
    }
}
