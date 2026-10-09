import FluidAudio

/// Something that turns 16 kHz mono samples into text.
public protocol SpeechModel: Sendable {
    /// Model id reported by `/v1/models` and `verbose_json` responses.
    var id: String { get }
    func transcribe(_ samples: [Float]) async throws -> String
}

/// The Parakeet variants this server can load.
public enum ModelChoice: String, Sendable, CaseIterable {
    /// Parakeet Unified 0.6B, English with punctuation; what OpenWhispr's own Parakeet uses.
    case unified
    /// Moondream's post-trained TDT v3: same speed, lower WER, 25 languages.
    case ultra
    /// Parakeet TDT 0.6B v2, English only.
    case v2
    /// Parakeet TDT 0.6B v3, 25 European languages.
    case v3

    public var modelID: String {
        switch self {
        case .unified: "parakeet-unified-en-0.6b"
        case .ultra: "parakeet-ultra"
        case .v2: "parakeet-tdt-0.6b-v2"
        case .v3: "parakeet-tdt-0.6b-v3"
        }
    }

    /// Download (first run only) and load the CoreML models onto the Neural Engine.
    public func load() async throws -> any SpeechModel {
        switch self {
        case .unified:
            let manager = UnifiedAsrManager()
            try await manager.loadModels()
            return UnifiedModel(id: modelID, manager: manager)
        case .ultra: return try await TdtModel.load(id: modelID, version: .ultra)
        case .v2: return try await TdtModel.load(id: modelID, version: .v2)
        case .v3: return try await TdtModel.load(id: modelID, version: .v3)
        }
    }
}

struct UnifiedModel: SpeechModel {
    let id: String
    let manager: UnifiedAsrManager

    func transcribe(_ samples: [Float]) async throws -> String {
        try await manager.transcribe(samples)
    }
}

struct TdtModel: SpeechModel {
    let id: String
    let manager: AsrManager

    static func load(id: String, version: AsrModelVersion) async throws -> TdtModel {
        let models = try await AsrModels.downloadAndLoad(version: version)
        let config = ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId),
            encoderHiddenSize: version.encoderHiddenSize
        )
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)
        return TdtModel(id: id, manager: manager)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        // Fresh decoder state per request: each upload is an independent utterance.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
    }
}
