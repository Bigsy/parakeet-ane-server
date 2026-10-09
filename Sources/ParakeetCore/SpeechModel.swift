import FluidAudio
import Foundation
import Darwin

protocol SpeechModel: Sendable {
    var id: String { get }
    func transcribe(_ samples: [Float]) async throws -> String
}

public enum ModelChoice: String, Sendable, CaseIterable {
    case unified, ultra, v2, v3
    public var modelID: String {
        switch self {
        case .unified: "parakeet-unified-en-0.6b"
        case .ultra: "parakeet-ultra"
        case .v2: "parakeet-tdt-0.6b-v2"
        case .v3: "parakeet-tdt-0.6b-v3"
        }
    }
    public var supportsStreaming: Bool { self == .unified }
    var repo: Repo {
        switch self {
        case .unified: .parakeetUnified
        case .ultra: .parakeetUltra
        case .v2: .parakeetV2
        case .v3: .parakeetV3
        }
    }
    var version: AsrModelVersion {
        switch self { case .v2: .v2; case .ultra: .ultra; default: .v3 }
    }
}

/// A cooperating cross-process preparation lock. Never unlinks a shared model cache.
private final class CacheLease: Sendable {
    let descriptor: Int32
    init(root: URL) throws {
        descriptor = open(root.appendingPathComponent(".parakeet-core.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ParakeetError.preparationFailed }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw ParakeetError.busy
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

func modelDirectory(
    configuration: EngineConfiguration,
    progress: @escaping @Sendable (PreparationProgress) -> Void
) async throws -> URL {
    let root = configuration.cacheRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    let repo = configuration.model.repo
    let directory = root.appendingPathComponent(repo.folderName, isDirectory: true)
    let variant: String? = configuration.model == .unified ? (configuration.mode == .batch ? "offline" : nil)
        : (configuration.model == .v3 ? "int8" : nil)
    var required: Set<String>
    switch configuration.model {
    case .unified: required = ModelNames.ParakeetUnified.requiredModels(variant: variant)
    case .v2: required = ModelNames.ASR.requiredModels
    case .v3, .ultra: required = ModelNames.ASR.requiredModelsV3()
    }
    if configuration.model == .unified, configuration.mode == .streaming {
        required.insert(ModelNames.ParakeetUnified.streamingEncoderInt8File)
    }
    if configuration.model != .unified { required.insert(ModelNames.ASR.vocabularyFile) }
    progress(.init(stage: .checkingCache))
    let complete = required.allSatisfy { name in
        let file = directory.appendingPathComponent(name)
        if name.hasSuffix(".mlmodelc") {
            guard FileManager.default.fileExists(atPath: file.appendingPathComponent("coremldata.bin").path) else { return false }
            guard let files = FileManager.default.enumerator(at: file, includingPropertiesForKeys: nil) else { return false }
            return !files.contains { ($0 as? URL)?.lastPathComponent.hasSuffix(".partial") == true }
        }
        return FileManager.default.fileExists(atPath: file.path)
    }
    if configuration.downloadPolicy == .requireCached {
        guard complete else { throw ParakeetError.missingCache }
        try Task.checkCancellation()
        progress(.init(stage: .loading))
        return directory // Read-only offline caches require no lock-file mutation.
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let lease = try CacheLease(root: root)
    // The lease covers downloads. Local loads never invoke upstream purge/recovery paths.
    defer { withExtendedLifetime(lease) {} }
    try Task.checkCancellation()
    if !complete {
        progress(.init(stage: .downloading))
        do {
            try await ModelHub.download(repo, to: root, variant: variant, additionalModelNames: required) { update in
                let stage: PreparationProgress.Stage
                switch update.phase {
                case .listing, .downloading: stage = .downloading
                case .compiling: stage = .loading
                }
                progress(.init(stage: stage, fractionCompleted: update.fractionCompleted))
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw ParakeetError.cancelled }
            throw ParakeetError.downloadFailed
        }
    }
    try Task.checkCancellation()
    progress(.init(stage: .loading))
    return directory
}

func loadSpeechModel(
    configuration: EngineConfiguration,
    progress: @escaping @Sendable (PreparationProgress) -> Void
) async throws -> any SpeechModel {
    guard configuration.mode == .batch else { throw ParakeetError.unsupportedMode }
    let directory = try await modelDirectory(configuration: configuration, progress: progress)
    if configuration.model == .unified {
        let manager = UnifiedAsrManager()
        try await manager.loadModels(from: directory)
        return UnifiedModel(id: configuration.model.modelID, manager: manager)
    }
    // loadLocal uses the same precision and per-component compute-unit choices as the
    // pinned downloadAndLoad path, but cannot delete/re-download a shared cache on error.
    let version = configuration.model.version
    let models = try await Task.detached {
        try AsrModels.loadLocal(from: directory, version: version)
    }.value
    try Task.checkCancellation()
    let config = ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize)
    let manager = AsrManager(config: config)
    try await manager.loadModels(models)
    return TdtModel(id: configuration.model.modelID, manager: manager)
}

struct UnifiedModel: SpeechModel {
    let id: String
    let manager: UnifiedAsrManager
    func transcribe(_ samples: [Float]) async throws -> String { try await manager.transcribe(samples) }
}

struct TdtModel: SpeechModel {
    let id: String
    let manager: AsrManager
    func transcribe(_ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
    }
}
