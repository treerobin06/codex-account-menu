import AppKit
import Testing
@testable import SwitcherCore

@MainActor
struct AppTerminationCoordinatorTests {
    @Test func activeMutationRejectsQuitWithoutStartingCleanup() async {
        var preparations = 0, replies = 0
        let gate = AppTerminationCoordinator(isBusy: { true }, prepare: { preparations += 1; return true })
        #expect(gate.request { _ in replies += 1 } == .terminateCancel)
        await Task.yield()
        #expect(preparations == 0 && replies == 0)
    }

    @Test(.timeLimit(.minutes(1))) func normalQuitWaitsForReaderAndRepeatedRequestsSharePreparation() async throws {
        var continuation: CheckedContinuation<Bool, Never>?
        var preparations = 0, replies: [Bool] = []
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (completed, completeSignal) = AsyncStream<Bool>.makeStream()
        var starts = started.makeAsyncIterator(), completions = completed.makeAsyncIterator()
        defer { continuation?.resume(returning: false) }
        let gate = AppTerminationCoordinator(isBusy: { false }, prepare: {
            preparations += 1
            return await withCheckedContinuation { continuation = $0; startSignal.yield(()) }
        })
        #expect(gate.request { replies.append($0); completeSignal.yield($0) } == .terminateLater)
        _ = await starts.next()
        let reader = try #require(continuation)
        #expect(gate.request { replies.append($0) } == .terminateLater)
        #expect(preparations == 1 && replies.isEmpty)
        continuation = nil
        reader.resume(returning: true)
        #expect(await completions.next() == true)
        #expect(replies == [true])
    }

    @Test(.timeLimit(.minutes(1))) func declinedPreparationCanBeRetried() async {
        var allow = false, replies: [Bool] = []
        let (completed, completeSignal) = AsyncStream<Bool>.makeStream()
        var completions = completed.makeAsyncIterator()
        let gate = AppTerminationCoordinator(isBusy: { false }, prepare: { allow })
        #expect(gate.request { replies.append($0); completeSignal.yield($0) } == .terminateLater)
        #expect(await completions.next() == false)
        #expect(replies == [false])
        allow = true
        #expect(gate.request { replies.append($0); completeSignal.yield($0) } == .terminateLater)
        #expect(await completions.next() == true)
        #expect(replies == [false, true])
    }
}
