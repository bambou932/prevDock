import CoreGraphics

enum DockFocusNavigation {
    static func cancelsPendingFocus(keyCode: Int64, flags: CGEventFlags) -> Bool {
        // Command-Tab/backtick and Control-arrow are explicit app, window, and Space navigation.
        if flags.contains(.maskCommand), keyCode == 48 || keyCode == 50 {
            return true
        }
        return flags.contains(.maskControl) && (123...126).contains(keyCode)
    }
}
