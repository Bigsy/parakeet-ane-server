import Foundation
import FluidAudio
import Logging
import ParakeetCore

// Baseline sources in this target are frozen from d4e9a8a; this only supplies
// the original service's sample-rate dependency without importing the HTTP adapter.
enum AudioDecoder { static let sampleRate = 16000 }

struct Observation: Codable {
    let implementation: String
    let fixture: String
    let iteration: Int
    let text: String
    let milliseconds: Double
}

@main struct Benchmark {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else {
            print("Benchmark baseline|core|prepare cache-root fixture.f32le [repetitions]")
            return
        }
        if args[0] == "session" || args[0] == "session-realtime" {
            try await sessionBenchmark(args: args); return
        }
        if args[0] == "residency" { try await residency(args: args); return }
        if args[0] == "streaming" || args[0] == "prepare-streaming" {
            try await streamingSpike(args: args); return
        }
        let root = URL(fileURLWithPath: args[1])
        if args[0] == "prepare" {
            let engine = ParakeetEngine(configuration: .init(cacheRoot: root))
            try await engine.prepare { event in
                FileHandle.standardError.write(Data("\(event.stage) \(event.fractionCompleted.map(String.init(describing:)) ?? "")\n".utf8))
            }
            try await engine.unload(); return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        guard data.count % 4 == 0 else { throw ParakeetError.invalidAudio }
        let samples = data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
        }
        let repetitions = args.count > 3 ? Int(args[3]) ?? 30 : 30
        let transcribe: @Sendable () async throws -> String
        if args[0] == "baseline" {
            let manager = UnifiedAsrManager()
            try await manager.loadModels(from: root.appendingPathComponent(Repo.parakeetUnified.folderName))
            let service = TranscriptionService(model: UnifiedModel(id: "parakeet-unified-en-0.6b", manager: manager), logger: Logger(label: "baseline"))
            await service.warmUp()
            transcribe = { try await service.transcribe(samples) }
        } else {
            let engine = ParakeetEngine(configuration: .init(cacheRoot: root, downloadPolicy: .requireCached))
            try await engine.prepare()
            let audio = try PCM16kMono(samples: samples)
            transcribe = { try await engine.transcribe(audio).text }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for iteration in 0..<repetitions {
            let start = ContinuousClock.now
            let text = try await transcribe()
            let duration = start.duration(to: .now).components
            let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            let observation = Observation(implementation: args[0], fixture: URL(fileURLWithPath: args[2]).lastPathComponent,
                                          iteration: iteration, text: text, milliseconds: ms)
            print(String(decoding: try encoder.encode(observation), as: UTF8.self))
        }
    }
}
