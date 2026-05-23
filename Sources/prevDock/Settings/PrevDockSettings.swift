import Foundation

enum PreviewOverflowMode: String, CaseIterable {
    case wrap
    case scroll

    var title: String {
        switch self {
        case .wrap:
            return "Wrap"
        case .scroll:
            return "Scroll"
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

enum PrevDockSettings {
    static let didChangeNotification = Notification.Name("PrevDockSettingsDidChange")
    static let previewSwitchDelayKey = "previewSwitchDelay"
    static let previewOverflowModeKey = "previewOverflowMode"
    static let previewContentSizeKey = "previewContentSize"
    static let previewWindowHeightKey = "previewWindowHeight"
    static let previewCloseButtonEnabledKey = "previewCloseButtonEnabled"
    static let previewDesktopGroupingEnabledKey = "previewDesktopGroupingEnabled"
    static let dockAppClickPreviewEnabledKey = "dockAppClickPreviewEnabled"
    static let legacyDockContextClickPreviewEnabledKey = "dockContextClickPreviewEnabled"
    static let nativeDockLabelSuppressionEnabledKey = "nativeDockLabelSuppressionEnabled"
    static let launchAtLoginDefaultAppliedKey = "launchAtLoginDefaultApplied"
    static let defaultPreviewSwitchDelay: TimeInterval = 0.3
    static let defaultPreviewOverflowMode = PreviewOverflowMode.scroll
    static let defaultPreviewContentSize = PreviewContentSize.regular
    static let defaultPreviewWindowHeight = PreviewWindowHeight.regular
    static let defaultPreviewCloseButtonEnabled = true
    static let defaultPreviewDesktopGroupingEnabled = true
    static let defaultDockAppClickPreviewEnabled = false
    static let defaultNativeDockLabelSuppressionEnabled = false
    static let previewSwitchDelayRange: ClosedRange<TimeInterval> = 0.0...2.0

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            previewSwitchDelayKey: defaultPreviewSwitchDelay,
            previewOverflowModeKey: defaultPreviewOverflowMode.rawValue,
            previewContentSizeKey: defaultPreviewContentSize.rawValue,
            previewWindowHeightKey: defaultPreviewWindowHeight.rawValue,
            previewCloseButtonEnabledKey: defaultPreviewCloseButtonEnabled,
            previewDesktopGroupingEnabledKey: defaultPreviewDesktopGroupingEnabled,
            dockAppClickPreviewEnabledKey: defaultDockAppClickPreviewEnabled,
            nativeDockLabelSuppressionEnabledKey: defaultNativeDockLabelSuppressionEnabled,
            launchAtLoginDefaultAppliedKey: false
        ])
    }

    static var hasPersistentSettingsDomain: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else {
            return false
        }
        return !domain.isEmpty
    }

    static var previewSwitchDelay: TimeInterval {
        get {
            clamp(UserDefaults.standard.double(forKey: previewSwitchDelayKey))
        }
        set {
            set(clamp(newValue), forKey: previewSwitchDelayKey)
        }
    }

    static var previewOverflowMode: PreviewOverflowMode {
        get {
            PreviewOverflowMode(rawValue: UserDefaults.standard.string(forKey: previewOverflowModeKey) ?? "") ??
                defaultPreviewOverflowMode
        }
        set {
            set(newValue.rawValue, forKey: previewOverflowModeKey)
        }
    }

    static var previewContentSize: PreviewContentSize {
        get {
            PreviewContentSize(rawValue: UserDefaults.standard.string(forKey: previewContentSizeKey) ?? "") ??
                defaultPreviewContentSize
        }
        set {
            set(newValue.rawValue, forKey: previewContentSizeKey)
        }
    }

    static var previewWindowHeight: PreviewWindowHeight {
        get {
            PreviewWindowHeight(rawValue: UserDefaults.standard.string(forKey: previewWindowHeightKey) ?? "") ??
                defaultPreviewWindowHeight
        }
        set {
            set(newValue.rawValue, forKey: previewWindowHeightKey)
        }
    }

    static var previewCloseButtonEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: previewCloseButtonEnabledKey) as? Bool ??
                defaultPreviewCloseButtonEnabled
        }
        set {
            set(newValue, forKey: previewCloseButtonEnabledKey)
        }
    }

    static var previewDesktopGroupingEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: previewDesktopGroupingEnabledKey) as? Bool ??
                defaultPreviewDesktopGroupingEnabled
        }
        set {
            set(newValue, forKey: previewDesktopGroupingEnabledKey)
        }
    }

    static var dockAppClickPreviewEnabled: Bool {
        get {
            if let value = persistedBool(forKey: dockAppClickPreviewEnabledKey) {
                return value
            }
            return persistedBool(forKey: legacyDockContextClickPreviewEnabledKey) ??
                defaultDockAppClickPreviewEnabled
        }
        set {
            set(newValue, forKey: dockAppClickPreviewEnabledKey)
        }
    }

    static var nativeDockLabelSuppressionEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: nativeDockLabelSuppressionEnabledKey) as? Bool ??
                defaultNativeDockLabelSuppressionEnabled
        }
        set {
            set(newValue, forKey: nativeDockLabelSuppressionEnabledKey)
        }
    }

    static var launchAtLoginDefaultApplied: Bool {
        get {
            UserDefaults.standard.object(forKey: launchAtLoginDefaultAppliedKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: launchAtLoginDefaultAppliedKey)
        }
    }

    static func formattedDelay(_ value: TimeInterval) -> String {
        let clamped = clamp(value)
        if clamped <= 0.01 {
            return "Instant"
        }
        return String(format: "%.2f s", clamped)
    }

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value, previewSwitchDelayRange.lowerBound), previewSwitchDelayRange.upperBound)
    }

    private static func persistedBool(forKey key: String) -> Bool? {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else {
            return nil
        }
        return domain[key] as? Bool
    }

    private static func set(_ value: Any, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
