import Foundation
import Testing
@testable import ParakeetCore

actor FakeStreamingModel: StreamingModel {
    private var blocks: [String: Int]
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(String, Int, CheckedContinuation<Void, Never>)] = []
    var events: [String] = []
    var received = 0
    var resetCount = 0
    var failReset = false
    var failProcess = false

    init(blocks: [String: Int] = [:]) { self.blocks = blocks }
    func event(_ name: String) async {
        events.append(name)
        if blocks[name, default: 0] > 0 {
            blocks[name, default: 0] -= 1
            await withCheckedContinuation { continuation in
                gates[name] = continuation
                notify()
            }
        } else { notify() }
    }
    private func notify() {
        let ready = observers.filter { name, count, _ in events.filter { $0 == name }.count >= count }
        observers.removeAll { name, count, _ in events.filter { $0 == name }.count >= count }
        for (_, _, continuation) in ready { continuation.resume() }
    }
    func waitFor(_ name: String, count: Int = 1) async {
        if events.filter({ $0 == name }).count >= count { return }
        await withCheckedContinuation { observers.append((name, count, $0)) }
    }
    func unblock(_ name: String) { gates.removeValue(forKey: name)?.resume() }
    func append(_ samples: [Float]) async throws { await event("append\(samples.count)"); received += samples.count }
    func process() async throws -> String? {
        await event("process")
        if failProcess { throw ParakeetError.inferenceFailed }
        return "partial \(received)"
    }
    func finish() async throws -> String { await event("finish"); return " final \(received) \n" }
    func reset() async throws {
        resetCount += 1; await event("reset")
        if failReset { throw ParakeetError.inferenceFailed }
        received = 0
    }
    func setFailure(reset: Bool = false, process: Bool = false) { failReset = reset; failProcess = process }
}

@Suite(.timeLimit(.minutes(1))) struct StreamingTests {
    func pcm(_ count: Int) throws -> PCM16kMono { try .init(samples: .init(repeating: 0, count: count)) }

    @Test func contiguousOffsetsLimitsAndIndependentSessions() async throws {
        let model = FakeStreamingModel()
        let engine = ParakeetEngine(configuration: .init(mode: .streaming, maximumAudioSamples: 640, maximumStreamingChunkSamples: 320), preparedStreamingModel: model)
        let first = try await engine.startStreaming()
        await #expect(throws: ParakeetError.busy) { try await engine.startStreaming() }
        await #expect(throws: ParakeetError.busy) { try await engine.unload() }
        await #expect(throws: ParakeetError.unsupportedMode) { try await engine.transcribe(pcm(1)) }
        await #expect(throws: ParakeetError.invalidSampleOffset) { try await first.append(pcm(320), startingAt: 1) }
        await #expect(throws: ParakeetError.audioLimitExceeded) { try await first.append(pcm(321), startingAt: 0) }
        try await first.append(pcm(320), startingAt: 0)
        await #expect(throws: ParakeetError.invalidSampleOffset) { try await first.append(pcm(320), startingAt: 0) }
        try await first.append(pcm(320), startingAt: 320)
        await #expect(throws: ParakeetError.audioLimitExceeded) { try await first.append(pcm(1), startingAt: 640) }
        let result = try await first.finish()
        #expect(result.text == "final 640")
        #expect(result.actualAudioDuration == 0.04)
        #expect(result.finalizationDuration != nil)
        #expect(try await first.finish() == result)
        #expect(await model.resetCount == 1)
        #expect(!(await engine.isBusy))
        let second = try await engine.startStreaming()
        #expect(second.id != first.id)
        try await second.append(pcm(1), startingAt: 0)
        #expect(try await second.finish().text == "final 1")
        #expect(await model.resetCount == 2)
        try await engine.unload()
    }

    @Test func newestValueSnapshotsAndRevisionOrder() async throws {
        let model = FakeStreamingModel()
        let session = try await ParakeetEngine(preparedStreamingModel: model).startStreaming()
        for index in 0..<3 { try await session.append(pcm(320), startingAt: index * 320) }
        var updates = session.updates.makeAsyncIterator()
        let latest = try #require(try await updates.next())
        #expect(latest.revision == 3)
        #expect(latest.fullTranscript == "partial 960")
        #expect(latest.receivedAudioPosition == 960)
        #expect(latest.processedAudioPosition == nil)
        #expect(latest.sessionID == session.id)
        _ = try await session.finish()
        let final = try #require(try await updates.next())
        #expect(final.revision == 4)
        #expect(final.fullTranscript == "final 960")
        #expect(try await updates.next() == nil)
    }

    @Test func orderedAppendAndFinishAcrossActorReentrancy() async throws {
        let model = FakeStreamingModel(blocks: ["process": 1])
        let session = try await ParakeetEngine(preparedStreamingModel: model).startStreaming()
        let first = Task { try await session.append(pcm(320), startingAt: 0) }
        await model.waitFor("process")
        let second = Task { try await session.append(pcm(640), startingAt: 320) }
        await waitUntil { await session.pendingJobCount == 1 }
        let final = Task { try await session.finish() }
        await waitUntil { await session.pendingJobCount == 2 }
        await #expect(throws: ParakeetError.sessionFinished) { try await session.append(pcm(1), startingAt: 960) }
        #expect(await model.events == ["append320", "process"])
        await model.unblock("process")
        try await first.value; try await second.value
        #expect(try await final.value.text == "final 960")
        #expect(await model.events == ["append320", "process", "append640", "process", "finish", "reset"])
    }

    @Test func cancellingQueuedAppendCancelsTimelineAndRetainsPermit() async throws {
        let model = FakeStreamingModel(blocks: ["process": 1])
        let engine = ParakeetEngine(preparedStreamingModel: model)
        let session = try await engine.startStreaming()
        let first = Task { try await session.append(pcm(320), startingAt: 0) }
        await model.waitFor("process")
        let second = Task { try await session.append(pcm(640), startingAt: 320) }
        await waitUntil { await session.pendingJobCount == 1 }
        second.cancel()
        await #expect(throws: ParakeetError.cancelled) { try await second.value }
        await #expect(throws: ParakeetError.cancelled) { try await first.value }
        #expect(await session.retainedQueuedSamples == 0)
        await #expect(throws: ParakeetError.busy) { try await engine.startStreaming() }
        await session.cancel(); await session.cancel()
        #expect(await model.resetCount == 0)
        await model.unblock("process")
        await session.waitForSettlement()
        #expect(await model.resetCount == 1)
        #expect(!((await model.events).contains("append640")))
        let next = try await engine.startStreaming()
        await next.cancel(); await next.waitForSettlement()
        #expect(await model.resetCount == 2)
    }

    @Test func cancelledAppendDoesNotStartExtraProcessing() async throws {
        let model = FakeStreamingModel(blocks: ["append320": 1])
        let engine = ParakeetEngine(preparedStreamingModel: model)
        let session = try await engine.startStreaming()
        let append = Task { try await session.append(pcm(320), startingAt: 0) }
        await model.waitFor("append320")
        append.cancel()
        // Do not await the session's cancellation lookup before releasing model work.
        await model.unblock("append320")
        await #expect(throws: ParakeetError.cancelled) { try await append.value }
        await session.waitForSettlement()
        #expect(await model.events == ["append320", "reset"])
        #expect(await model.resetCount == 1)
        #expect(!(await engine.isBusy))
    }

    @Test func cancelSuppressesFinalAndClearsUnreadPartials() async throws {
        let model = FakeStreamingModel(blocks: ["finish": 1])
        let engine = ParakeetEngine(preparedStreamingModel: model)
        let session = try await engine.startStreaming()
        try await session.append(pcm(320), startingAt: 0) // unread provisional value
        let final = Task { try await session.finish() }
        await model.waitFor("finish")
        final.cancel()
        await #expect(throws: ParakeetError.cancelled) { try await final.value }
        var updates = session.updates.makeAsyncIterator()
        await #expect(throws: ParakeetError.cancelled) { try await updates.next() }
        await model.unblock("finish")
        await session.waitForSettlement()
        await #expect(throws: ParakeetError.cancelled) { try await session.finish() }
        #expect(await model.resetCount == 1)
        #expect(!(await engine.isBusy))
    }

    @Test func observationCancellationLeavesRecordingUsable() async throws {
        let model = FakeStreamingModel()
        let engine = ParakeetEngine(preparedStreamingModel: model)
        let session = try await engine.startStreaming()
        let observer = Task {
            for try await _ in session.updates {}
        }
        observer.cancel(); try await observer.value
        try await session.append(pcm(320), startingAt: 0)
        #expect(try await session.finish().text == "final 320")
    }

    @Test func emptyFinishAndCancelAfterSuccessAreIdempotent() async throws {
        let model = FakeStreamingModel()
        let engine = ParakeetEngine(preparedStreamingModel: model)
        let session = try await engine.startStreaming()
        let result = try await session.finish()
        #expect(result.text.isEmpty)
        #expect(result.actualAudioDuration == 0)
        await session.cancel(); await session.cancel(); await session.waitForSettlement()
        #expect(try await session.finish() == result)
        #expect(await model.events == ["reset"])
        #expect(await model.resetCount == 1)
    }

    @Test func backpressureLimitsNeverSilentlyDropSamples() async throws {
        let model = FakeStreamingModel(blocks: ["process": 1])
        let engine = ParakeetEngine(configuration: .init(mode: .streaming, queueCapacity: 1, maximumQueuedSamples: 320), preparedStreamingModel: model)
        let session = try await engine.startStreaming()
        let first = Task { try await session.append(pcm(320), startingAt: 0) }
        await model.waitFor("process")
        await #expect(throws: ParakeetError.queueFull) { try await session.append(pcm(640), startingAt: 320) }
        let queued = Task { try await session.append(pcm(320), startingAt: 320) }
        await waitUntil { await session.pendingJobCount == 1 }
        await #expect(throws: ParakeetError.queueFull) { try await session.append(pcm(320), startingAt: 640) }
        await model.unblock("process")
        try await first.value; try await queued.value
        try await session.append(pcm(320), startingAt: 640) // overflow did not reserve an offset
        #expect(try await session.finish().text == "final 960")
    }

    @Test func resetFailureRequiresPreparationAndIsNotRetried() async throws {
        let model = FakeStreamingModel()
        await model.setFailure(reset: true)
        let engine = ParakeetEngine(preparedStreamingModel: model)
        let session = try await engine.startStreaming()
        await #expect(throws: ParakeetError.inferenceFailed) { try await session.finish() }
        await session.waitForSettlement()
        #expect(await model.resetCount == 1)
        #expect(await engine.state == .failed)
        await #expect(throws: ParakeetError.notReady) { try await engine.startStreaming() }
    }

    @Test func abandonedSessionHasExplicitEngineCancellation() async throws {
        let model = FakeStreamingModel()
        let engine = ParakeetEngine(preparedStreamingModel: model)
        let session = try await engine.startStreaming()
        await engine.cancelStreaming(); await session.waitForSettlement()
        #expect(!(await engine.isBusy))
        try await engine.unload()
    }

    @Test func failureResetsTimelineAndNextSessionProceeds() async throws {
        let model = FakeStreamingModel()
        await model.setFailure(process: true)
        let engine = ParakeetEngine(preparedStreamingModel: model)
        let failed = try await engine.startStreaming()
        await #expect(throws: ParakeetError.inferenceFailed) { try await failed.append(pcm(320), startingAt: 0) }
        await failed.waitForSettlement()
        #expect(await engine.state == .ready)
        await model.setFailure()
        let next = try await engine.startStreaming()
        try await next.append(pcm(640), startingAt: 0)
        #expect(try await next.finish().text == "final 640")
        await #expect(throws: ParakeetError.inferenceFailed) { try await failed.finish() }
        #expect(await model.resetCount == 2)
    }

    @Test func deadlinesRetainStreamingOwnershipUntilSafeReset() async throws {
        let model = FakeStreamingModel(blocks: ["process": 1])
        let engine = ParakeetEngine(configuration: .init(mode: .streaming, inferenceTimeout: .milliseconds(10)), preparedStreamingModel: model)
        let session = try await engine.startStreaming()
        let append = Task { try await session.append(pcm(320), startingAt: 0) }
        await model.waitFor("process")
        await #expect(throws: ParakeetError.inferenceDeadlineExceeded) { try await append.value }
        await #expect(throws: ParakeetError.busy) { try await engine.unload() }
        #expect(await model.resetCount == 0)
        await model.unblock("process"); await session.waitForSettlement()
        #expect(await model.resetCount == 1)
        try await engine.unload()
    }

    @Test func closedSessionDoesNotRetainUnloadedModel() async throws {
        var model: FakeStreamingModel? = FakeStreamingModel()
        weak var weakModel = model
        let engine = ParakeetEngine(preparedStreamingModel: try #require(model))
        let session = try await engine.startStreaming()
        _ = try await session.finish()
        model = nil
        try await engine.unload()
        await waitUntil { weakModel == nil }
        #expect(try await session.finish().text == "")
    }

    @Test func streamingPreparationWarmsAndResetsBeforeReady() async throws {
        let model = FakeStreamingModel()
        let engine = ParakeetEngine(configuration: .init(mode: .streaming), streamingLoader: { _, _ in model })
        try await engine.prepare(); try await engine.prepare()
        #expect(await model.events == ["append16000", "finish", "reset"])
        let session = try await engine.startStreaming()
        #expect(try await session.finish().text == "")
        let unsupported = ParakeetEngine(configuration: .init(model: .v2, mode: .streaming))
        await #expect(throws: ParakeetError.unsupportedMode) { try await unsupported.prepare() }
    }
}
