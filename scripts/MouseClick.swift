import ApplicationServices
import Foundation

guard (3...4).contains(CommandLine.arguments.count),
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    fputs("usage: MouseClick quartzX quartzY [left|right]\n", stderr)
    exit(2)
}

let point = CGPoint(x: x, y: y)
let buttonName = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : "left"
let button: CGMouseButton = buttonName == "right" ? .right : .left
let eventTypes: [CGEventType] = button == .right ?
    [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
for type in eventTypes {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    event?.post(tap: .cghidEventTap)
    usleep(40_000)
}
