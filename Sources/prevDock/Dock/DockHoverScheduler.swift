import Cocoa

final class DockHoverScheduler {
    private let onTick: () -> Void
    private var timer: Timer?
    private var wakeTickScheduled = false

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    deinit { cancelTimer() }

    func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    func wake() {
        if Thread.isMainThread {
            scheduleWakeTick()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.scheduleWakeTick()
        }
    }

    private func scheduleWakeTick() {
        guard !wakeTickScheduled else { return }
        wakeTickScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wakeTickScheduled = false
            self.onTick()
        }
    }

    func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(interval, 0.01), repeats: false) { [weak self] _ in
            self?.onTick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
