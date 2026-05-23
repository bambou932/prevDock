import Cocoa

enum RunningAppMatcher {
    static func matchDockItem(title: String?, url: URL?) -> NSRunningApplication? {
        let apps = regularApps

        if let url,
           isApplicationURL(url),
           let match = apps.first(where: { bundleURL($0, matches: url) }) {
            return match
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

        if let exact = apps.first(where: { normalize($0.localizedName ?? "") == normalizedTitle }) {
            return exact
        }

        return apps
            .filter { app in
                let name = normalize(app.localizedName ?? "")
                return !name.isEmpty && (normalizedTitle.contains(name) || name.contains(normalizedTitle))
            }
            .sorted { ($0.localizedName ?? "").count > ($1.localizedName ?? "").count }
            .first
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
