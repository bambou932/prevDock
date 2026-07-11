import CoreGraphics
import Darwin
import Foundation

@main
enum SettingsPreviewStageLayoutTests {
    private static let epsilon: CGFloat = 0.000_1
    private static let referenceScreenHeight: CGFloat = 1_440
    private static var assertionCount = 0
    private static var layoutCount = 0

    static func main() {
        testFixedLayoutConstants()
        testActualPreviewSizingAndGrouping()
        testEveryPreviewSizeAndGroupingCombination()
        testCompactReservedStageSizes()
        testShortAndLongDockFragments()
        testUltraShortDockLeavesTransparentRemainder()
        testNonZeroStageOrigin()
        testCropGeometryAtOneAndTwoTimesScale()
        testMixedScaleAndNegativeDisplayOrigin()
        testFractionalCropGeometry()
        testQuartzAndAppKitEdgeDetection()
        testHiddenDockEdgeDetectionUsesLongAxis()
        testWindowCandidateSelection()
        testAlphaValidationAndTightCrop()
        testCropClampAndInvalidGeometry()
        testScreenFrameKeyTracksDisplayOrigin()
        print("Preview size stage tests passed: \(layoutCount) layouts, \(assertionCount) assertions")
    }

    private static func testFixedLayoutConstants() {
        expectEqual(SettingsPreviewStageLayout.stageInset, 12, "stage inset must remain 12pt")
        expectEqual(SettingsPreviewStageLayout.dockGap, 4, "preview-to-Dock gap must remain 4pt")
    }

    private static func testActualPreviewSizingAndGrouping() {
        let minimumGrouped = PreviewSizing.previewPanelSize(
            contentSize: .extraSmall,
            windowHeight: .extraSmall,
            screenHeight: referenceScreenHeight,
            isGrouped: true
        )
        let maximumGrouped = PreviewSizing.maximumPreviewPanelSize(
            screenHeight: referenceScreenHeight
        )
        expectSize(minimumGrouped, equals: CGSize(width: 379.6, height: 252.8))
        expectSize(maximumGrouped, equals: CGSize(width: 554, height: 380.8))

        for contentSize in PreviewContentSize.allCases {
            let expectedHeightDelta = expectedGroupingHeightDelta(for: contentSize)
            for windowHeight in PreviewWindowHeight.allCases {
                let grouped = PreviewSizing.previewPanelSize(
                    contentSize: contentSize,
                    windowHeight: windowHeight,
                    screenHeight: referenceScreenHeight,
                    isGrouped: true
                )
                let ungrouped = PreviewSizing.previewPanelSize(
                    contentSize: contentSize,
                    windowHeight: windowHeight,
                    screenHeight: referenceScreenHeight,
                    isGrouped: false
                )
                expectEqual(grouped.width - ungrouped.width, 10, "actual grouping width delta")
                expectEqual(grouped.height - ungrouped.height, expectedHeightDelta, "actual grouping height delta")
            }
        }
    }

    private static func testEveryPreviewSizeAndGroupingCombination() {
        for contentSize in PreviewContentSize.allCases {
            for windowHeight in PreviewWindowHeight.allCases {
                for isGrouped in [false, true] {
                    let previewSize = PreviewSizing.previewPanelSize(
                        contentSize: contentSize,
                        windowHeight: windowHeight,
                        screenHeight: referenceScreenHeight,
                        isGrouped: isGrouped
                    )
                    for edge in DockSnapshotEdge.allCases {
                        let shortGeometry = geometry(edge: edge, isLong: false)
                        verifyLayout(
                            stageBounds: reservedStageBounds(for: shortGeometry),
                            previewSize: previewSize,
                            geometry: shortGeometry
                        )
                        let longGeometry = geometry(edge: edge, isLong: true)
                        verifyLayout(
                            stageBounds: reservedStageBounds(for: longGeometry),
                            previewSize: previewSize,
                            geometry: longGeometry
                        )
                    }
                }
            }
        }

        expect(layoutCount == 400, "expected 25 sizes x 2 grouping states x 4 edges x 2 Dock lengths")
    }

    private static func testCompactReservedStageSizes() {
        let horizontal = geometry(edge: .bottom, isLong: false)
        let vertical = geometry(edge: .left, isLong: false)
        expectSize(reservedStageBounds(for: horizontal).size, equals: CGSize(width: 578, height: 501))
        expectSize(reservedStageBounds(for: vertical).size, equals: CGSize(width: 674, height: 405))
        for edge in DockSnapshotEdge.allCases {
            let short = geometry(edge: edge, isLong: false)
            let long = geometry(edge: edge, isLong: true)
            expectSize(
                reservedStageBounds(for: short).size,
                equals: reservedStageBounds(for: long).size
            )
            expectEqual(
                PreviewSizing.stageHeight(
                    screenHeight: referenceScreenHeight,
                    dockImageSize: short.imageSize,
                    edge: edge
                ),
                reservedStageBounds(for: short).height,
                "stageHeight compatibility"
            )
        }
    }

    private static func testShortAndLongDockFragments() {
        let previewSize = PreviewSizing.maximumPreviewPanelSize(
            screenHeight: referenceScreenHeight
        )
        for isLong in [false, true] {
            for edge in DockSnapshotEdge.allCases {
                let geometry = geometry(edge: edge, isLong: isLong)
                let result = SettingsPreviewStageLayout.calculate(
                    stageBounds: reservedStageBounds(for: geometry),
                    previewSize: previewSize,
                    dockImageSize: geometry.imageSize,
                    geometry: geometry
                )
                switch edge {
                case .bottom, .top:
                    expectRect(
                        result.dockSourceVisibleRect,
                        equals: CGRect(x: 0, y: 0, width: previewSize.width, height: geometry.imageSize.height)
                    )
                case .left, .right:
                    expectRect(
                        result.dockSourceVisibleRect,
                        equals: CGRect(
                            x: 0,
                            y: geometry.imageSize.height - previewSize.height,
                            width: geometry.imageSize.width,
                            height: previewSize.height
                        )
                    )
                }
            }
        }
    }

    private static func testUltraShortDockLeavesTransparentRemainder() {
        let previewSize = PreviewSizing.maximumPreviewPanelSize(
            screenHeight: referenceScreenHeight
        )
        for edge in DockSnapshotEdge.allCases {
            let geometry = ultraShortGeometry(edge: edge)
            let result = SettingsPreviewStageLayout.calculate(
                stageBounds: reservedStageBounds(for: geometry),
                previewSize: previewSize,
                dockImageSize: geometry.imageSize,
                geometry: geometry
            )
            let sourceBounds = CGRect(origin: .zero, size: geometry.imageSize)

            expectSize(result.dockImageFrame.size, equals: geometry.imageSize)
            expectContains(sourceBounds, result.dockSourceVisibleRect, "ultra-short source must remain in bounds")
            switch edge {
            case .bottom, .top:
                expectEqual(result.dockVisibleRect.width, previewSize.width, "ultra-short horizontal comparison span")
                expectEqual(result.previewFrame.minX, result.dockVisibleRect.minX, "ultra-short horizontal shared minX")
                expectEqual(result.previewFrame.maxX, result.dockVisibleRect.maxX, "ultra-short horizontal shared maxX")
                expectRect(result.dockSourceVisibleRect, equals: sourceBounds)
                expect(result.dockSourceVisibleRect.width < result.dockVisibleRect.width, "horizontal remainder must stay transparent")
                expectEqual(result.dockImageFrame.minX, result.dockVisibleRect.minX, "horizontal ultra-short leading placement")
            case .left, .right:
                expectEqual(result.dockVisibleRect.height, previewSize.height, "ultra-short vertical comparison span")
                expectEqual(result.previewFrame.minY, result.dockVisibleRect.minY, "ultra-short vertical shared minY")
                expectEqual(result.previewFrame.maxY, result.dockVisibleRect.maxY, "ultra-short vertical shared maxY")
                expectRect(result.dockSourceVisibleRect, equals: sourceBounds)
                expect(result.dockSourceVisibleRect.height < result.dockVisibleRect.height, "vertical remainder must stay transparent")
                expectEqual(result.dockImageFrame.maxY, result.dockVisibleRect.maxY, "vertical ultra-short top placement")
            }
        }
    }

    private static func testNonZeroStageOrigin() {
        for edge in DockSnapshotEdge.allCases {
            let geometry = geometry(edge: edge, isLong: true)
            let reservedBounds = reservedStageBounds(for: geometry)
            let stageBounds = CGRect(
                x: -430,
                y: 180,
                width: reservedBounds.width,
                height: reservedBounds.height
            )
            let contentRect = stageBounds.insetBy(dx: 12, dy: 12)
            let result = SettingsPreviewStageLayout.calculate(
                stageBounds: stageBounds,
                previewSize: PreviewSizing.maximumPreviewPanelSize(
                    screenHeight: referenceScreenHeight
                ),
                dockImageSize: geometry.imageSize,
                geometry: geometry
            )
            expectEqual(result.sceneFrame.midX, stageBounds.midX, "offset scene center X")
            expectEqual(result.sceneFrame.midY, stageBounds.midY, "offset scene center Y")
            expectContains(contentRect, result.sceneFrame, "scene must respect an offset stage's inset")
            expectContains(contentRect, result.previewFrame, "preview must respect an offset stage's inset")
            expectContains(contentRect, result.dockVisibleRect, "visible Dock must respect an offset stage's inset")
        }
    }

    private static func testCropGeometryAtOneAndTwoTimesScale() {
        let windowBounds = CGRect(x: 0, y: 0, width: 1_000, height: 160)
        let dockRect = CGRect(x: 8, y: 72, width: 900, height: 80)
        let finderRect = CGRect(x: 18, y: 80, width: 64, height: 64)
        let oneX = requireCropGeometry(
            windowBounds: windowBounds,
            dockRect: dockRect,
            finderRect: finderRect,
            imagePixelSize: windowBounds.size,
            edge: .bottom
        )
        let twoX = requireCropGeometry(
            windowBounds: windowBounds,
            dockRect: dockRect,
            finderRect: finderRect,
            imagePixelSize: CGSize(width: 2_000, height: 320),
            edge: .bottom
        )

        expectEqual(oneX.scaleX, 1, "1x horizontal scale")
        expectEqual(oneX.scaleY, 1, "1x vertical scale")
        expectEqual(twoX.scaleX, 2, "2x horizontal scale")
        expectEqual(twoX.scaleY, 2, "2x vertical scale")
        expectRect(oneX.pointCropRect, equals: twoX.pointCropRect)
        expectSize(oneX.geometry.imageSize, equals: twoX.geometry.imageSize)
        expectRect(oneX.geometry.dockRectInImage, equals: twoX.geometry.dockRectInImage)
        expectRect(oneX.geometry.finderRectInImage, equals: twoX.geometry.finderRectInImage)
        expectEqual(twoX.pixelCropRect.minX, oneX.pixelCropRect.minX * 2, "2x crop minX")
        expectEqual(twoX.pixelCropRect.minY, oneX.pixelCropRect.minY * 2, "2x crop minY")
        expectEqual(twoX.pixelCropRect.width, oneX.pixelCropRect.width * 2, "2x crop width")
        expectEqual(twoX.pixelCropRect.height, oneX.pixelCropRect.height * 2, "2x crop height")

        let stageBounds = reservedStageBounds(for: oneX.geometry)
        let previewSize = PreviewSizing.maximumPreviewPanelSize(
            screenHeight: referenceScreenHeight
        )
        let oneXLayout = SettingsPreviewStageLayout.calculate(
            stageBounds: stageBounds,
            previewSize: previewSize,
            dockImageSize: oneX.geometry.imageSize,
            geometry: oneX.geometry
        )
        let twoXLayout = SettingsPreviewStageLayout.calculate(
            stageBounds: stageBounds,
            previewSize: previewSize,
            dockImageSize: twoX.geometry.imageSize,
            geometry: twoX.geometry
        )
        expectRect(oneXLayout.dockImageFrame, equals: twoXLayout.dockImageFrame)
        expectRect(oneXLayout.dockSourceVisibleRect, equals: twoXLayout.dockSourceVisibleRect)
    }

    private static func testMixedScaleAndNegativeDisplayOrigin() {
        let windowBounds = CGRect(x: -1_512, y: 100, width: 1_000, height: 160)
        let dockRect = CGRect(x: -1_504, y: 172, width: 900, height: 80)
        let finderRect = CGRect(x: -1_494, y: 180, width: 64, height: 64)
        let oneX = requireCropGeometry(
            windowBounds: windowBounds,
            dockRect: dockRect,
            finderRect: finderRect,
            imagePixelSize: windowBounds.size,
            edge: .bottom
        )
        let mixed = requireCropGeometry(
            windowBounds: windowBounds,
            dockRect: dockRect,
            finderRect: finderRect,
            imagePixelSize: CGSize(width: 2_000, height: 160),
            edge: .bottom
        )

        expectEqual(mixed.scaleX, 2, "mixed scale X")
        expectEqual(mixed.scaleY, 1, "mixed scale Y")
        expectRect(oneX.pointCropRect, equals: mixed.pointCropRect)
        expectRect(oneX.geometry.dockRectInImage, equals: mixed.geometry.dockRectInImage)
        expectRect(oneX.geometry.finderRectInImage, equals: mixed.geometry.finderRectInImage)
    }

    private static func testFractionalCropGeometry() {
        let crop = requireCropGeometry(
            windowBounds: CGRect(x: -100.25, y: 50.5, width: 200, height: 100),
            dockRect: CGRect(x: -95.1, y: 110.2, width: 160.25, height: 35.35),
            finderRect: CGRect(x: -90.4, y: 115.75, width: 25.2, height: 24.1),
            imagePixelSize: CGSize(width: 300, height: 200),
            edge: .bottom
        )
        expectEqual(crop.scaleX, 1.5, "fractional crop scale X")
        expectEqual(crop.scaleY, 2, "fractional crop scale Y")
        expectRect(crop.pixelCropRect, equals: CGRect(x: 0, y: 103, width: 261, height: 97))
        expectRect(crop.pointCropRect, equals: CGRect(x: -100.25, y: 102, width: 174, height: 48.5))
        expectRect(
            crop.geometry.dockRectInImage,
            equals: CGRect(x: 5.15, y: 4.95, width: 160.25, height: 35.35)
        )
        expectRect(
            crop.geometry.finderRectInImage,
            equals: CGRect(x: 9.85, y: 10.65, width: 25.2, height: 24.1)
        )
    }

    private static func testQuartzAndAppKitEdgeDetection() {
        let frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        expect(DockSnapshotGeometryCalculator.edge(for: CGRect(x: 200, y: 0, width: 600, height: 80), in: frame) == .bottom, "AppKit bottom edge")
        expect(DockSnapshotGeometryCalculator.edge(for: CGRect(x: 200, y: 720, width: 600, height: 80), in: frame) == .top, "AppKit top edge")
        expect(DockSnapshotGeometryCalculator.edge(for: CGRect(x: 0, y: 120, width: 80, height: 560), in: frame) == .left, "AppKit left edge")
        expect(DockSnapshotGeometryCalculator.edge(for: CGRect(x: 920, y: 120, width: 80, height: 560), in: frame) == .right, "AppKit right edge")
        expect(DockSnapshotGeometryCalculator.edge(forQuartzDockRect: CGRect(x: 200, y: 720, width: 600, height: 80), in: frame) == .bottom, "Quartz bottom edge")
        expect(DockSnapshotGeometryCalculator.edge(forQuartzDockRect: CGRect(x: 200, y: 0, width: 600, height: 80), in: frame) == .top, "Quartz top edge")
        expect(DockSnapshotGeometryCalculator.edge(forQuartzDockRect: CGRect(x: 0, y: 120, width: 80, height: 560), in: frame) == .left, "Quartz left edge")
        expect(DockSnapshotGeometryCalculator.edge(forQuartzDockRect: CGRect(x: 920, y: 120, width: 80, height: 560), in: frame) == .right, "Quartz right edge")
    }

    private static func testHiddenDockEdgeDetectionUsesLongAxis() {
        let screen = CGRect(x: 2_560, y: 233, width: 1_512, height: 982)
        let hiddenRight = CGRect(x: 4_072, y: 292, width: 47, height: 897)
        let hiddenLeft = CGRect(x: 2_513, y: 292, width: 47, height: 897)
        let hiddenAppKitBottom = CGRect(x: 2_586, y: 186, width: 1_460, height: 47)
        let hiddenAppKitTop = CGRect(x: 2_586, y: 1_215, width: 1_460, height: 47)
        let hiddenQuartzTop = hiddenAppKitBottom
        let hiddenQuartzBottom = hiddenAppKitTop

        expect(
            DockSnapshotGeometryCalculator.edge(for: hiddenRight, in: screen) == .right,
            "AppKit hidden right Dock must follow its vertical long axis"
        )
        expect(
            DockSnapshotGeometryCalculator.edge(for: hiddenLeft, in: screen) == .left,
            "AppKit hidden left Dock must follow its vertical long axis"
        )
        expect(
            DockSnapshotGeometryCalculator.edge(for: hiddenAppKitBottom, in: screen) == .bottom,
            "AppKit hidden bottom Dock must ignore a closer side distance"
        )
        expect(
            DockSnapshotGeometryCalculator.edge(for: hiddenAppKitTop, in: screen) == .top,
            "AppKit hidden top Dock must ignore a closer side distance"
        )
        expect(
            DockSnapshotGeometryCalculator.edge(forQuartzDockRect: hiddenRight, in: screen) == .right,
            "Quartz hidden right Dock must follow its vertical long axis"
        )
        expect(
            DockSnapshotGeometryCalculator.edge(forQuartzDockRect: hiddenLeft, in: screen) == .left,
            "Quartz hidden left Dock must follow its vertical long axis"
        )
        expect(
            DockSnapshotGeometryCalculator.edge(forQuartzDockRect: hiddenQuartzBottom, in: screen) == .bottom,
            "Quartz hidden bottom Dock must ignore a closer side distance"
        )
        expect(
            DockSnapshotGeometryCalculator.edge(forQuartzDockRect: hiddenQuartzTop, in: screen) == .top,
            "Quartz hidden top Dock must ignore a closer side distance"
        )
    }

    private static func testWindowCandidateSelection() {
        let dockRect = CGRect(x: 100, y: 0, width: 700, height: 90)
        let dockPID: Int32 = 42
        let candidates = [
            DockSnapshotWindowCandidate(
                windowID: 1,
                ownerPID: dockPID,
                layer: 10,
                bounds: dockRect,
                name: "Wallpaper Backdrop",
                ownerName: "Dock",
                isOnScreen: true
            ),
            DockSnapshotWindowCandidate(
                windowID: 2,
                ownerPID: dockPID,
                layer: 10,
                bounds: dockRect.insetBy(dx: -4, dy: -4),
                name: "Dock",
                ownerName: "Dock",
                isOnScreen: true
            ),
            DockSnapshotWindowCandidate(
                windowID: 3,
                ownerPID: dockPID + 1,
                layer: 10,
                bounds: dockRect,
                name: "Dock",
                ownerName: "Dock",
                isOnScreen: true
            )
        ]
        let selected = DockSnapshotGeometryCalculator.bestWindowCandidate(
            from: candidates,
            dockPID: dockPID,
            dockRect: dockRect,
            preferredWindowID: 1
        )
        expect(selected?.windowID == 2, "Wallpaper and foreign-PID surfaces must be excluded")

        let preferredLayerZero = DockSnapshotWindowCandidate(
            windowID: 4,
            ownerPID: dockPID,
            layer: 0,
            bounds: dockRect,
            name: "Dock",
            ownerName: "Dock",
            isOnScreen: true
        )
        let exact = DockSnapshotGeometryCalculator.bestWindowCandidate(
            from: candidates + [preferredLayerZero],
            dockPID: dockPID,
            dockRect: dockRect,
            preferredWindowID: preferredLayerZero.windowID
        )
        expect(exact?.windowID == preferredLayerZero.windowID, "valid preferred layer-0 surface must win exactly")

        let fallback = DockSnapshotGeometryCalculator.bestWindowCandidate(
            from: [preferredLayerZero, candidates[1]],
            dockPID: dockPID,
            dockRect: dockRect,
            preferredWindowID: nil
        )
        expect(fallback?.windowID == 2, "layer-0 surface must be excluded from fallback selection")
        let layerZeroOnlyFallback = DockSnapshotGeometryCalculator.bestWindowCandidate(
            from: [preferredLayerZero],
            dockPID: dockPID,
            dockRect: dockRect,
            preferredWindowID: nil
        )
        expect(layerZeroOnlyFallback == nil, "fallback must require a positive layer")
    }

    private static func testAlphaValidationAndTightCrop() {
        let transparent = makeImage(width: 200, height: 100, alpha: 0)
        let opaque = makeImage(width: 200, height: 100, alpha: 1)
        let belowThreshold = makeSparseImage(width: 64, height: 64, visiblePixelCount: 19)
        let atThreshold = makeSparseImage(width: 64, height: 64, visiblePixelCount: 20)
        expect(!DockSnapshotAlphaValidator.hasUsableAlpha(transparent), "transparent Dock capture must be rejected")
        expect(DockSnapshotAlphaValidator.hasUsableAlpha(opaque), "visible Dock capture must be accepted")
        expect(!DockSnapshotAlphaValidator.hasUsableAlpha(belowThreshold), "sparse alpha below 0.5% must be rejected")
        expect(DockSnapshotAlphaValidator.hasUsableAlpha(atThreshold), "sparse alpha at 0.5% must be accepted")

        guard let crop = DockSnapshotImageProcessor.tightCrop(
            opaque,
            to: CGRect(x: 20, y: 10, width: 24, height: 80)
        ) else {
            fail("expected a tight Dock crop")
        }
        expect(crop.width == 24, "tight crop width")
        expect(crop.height == 80, "tight crop height")
        expect(crop.bytesPerRow == crop.width * 4, "tight crop must not retain the source framebuffer stride")
        expect(DockSnapshotAlphaValidator.hasUsableAlpha(crop), "tight crop must preserve alpha")
    }

    private static func testCropClampAndInvalidGeometry() {
        let clamped = DockSnapshotGeometryCalculator.cropGeometry(
            windowBounds: CGRect(x: -100, y: 50, width: 200, height: 100),
            dockRect: CGRect(x: -120, y: 120, width: 180, height: 50),
            finderRect: CGRect(x: -95, y: 125, width: 30, height: 30),
            imagePixelSize: CGSize(width: 400, height: 200),
            edge: .bottom
        )
        guard let clamped else { fail("partially visible Dock geometry should clamp") }
        expectRect(clamped.pixelCropRect, equals: CGRect(x: 0, y: 124, width: 336, height: 76))
        expectRect(clamped.pointCropRect, equals: CGRect(x: -100, y: 112, width: 168, height: 38))
        expectRect(clamped.geometry.dockRectInImage, equals: CGRect(x: 0, y: 0, width: 160, height: 30))
        expectRect(clamped.geometry.finderRectInImage, equals: CGRect(x: 5, y: 0, width: 30, height: 25))

        let invalid = DockSnapshotGeometryCalculator.cropGeometry(
            windowBounds: .zero,
            dockRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            finderRect: CGRect(x: 0, y: 0, width: 5, height: 5),
            imagePixelSize: CGSize(width: 100, height: 100),
            edge: .bottom
        )
        expect(invalid == nil, "zero-sized capture window must be rejected")
    }

    private static func testScreenFrameKeyTracksDisplayOrigin() {
        let original = DockSnapshotScreenFrameKey(
            frame: CGRect(x: 2_560, y: 233, width: 1_512, height: 982)
        )
        let unchanged = DockSnapshotScreenFrameKey(
            frame: CGRect(x: 2_560, y: 233, width: 1_512, height: 982)
        )
        let moved = DockSnapshotScreenFrameKey(
            frame: CGRect(x: -1_512, y: 233, width: 1_512, height: 982)
        )
        expect(original == unchanged, "unchanged display frame must reuse its snapshot cache")
        expect(original != moved, "moving a display must invalidate its snapshot cache")
    }

    private static func makeImage(width: Int, height: Int, alpha: CGFloat) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fail("could not create test bitmap context")
        }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { fail("could not create test image") }
        return image
    }

    private static func makeSparseImage(width: Int, height: Int, visiblePixelCount: Int) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fail("could not create sparse test bitmap context")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(false)
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        for index in 0..<max(0, min(visiblePixelCount, width * height)) {
            context.fill(CGRect(x: index % width, y: index / width, width: 1, height: 1))
        }
        guard let image = context.makeImage() else { fail("could not create sparse test image") }
        return image
    }

    private static func verifyLayout(
        stageBounds: CGRect,
        previewSize: CGSize,
        geometry: DockSnapshotGeometry
    ) {
        let contentRect = stageBounds.insetBy(dx: 12, dy: 12)
        let result = SettingsPreviewStageLayout.calculate(
            stageBounds: stageBounds,
            previewSize: previewSize,
            dockImageSize: geometry.imageSize,
            geometry: geometry
        )
        let expectedSceneSize = SettingsPreviewStageLayout.sceneSize(
            previewSize: previewSize,
            dockImageSize: geometry.imageSize,
            edge: geometry.edge
        )

        layoutCount += 1
        expectSize(result.sceneFrame.size, equals: expectedSceneSize)
        expectSize(result.previewFrame.size, equals: previewSize)
        expectSize(result.dockImageFrame.size, equals: geometry.imageSize)
        expectEqual(result.sceneFrame.midX, stageBounds.midX, "current scene center X")
        expectEqual(result.sceneFrame.midY, stageBounds.midY, "current scene center Y")
        expectContains(contentRect, result.sceneFrame, "current scene must remain inside the reserved inset")
        expectContains(result.sceneFrame, result.previewFrame, "preview must remain inside its compact scene")
        expectContains(result.sceneFrame, result.dockVisibleRect, "Dock fragment must remain inside its compact scene")
        expectRect(result.sceneFrame, equals: result.previewFrame.union(result.dockVisibleRect))
        expectSize(result.dockVisibleRect.size, equals: result.dockSourceVisibleRect.size)
        verifyGap(result.previewFrame, dockVisibleRect: result.dockVisibleRect, edge: geometry.edge)

        switch geometry.edge {
        case .bottom, .top:
            expectEqual(result.previewFrame.minX, result.dockVisibleRect.minX, "horizontal scene shared minX")
            expectEqual(result.previewFrame.maxX, result.dockVisibleRect.maxX, "horizontal scene shared maxX")
            expectEqual(result.dockVisibleRect.width, previewSize.width, "horizontal Dock fragment width")
            expectEqual(result.dockVisibleRect.height, geometry.imageSize.height, "horizontal Dock fragment thickness")
            expectEqual(result.dockSourceVisibleRect.minX, 0, "horizontal source leading edge")
            expectEqual(result.dockSourceVisibleRect.minY, 0, "horizontal source must not bottom-crop")
            expectEqual(result.dockSourceVisibleRect.width, previewSize.width, "horizontal source fragment width")
            expectEqual(result.dockSourceVisibleRect.maxY, geometry.imageSize.height, "horizontal source height")
            expectEqual(result.dockImageFrame.minX, result.dockVisibleRect.minX, "horizontal source leading placement")
            expectEqual(result.dockImageFrame.minY, result.dockVisibleRect.minY, "horizontal source cross-axis placement")
        case .left, .right:
            expectEqual(result.previewFrame.minY, result.dockVisibleRect.minY, "vertical scene shared minY")
            expectEqual(result.previewFrame.maxY, result.dockVisibleRect.maxY, "vertical scene shared maxY")
            expectEqual(result.dockVisibleRect.height, previewSize.height, "vertical Dock fragment height")
            expectEqual(result.dockVisibleRect.width, geometry.imageSize.width, "vertical Dock fragment thickness")
            expectEqual(result.dockSourceVisibleRect.minX, 0, "vertical source must not leading-crop")
            expectEqual(result.dockSourceVisibleRect.maxY, geometry.imageSize.height, "vertical source top edge")
            expectEqual(result.dockSourceVisibleRect.maxX, geometry.imageSize.width, "vertical source width")
            expectEqual(result.dockSourceVisibleRect.height, previewSize.height, "vertical source fragment height")
            expectEqual(result.dockImageFrame.maxY, result.dockVisibleRect.maxY, "vertical source top placement")
            expectEqual(result.dockImageFrame.minX, result.dockVisibleRect.minX, "vertical source cross-axis placement")
        }
    }

    private static func verifyGap(
        _ previewFrame: CGRect,
        dockVisibleRect: CGRect,
        edge: DockSnapshotEdge
    ) {
        let gap: CGFloat
        switch edge {
        case .bottom:
            gap = previewFrame.minY - dockVisibleRect.maxY
        case .top:
            gap = dockVisibleRect.minY - previewFrame.maxY
        case .left:
            gap = previewFrame.minX - dockVisibleRect.maxX
        case .right:
            gap = dockVisibleRect.minX - previewFrame.maxX
        }
        expectEqual(gap, 4, "preview-to-Dock fragment gap must remain exactly 4pt")
    }

    private static func geometry(edge: DockSnapshotEdge, isLong: Bool) -> DockSnapshotGeometry {
        switch edge {
        case .bottom, .top:
            let imageSize = CGSize(width: isLong ? 1_300 : 620, height: 92)
            return DockSnapshotGeometry(
                edge: edge,
                imageSize: imageSize,
                dockRectInImage: CGRect(x: 8, y: 8, width: imageSize.width - 16, height: 76),
                finderRectInImage: CGRect(x: 18, y: 16, width: 60, height: 60)
            )
        case .left, .right:
            let imageSize = CGSize(width: 92, height: isLong ? 900 : 450)
            return DockSnapshotGeometry(
                edge: edge,
                imageSize: imageSize,
                dockRectInImage: CGRect(x: 8, y: 8, width: 76, height: imageSize.height - 16),
                finderRectInImage: CGRect(x: 16, y: imageSize.height - 78, width: 60, height: 60)
            )
        }
    }

    private static func ultraShortGeometry(edge: DockSnapshotEdge) -> DockSnapshotGeometry {
        switch edge {
        case .bottom, .top:
            let imageSize = CGSize(width: 280, height: 92)
            return DockSnapshotGeometry(
                edge: edge,
                imageSize: imageSize,
                dockRectInImage: CGRect(x: 8, y: 8, width: 264, height: 76),
                finderRectInImage: CGRect(x: 18, y: 16, width: 60, height: 60)
            )
        case .left, .right:
            let imageSize = CGSize(width: 92, height: 180)
            return DockSnapshotGeometry(
                edge: edge,
                imageSize: imageSize,
                dockRectInImage: CGRect(x: 8, y: 8, width: 76, height: 164),
                finderRectInImage: CGRect(x: 16, y: 102, width: 60, height: 60)
            )
        }
    }

    private static func expectedGroupingHeightDelta(for contentSize: PreviewContentSize) -> CGFloat {
        switch contentSize {
        case .extraSmall: return 32
        case .small: return 33
        case .regular: return 34
        case .large: return 36
        case .extraLarge: return 38
        }
    }

    private static func reservedStageBounds(for geometry: DockSnapshotGeometry) -> CGRect {
        CGRect(
            origin: .zero,
            size: PreviewSizing.reservedStageSize(
                screenHeight: referenceScreenHeight,
                dockImageSize: geometry.imageSize,
                edge: geometry.edge
            )
        )
    }

    private static func requireCropGeometry(
        windowBounds: CGRect,
        dockRect: CGRect,
        finderRect: CGRect,
        imagePixelSize: CGSize,
        edge: DockSnapshotEdge
    ) -> DockSnapshotCropGeometry {
        guard let geometry = DockSnapshotGeometryCalculator.cropGeometry(
            windowBounds: windowBounds,
            dockRect: dockRect,
            finderRect: finderRect,
            imagePixelSize: imagePixelSize,
            edge: edge
        ) else {
            fail("expected valid crop geometry")
        }
        return geometry
    }

    private static func expectContains(_ outer: CGRect, _ inner: CGRect, _ message: String) {
        expect(inner.minX >= outer.minX - epsilon, "\(message): minX")
        expect(inner.minY >= outer.minY - epsilon, "\(message): minY")
        expect(inner.maxX <= outer.maxX + epsilon, "\(message): maxX")
        expect(inner.maxY <= outer.maxY + epsilon, "\(message): maxY")
    }

    private static func expectRect(_ actual: CGRect, equals expected: CGRect) {
        expectEqual(actual.minX, expected.minX, "rect minX")
        expectEqual(actual.minY, expected.minY, "rect minY")
        expectEqual(actual.width, expected.width, "rect width")
        expectEqual(actual.height, expected.height, "rect height")
    }

    private static func expectSize(_ actual: CGSize, equals expected: CGSize) {
        expectEqual(actual.width, expected.width, "size width")
        expectEqual(actual.height, expected.height, "size height")
    }

    private static func expectEqual(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        expect(abs(actual - expected) <= epsilon, "\(message): expected \(expected), got \(actual)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertionCount += 1
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Preview size stage test failed: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}
