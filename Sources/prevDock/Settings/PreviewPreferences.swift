import Foundation

enum PreviewOverflowMode: String, CaseIterable {
    case scroll
    case wrap

    var title: String {
        switch self {
        case .scroll:
            return "1 Row + Scroll"
        case .wrap:
            return "Wrap Into Rows"
        }
    }
}

enum PreviewContentSize: String, CaseIterable {
    case extraSmall
    case small
    case regular
    case large
    case extraLarge

    var title: String {
        switch self {
        case .extraSmall:
            return "Extra Small"
        case .small:
            return "Small"
        case .regular:
            return "Regular"
        case .large:
            return "Large"
        case .extraLarge:
            return "Extra Large"
        }
    }
}

enum PreviewWindowHeight: String, CaseIterable {
    case extraSmall
    case small
    case regular
    case large
    case extraLarge

    var title: String {
        switch self {
        case .extraSmall:
            return "Extra Small"
        case .small:
            return "Small"
        case .regular:
            return "Regular"
        case .large:
            return "Large"
        case .extraLarge:
            return "Extra Large"
        }
    }
}
