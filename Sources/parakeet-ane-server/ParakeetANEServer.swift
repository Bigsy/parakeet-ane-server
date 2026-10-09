import ArgumentParser
import Foundation
import Logging
import ParakeetANE
import ParakeetCore

extension ModelChoice: ExpressibleByArgument {}

@main
struct ParakeetANEServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parakeet-ane-server",
        abstract: "OpenAI-compatible speech-to-text server running Parakeet on the Apple Neural Engine."
    )

    @Option(help: "Address to bind.")
    var host = "127.0.0.1"

    @Option(help: "Port to listen on.")
    var port = 11435

    @Option(help: "Model to serve: \(ModelChoice.allCases.map(\.rawValue).joined(separator: ", ")).")
    var model = ModelChoice.unified

    @Option(help: "Path to ffmpeg, for WebM/Ogg uploads. Defaults to the first one found.")
    var ffmpeg: String?

    @Flag(help: "Log transcript text (off by default).")
    var logTranscripts = false

    @Option(help: "Log level: trace, debug, info, notice, warning, error, critical.")
    var logLevel = "info"

    @Option(help: "Maximum decoded audio duration per request in seconds.")
    var maxAudioSeconds = 3600

    @Option(help: "Maximum waiting transcription jobs (excluding active inference).")
    var queueCapacity = 8

    @Option(help: "Maximum total waiting decoded audio duration in seconds.")
    var maxQueuedAudioSeconds = 7200

    @Option(help: "Base FluidAudio Models cache directory.")
    var cacheRoot: String?

    @Flag(help: "Require an existing model cache; never download during preparation.")
    var offline = false

    func validate() throws {
        guard maxAudioSeconds > 0, maxAudioSeconds <= Int.max / PCM16kMono.sampleRate,
              maxQueuedAudioSeconds >= 0, maxQueuedAudioSeconds <= Int.max / PCM16kMono.sampleRate,
              queueCapacity >= 0 else { throw ValidationError("Invalid audio or queue limits.") }
    }

    func run() async throws {
        var logger = Logger(label: "parakeet-ane-server")
        logger.logLevel = Logger.Level(rawValue: logLevel) ?? .info

        let ffmpegPath = ffmpeg ?? AudioDecoder.locateFFmpeg()
        if ffmpegPath == nil {
            logger.warning("ffmpeg not found: Ogg and unsupported WebM uploads will be rejected")
        }

        logger.info("Loading \(model.modelID) (downloads on first run)")
        let start = ContinuousClock.now
        let engine = ParakeetEngine(configuration: .init(
            model: model, cacheRoot: cacheRoot.map { URL(fileURLWithPath: $0) },
            downloadPolicy: offline ? .requireCached : .allow, queueCapacity: queueCapacity,
            maximumAudioSamples: maxAudioSeconds * PCM16kMono.sampleRate,
            maximumQueuedSamples: maxQueuedAudioSeconds * PCM16kMono.sampleRate))
        try await engine.prepare()
        logger.info("Prepared in \(start.duration(to: .now))")
        let service = TranscriptionService(engine: engine)

        let options = ServerOptions(host: host, port: port, logTranscripts: logTranscripts)
        let app = makeApplication(
            service: service, decoder: AudioDecoder(ffmpegPath: ffmpegPath), options: options, logger: logger)
        try await app.runService()
    }
}
