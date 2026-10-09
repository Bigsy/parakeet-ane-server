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
            print("ParakeetCore: \(engine.modelID), PCM rate \(PCM16kMono.sampleRate); use --transcribe audio.f32le [cache-root] [--download] [--streaming]")
            return
        }
        let root = args.count >= 3 && !args[2].hasPrefix("--") ? URL(fileURLWithPath: args[2]) : nil
        let streaming = args.contains("--streaming")
        let engine = ParakeetEngine(configuration: .init(
            mode: streaming ? .streaming : .batch, cacheRoot: root, downloadPolicy: args.contains("--download") ? .allow : .requireCached))
        try await engine.prepare { print("Preparation: \($0.stage)") }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        guard data.count % 4 == 0 else { throw ParakeetError.invalidAudio }
        let samples = data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
        }
        do {
            let result: TranscriptionResult
            if streaming {
                let session = try await engine.startStreaming()
                let observer = Task {
                    for try await update in session.updates {
                        print("Partial \(update.revision): \(update.fullTranscript)")
                    }
                }
                do {
                    for offset in stride(from: 0, to: samples.count, by: 320) {
                        let chunk = Array(samples[offset..<min(offset + 320, samples.count)])
                        try await session.append(PCM16kMono(samples: chunk), startingAt: offset)
                    }
                    result = try await session.finish()
                    try await observer.value
                } catch {
                    await session.cancel()
                    await session.waitForSettlement()
                    observer.cancel(); _ = try? await observer.value
                    throw error
                }
            } else {
                result = try await engine.transcribe(PCM16kMono(samples: samples))
            }
            print(result.text)
            print("Audio \(result.actualAudioDuration)s, queue \(result.queueDuration), inference \(result.inferenceDuration)")
        } catch let error as ParakeetError {
            print(error.localizedDescription)
            throw error
        }
        try await engine.unload()
    }
}
