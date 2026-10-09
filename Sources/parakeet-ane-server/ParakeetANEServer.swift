import ArgumentParser
import Foundation
import Logging
import ParakeetANE

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

    func run() async throws {
        var logger = Logger(label: "parakeet-ane-server")
        logger.logLevel = Logger.Level(rawValue: logLevel) ?? .info

        let ffmpegPath = ffmpeg ?? AudioDecoder.locateFFmpeg()
        if ffmpegPath == nil {
            logger.warning("ffmpeg not found: WebM and Ogg uploads will be rejected")
        }

        logger.info("Loading \(model.modelID) (downloads on first run)")
        let start = ContinuousClock.now
        let speechModel = try await model.load()
        logger.info("Loaded in \(start.duration(to: .now))")

        let service = TranscriptionService(model: speechModel, logger: logger)
        await service.warmUp()

        let options = ServerOptions(host: host, port: port, logTranscripts: logTranscripts)
        let app = makeApplication(
            service: service, decoder: AudioDecoder(ffmpegPath: ffmpegPath), options: options, logger: logger)
        try await app.runService()
    }
}
