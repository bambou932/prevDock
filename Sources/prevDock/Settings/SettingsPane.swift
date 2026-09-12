import AppKit

enum SettingsPane: Int, CaseIterable {
    case general, appearance, layout, permissions, updates

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .layout: return "Layout"
        case .permissions: return "Permissions"
        case .updates: return "Updates"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Choose how prevDock works with your Dock."
        case .appearance: return "Make your window previews feel right."
        case .layout: return "Give every window its place."
        case .permissions: return "Control the access that makes previews possible."
        case .updates: return "Keep prevDock up to date."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .layout: return "rectangle.3.group"
        case .permissions: return "hand.raised"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}
