import Foundation

enum DockSystemPreferences {
    private static let applicationID = "com.apple.dock" as CFString

    static var isAutoHideEnabled: Bool {
        number(for: "autohide")?.boolValue ?? false
    }

    static var orientation: DockSnapshotEdge? {
        guard let value = value(for: "orientation") as? String else { return nil }
        return DockSnapshotEdge(rawValue: value)
    }

    static var tileSize: CGFloat? {
        guard let value = number(for: "tilesize")?.doubleValue,
              value.isFinite,
              value > 0 else {
            return nil
        }
        return CGFloat(value)
    }

    private static func number(for key: String) -> NSNumber? {
        value(for: key) as? NSNumber
    }

    private static func value(for key: String) -> Any? {
        CFPreferencesAppSynchronize(applicationID)
        return CFPreferencesCopyAppValue(key as CFString, applicationID)
    }
}
