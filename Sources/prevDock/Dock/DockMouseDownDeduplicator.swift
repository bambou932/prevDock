struct DockMouseDownDeduplicator {
    private struct Event {
        let kind: MouseDownKind
        let timestamp: UInt64
    }

    private let capacity: Int
    private var handledEvents = [Event]()

    init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    mutating func record(kind: MouseDownKind, timestamp: UInt64) {
        guard timestamp != 0, !wasHandled(kind: kind, timestamp: timestamp) else { return }
        if handledEvents.count == capacity {
            handledEvents.removeFirst()
        }
        handledEvents.append(Event(kind: kind, timestamp: timestamp))
    }

    func wasHandled(kind: MouseDownKind, timestamp: UInt64?) -> Bool {
        guard let timestamp, timestamp != 0 else { return false }
        return handledEvents.contains { $0.kind == kind && $0.timestamp == timestamp }
    }
}
