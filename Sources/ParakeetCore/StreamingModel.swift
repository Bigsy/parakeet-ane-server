@preconcurrency import AVFoundation
import FluidAudio
import Foundation

protocol StreamingModel: Sendable {
    func append(_ samples: [Float]) async throws
    /// Returns a full snapshot only when new model windows were processed.
    func process() async throws -> String?
    func finish() async throws -> String
    func reset() async throws
}

func loadStreamingModel(
    configuration: EngineConfiguration,
    progress: @escaping @Sendable (PreparationProgress) -> Void
) async throws -> any StreamingModel {
    guard configuration.model == .unified else { throw ParakeetError.unsupportedMode }
    let directory = try await modelDirectory(configuration: configuration, progress: progress)
    let manager = StreamingUnifiedAsrManager()
    try await manager.loadModels(from: directory)
    return UnifiedStreamingModel(manager: manager)
}

actor UnifiedStreamingModel: StreamingModel {
    let manager: StreamingUnifiedAsrManager
    private let config = UnifiedConfig()
    private var receivedSamples = 0
    private var nextWindowAt: Int

    init(manager: StreamingUnifiedAsrManager) {
        self.manager = manager
        self.nextWindowAt = UnifiedConfig().chunkSamples + UnifiedConfig().rightSamples
    }

    func append(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard samples.count <= Int(UInt32.max),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw ParakeetError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        // Upstream recognizes this exact format and extracts samples without resampling.
        try await manager.appendAudio(buffer)
        receivedSamples += samples.count
    }

    func process() async throws -> String? {
        guard receivedSamples >= nextWindowAt else { return nil }
        try await manager.processBufferedAudio()
        // Drain unused token observations so they do not grow through a long session.
        _ = await manager.consumeTokenTimings()
        while nextWindowAt <= receivedSamples {
            let (next, overflow) = nextWindowAt.addingReportingOverflow(config.chunkSamples)
            nextWindowAt = overflow ? Int.max : next
            if overflow { break }
        }
        return await manager.getPartialTranscript()
    }

    func finish() async throws -> String {
        let text = try await manager.finish()
        _ = await manager.consumeTokenTimings()
        return text
    }

    func reset() async throws {
        try await manager.reset()
        receivedSamples = 0
        nextWindowAt = config.chunkSamples + config.rightSamples
    }
}
