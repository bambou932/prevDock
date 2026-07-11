import AppKit
import Foundation

private final class FixtureAppDelegate: NSObject, NSApplicationDelegate {
    private var windows = [NSWindow]()
    private var nextWindowIndex = 0
    private var addWindowSource: DispatchSourceSignal?
    private var removeWindowSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let count = Self.requestedWindowCount()
        NSApp.setActivationPolicy(.regular)
        installWindowMutationSignals()
        for _ in 0..<count {
            addWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func addWindow() {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let index = nextWindowIndex
        nextWindowIndex += 1
        let size = Self.windowSize(index: index, fitting: visibleFrame.size)
        let origin = Self.windowOrigin(index: index, size: size, in: visibleFrame)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(format: "prevDock Fixture %03d", index + 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 120, height: 120)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = Self.color(index: index).cgColor
        window.orderFrontRegardless()
        windows.append(window)
    }

    private func removeWindow() {
        guard let window = windows.popLast() else { return }
        window.close()
    }

    private func installWindowMutationSignals() {
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        addWindowSource = signalSource(signal: SIGUSR1) { [weak self] in
            self?.addWindow()
        }
        removeWindowSource = signalSource(signal: SIGUSR2) { [weak self] in
            self?.removeWindow()
        }
    }

    private func signalSource(signal: Int32, handler: @escaping () -> Void) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }

    private static func requestedWindowCount() -> Int {
        let value = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 12
        return min(max(value, 1), 100)
    }

    private static func windowSize(index: Int, fitting screenSize: NSSize) -> NSSize {
        let aspectRatios: [CGFloat] = [0.30, 0.55, 1.0, 1.40, 16.0 / 9.0, 2.40, 3.15]
        let aspect = aspectRatios[index % aspectRatios.count]
        let height = min(max(180, screenSize.height * 0.32), 420)
        let width = min(max(120, height * aspect), max(120, screenSize.width * 0.72))
        return NSSize(width: width, height: height)
    }

    private static func windowOrigin(index: Int, size: NSSize, in frame: NSRect) -> NSPoint {
        let column = index % 8
        let row = (index / 8) % 6
        let xRange = max(1, frame.width - size.width)
        let yRange = max(1, frame.height - size.height)
        return NSPoint(
            x: frame.minX + (CGFloat(column) * 54).truncatingRemainder(dividingBy: xRange),
            y: frame.minY + (CGFloat(row) * 46).truncatingRemainder(dividingBy: yRange)
        )
    }

    private static func color(index: Int) -> NSColor {
        let hue = CGFloat(index % 17) / 17
        return NSColor(calibratedHue: hue, saturation: 0.48, brightness: 0.78, alpha: 1)
    }
}

private let app = NSApplication.shared
private let delegate = FixtureAppDelegate()
app.delegate = delegate
app.run()
