import ApplicationServices
import Darwin
import Foundation

@main
enum WindowAccessibilityAttributesTests {
    private static var failureCount = 0
    private static let element = AXUIElementCreateApplication(-1)

    static func main() {
        testBatchedWindowAttributes()
        testUnsupportedOptionalAttributes()
        testUnsupportedBatchFallsBack()
        testStaleWindowDoesNotRetry()
        testTimeoutStopsFallback()
        testCancellationStopsFallback()
        testFailedBatchAttributeRejectsSnapshot()
        testCancellationAfterBatchRejectsSnapshot()
        guard failureCount == 0 else {
            fputs("WindowAccessibilityAttributesTests: \(failureCount) failure(s)\n", stderr)
            exit(1)
        }
        print("WindowAccessibilityAttributesTests: passed")
    }

    private static func testBatchedWindowAttributes() {
        var point = CGPoint(x: 120, y: -45)
        var size = CGSize(width: 1200, height: 800)
        let values: [Any] = [
            "  Window title \n", kAXWindowRole, kAXStandardWindowSubrole,
            AXValueCreate(.cgPoint, &point)!, AXValueCreate(.cgSize, &size)!,
            kCFBooleanTrue!, kCFBooleanFalse!
        ]
        var individualReadCount = 0
        let result = WindowAccessibilityAttributes.read(
            from: element,
            copyMultiple: { _, names in
                expect(names.count == values.count, "batch should request every window attribute once")
                return (.success, values)
            },
            copySingle: { _, _ in
                individualReadCount += 1
                return (.failure, nil)
            }
        )
        guard case .available(let attributes) = result else {
            expect(false, "valid batch should return window attributes")
            return
        }
        expect(attributes.title == "Window title", "window titles should be trimmed")
        expect(attributes.role == kAXWindowRole, "window role should survive batching")
        expect(attributes.subrole == kAXStandardWindowSubrole, "window subrole should survive batching")
        expect(attributes.position == point, "AX point should preserve coordinates on secondary displays")
        expect(attributes.size == size, "AX size should preserve window geometry")
        expect(attributes.isMinimized, "CFBoolean true should decode correctly")
        expect(!attributes.isFullscreen, "CFBoolean false should decode correctly")
        expect(individualReadCount == 0, "successful batching should avoid seven extra IPC calls")
    }

    private static func testUnsupportedOptionalAttributes() {
        var unsupported = AXError.attributeUnsupported
        let error = AXValueCreate(.axError, &unsupported)!
        let values: [Any] = [NSNull(), kAXWindowRole, kAXStandardWindowSubrole, error, error, error, error]
        let result = WindowAccessibilityAttributes.read(
            from: element,
            copyMultiple: { _, _ in (.success, values) }
        )
        guard case .available(let attributes) = result else {
            expect(false, "unsupported optional fields must not discard the window")
            return
        }
        expect(attributes.title == nil, "null title should remain absent")
        expect(attributes.position == nil && attributes.size == nil, "AX errors must not decode as geometry")
        expect(!attributes.isMinimized && !attributes.isFullscreen, "AX errors must not decode as true")
    }

    private static func testUnsupportedBatchFallsBack() {
        var readCount = 0
        let result = WindowAccessibilityAttributes.read(
            from: element,
            copyMultiple: { _, _ in (.notImplemented, nil) },
            copySingle: { _, name in
                readCount += 1
                if name == kAXRoleAttribute { return (.success, kAXWindowRole) }
                if name == kAXSubroleAttribute { return (.success, kAXStandardWindowSubrole) }
                return (.attributeUnsupported, nil)
            }
        )
        guard case .available(let attributes) = result else {
            expect(false, "apps without multiple-attribute support must still expose windows")
            return
        }
        expect(readCount == 7, "fallback should read each attribute once")
        expect(attributes.role == kAXWindowRole, "fallback should preserve the window role")
        expect(attributes.size == nil && !attributes.isMinimized, "missing fallback fields should remain optional")
    }

    private static func testStaleWindowDoesNotRetry() {
        var readCount = 0
        let result = WindowAccessibilityAttributes.read(
            from: element,
            copyMultiple: { _, _ in (.invalidUIElement, nil) },
            copySingle: { _, _ in
                readCount += 1
                return (.failure, nil)
            }
        )
        expect(isUnavailable(result, error: .invalidUIElement), "closed windows must be distinguishable from timeouts")
        expect(readCount == 0, "a vanished window must not trigger individual retries")
    }

    private static func testTimeoutStopsFallback() {
        var readCount = 0
        let result = WindowAccessibilityAttributes.read(
            from: element,
            copyMultiple: { _, _ in (.attributeUnsupported, nil) },
            copySingle: { _, _ in
                readCount += 1
                return (.cannotComplete, nil)
            }
        )
        expect(isUnavailable(result, error: .cannotComplete), "AX timeouts must remain failures, not fresh empty metadata")
        expect(readCount == 1, "a timed-out app should not receive six additional reads")
    }

    private static func testCancellationStopsFallback() {
        var readCount = 0
        let result = WindowAccessibilityAttributes.read(
            from: element,
            shouldContinue: { readCount == 0 },
            copyMultiple: { _, _ in (.attributeUnsupported, nil) },
            copySingle: { _, _ in
                readCount += 1
                return (.success, "value")
            }
        )
        expect(isUnavailable(result, error: .cannotComplete), "cancelled reads must not publish partial attributes")
        expect(readCount == 1, "cancellation should stop before the next individual AX call")
    }

    private static func testFailedBatchAttributeRejectsSnapshot() {
        for failure: AXError in [.failure, .cannotComplete, .invalidUIElement, .apiDisabled] {
            for index in 0..<7 {
                var failureValue = failure
                let axError = AXValueCreate(.axError, &failureValue)!
                var values: [Any] = ["Window", kAXWindowRole, kAXStandardWindowSubrole,
                                     NSNull(), NSNull(), false, false]
                values[index] = axError
                var fallbackReads = 0
                let result = WindowAccessibilityAttributes.read(
                    from: element,
                    copyMultiple: { _, _ in (.success, values) },
                    copySingle: { _, _ in
                        fallbackReads += 1
                        return (.success, NSNull())
                    }
                )
                expect(isUnavailable(result, error: failure),
                       "batched attribute failure must preserve cached metadata instead of publishing a partial window")
                expect(fallbackReads == 0, "failed batch must not multiply IPC retries")
            }
        }
    }

    private static func testCancellationAfterBatchRejectsSnapshot() {
        var active = true
        let result = WindowAccessibilityAttributes.read(
            from: element,
            shouldContinue: { active },
            copyMultiple: { _, _ in
                active = false
                return (.success, ["Window", kAXWindowRole, kAXStandardWindowSubrole,
                                   NSNull(), NSNull(), false, false])
            }
        )
        expect(isUnavailable(result, error: .cannotComplete),
               "cancellation during a successful batch must not publish metadata")
    }

    private static func isUnavailable(_ result: WindowAccessibilityAttributes.ReadResult, error: AXError) -> Bool {
        guard case .unavailable(let actualError) = result else { return false }
        return actualError == error
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else { return }
        failureCount += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}
