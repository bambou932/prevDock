import Foundation
import Darwin

@main
enum SettingsBooleanTests {
    private static let booleanSettings: [(String, () -> Bool)] = [
        (PrevDockSettings.previewAutoFitEnabledKey, { PrevDockSettings.previewAutoFitEnabled }),
        (PrevDockSettings.previewCloseButtonEnabledKey, { PrevDockSettings.previewCloseButtonEnabled }),
        (PrevDockSettings.previewDesktopGroupingEnabledKey, { PrevDockSettings.previewDesktopGroupingEnabled }),
        (PrevDockSettings.dockAppClickPreviewEnabledKey, { PrevDockSettings.dockAppClickPreviewEnabled }),
        (PrevDockSettings.nativeDockLabelSuppressionEnabledKey, { PrevDockSettings.nativeDockLabelSuppressionEnabled }),
        (PrevDockSettings.launchAtLoginDefaultAppliedKey, { PrevDockSettings.launchAtLoginDefaultApplied }),
        (PrevDockSettings.launchAtLoginDefaultPendingKey, { PrevDockSettings.launchAtLoginDefaultPending }),
        (PrevDockSettings.permissionSetupShownKey, { PrevDockSettings.permissionSetupShown })
    ]

    static func main() {
        PrevDockSettings.registerDefaults()
        switch CommandLine.arguments.dropFirst().first {
        case "argv-yes": expectAll(true)
        case "argv-no": expectAll(false)
        case "legacy-yes": expect(PrevDockSettings.dockAppClickPreviewEnabled, "legacy argument should remain supported")
        case "legacy-overridden": expect(!PrevDockSettings.dockAppClickPreviewEnabled, "explicit new argument should override legacy")
        default: verifyAbsentAndNSNumberValues()
        }
        print("SettingsBooleanTests: passed")
    }

    private static func verifyAbsentAndNSNumberValues() {
        let defaults = UserDefaults.standard
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        let expected = [true, true, true, false, false, false, false, false]
        for (setting, value) in zip(booleanSettings, expected) {
            expect(setting.1() == value, "absent key should retain default for \(setting.0)")
        }
        for value in [true, false] {
            let values = Dictionary(uniqueKeysWithValues: booleanSettings.map { ($0.0, NSNumber(value: value)) })
            defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
            expectAll(value)
        }
        verifyLegacyAndAutoInference(defaults)
    }

    private static func verifyLegacyAndAutoInference(_ defaults: UserDefaults) {
        defaults.setVolatileDomain([
            PrevDockSettings.legacyDockContextClickPreviewEnabledKey: NSNumber(value: true)
        ], forName: UserDefaults.argumentDomain)
        expect(PrevDockSettings.dockAppClickPreviewEnabled, "legacy NSNumber should survive defaults registration")
        for mode in ["scroll", "wrap"] {
            defaults.setVolatileDomain([PrevDockSettings.previewOverflowModeKey: mode], forName: UserDefaults.argumentDomain)
            expect(!PrevDockSettings.previewAutoFitEnabled, "existing \(mode) choice should not implicitly enable auto-fit")
        }
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        expect(PrevDockSettings.previewAutoFitEnabled, "absent overflow should retain default auto-fit")
    }

    private static func expectAll(_ value: Bool) {
        for (key, read) in booleanSettings {
            expect(read() == value, "standard boolean conversion should produce \(value) for \(key)")
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
