import Foundation
import Logging

/// Runs transcriptions one at a time and optionally keeps the model warm.
///
/// FluidAudio's managers are actors, but actors are re-entrant across `await`, so two
/// overlapping requests could interleave inside one decode. Requests are chained so
/// each waits for the previous one to finish.
public actor TranscriptionService {
    public nonisolated let model: any SpeechModel
    private let logger: Logger
    private var tail: Task<Void, Never> = Task {}
    private var lastUse = ContinuousClock.now

    /// Parakeet rejects clips under one second, so shorter ones are padded with silence.
    static let minimumSamples = AudioDecoder.sampleRate

    public init(model: any SpeechModel, logger: Logger) {
        self.model = model
        self.logger = logger
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let padded =
            samples.count < Self.minimumSamples
            ? samples + [Float](repeating: 0, count: Self.minimumSamples - samples.count)
            : samples
        let previous = tail
        let model = self.model
        let job = Task {
            await previous.value
            return try await model.transcribe(padded)
        }
        tail = Task { _ = try? await job.value }
        defer { lastUse = .now }
        return try await job.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run one second of silence through the model, so the first real request
    /// doesn't pay for Neural Engine compilation or paged-out weights.
    public func warmUp() async {
        let start = ContinuousClock.now
        do {
            _ = try await transcribe([Float](repeating: 0, count: Self.minimumSamples))
            logger.info("Warm-up took \(start.duration(to: .now).milliseconds) ms")
        } catch {
            logger.warning("Warm-up failed: \(error)")
        }
    }

    /// Warm the model whenever it has sat idle for `interval`. Runs until cancelled.
    public func keepWarm(every interval: Duration) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if lastUse.duration(to: .now) >= interval {
                await warmUp()
            }
        }
    }
}

extension Duration {
    var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
