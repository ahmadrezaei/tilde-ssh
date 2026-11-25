import Foundation
import Synchronization
import Testing
@testable import TildeSSH

@Suite struct OutputPipeTests {
    private final class ReadControlLog: Sendable {
        private let events = Mutex<[Bool]>([])
        func record(_ enabled: Bool) { events.withLock { $0.append(enabled) } }
        var all: [Bool] { events.withLock { $0 } }
    }

    private func chunk(_ size: Int) -> Data { Data(repeating: 1, count: size) }

    @Test func deliversInOrderAndCountsPendingBytes() async {
        let pipe = OutputPipe(highWater: 100, lowWater: 10)
        pipe.push(Data("a".utf8)); pipe.push(Data("bc".utf8))
        #expect(pipe.pendingBytes == 3)
        #expect(await pipe.next() == Data("a".utf8))
        #expect(await pipe.next() == Data("bc".utf8))
        #expect(pipe.pendingBytes == 0)
    }

    @Test func waitingConsumerGetsDataImmediately() async {
        let pipe = OutputPipe()
        async let received = pipe.next()
        try? await Task.sleep(for: .milliseconds(50))
        pipe.push(Data("x".utf8))
        #expect(await received == Data("x".utf8))
        #expect(pipe.pendingBytes == 0)
    }

    @Test func pausesAboveHighWaterAndResumesBelowLowWater() async {
        let pipe = OutputPipe(highWater: 100, lowWater: 30)
        let log = ReadControlLog()
        pipe.setReadControl { log.record($0) }

        for _ in 0..<9 { pipe.push(chunk(10)) }          // 90 bytes: below the mark
        #expect(log.all.isEmpty)
        pipe.push(chunk(10))                              // 100: pause
        pipe.push(chunk(10))                              // already paused: no second call
        #expect(log.all == [false])

        for _ in 0..<7 { _ = await pipe.next() }          // 110 -> 40 bytes pending, still above low water
        #expect(log.all == [false])
        _ = await pipe.next()                             // 30: resume
        #expect(log.all == [false, true])
        #expect(pipe.pendingBytes == 30)
    }

    @Test func aNewConnectionStartsReadingAgain() {
        let pipe = OutputPipe(highWater: 10, lowWater: 5)
        let first = ReadControlLog(), second = ReadControlLog()
        pipe.setReadControl { first.record($0) }
        pipe.push(chunk(10))
        #expect(first.all == [false])
        pipe.setReadControl { second.record($0) }
        pipe.push(chunk(10))                              // backlog is still above the mark: pauses the new connection too
        #expect(second.all == [false])
    }

    @Test func finishDrainsThenEnds() async {
        let pipe = OutputPipe()
        pipe.push(Data("tail".utf8))
        pipe.finish()
        #expect(await pipe.next() == Data("tail".utf8))
        #expect(await pipe.next() == nil)
    }

    @Test func cancellingAWaitingConsumerEndsOnlyThatIteration() async {
        let pipe = OutputPipe()
        let waiting = Task { await pipe.next() }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        #expect(await waiting.value == nil)
        // The pipe itself is still usable: a fresh consumer gets the next chunk.
        pipe.push(Data("later".utf8))
        #expect(await pipe.next() == Data("later".utf8))
    }

    @Test func manyChunksSurviveCompaction() async {
        let pipe = OutputPipe(highWater: .max, lowWater: 0)
        for index in 0..<500 { pipe.push(Data([UInt8(index % 251)])) }
        var received: [UInt8] = []
        for _ in 0..<500 { if let data = await pipe.next() { received.append(data[0]) } }
        #expect(received == (0..<500).map { UInt8($0 % 251) })
        #expect(pipe.pendingBytes == 0)
    }
}

@Suite struct StateBroadcasterTests {
    @Test func subscribersSeeReplayThenOrderedUpdatesWithoutGaps() async {
        let broadcaster = StateBroadcaster<Int>(initial: 0)
        let sender = Task {
            for value in 1...2000 {
                broadcaster.send(value)
                if value % 100 == 0 { await Task.yield() }
            }
        }
        // Subscribe while the sender is running.
        var seen: [Int] = []
        for await value in broadcaster.stream() {
            seen.append(value)
            if value == 2000 { break }
        }
        await sender.value
        #expect(seen.last == 2000)
        #expect(seen == seen.sorted(), "values must arrive in send order")
        // After the replayed starting value, every later value arrives exactly once and contiguously.
        for (a, b) in zip(seen, seen.dropFirst()).dropFirst() { #expect(b == a + 1) }
        #expect(broadcaster.current == 2000)
    }

    @Test func eachNewStreamReplaysTheLatestValue() async {
        let broadcaster = StateBroadcaster<String>(initial: "a")
        broadcaster.send("b")
        var iterator = broadcaster.stream().makeAsyncIterator()
        #expect(await iterator.next() == "b")
    }
}
