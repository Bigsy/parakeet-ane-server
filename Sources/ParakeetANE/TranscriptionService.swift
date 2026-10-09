import Foundation
import ParakeetCore

/// HTTP adapter; queue, preparation and inference live exclusively in ParakeetCore.
public struct TranscriptionService: Sendable {
    public let engine: ParakeetEngine
    public var modelID: String { engine.modelID }
    public var isReady: Bool { get async { await engine.state == .ready } }
    public init(engine: ParakeetEngine) { self.engine = engine }
    public func transcribe(_ samples: [Float]) async throws -> String {
        let audio = try PCM16kMono(samples: samples, maximumSamples: engine.configuration.maximumAudioSamples)
        return try await engine.transcribe(audio).text
    }
}

extension Duration {
    var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
