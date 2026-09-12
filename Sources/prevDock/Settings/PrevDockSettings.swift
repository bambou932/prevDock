import Foundation

enum PrevDockSettings {
    static let didChangeNotification = Notification.Name("PrevDockSettingsDidChange")
    static let previewSwitchDelayKey = "previewSwitchDelay"
    static let previewOverflowModeKey = "previewOverflowMode"
    static let previewAutoFitEnabledKey = "previewAutoFitEnabled"
    static let previewContentSizeKey = "previewContentSize"
    static let previewWindowHeightKey = "previewWindowHeight"
    static let previewCloseButtonEnabledKey = "previewCloseButtonEnabled"
    static let previewDesktopGroupingEnabledKey = "previewDesktopGroupingEnabled"
    static let dockAppClickPreviewEnabledKey = "dockAppClickPreviewEnabled"
    static let legacyDockContextClickPreviewEnabledKey = "dockContextClickPreviewEnabled"
    static let nativeDockLabelSuppressionEnabledKey = "nativeDockLabelSuppressionEnabled"
    static let launchAtLoginDefaultAppliedKey = "launchAtLoginDefaultApplied"
    static let launchAtLoginDefaultPendingKey = "launchAtLoginDefaultPending"
    static let permissionSetupShownKey = "permissionSetupShown"
    static let defaultPreviewSwitchDelay: TimeInterval = 0.3
    static let defaultPreviewOverflowMode = PreviewOverflowMode.scroll
    static let defaultPreviewAutoFitEnabled = true
    static let defaultPreviewContentSize = PreviewContentSize.regular
    static let defaultPreviewWindowHeight = PreviewWindowHeight.regular
    static let defaultPreviewCloseButtonEnabled = true
    static let defaultPreviewDesktopGroupingEnabled = true
    static let defaultDockAppClickPreviewEnabled = false
    static let defaultNativeDockLabelSuppressionEnabled = false
    static let previewSwitchDelayRange: ClosedRange<TimeInterval> = 0.0...2.0

    static func registerDefaults() {
        migrateLegacyAutoMode()
        UserDefaults.standard.register(defaults: [
            previewSwitchDelayKey: defaultPreviewSwitchDelay,
            previewContentSizeKey: defaultPreviewContentSize.rawValue,
            previewWindowHeightKey: defaultPreviewWindowHeight.rawValue,
            previewCloseButtonEnabledKey: defaultPreviewCloseButtonEnabled,
            previewDesktopGroupingEnabledKey: defaultPreviewDesktopGroupingEnabled,
            nativeDockLabelSuppressionEnabledKey: defaultNativeDockLabelSuppressionEnabled,
            launchAtLoginDefaultAppliedKey: false,
            launchAtLoginDefaultPendingKey: false,
            permissionSetupShownKey: false
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
            normalizedDelay(UserDefaults.standard.double(forKey: previewSwitchDelayKey))
        }
        set {
            set(normalizedDelay(newValue), replacing: previewSwitchDelay, forKey: previewSwitchDelayKey)
        }
    }

    static var previewOverflowMode: PreviewOverflowMode {
        get {
            let rawValue = UserDefaults.standard.object(forKey: previewOverflowModeKey) as? String
            return PreviewOverflowMode(rawValue: rawValue ?? "") ?? defaultPreviewOverflowMode
        }
        set {
            let defaults = UserDefaults.standard
            let currentRawValue = defaults.object(forKey: previewOverflowModeKey) as? String
            guard currentRawValue != newValue.rawValue else { return }
            persistInferredAutoFitPreferenceIfNeeded()
            defaults.set(newValue.rawValue, forKey: previewOverflowModeKey)
            postChange(forKey: previewOverflowModeKey)
        }
    }

    static var previewAutoFitEnabled: Bool {
        get {
            optionalBool(forKey: previewAutoFitEnabledKey) ?? inferredAutoFitPreference
        }
        set {
            set(newValue, replacing: previewAutoFitEnabled, forKey: previewAutoFitEnabledKey)
        }
    }

    static var previewContentSize: PreviewContentSize {
        get {
            PreviewContentSize(rawValue: UserDefaults.standard.string(forKey: previewContentSizeKey) ?? "") ??
                defaultPreviewContentSize
        }
        set {
            set(newValue.rawValue, replacing: previewContentSize.rawValue, forKey: previewContentSizeKey)
        }
    }

    static var previewWindowHeight: PreviewWindowHeight {
        get {
            PreviewWindowHeight(rawValue: UserDefaults.standard.string(forKey: previewWindowHeightKey) ?? "") ??
                defaultPreviewWindowHeight
        }
        set {
            set(newValue.rawValue, replacing: previewWindowHeight.rawValue, forKey: previewWindowHeightKey)
        }
    }

    static var previewCloseButtonEnabled: Bool {
        get {
            optionalBool(forKey: previewCloseButtonEnabledKey) ??
                defaultPreviewCloseButtonEnabled
        }
        set {
            set(newValue, replacing: previewCloseButtonEnabled, forKey: previewCloseButtonEnabledKey)
        }
    }

    static var previewDesktopGroupingEnabled: Bool {
        get {
            optionalBool(forKey: previewDesktopGroupingEnabledKey) ??
                defaultPreviewDesktopGroupingEnabled
        }
        set {
            set(newValue, replacing: previewDesktopGroupingEnabled, forKey: previewDesktopGroupingEnabledKey)
        }
    }

    static var dockAppClickPreviewEnabled: Bool {
        get {
            optionalBool(forKey: dockAppClickPreviewEnabledKey) ??
                optionalBool(forKey: legacyDockContextClickPreviewEnabledKey) ??
                defaultDockAppClickPreviewEnabled
        }
        set {
            set(newValue, replacing: dockAppClickPreviewEnabled, forKey: dockAppClickPreviewEnabledKey)
        }
    }

    static var nativeDockLabelSuppressionEnabled: Bool {
        get {
            optionalBool(forKey: nativeDockLabelSuppressionEnabledKey) ??
                defaultNativeDockLabelSuppressionEnabled
        }
        set {
            set(newValue, replacing: nativeDockLabelSuppressionEnabled, forKey: nativeDockLabelSuppressionEnabledKey)
        }
    }

    static var launchAtLoginDefaultApplied: Bool {
        get {
            optionalBool(forKey: launchAtLoginDefaultAppliedKey) ?? false
        }
        set {
            guard newValue != launchAtLoginDefaultApplied else { return }
            UserDefaults.standard.set(newValue, forKey: launchAtLoginDefaultAppliedKey)
        }
    }

    static var permissionSetupShown: Bool {
        get {
            optionalBool(forKey: permissionSetupShownKey) ?? false
        }
        set {
            guard newValue != permissionSetupShown else { return }
            UserDefaults.standard.set(newValue, forKey: permissionSetupShownKey)
        }
    }

    static var launchAtLoginDefaultPending: Bool {
        get {
            optionalBool(forKey: launchAtLoginDefaultPendingKey) ?? false
        }
        set {
            guard newValue != launchAtLoginDefaultPending else { return }
            UserDefaults.standard.set(newValue, forKey: launchAtLoginDefaultPendingKey)
        }
    }

    static func formattedDelay(_ value: TimeInterval) -> String {
        let clamped = normalizedDelay(value)
        if clamped <= 0.01 {
            return "Instant"
        }
        return String(format: "%.2f s", clamped)
    }

    private static func normalizedDelay(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultPreviewSwitchDelay }
        return min(max(value, previewSwitchDelayRange.lowerBound), previewSwitchDelayRange.upperBound)
    }

    private static func optionalBool(forKey key: String) -> Bool? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    private static var inferredAutoFitPreference: Bool {
        let rawMode = UserDefaults.standard.object(forKey: previewOverflowModeKey) as? String
        switch rawMode {
        case PreviewOverflowMode.scroll.rawValue, PreviewOverflowMode.wrap.rawValue:
            return false
        default:
            return defaultPreviewAutoFitEnabled
        }
    }

    private static func migrateLegacyAutoMode() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: previewOverflowModeKey) as? String == "auto" else { return }
        defaults.set(PreviewOverflowMode.scroll.rawValue, forKey: previewOverflowModeKey)
        defaults.set(true, forKey: previewAutoFitEnabledKey)
    }

    private static func persistInferredAutoFitPreferenceIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: previewAutoFitEnabledKey) == nil else { return }
        defaults.set(inferredAutoFitPreference, forKey: previewAutoFitEnabledKey)
    }

    private static func set<Value: Equatable>(_ value: Value, replacing currentValue: Value, forKey key: String) {
        guard value != currentValue else { return }
        UserDefaults.standard.set(value, forKey: key)
        postChange(forKey: key)
    }

    private static func postChange(forKey key: String) {
        NotificationCenter.default.post(name: didChangeNotification, object: key)
    }
}
