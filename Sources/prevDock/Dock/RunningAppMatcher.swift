import Cocoa

enum RunningAppMatcher {
    static func matchDockItem(title: String?, url: URL?) -> NSRunningApplication? {
        let apps = regularApps

        if let url, isApplicationURL(url) {
            let result = matchApplication(at: url, among: apps)
            if let app = result.app { return app }
            if result.isAuthoritative { return nil }
        }

        guard let title, !title.isEmpty else { return nil }
        return matchDockTitle(title, among: apps)
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

    private static func matchApplication(
        at dockURL: URL,
        among apps: [NSRunningApplication]
    ) -> (app: NSRunningApplication?, isAuthoritative: Bool) {
        let pathMatches = apps.filter { bundleURL($0, matches: dockURL) }
        if !pathMatches.isEmpty {
            return (preferredApplication(from: pathMatches), true)
        }

        guard let bundleIdentifier = Bundle(url: dockURL)?.bundleIdentifier else {
            return (nil, false)
        }
        let identifierMatches = apps.filter { $0.bundleIdentifier == bundleIdentifier }
        return (preferredApplication(from: identifierMatches), true)
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
