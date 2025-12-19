import Foundation

enum LogBatchingUtility {

    static let defaultBatchSize = 10
    static let defaultFlushInterval: Duration = .milliseconds(100)

    static func batchLines<S: AsyncSequence>(
        from asyncSequence: S,
        batchSize: Int = defaultBatchSize,
        flushInterval: Duration = defaultFlushInterval,
        handler: @escaping ([String]) -> Void
    ) async throws where S.Element == String {
        var buffer: [String] = []
        var lastFlush = ContinuousClock.now

        for try await line in asyncSequence {
            buffer.append(line)

            let now = ContinuousClock.now
            if buffer.count >= batchSize || now - lastFlush >= flushInterval {
                handler(buffer)
                buffer.removeAll(keepingCapacity: true)
                lastFlush = now
            }
        }

        // Flush remaining lines
        if !buffer.isEmpty {
            handler(buffer)
        }
    }
}
