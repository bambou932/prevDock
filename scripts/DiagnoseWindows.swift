import ApplicationServices
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

typealias CGSConnectionID = UInt32

struct CGSWindowCaptureOptions: OptionSet {
    let rawValue: UInt32
    static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
    static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
    static let fullSize = CGSWindowCaptureOptions(rawValue: 1 << 19)
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: inout CGWindowID) -> AXError

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(_ connection: CGSConnectionID, _ windowList: UnsafeMutablePointer<CGWindowID>, _ windowCount: UInt32, _ options: CGSWindowCaptureOptions) -> Unmanaged<CFArray>

func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
    return CFBooleanGetValue((value as! CFBoolean))
}

func sizeAttribute(_ element: AXUIElement) -> CGSize {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return .zero }
    var size = CGSize.zero
    AXValueGetValue(value as! AXValue, .cgSize, &size)
    return size
}

func save(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let query = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !query.isEmpty else {
    print("usage: DiagnoseWindows app-name-or-bundle-id")
    exit(2)
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(query) ||
    ($0.localizedName ?? "").localizedCaseInsensitiveContains(query)
}) else {
    print("app not running: \(query)")
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
var rawWindows: CFTypeRef?
let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
let windows = rawWindows as? [AXUIElement] ?? []
print("app=\(app.localizedName ?? "") pid=\(app.processIdentifier) axResult=\(result.rawValue) axWindows=\(windows.count)")

let connection = CGSMainConnectionID()
for (index, window) in windows.enumerated() {
    var id = CGWindowID(0)
    let idResult = _AXUIElementGetWindow(window, &id)
    let title = stringAttribute(window, kAXTitleAttribute as CFString) ?? ""
    let role = stringAttribute(window, kAXRoleAttribute as CFString) ?? ""
    let subrole = stringAttribute(window, kAXSubroleAttribute as CFString) ?? ""
    let minimized = boolAttribute(window, kAXMinimizedAttribute as CFString)
    let size = sizeAttribute(window)
    print("#\(index) id=\(id) idResult=\(idResult.rawValue) minimized=\(minimized) size=\(Int(size.width))x\(Int(size.height)) role=\(role) subrole=\(subrole) title=\(title)")
    guard id != 0 else { continue }
    var idCopy = id
    let images = CGSHWCaptureWindowList(connection, &idCopy, 1, [.ignoreGlobalClipShape, .bestResolution, .fullSize]).takeRetainedValue() as? [CGImage] ?? []
    if let image = images.first {
        let url = URL(fileURLWithPath: "/tmp/prevdock-\(app.processIdentifier)-\(id).png")
        save(image, to: url)
        print("  captured \(image.width)x\(image.height) -> \(url.path)")
    } else {
        print("  capture failed")
    }
}
