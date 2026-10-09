import Foundation
import Testing
@testable import ParakeetCore

actor BarrierModel: SpeechModel {
    nonisolated let id = "barrier"
    var counts: [Int] = []
    private var pending: [CheckedContinuation<String, any Error>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func transcribe(_ samples: [Float]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            counts.append(samples.count); pending.append(continuation)
            let ready = observers.filter { counts.count >= $0.0 }
            observers.removeAll { counts.count >= $0.0 }
            for observer in ready { observer.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if counts.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func resolve(_ result: Result<String, any Error> = .success("  hello\n")) {
        pending.removeFirst().resume(with: result)
    }
}

struct EchoModel: SpeechModel {
    let id = "echo"
    func transcribe(_ samples: [Float]) async throws -> String { " \(samples.count) \n" }
}

func waitUntil(_ condition: () async -> Bool) async {
    while !(await condition()) { await Task.yield() }
}

@Suite(.timeLimit(.minutes(1))) struct EngineTests {
    @Test func validatesPCMAndPreservesActualDuration() async throws {
        #expect(throws: ParakeetError.invalidAudio) { try PCM16kMono(samples: [.nan]) }
        #expect(throws: ParakeetError.invalidAudio) { try PCM16kMono(samples: [.infinity]) }
        #expect(throws: ParakeetError.audioLimitExceeded) { try PCM16kMono(samples: [0, 0], maximumSamples: 1) }
        #expect(throws: ParakeetError.invalidConfiguration) { try PCM16kMono(samples: [], maximumSamples: -1) }
        #expect(try PCM16kMono(samples: [2]).samples == [2])
        let engine = ParakeetEngine(preparedModel: EchoModel())
        for count in [0, 1, 4000, 16000, 16001] {
            let result = try await engine.transcribe(PCM16kMono(samples: .init(repeating: 0, count: count)))
            #expect(result.text == (count == 0 ? "" : String(max(16000, count))))
            #expect(result.actualAudioDuration == Double(count) / 16000)
            #expect(result.totalDuration >= result.inferenceDuration)
        }
    }

    @Test func cancellationBeforeAdmissionDoesNotInvokeModel() async throws {
        let model = BarrierModel()
        let engine = ParakeetEngine(preparedModel: model)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.transcribe(PCM16kMono(samples: [0]))
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch {}
        #expect(await model.counts.isEmpty)
    }

    @Test func fifoCapacityAndCancellationKeepNonpreemptibleOwnership() async throws {
        let model = BarrierModel()
        let engine = ParakeetEngine(configuration: .init(queueCapacity: 1, maximumQueuedSamples: 2), preparedModel: model)
        let audio = try PCM16kMono(samples: [0])
        let first = Task { try await engine.transcribe(audio) }
        await model.waitForCalls(1)
        let second = Task { try await engine.transcribe(audio) }
        await waitUntil { await engine.pendingJobCount == 1 }
        await #expect(throws: ParakeetError.queueFull) { try await engine.transcribe(audio) }
        second.cancel()
        await #expect(throws: ParakeetError.cancelled) { try await second.value }
        #expect(await engine.retainedQueuedSamples == 0)
        first.cancel()
        await #expect(throws: ParakeetError.cancelled) { try await first.value }
        await #expect(throws: ParakeetError.busy) { try await engine.unload() }
        let third = Task { try await engine.transcribe(audio) }
        await waitUntil { await engine.pendingJobCount == 1 }
        #expect(await model.counts.count == 1)
        await model.resolve() // cancelled inference actually settles here
        await model.waitForCalls(2)
        await model.resolve(.success("third"))
        #expect(try await third.value.text == "third")
        try await engine.unload()
        try await engine.unload()
        #expect(await engine.state == .unloaded)
    }

    @Test func fifoAndFailureDoNotPoisonQueue() async throws {
        let model = BarrierModel()
        let engine = ParakeetEngine(preparedModel: model)
        let a = Task { try await engine.transcribe(PCM16kMono(samples: .init(repeating: 0, count: 16000))) }
        await model.waitForCalls(1)
        let b = Task { try await engine.transcribe(PCM16kMono(samples: .init(repeating: 0, count: 17000))) }
        await waitUntil { await engine.pendingJobCount == 1 }
        let c = Task { try await engine.transcribe(PCM16kMono(samples: .init(repeating: 0, count: 18000))) }
        await waitUntil { await engine.pendingJobCount == 2 }
        await model.resolve(.failure(ParakeetError.inferenceFailed))
        await #expect(throws: ParakeetError.inferenceFailed) { try await a.value }
        await model.waitForCalls(2); await model.resolve(.success("b"))
        await model.waitForCalls(3); await model.resolve(.success("c"))
        #expect(try await b.value.text == "b")
        #expect(try await c.value.text == "c")
        #expect(await model.counts == [16000, 17000, 18000])
    }

    @Test func retainedSamplesAndAudioLimits() async throws {
        let model = BarrierModel()
        let engine = ParakeetEngine(configuration: .init(maximumAudioSamples: 3, maximumQueuedSamples: 1), preparedModel: model)
        await #expect(throws: ParakeetError.audioLimitExceeded) {
            try await engine.transcribe(PCM16kMono(samples: [0, 0, 0, 0]))
        }
        let a = Task { try await engine.transcribe(PCM16kMono(samples: [0])) }
        await model.waitForCalls(1)
        await #expect(throws: ParakeetError.queueFull) { try await engine.transcribe(PCM16kMono(samples: [0, 0])) }
        await model.resolve(); _ = try await a.value
    }

    @Test func preparationIsExclusiveFailsWarmupAndRecovers() async throws {
        let model = BarrierModel()
        let engine = ParakeetEngine(loader: { _, progress in
            progress(.init(stage: .checkingCache)); progress(.init(stage: .loading)); return model
        })
        await #expect(throws: ParakeetError.notReady) { try await engine.transcribe(PCM16kMono(samples: [])) }
        let first = Task { try await engine.prepare() }
        await model.waitForCalls(1)
        await #expect(throws: ParakeetError.busy) { try await engine.prepare() }
        await #expect(throws: ParakeetError.busy) { try await engine.unload() }
        await model.resolve(.failure(ParakeetError.inferenceFailed))
        await #expect(throws: ParakeetError.preparationFailed) { try await first.value }
        #expect(await engine.state == .failed)
        let retry = Task { try await engine.prepare() }
        await model.waitForCalls(2); await model.resolve()
        try await retry.value
        try await engine.prepare()
        #expect(await model.counts == [16000, 16000])
        #expect(await engine.state == .ready)
    }

    @Test func cancelledPreparationCannotPublishReadiness() async throws {
        let model = BarrierModel()
        let engine = ParakeetEngine(loader: { _, _ in model })
        let task = Task { try await engine.prepare() }
        await model.waitForCalls(1); task.cancel(); await model.resolve()
        await #expect(throws: ParakeetError.cancelled) { try await task.value }
        #expect(await engine.state == .failed)
        let retry = Task { try await engine.prepare() }
        await model.waitForCalls(2); await model.resolve(); try await retry.value
        #expect(await engine.state == .ready)
    }

    @Test func offlineCacheAndConfigurationErrorsAreActionable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = ParakeetEngine(configuration: .init(cacheRoot: root, downloadPolicy: .requireCached))
        await #expect(throws: ParakeetError.missingCache) { try await engine.prepare() }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let invalid = ParakeetEngine(configuration: .init(queueCapacity: -1))
        await #expect(throws: ParakeetError.invalidConfiguration) { try await invalid.prepare() }
    }

    @Test func inferenceDeadlineDoesNotReleasePermit() async throws {
        let model = BarrierModel()
        let engine = ParakeetEngine(configuration: .init(inferenceTimeout: .milliseconds(10)), preparedModel: model)
        let a = Task { try await engine.transcribe(PCM16kMono(samples: [0])) }
        await model.waitForCalls(1)
        await #expect(throws: ParakeetError.inferenceDeadlineExceeded) { try await a.value }
        await #expect(throws: ParakeetError.busy) { try await engine.unload() }
        await model.resolve()
        await waitUntil { (try? await engine.unload()) != nil }
    }

    @Test func queueDeadlineRemovesAudio() async throws {
        let model = BarrierModel()
        let engine = ParakeetEngine(configuration: .init(queueWaitTimeout: .milliseconds(10)), preparedModel: model)
        let a = Task { try await engine.transcribe(PCM16kMono(samples: [0])) }
        await model.waitForCalls(1)
        await #expect(throws: ParakeetError.queueDeadlineExceeded) { try await engine.transcribe(PCM16kMono(samples: [0])) }
        #expect(await engine.retainedQueuedSamples == 0)
        await model.resolve(); _ = try await a.value
        #expect(await model.counts.count == 1)
    }
}
