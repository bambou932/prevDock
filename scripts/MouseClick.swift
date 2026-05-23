import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    fputs("usage: MouseClick quartzX quartzY\n", stderr)
    exit(2)
}

let point = CGPoint(x: x, y: y)
for type in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.post(tap: .cghidEventTap)
    usleep(40_000)
}
