import CoreGraphics

enum PreviewSizing {
    struct ContentMetrics: Equatable {
        let cardVerticalChrome: CGFloat
        let titleFontSize: CGFloat
        let statusFontSize: CGFloat
        let appIconSize: CGFloat

        var desktopGroupLabelHeight: CGFloat {
            max(18, ceil(titleFontSize + 6))
        }
    }

    static let maximumImageWidth: CGFloat = 520
    static let minimumAspectRatio: CGFloat = 0.30
    static let maximumAspectRatio: CGFloat = 3.15
    static let cardContentPadding: CGFloat = 6
    static let panelPadding: CGFloat = 6
    static let desktopGroupPadding: CGFloat = 5
    static let desktopGroupHeaderSpacing: CGFloat = 4

    static func contentMetrics(for contentSize: PreviewContentSize) -> ContentMetrics {
        switch contentSize {
        case .extraSmall:
            return ContentMetrics(cardVerticalChrome: 24, titleFontSize: 12, statusFontSize: 10, appIconSize: 14)
        case .small:
            return ContentMetrics(cardVerticalChrome: 27, titleFontSize: 13, statusFontSize: 11, appIconSize: 16)
        case .regular:
            return ContentMetrics(cardVerticalChrome: 30, titleFontSize: 14, statusFontSize: 12, appIconSize: 18)
        case .large:
            return ContentMetrics(cardVerticalChrome: 34, titleFontSize: 16, statusFontSize: 13, appIconSize: 21)
        case .extraLarge:
            return ContentMetrics(cardVerticalChrome: 38, titleFontSize: 18, statusFontSize: 14, appIconSize: 24)
        }
    }

    static func windowHeightScale(for windowHeight: PreviewWindowHeight) -> CGFloat {
        switch windowHeight {
        case .extraSmall: return 0.80
        case .small: return 0.90
        case .regular: return 1.00
        case .large: return 1.15
        case .extraLarge: return 1.30
        }
    }

    static func imageHeight(screenHeight: CGFloat, windowHeight: PreviewWindowHeight) -> CGFloat {
        let resolvedScreenHeight = screenHeight.isFinite && screenHeight > 0 ? screenHeight : 1_080
        let baseHeight = clamp(resolvedScreenHeight * 0.15, minimum: 128, maximum: 260)
        return clamp(
            baseHeight * windowHeightScale(for: windowHeight),
            minimum: 96,
            maximum: 338
        )
    }

    static func previewPanelSize(
        contentSize: PreviewContentSize,
        windowHeight: PreviewWindowHeight,
        screenHeight: CGFloat,
        isGrouped: Bool,
        sourceAspectRatio: CGFloat = 2
    ) -> CGSize {
        let metrics = contentMetrics(for: contentSize)
        let imageHeight = imageHeight(screenHeight: screenHeight, windowHeight: windowHeight)
        let aspectRatio = clamp(sourceAspectRatio, minimum: minimumAspectRatio, maximum: maximumAspectRatio)
        let imageWidth = min(maximumImageWidth, imageHeight * aspectRatio)
        var width = imageWidth + cardContentPadding * 2
        var height = imageHeight + metrics.cardVerticalChrome + cardContentPadding * 2
        if isGrouped {
            width += desktopGroupPadding * 2
            height += metrics.desktopGroupLabelHeight + desktopGroupHeaderSpacing + desktopGroupPadding * 2
        }
        return CGSize(
            width: width + panelPadding * 2,
            height: height + panelPadding * 2
        )
    }

    static func maximumPreviewPanelSize(
        screenHeight: CGFloat,
        sourceAspectRatio: CGFloat = 2
    ) -> CGSize {
        previewPanelSize(
            contentSize: .extraLarge,
            windowHeight: .extraLarge,
            screenHeight: screenHeight,
            isGrouped: true,
            sourceAspectRatio: sourceAspectRatio
        )
    }

    static func stageHeight(
        screenHeight: CGFloat,
        dockImageSize: CGSize,
        edge: DockSnapshotEdge,
        sourceAspectRatio: CGFloat = 2
    ) -> CGFloat {
        reservedStageSize(
            screenHeight: screenHeight,
            dockImageSize: dockImageSize,
            edge: edge,
            sourceAspectRatio: sourceAspectRatio
        ).height
    }

    static func reservedStageSize(
        screenHeight: CGFloat,
        dockImageSize: CGSize,
        edge: DockSnapshotEdge,
        sourceAspectRatio: CGFloat = 2
    ) -> CGSize {
        let maximumPreviewSize = maximumPreviewPanelSize(
            screenHeight: screenHeight,
            sourceAspectRatio: sourceAspectRatio
        )
        let maximumSceneSize = SettingsPreviewStageLayout.sceneSize(
            previewSize: maximumPreviewSize,
            dockImageSize: dockImageSize,
            edge: edge
        )
        return CGSize(
            width: ceil(maximumSceneSize.width + SettingsPreviewStageLayout.stageInset * 2),
            height: ceil(maximumSceneSize.height + SettingsPreviewStageLayout.stageInset * 2)
        )
    }

    private static func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }
}
