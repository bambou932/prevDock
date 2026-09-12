import ApplicationServices
import Foundation

struct WindowAccessibilityAttributes {
    enum ReadResult {
        case available(WindowAccessibilityAttributes)
        case unavailable(AXError)
    }

    private static let names = [
        kAXTitleAttribute,
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXMinimizedAttribute,
        "AXFullScreen"
    ]

    private let values: [Any]

    var title: String? {
        (values[0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var role: String? { values[1] as? String }
    var subrole: String? { values[2] as? String }
    var position: CGPoint? {
        guard let value = axValue(at: 3, type: .cgPoint) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let value = axValue(at: 4, type: .cgSize) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
    var isMinimized: Bool { values[5] as? Bool ?? false }
    var isFullscreen: Bool { values[6] as? Bool ?? false }

    static func read(
        from element: AXUIElement,
        shouldContinue: () -> Bool = { true },
        copyMultiple: (AXUIElement, [String]) -> (AXError, [Any]?) = copyMultipleAttributes,
        copySingle: (AXUIElement, String) -> (AXError, Any?) = copyAttribute
    ) -> ReadResult {
        guard shouldContinue() else { return .unavailable(.cannotComplete) }
        let (error, values) = copyMultiple(element, names)
        guard shouldContinue() else { return .unavailable(.cannotComplete) }
        if error == .attributeUnsupported || error == .notImplemented {
            return readIndividually(from: element, shouldContinue: shouldContinue, copySingle: copySingle)
        }
        guard error == .success else { return .unavailable(error) }
        guard let values, values.count == names.count else { return .unavailable(.failure) }
        if let failure = readFailure(in: values) { return .unavailable(failure) }
        return .available(WindowAccessibilityAttributes(values: values))
    }

    private static func readIndividually(
        from element: AXUIElement,
        shouldContinue: () -> Bool,
        copySingle: (AXUIElement, String) -> (AXError, Any?)
    ) -> ReadResult {
        var values = [Any]()
        for name in names {
            guard shouldContinue() else { return .unavailable(.cannotComplete) }
            let (error, value) = copySingle(element, name)
            switch error {
            case .success, .attributeUnsupported, .noValue, .notImplemented:
                values.append(value ?? NSNull())
            default:
                return .unavailable(error)
            }
        }
        return .available(WindowAccessibilityAttributes(values: values))
    }

    private static func readFailure(in values: [Any]) -> AXError? {
        for value in values {
            let rawValue = value as CFTypeRef
            guard CFGetTypeID(rawValue) == AXValueGetTypeID() else { continue }
            let axValue = rawValue as! AXValue
            var error = AXError.success
            guard AXValueGetType(axValue) == .axError,
                  AXValueGetValue(axValue, .axError, &error) else {
                continue
            }
            switch error {
            case .success, .attributeUnsupported, .noValue, .notImplemented:
                continue
            default:
                return error
            }
        }
        return nil
    }

    private static func copyMultipleAttributes(
        from element: AXUIElement,
        names: [String]
    ) -> (AXError, [Any]?) {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )
        return (error, values as? [Any])
    }

    private static func copyAttribute(from element: AXUIElement, name: String) -> (AXError, Any?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }

    private func axValue(at index: Int, type: AXValueType) -> AXValue? {
        let rawValue = values[index] as CFTypeRef
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let axValue = rawValue as! AXValue
        return AXValueGetType(axValue) == type ? axValue : nil
    }
}
