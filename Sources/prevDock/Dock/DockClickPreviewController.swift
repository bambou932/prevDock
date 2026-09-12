import Cocoa

final class DockClickPreviewController {
    enum Event {
        case initial(DockHoverTarget, NSRunningApplication, [WindowPreview])
        case resolved(DockHoverTarget, NSRunningApplication, DockClickPreviewState.Resolution, [WindowPreview])
        case discarded(targetKey: String)
    }

    private let refreshes: DockPreviewRefreshController
    private let onEvent: (Event) -> Void
    private let retryInterval: TimeInterval
    private var pendingDockClickAction: PendingDockClickAction?
    private var dockClickActionGeneration = 0

    init(
        refreshes: DockPreviewRefreshController,
        retryInterval: TimeInterval,
        onEvent: @escaping (Event) -> Void
    ) {
        self.refreshes = refreshes
        self.retryInterval = retryInterval
        self.onEvent = onEvent
    }

    deinit { cancel() }

    var isHoldingPendingClick: Bool {
        guard let action = pendingDockClickAction, isCurrentDockClick(action) else { return false }
        return ProcessInfo.processInfo.systemUptime < action.state.deadline
    }

    func advanceGeneration() {
        dockClickActionGeneration &+= 1
    }

    func cancel() {
        refreshes.cancelClickValidationRefresh()
        pendingDockClickAction = nil
    }

    func begin(target: DockHoverTarget, app: NSRunningApplication, previews: [WindowPreview], now: TimeInterval) {
        let state = DockClickPreviewState(
            actionGeneration: dockClickActionGeneration,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            startedAt: now,
            hasUsablePreviews: previews.count >= 2
        )
        let action = PendingDockClickAction(target: target, app: app, state: state)
        pendingDockClickAction = action
        onEvent(.initial(target, app, previews))
        refreshes.noteMetadataPresentation(at: now)
        refreshes.noteThumbnailRefresh(at: now)
        refreshDockClick(action)
        expireDockClick(action)
    }

    private func refreshDockClick(_ action: PendingDockClickAction) {
        guard isCurrentDockClick(action) else { return }
        refreshes.refreshClickValidation(for: action.app, targetKey: action.target.key) { [weak self] previews in
            self?.resolveDockClick(action, previews: previews)
        }
    }

    private func finishDockClick(
        _ action: PendingDockClickAction,
        resolution: DockClickPreviewState.Resolution,
        previews: [WindowPreview] = []
    ) {
        cancel()
        onEvent(.resolved(action.target, action.app, resolution, previews))
        if resolution == .restoreNativeClick {
            restoreSuppressedDockClick(for: action.app, state: action.state)
        }
    }

    private func discardDockClick(_ action: PendingDockClickAction) {
        guard pendingDockClickAction?.state.actionGeneration == action.state.actionGeneration else { return }
        cancel()
        onEvent(.discarded(targetKey: action.target.key))
    }

    private func resolveDockClick(_ action: PendingDockClickAction, previews: [WindowPreview]) {
        guard isCurrentDockClick(action) else {
            discardDockClick(action)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // A partial refresh can return old data; only a snapshot completed since this click is authoritative.
        let completePreviews = WindowInventory.cachedWindows(
            for: action.app,
            refreshedWithin: max(0, now - action.state.startedAt)
        )
        let resolvedPreviews = completePreviews ?? previews
        let resolution = action.state.resolution(
            windowCount: resolvedPreviews.count,
            isComplete: completePreviews != nil,
            now: now
        )
        if resolution == .retry {
            retryDockClick(action)
            return
        }
        if completePreviews != nil {
            refreshes.didCompleteMetadataRefresh(for: action.app.processIdentifier)
        }
        finishDockClick(action, resolution: resolution, previews: resolvedPreviews)
    }

    private func retryDockClick(_ action: PendingDockClickAction) {
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
            guard let self, self.isCurrentDockClick(action),
                  ProcessInfo.processInfo.systemUptime < action.state.deadline else { return }
            self.refreshDockClick(action)
        }
    }

    private func isCurrentDockClick(_ action: PendingDockClickAction) -> Bool {
        pendingDockClickAction?.state.actionGeneration == action.state.actionGeneration &&
            action.state.isCurrent(
                actionGeneration: dockClickActionGeneration,
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
            )
    }

    func discardInvalidDockClickIfNeeded() {
        guard let action = pendingDockClickAction, !isCurrentDockClick(action) else { return }
        discardDockClick(action)
    }

    private func restoreSuppressedDockClick(for app: NSRunningApplication, state: DockClickPreviewState) {
        guard !app.isTerminated else { return }
        guard let url = app.bundleURL else {
            _ = app.activate(options: [.activateAllWindows])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        // Opening an already running app sends reopen, including when all of its windows are closed.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self, weak app] _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self, let app, !app.isTerminated,
                      state.isCurrent(
                        actionGeneration: self.dockClickActionGeneration,
                        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
                      ) else { return }
                if !app.activate(options: [.activateAllWindows]) {
                    NSLog("prevDock: could not restore a suppressed Dock click")
                }
            }
        }
    }

    private func expireDockClick(_ action: PendingDockClickAction) {
        let delay = max(0, action.state.deadline - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.pendingDockClickAction?.state.actionGeneration == action.state.actionGeneration else { return }
            guard self.isCurrentDockClick(action) else {
                self.discardDockClick(action)
                return
            }
            self.finishDockClick(action, resolution: action.state.timeoutResolution)
        }
    }
}

private struct PendingDockClickAction {
    let target: DockHoverTarget
    let app: NSRunningApplication
    let state: DockClickPreviewState
}
