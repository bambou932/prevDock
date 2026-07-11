import Cocoa

enum NativeDockMenuVisibility: Equatable {
    case visible(Set<CGWindowID>)
    case absent
    case unknown
}

enum DockAccessibilityMenuProbe: Equatable {
    case visible(CGRect)
    case absent
    case unknown
}

enum NativeDockMenuPreflightDecision: Equatable {
    case performAction
    case adoptVisibleMenu(Set<CGWindowID>)
    case wait
}

enum DockConnectedPopupContainment: Equatable {
    case contains(Set<CGWindowID>)
    case outside
    case unknown
}

enum DockPopupMenuSessionClassifier {
    static let connectionDistance: CGFloat = 48

    static func visibility(
        popupFrames: [CGWindowID: CGRect]?,
        accessibility: DockAccessibilityMenuProbe,
        anchoredTo anchor: CGRect
    ) -> NativeDockMenuVisibility {
        guard let popupFrames else { return .unknown }
        let connectedWindowIDs = connectedWindowIDs(
            popupFrames: popupFrames,
            anchoredTo: anchor
        )
        guard !connectedWindowIDs.isEmpty else { return .absent }
        switch accessibility {
        case .visible(let menuFrame):
            let intersectsMenu = connectedWindowIDs.contains {
                popupFrames[$0]?.intersects(menuFrame) == true
            }
            return intersectsMenu ? .visible(connectedWindowIDs) : .absent
        case .absent:
            return .absent
        case .unknown:
            return .unknown
        }
    }

    static func connectedWindowIDs(
        popupFrames: [CGWindowID: CGRect],
        anchoredTo anchor: CGRect
    ) -> Set<CGWindowID> {
        var connected = Set(popupFrames.compactMap { windowID, frame in
            squaredDistance(between: frame, and: anchor) <= connectionDistance * connectionDistance ?
                windowID : nil
        })
        var remaining = Set(popupFrames.keys).subtracting(connected)
        while !connected.isEmpty, !remaining.isEmpty {
            let additional = Set(remaining.filter { windowID in
                guard let frame = popupFrames[windowID] else { return false }
                return connected.contains { connectedID in
                    guard let connectedFrame = popupFrames[connectedID] else { return false }
                    return squaredDistance(between: frame, and: connectedFrame) <=
                        connectionDistance * connectionDistance
                }
            })
            guard !additional.isEmpty else { break }
            connected.formUnion(additional)
            remaining.subtract(additional)
        }
        return connected
    }

    static func connectedContainment(
        of point: CGPoint,
        popupFrames: [CGWindowID: CGRect]?,
        anchoredTo anchor: CGRect,
        intersecting knownWindowIDs: Set<CGWindowID>,
        padding: CGFloat = 0
    ) -> DockConnectedPopupContainment {
        guard let popupFrames else { return .unknown }
        let connectedWindowIDs = connectedWindowIDs(
            popupFrames: popupFrames,
            anchoredTo: anchor
        )
        guard !connectedWindowIDs.isDisjoint(with: knownWindowIDs) else {
            return .outside
        }
        let containsPoint = connectedWindowIDs.contains {
            popupFrames[$0]?.insetBy(dx: -padding, dy: -padding).contains(point) == true
        }
        return containsPoint ? .contains(connectedWindowIDs) : .outside
    }

    private static func squaredDistance(between lhs: CGRect, and rhs: CGRect) -> CGFloat {
        let dx = max(max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX), 0)
        let dy = max(max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY), 0)
        return dx * dx + dy * dy
    }
}

enum NativeDockMenuLifecyclePolicy {
    static func shouldSuppressRepeatedAction(
        attemptTargetKey: String,
        attemptHoverSession: Int,
        attemptGeneration: Int,
        targetKey: String,
        currentHoverSession: Int,
        requestGeneration: Int
    ) -> Bool {
        attemptTargetKey == targetKey &&
            attemptHoverSession == currentHoverSession &&
            attemptGeneration != requestGeneration
    }

    static func shouldRefreshConnectedPopup(
        hasKnownMenu: Bool,
        cachedContainsPoint: Bool,
        overTarget: Bool,
        overOtherDockTarget: Bool,
        awaitingFirstMenu: Bool,
        wasOutside: Bool
    ) -> Bool {
        hasKnownMenu &&
            !cachedContainsPoint &&
            !overTarget &&
            !overOtherDockTarget &&
            !awaitingFirstMenu &&
            !wasOutside
    }

    static func focusedProbeRequiresTreeFallback(
        _ probe: DockAccessibilityMenuProbe
    ) -> Bool {
        if case .absent = probe { return true }
        return false
    }

    static func isInsidePendingMenuCorridor(
        _ point: CGPoint,
        anchor: CGRect,
        connectionDistance: CGFloat = DockPopupMenuSessionClassifier.connectionDistance
    ) -> Bool {
        let reach = connectionDistance * 3
        return anchor.insetBy(dx: -reach, dy: -reach).contains(point)
    }

    static func preflightDecision(
        visibility: NativeDockMenuVisibility
    ) -> NativeDockMenuPreflightDecision {
        switch visibility {
        case .visible(let windowIDs):
            return .adoptVisibleMenu(windowIDs)
        case .absent:
            return .performAction
        case .unknown:
            return .wait
        }
    }

    static func trackedActionGeneration(generation: Int, actionStarted: Bool) -> Int? {
        actionStarted ? generation : nil
    }

    static func safeAfter(
        actionStartedAt: Date?,
        actionCompletedAt: Date?,
        quietInterval: TimeInterval,
        now: Date
    ) -> Date {
        [actionStartedAt, actionCompletedAt]
            .compactMap { $0?.addingTimeInterval(quietInterval) }
            .max() ?? now
    }

    static func absenceIsEligible(
        actionGeneration: Int?,
        actionCompleted: Bool,
        now: Date,
        safeAfter: Date
    ) -> Bool {
        let completionConfirmed = actionGeneration == nil || actionCompleted
        return completionConfirmed && now >= safeAfter
    }

    static func visibilityBackoff(
        unknownObservations: Int,
        baseInterval: TimeInterval,
        maximumInterval: TimeInterval = 1
    ) -> TimeInterval {
        let exponent = min(max(unknownObservations, 0), 4)
        return min(maximumInterval, baseInterval * pow(2, Double(exponent)))
    }

    static func shouldLatchDismissal(sourceHoverSession: Int, currentHoverSession: Int) -> Bool {
        sourceHoverSession == currentHoverSession
    }

    static func canPromoteLateMenu(
        requestGeneration: Int,
        cleanupGeneration: Int?,
        activeFailedGeneration: Int?,
        sourceHoverSession: Int,
        currentHoverSession: Int
    ) -> Bool {
        requestGeneration == cleanupGeneration &&
            requestGeneration == activeFailedGeneration &&
            sourceHoverSession == currentHoverSession
    }
}
