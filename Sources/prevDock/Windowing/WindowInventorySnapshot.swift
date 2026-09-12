import Foundation

enum WindowInventorySnapshot {
    static func merging<Value, Identifier: Hashable>(
        discovered: [Value],
        previous: [Value],
        unresolvedIDs: Set<Identifier>?,
        identifier: (Value) -> Identifier
    ) -> [Value] {
        merging(
            discovered: discovered, previous: previous, unresolvedIDs: unresolvedIDs,
            identifier: identifier, shouldRetain: { _ in true }
        )
    }

    static func merging<Value, Identifier: Hashable>(
        discovered: [Value],
        previous: [Value],
        unresolvedIDs: Set<Identifier>?,
        identifier: (Value) -> Identifier,
        shouldRetain: (Value) throws -> Bool
    ) rethrows -> [Value] {
        var seen = Set(discovered.map(identifier))
        let retained = try previous.filter { value in
            let id = identifier(value)
            guard unresolvedIDs?.contains(id) ?? true,
                  seen.insert(id).inserted else { return false }
            return try shouldRetain(value)
        }
        // A scan deadline is not evidence that a WindowServer-confirmed window closed.
        return discovered + retained
    }
}
