import Cocoa

enum PrevDockColors {
    static var highlight: NSColor {
        NSColor.selectedContentBackgroundColor
    }

    static func highlight(alpha: CGFloat) -> NSColor {
        highlight.withAlphaComponent(alpha)
    }
}
