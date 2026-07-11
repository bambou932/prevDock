import ApplicationServices
import CoreGraphics
import Foundation

private let skyLightConnection = CGSMainConnectionID()

typealias CGSConnectionID = UInt32

struct CGSWindowCaptureOptions: OptionSet {
    let rawValue: UInt32

    static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
    static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
    static let fullSize = CGSWindowCaptureOptions(rawValue: 1 << 19)
}

struct CGSSpaceMask: OptionSet {
    let rawValue: UInt32

    static let current = CGSSpaceMask(rawValue: 1 << 0)
    static let others = CGSSpaceMask(rawValue: 1 << 1)
    static let user = CGSSpaceMask(rawValue: 1 << 2)
}

enum SkyLightCapture {
    static func capture(windowID: CGWindowID) -> CGImage? {
        var id = windowID
        let options: CGSWindowCaptureOptions = [.ignoreGlobalClipShape, .bestResolution, .fullSize]
        guard let result = CGSHWCaptureWindowList(skyLightConnection, &id, 1, options),
              let images = result.takeRetainedValue() as? [CGImage] else {
            return nil
        }
        return images.first
    }

    static func level(windowID: CGWindowID) -> CGWindowLevel? {
        var level = CGWindowLevel(0)
        guard CGSGetWindowLevel(skyLightConnection, windowID, &level) == .success else { return nil }
        return level
    }

    static func managedDesktopSpaces() -> [WindowDesktop] {
        let displays = managedDisplaySpaceDictionaries()
        let currentIDs = currentDesktopIDs(from: displays)
        return orderedDesktopSpaces(from: displays, currentIDs: currentIDs)
    }

    static func currentDesktopIDs() -> Set<UInt64> {
        currentDesktopIDs(from: managedDisplaySpaceDictionaries())
    }

    static func currentDesktopID(displayIdentifier: String?) -> UInt64? {
        guard let displayIdentifier else { return nil }
        return managedDisplaySpaceDictionaries()
            .first { $0["Display Identifier"] as? String == displayIdentifier }
            .flatMap { spaceID(from: $0["Current Space"]) }
    }

    static func spaceIDs(windowID: CGWindowID) -> [UInt64] {
        spaceIDsIfAvailable(windowID: windowID) ?? []
    }

    static func spaceIDsIfAvailable(windowID: CGWindowID) -> [UInt64]? {
        let windows = [NSNumber(value: windowID)] as CFArray
        let mask: CGSSpaceMask = [.current, .others, .user]
        guard let result = CGSCopySpacesForWindows(skyLightConnection, mask, windows) else { return nil }
        let spaces = result.takeRetainedValue() as NSArray
        return spaces.compactMap { ($0 as? NSNumber)?.uint64Value }
    }

    @discardableResult
    static func focusWindow(windowID: CGWindowID, pid: pid_t) -> Bool {
        var psn = ProcessSerialNumber()
        guard HIGetProcessForPID(pid, &psn) == 0 else { return false }
        let result = SLPSSetFrontProcessWithOptions(&psn, windowID, SLPSMode.userGenerated)
        guard result == .success else { return false }
        return postMakeKeyWindowEvent(to: &psn, windowID: windowID)
    }

    private static func postMakeKeyWindowEvent(
        to psn: inout ProcessSerialNumber,
        windowID: CGWindowID
    ) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { rawWindowID in
            for offset in 0..<MemoryLayout<UInt32>.size {
                bytes[0x3c + offset] = rawWindowID[offset]
            }
        }
        for offset in 0..<0x10 {
            bytes[0x20 + offset] = 0xff
        }
        bytes[0x08] = 0x01
        let keyDownResult = SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        let keyUpResult = SLPSPostEventRecordTo(&psn, &bytes)
        return keyDownResult == .success && keyUpResult == .success
    }

    private static func managedDisplaySpaceDictionaries() -> [[String: Any]] {
        guard let result = CGSCopyManagedDisplaySpaces(skyLightConnection) else { return [] }
        let displays = result.takeRetainedValue() as NSArray
        return displays.compactMap { $0 as? [String: Any] }
    }

    private static func currentDesktopIDs(from displays: [[String: Any]]) -> Set<UInt64> {
        Set(displays.compactMap { spaceID(from: $0["Current Space"]) })
    }

    private static func orderedDesktopSpaces(
        from displays: [[String: Any]],
        currentIDs: Set<UInt64>
    ) -> [WindowDesktop] {
        var builder = DesktopSpaceBuilder(currentIDs: currentIDs)
        displays.forEach { builder.appendSpaces(from: $0) }
        return builder.spaces
    }

    private static func spaceID(from value: Any?) -> UInt64? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return (dictionary["ManagedSpaceID"] as? NSNumber)?.uint64Value ??
            (dictionary["id64"] as? NSNumber)?.uint64Value
    }
}

private struct DesktopSpaceBuilder {
    private let currentIDs: Set<UInt64>
    private var seenIDs = Set<UInt64>()
    private var desktopNumber = 1
    private var spaceNumber = 1
    private var nextSortOrder = 0
    private(set) var spaces = [WindowDesktop]()

    init(currentIDs: Set<UInt64>) {
        self.currentIDs = currentIDs
    }

    mutating func appendSpaces(from display: [String: Any]) {
        guard let rawSpaces = display["Spaces"] as? [[String: Any]] else { return }
        rawSpaces.forEach { appendSpace($0) }
    }

    private mutating func appendSpace(_ rawSpace: [String: Any]) {
        guard let id = spaceID(from: rawSpace), !seenIDs.contains(id) else { return }
        seenIDs.insert(id)
        spaces.append(WindowDesktop(
            id: id,
            title: title(for: rawSpace),
            sortOrder: nextSortOrder,
            isCurrent: currentIDs.contains(id)
        ))
        nextSortOrder += 1
    }

    private mutating func title(for rawSpace: [String: Any]) -> String {
        if let name = rawSpace["name"] as? String, !name.isEmpty {
            return name
        }
        return fallbackTitle(isDesktop: (rawSpace["type"] as? NSNumber)?.intValue == 0)
    }

    private mutating func fallbackTitle(isDesktop: Bool) -> String {
        guard isDesktop else {
            defer { spaceNumber += 1 }
            return "Space \(spaceNumber)"
        }
        defer { desktopNumber += 1 }
        return "Desktop \(desktopNumber)"
    }

    private func spaceID(from rawSpace: [String: Any]) -> UInt64? {
        (rawSpace["ManagedSpaceID"] as? NSNumber)?.uint64Value ??
            (rawSpace["id64"] as? NSNumber)?.uint64Value
    }
}

private enum SLPSMode {
    static let userGenerated: UInt32 = 0x200
}

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(_ connection: CGSConnectionID, _ windowList: UnsafeMutablePointer<CGWindowID>, _ windowCount: UInt32, _ options: CGSWindowCaptureOptions) -> Unmanaged<CFArray>?

@_silgen_name("CGSGetWindowLevel")
@discardableResult
func CGSGetWindowLevel(_ connection: CGSConnectionID, _ windowID: CGWindowID, _ level: UnsafeMutablePointer<CGWindowLevel>) -> CGError

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ connection: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ connection: CGSConnectionID, _ mask: CGSSpaceMask, _ windows: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("GetProcessForPID")
@discardableResult
func HIGetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("_SLPSSetFrontProcessWithOptions")
@discardableResult
func SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ windowID: CGWindowID, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo")
@discardableResult
func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError
