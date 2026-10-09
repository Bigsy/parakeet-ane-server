import Foundation
import ParakeetCore

@main struct CoreConsumer {
    static func main() async throws {
        // A normal import and construction have no model download or microphone side effects.
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--check-resources" {
            let bundleURL = Bundle.main.bundleURL.appendingPathComponent("FluidAudio_FluidAudio.bundle")
            guard let bundle = Bundle(url: bundleURL),
                  bundle.url(forResource: "luxtts_en_us_g2p_aux", withExtension: "json") != nil
            else { throw ParakeetError.preparationFailed }
            print("FluidAudio resources available at \(bundleURL.path)")
            return
        }
        guard args.first == "--transcribe", args.count >= 2 else {
            let engine = ParakeetEngine()
            print("ParakeetCore: \(engine.modelID), PCM rate \(PCM16kMono.sampleRate); use --transcribe audio.f32le [cache-root] [--download]")
            return
        }
        let root = args.count >= 3 && !args[2].hasPrefix("--") ? URL(fileURLWithPath: args[2]) : nil
        let engine = ParakeetEngine(configuration: .init(
            cacheRoot: root, downloadPolicy: args.contains("--download") ? .allow : .requireCached))
        try await engine.prepare { print("Preparation: \($0.stage)") }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        guard data.count % 4 == 0 else { throw ParakeetError.invalidAudio }
        let samples = data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
        }
        do {
            let result = try await engine.transcribe(PCM16kMono(samples: samples))
            print(result.text)
            print("Audio \(result.actualAudioDuration)s, queue \(result.queueDuration), inference \(result.inferenceDuration)")
        } catch let error as ParakeetError {
            print(error.localizedDescription)
            throw error
        }
        try await engine.unload()
    }
}
