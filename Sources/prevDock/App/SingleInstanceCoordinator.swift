import Cocoa
import Darwin

enum SingleInstanceCoordinator {
    private static var lockFileDescriptor: Int32 = -1

    static func claimInstance() -> Bool {
        guard lockFileDescriptor < 0 else { return true }
        let descriptor = open(lockFilePath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            NSLog("prevDock: could not create the single-instance lock; using process detection")
            closeLegacyInstances()
            return true
        }

        var result: Int32
        repeat {
            result = flock(descriptor, LOCK_EX | LOCK_NB)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK {
                activateExistingInstance()
                return false
            }
            NSLog("prevDock: could not lock the single-instance file (errno \(error)); using process detection")
            closeLegacyInstances()
            return true
        }
        lockFileDescriptor = descriptor
        closeLegacyInstances()
        return true
    }

    private static func closeLegacyInstances() {
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
           !bundleIdentifier.isEmpty {
            return app.bundleIdentifier == bundleIdentifier
        }
        guard let currentExecutable = Bundle.main.executableURL,
              let executable = app.executableURL else {
            return false
        }
        return currentExecutable.standardizedFileURL == executable.standardizedFileURL
    }

    private static func activateExistingInstance() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSWorkspace.shared.runningApplications
            .first(where: {
                $0.processIdentifier != currentPID && !$0.isTerminated && isPrevDockInstance($0)
            })?
            .activate(options: [])
    }

    private static var lockFilePath: String {
        let identifier = Bundle.main.bundleIdentifier ?? "prevDock"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(identifier).instance.lock")
            .path
    }
}
