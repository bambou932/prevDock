import ApplicationServices
import Cocoa

// The scan is tested independently of live running applications and Dock permissions.
struct DockHoverTarget {
    let app: NSRunningApplication?
    let title: String
    let url: URL?
    let anchor: CGRect
}

@main
enum DockHoverTargetTests {
    static func main() {
        testSlowHitUsesSharedBudget()
        testCandidateStopsBetweenFields()
        testTitleFallbackStopsAtDeadline()
        testParentDoesNotResetBudget()
        testMetadataIsReadOnce()
        testCandidateCompatibility()
        testTitleAndURLFallbacks()
        testGeometryUsesRemainingBudget()
        testParentDepthLimit()
        print("Dock hover target tests passed")
    }

    static func testSlowHitUsesSharedBudget() {
        let fixture = Fixture()
        fixture.durations["hit"] = 0.13
        let scan = fixture.scan()
        check(scan.item(at: .zero, dockElement: fixture.dock) == nil, "slow hit must exhaust the whole scan")
        check(fixture.calls == ["hit"], "no candidate reads may begin after slow hit")
    }

    static func testCandidateStopsBetweenFields() {
        let fixture = Fixture()
        fixture.durations = ["hit": 0.06, "leaf:AXRole": 0.04, "leaf:AXRoleDescription": 0.03]
        let scan = fixture.scan()
        check(scan.item(at: .zero, dockElement: fixture.dock) == nil, "partial candidate must not be used")
        check(fixture.calls == ["hit", "leaf:AXRole", "leaf:AXRoleDescription"], "budget must cover individual fields")
    }

    static func testTitleFallbackStopsAtDeadline() {
        let fixture = Fixture()
        fixture.fields["leaf:AXTitle"] = "  "
        fixture.fields["leaf:AXDescription"] = "Application"
        fixture.durations = ["leaf:AXTitle": 0.07, "leaf:AXDescription": 0.06]
        let scan = fixture.scan()
        check(scan.item(at: .zero, dockElement: fixture.dock) == nil, "expired title discovery must not produce a target")
        check(!fixture.calls.contains("leaf:AXURL"), "URL IPC must not begin after title exhausted the budget")
        check(!fixture.calls.contains("leaf:parent"), "parent IPC must not begin after title exhausted the budget")
    }

    static func testParentDoesNotResetBudget() {
        let fixture = Fixture()
        fixture.fields["leaf:AXRole"] = "AXImage"
        fixture.fields["leaf:AXSubrole"] = ""
        fixture.hasParent = true
        fixture.durations = ["leaf:parent": 0.08, "parent:AXRole": 0.05]
        let scan = fixture.scan()
        check(scan.item(at: .zero, dockElement: fixture.dock) == nil, "parent traversal shares the original deadline")
        check(fixture.calls.last == "parent:AXRole", "parent must not start a fresh candidate budget")
    }

    static func testMetadataIsReadOnce() {
        let fixture = Fixture()
        fixture.fields["leaf:AXTitle"] = " \u{200B}Application\u{FEFF}\n3 windows "
        let scan = fixture.scan()
        guard let item = scan.item(at: .zero, dockElement: fixture.dock) else { fatalError("expected Dock item") }
        check(item.title == "Application", "title cleaning must preserve the original behavior")
        check(item.subrole == "AXApplicationDockItem" && item.url == fixture.url, "reuse application identity fields")
        let anchor = scan.anchor(for: item.element, fallback: .zero)
        check(anchor.size == CGSize(width: 64, height: 64), "geometry must survive normal fast reads")
        for attribute in ["AXRole", "AXRoleDescription", "AXSubrole", "AXTitle", "AXURL", "AXPosition", "AXSize"] {
            check(fixture.calls.filter { $0 == "leaf:\(attribute)" }.count == 1, "\(attribute) must be read once")
        }
        check(!fixture.calls.contains("leaf:AXDescription"), "valid title must not trigger fallback title reads")
    }

    static func testCandidateCompatibility() {
        for fields in [
            ["leaf:AXRole": "AXDockItem", "leaf:AXSubrole": ""],
            ["leaf:AXRole": "AXButton", "leaf:AXSubrole": ""],
            ["leaf:AXRole": "AXGroup", "leaf:AXRoleDescription": "Dock item", "leaf:AXSubrole": ""],
            ["leaf:AXRole": "AXGroup", "leaf:AXSubrole": "AXApplicationDockItem"]
        ] {
            let fixture = Fixture()
            fixture.fields.merge(fields) { _, value in value }
            let scan = fixture.scan()
            check(scan.item(at: .zero, dockElement: fixture.dock) != nil, "all existing candidate role fallbacks must remain")
        }
        let fixture = Fixture()
        fixture.fields["leaf:AXRole"] = "AXImage"
        fixture.fields["leaf:AXSubrole"] = ""
        fixture.hasParent = true
        let scan = fixture.scan()
        check(scan.item(at: .zero, dockElement: fixture.dock)?.title == "Parent app", "child hits must still resolve their Dock parent")
    }

    static func testTitleAndURLFallbacks() {
        for attribute in ["AXDescription", "AXHelp"] {
            let fixture = Fixture()
            fixture.fields["leaf:AXTitle"] = " "
            fixture.fields["leaf:\(attribute)"] = "Fallback app"
            let scan = fixture.scan()
            check(scan.item(at: .zero, dockElement: fixture.dock)?.title == "Fallback app", "\(attribute) remains a title fallback")
        }
        let fixture = Fixture()
        fixture.fields["leaf:AXTitle"] = " "
        let scan = fixture.scan()
        let item = scan.item(at: .zero, dockElement: fixture.dock)
        check(item?.title == nil && item?.url == fixture.url, "URL-only Dock items remain candidates")
    }

    static func testGeometryUsesRemainingBudget() {
        let fixture = Fixture()
        let scan = fixture.scan()
        guard let item = scan.item(at: .zero, dockElement: fixture.dock) else { fatalError("expected Dock item") }
        fixture.uptime = 0.10
        fixture.durations["leaf:AXPosition"] = 0.03
        let anchor = scan.anchor(for: item.element, fallback: CGPoint(x: 100, y: 200))
        check(anchor == CGRect(x: 76, y: 176, width: 48, height: 48), "missing geometry retains the pointer fallback")
        check(!fixture.calls.contains("leaf:AXSize"), "size IPC must not start after position exhausts the deadline")
        let count = fixture.calls.count
        _ = scan.anchor(for: item.element, fallback: .zero)
        check(fixture.calls.count == count, "expired scans may not issue fresh geometry reads")
    }

    static func testParentDepthLimit() {
        let fixture = Fixture()
        fixture.fields["leaf:AXRole"] = "AXImage"
        fixture.fields["leaf:AXSubrole"] = ""
        fixture.cyclesParent = true
        let scan = fixture.scan()
        check(scan.item(at: .zero, dockElement: fixture.dock) == nil, "cyclic ancestry must terminate")
        check(fixture.calls.filter { $0 == "leaf:AXRole" }.count == 8, "keep the existing eight-element depth cap")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}

private final class Fixture {
    let dock = AXUIElementCreateApplication(17771)
    let leaf = AXUIElementCreateApplication(17772)
    let parent = AXUIElementCreateApplication(17773)
    let url = URL(fileURLWithPath: "/Applications/Example.app")
    var uptime: TimeInterval = 0
    var durations: [String: TimeInterval] = [:]
    var calls: [String] = []
    var fields = [
        "leaf:AXRole": "AXDockItem", "leaf:AXSubrole": "AXApplicationDockItem", "leaf:AXTitle": "Application",
        "parent:AXRole": "AXDockItem", "parent:AXSubrole": "AXApplicationDockItem", "parent:AXTitle": "Parent app"
    ]
    var hasParent = false
    var cyclesParent = false

    func scan() -> DockHoverTargetScan {
        DockHoverTargetScan(access: .init(
            now: { self.uptime },
            prepare: { _ in },
            hit: { _, _ in self.record("hit"); return self.leaf },
            string: { element, attribute in
                let key = self.key(element, attribute as String)
                self.record(key)
                return self.fields[key]
            },
            url: { element, attribute in self.record(self.key(element, attribute as String)); return self.url },
            parent: { element in
                self.record(self.key(element, "parent"))
                if self.cyclesParent { return self.leaf }
                return self.hasParent && CFEqual(element, self.leaf) ? self.parent : nil
            },
            position: { element, attribute in
                self.record(self.key(element, attribute as String))
                return CGPoint(x: 50, y: 75)
            },
            size: { element, attribute in
                self.record(self.key(element, attribute as String))
                return CGSize(width: 64, height: 64)
            }
        ))
    }

    private func key(_ element: AXUIElement, _ attribute: String) -> String {
        "\(CFEqual(element, leaf) ? "leaf" : "parent"):\(attribute)"
    }

    private func record(_ name: String) {
        calls.append(name)
        uptime += durations[name] ?? 0
    }
}
