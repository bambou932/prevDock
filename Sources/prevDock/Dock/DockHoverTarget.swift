import Cocoa

struct DockHoverTarget {
    let app: NSRunningApplication?
    let title: String
    let url: URL?
    let anchor: CGRect

    var key: String {
        if let app {
            return "app:\(app.processIdentifier)"
        }
        if let url {
            return "dock:\(url.isFileURL ? url.path : url.absoluteString)"
        }
        return "dock:\(title)"
    }
}
