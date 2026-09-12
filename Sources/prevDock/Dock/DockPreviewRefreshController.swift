import Cocoa

final class DockPreviewRefreshController {
    private(set) var lastMetadataRefresh = -TimeInterval.infinity
    private var spaceChangeGeneration: UInt64 = 0
    private var metadataSpaceGenerationByPID = [pid_t: UInt64]()
    private(set) var lastLiveThumbnailRefresh = -TimeInterval.infinity
    private var lastWarmupByPID = [pid_t: TimeInterval]()
    private var metadataRefresh: PendingWindowRefresh?
    private var warmupRefresh: PendingWindowRefresh?
    private var clickValidationRefresh: PendingWindowRefresh?
    private(set) var thumbnailTargetPID: pid_t?
    private var thumbnailRefreshGeneration: UInt64 = 0
    private var nextRefreshIdentifier: UInt64 = 0
    private let previewWarmupInterval: TimeInterval = 3.0

    deinit {
        cancelClickValidationRefresh()
        cancelRefreshRequests()
        WindowInventory.setBackgroundThumbnailTarget(pid: nil)
    }

    func resetThumbnailTarget() {
        thumbnailTargetPID = nil
        thumbnailRefreshGeneration &+= 1
        WindowInventory.setBackgroundThumbnailTarget(pid: nil)
    }

    func spaceDidChange() {
        spaceChangeGeneration &+= 1
    }

    func needsSpaceRefresh(for pid: pid_t) -> Bool {
        metadataSpaceGenerationByPID[pid, default: 0] != spaceChangeGeneration
    }

    func noteMetadataPresentation(at now: TimeInterval) {
        lastMetadataRefresh = now
    }

    func noteThumbnailRefresh(at now: TimeInterval) {
        lastLiveThumbnailRefresh = now
    }

    func refreshThumbnails(
        for app: NSRunningApplication,
        maximumStaleCount: Int = 2,
        completion: @escaping (CGWindowID, FreshThumbnailCaptureResult) -> Void
    ) {
        let generation = thumbnailRefreshGeneration
        WindowInventory.refreshThumbnails(for: app, maximumStaleCount: maximumStaleCount) { [weak self, weak app] windowID, result in
            guard let self, app != nil, self.thumbnailRefreshGeneration == generation else { return }
            completion(windowID, result)
        }
    }

    func refreshMetadata(
        for app: NSRunningApplication,
        targetKey: String,
        completion: @escaping (NSRunningApplication, [WindowPreview]) -> Void
    ) {
        guard metadataRefresh == nil, clickValidationRefresh?.targetKey != targetKey else { return }
        let refreshIdentifier = makeRefreshIdentifier()
        let request = WindowInventory.refreshWindows(for: app, thumbnailPolicy: .none) { [weak self, weak app] previews in
            guard let self, self.consumeMetadataRefresh(identifier: refreshIdentifier), let app else { return }
            completion(app, previews)
        } thumbnail: { _, _ in }
        metadataRefresh = PendingWindowRefresh(
            targetKey: targetKey, pid: app.processIdentifier, identifier: refreshIdentifier, request: request
        )
    }

    func refreshClickValidation(
        for app: NSRunningApplication,
        targetKey: String,
        completion: @escaping ([WindowPreview]) -> Void
    ) {
        let refreshIdentifier = makeRefreshIdentifier()
        let request = WindowInventory.refreshWindows(for: app, thumbnailPolicy: .none) { [weak self] previews in
            guard let self, self.consumeClickValidationRefresh(identifier: refreshIdentifier) else { return }
            completion(previews)
        } thumbnail: { _, _ in }
        clickValidationRefresh = PendingWindowRefresh(
            targetKey: targetKey, pid: app.processIdentifier, identifier: refreshIdentifier, request: request
        )
        metadataRefresh?.request.cancel()
        metadataRefresh = nil
    }

    func cancelClickValidationRefresh() {
        clickValidationRefresh?.request.cancel()
        clickValidationRefresh = nil
    }

    func warmPreviewCacheIfNeeded(
        for target: DockHoverTarget,
        now: TimeInterval,
        pendingTarget: DockHoverTarget?,
        pendingTargetStartedAt: TimeInterval,
        fastTickInterval: TimeInterval
    ) {
        guard let app = target.app else { return }
        let switchDelay = PrevDockSettings.previewSwitchDelay
        guard switchDelay > 0 else { return }
        let warmupDelay = min(switchDelay, fastTickInterval)
        guard pendingTarget?.key == target.key,
              (now - pendingTargetStartedAt) >= warmupDelay else {
            return
        }
        if let warmupRefresh {
            guard warmupRefresh.targetKey != target.key else { return }
            warmupRefresh.request.cancel()
            self.warmupRefresh = nil
        }
        let pid = app.processIdentifier
        let spaceGeneration = spaceChangeGeneration
        let needsSpaceRefresh = metadataSpaceGenerationByPID[pid, default: 0] != spaceGeneration
        if !needsSpaceRefresh {
            guard WindowInventory.cachedWindows(
                for: app,
                refreshedWithin: previewWarmupInterval
            ) == nil,
            (now - lastWarmupByPID[pid, default: -TimeInterval.infinity]) > previewWarmupInterval else {
                return
            }
        }

        lastWarmupByPID[pid] = now
        if lastWarmupByPID.count > 32 {
            lastWarmupByPID = lastWarmupByPID.filter {
                (now - $0.value) <= previewWarmupInterval
            }
        }
        let refreshIdentifier = makeRefreshIdentifier()
        let request = WindowInventory.warmPreviewCache(for: app) { [weak self] _ in
            guard let self,
                  self.warmupRefresh?.identifier == refreshIdentifier else {
                return
            }
            self.warmupRefresh = nil
            guard self.spaceChangeGeneration == spaceGeneration else { return }
            self.metadataSpaceGenerationByPID[pid] = spaceGeneration
        }
        warmupRefresh = PendingWindowRefresh(
            targetKey: target.key,
            pid: app.processIdentifier,
            identifier: refreshIdentifier,
            request: request
        )
    }

    func cancelRefreshRequests(except targetKey: String? = nil) {
        if metadataRefresh?.targetKey != targetKey {
            metadataRefresh?.request.cancel()
            metadataRefresh = nil
        }
        if let pendingWarmup = warmupRefresh, pendingWarmup.targetKey != targetKey {
            let wasActive = pendingWarmup.request.isActive
            pendingWarmup.request.cancel()
            if wasActive {
                lastWarmupByPID.removeValue(forKey: pendingWarmup.pid)
            }
            warmupRefresh = nil
        }
    }

    func setThumbnailTargetPID(_ pid: pid_t?) {
        guard thumbnailTargetPID != pid else { return }
        thumbnailTargetPID = pid
        thumbnailRefreshGeneration &+= 1
        WindowInventory.setBackgroundThumbnailTarget(pid: pid)
    }

    private func consumeMetadataRefresh(identifier: UInt64) -> Bool {
        guard metadataRefresh?.identifier == identifier else { return false }
        metadataRefresh = nil
        return true
    }

    func didCompleteMetadataRefresh(for pid: pid_t) {
        lastMetadataRefresh = ProcessInfo.processInfo.systemUptime
        metadataSpaceGenerationByPID[pid] = spaceChangeGeneration
    }

    private func consumeClickValidationRefresh(identifier: UInt64) -> Bool {
        guard clickValidationRefresh?.identifier == identifier else { return false }
        clickValidationRefresh = nil
        return true
    }

    private func makeRefreshIdentifier() -> UInt64 {
        nextRefreshIdentifier &+= 1
        return nextRefreshIdentifier
    }
}

private struct PendingWindowRefresh {
    let targetKey: String
    let pid: pid_t
    let identifier: UInt64
    let request: WindowRefreshRequest
}
