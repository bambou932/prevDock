import Cocoa

enum RunningAppMatcher {
    static func matchDockItem(title: String?, url: URL?) -> NSRunningApplication? {
        if let url, isApplicationURL(url) {
            let result = matchApplication(at: url)
            if let app = result.app { return app }
            if result.isAuthoritative { return nil }
        }

        guard let title, !title.isEmpty else { return nil }
        return matchDockTitle(title, among: regularApps)
    }

    static func matchDockTitle(_ title: String) -> NSRunningApplication? {
        matchDockTitle(title, among: regularApps)
    }

    private static var regularApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
    }

    private static func matchDockTitle(_ title: String, among apps: [NSRunningApplication]) -> NSRunningApplication? {
        let normalizedTitle = normalize(title)
        guard !normalizedTitle.isEmpty else { return nil }

        let exactMatches = apps.filter { normalize($0.localizedName ?? "") == normalizedTitle }
        if !exactMatches.isEmpty {
            return preferredApplication(from: exactMatches)
        }

        let fuzzyMatches = apps.filter { app in
            let name = normalize(app.localizedName ?? "")
            guard !name.isEmpty,
                  normalizedTitle.contains(name) || name.contains(normalizedTitle) else {
                return false
            }
            let similarity = Double(min(name.count, normalizedTitle.count)) /
                Double(max(name.count, normalizedTitle.count))
            return similarity >= 0.6
        }
        guard fuzzyMatches.count == 1 else { return nil }
        return fuzzyMatches[0]
    }

    private static func matchApplication(at dockURL: URL) -> (app: NSRunningApplication?, isAuthoritative: Bool) {
        if let bundleIdentifier = Bundle(url: dockURL)?.bundleIdentifier {
            let identifierMatches = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter(isMatchableApplication)
            guard identifierMatches.count != 1 else {
                return (identifierMatches[0], true)
            }
            let pathMatches = identifierMatches.filter { bundleURL($0, matches: dockURL) }
            return (
                preferredApplication(from: pathMatches.isEmpty ? identifierMatches : pathMatches),
                true
            )
        }

        let pathMatches = regularApps.filter { bundleURL($0, matches: dockURL) }
        return (preferredApplication(from: pathMatches), !pathMatches.isEmpty)
    }

    private static func isMatchableApplication(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular &&
            app.bundleIdentifier != Bundle.main.bundleIdentifier &&
            !app.isTerminated
    }

    private static func preferredApplication(
        from apps: [NSRunningApplication]
    ) -> NSRunningApplication? {
        apps.first(where: \.isActive) ??
            apps.first(where: { !$0.isHidden && !$0.isTerminated }) ??
            apps.first(where: { !$0.isTerminated })
    }

    private static func bundleURL(_ app: NSRunningApplication, matches dockURL: URL) -> Bool {
        guard let appURL = app.bundleURL else { return false }
        return normalizedFilePath(appURL) == normalizedFilePath(dockURL)
    }

    private static func isApplicationURL(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    private static func normalizedFilePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
