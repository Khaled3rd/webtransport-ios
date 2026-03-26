import Foundation

/// Lock-free ring buffer for NAL unit payloads, used to pass data between
/// the WebTransport bridge and the H264 decoder without blocking the main thread.
actor NalRingBuffer {
    private var items: [Data] = []
    private let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    func push(_ data: Data) {
        if items.count >= capacity {
            items.removeFirst()
        }
        items.append(data)
    }

    func pop() -> Data? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
}
