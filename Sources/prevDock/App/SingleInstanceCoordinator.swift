import Cocoa

enum SingleInstanceCoordinator {
    static func closeOtherInstances() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != currentPID && isPrevDockInstance($0) }
        guard !otherInstances.isEmpty else { return }
        otherInstances.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            otherInstances.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
    }

    private static func isPrevDockInstance(_ app: NSRunningApplication) -> Bool {
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           app.bundleIdentifier == bundleIdentifier {
            return true
        }
        if app.localizedName == "prevDock" { return true }
        if app.executableURL?.lastPathComponent == "prevDock" { return true }
        return false
    }
}
