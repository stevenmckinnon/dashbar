import Foundation
import Testing
@testable import Dashbar

// MARK: - Refresh requests don't pile up

@Suite struct CoalescerTests {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var runs: [Worker.LiveRequest] = []
        func add(_ r: Worker.LiveRequest) { lock.withLock { runs.append(r) } }
        var all: [Worker.LiveRequest] { lock.withLock { runs } }
    }

    @Test func aBurstOfRequestsBecomesOneMergedJob() {
        let queue = DispatchQueue(label: "test.coalescer")
        let log = Log()
        let c = Coalescer<Worker.LiveRequest>(queue: queue, merge: { $0.merged(with: $1) }) { log.add($0) }
        queue.suspend()
        c.submit(.init(servers: false, panel: false, system: true))
        c.submit(.init(servers: true, panel: false, system: false))
        for _ in 0..<20 { c.submit(.init()) }
        queue.resume()
        queue.sync {}
        #expect(log.all == [Worker.LiveRequest(servers: true, panel: false, system: true)])
    }

    @Test func requestsDuringARunQueueExactlyOneMore() {
        let queue = DispatchQueue(label: "test.coalescer.running")
        let log = Log()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let c = Coalescer<Worker.LiveRequest>(queue: queue, merge: { $0.merged(with: $1) }) { r in
            log.add(r)
            if log.all.count == 1 { started.signal(); release.wait() }
        }
        c.submit(.init())
        started.wait()                                  // the first job is running
        for _ in 0..<10 { c.submit(.init(panel: true)) }
        release.signal()
        queue.sync {}
        #expect(log.all == [Worker.LiveRequest(), Worker.LiveRequest(panel: true)])
    }
}
