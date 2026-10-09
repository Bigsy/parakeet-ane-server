import FluidAudio
import Foundation
import ParakeetCore

public enum AudioDecodeError: Error, CustomStringConvertible {
    case unrecognisedFormat
    case ffmpegUnavailable(AudioFormat?)
    case ffmpegFailed(status: Int32, stderr: String)
    case nativeDecodeFailed(any Error)

    public var description: String {
        switch self {
        case .unrecognisedFormat:
            "Unrecognised audio format."
        case .ffmpegUnavailable(let format):
            "Decoding \(format?.rawValue ?? "this audio") needs ffmpeg, which was not found."
        case .ffmpegFailed(let status, let stderr):
            "ffmpeg exited with status \(status): \(stderr)"
        case .nativeDecodeFailed(let error):
            "Could not decode audio: \(error)"
        }
    }
}

public struct DecodedAudio: Sendable {
    public enum Path: String, Sendable {
        case coreAudio = "core-audio"
        case webmOpus = "webm-opus"
        case ffmpeg
    }

    public let samples: [Float]
    public let format: AudioFormat?
    /// Which decoder handled it, for the request log.
    public let path: Path
}

/// Turns an uploaded audio file into 16 kHz mono Float32 samples, the input every
/// Parakeet model expects.
public struct AudioDecoder: Sendable {
    public static let sampleRate = PCM16kMono.sampleRate

    /// Path to ffmpeg, used for containers Core Audio can't read (WebM, Ogg).
    public let ffmpegPath: String?

    public init(ffmpegPath: String?) {
        self.ffmpegPath = ffmpegPath
    }

    /// First ffmpeg found in the usual Homebrew locations or on PATH.
    public static func locateFFmpeg() -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin"] + pathDirs
        return candidates.map { "\($0)/ffmpeg" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func decode(_ bytes: [UInt8]) async throws -> DecodedAudio {
        let format = AudioFormat.sniff(bytes)

        // Browser recordings: demux and decode in-process, no temp file or ffmpeg.
        if format == .webm, let samples = try? WebMOpus.decode(bytes) {
            return DecodedAudio(samples: samples, format: format, path: .webmOpus)
        }

        let input = try TemporaryFile(bytes: bytes, fileExtension: format?.fileExtension ?? "bin")
        defer { input.remove() }

        if let format, format.isNativelyDecodable {
            do {
                let samples = try AudioConverter().resampleAudioFile(input.url)
                return DecodedAudio(samples: samples, format: format, path: .coreAudio)
            } catch {
                // A mislabelled or unusual file may still be readable by ffmpeg.
                guard ffmpegPath != nil else { throw AudioDecodeError.nativeDecodeFailed(error) }
            }
        }
        guard let ffmpegPath else {
            throw format == nil ? AudioDecodeError.unrecognisedFormat : AudioDecodeError.ffmpegUnavailable(format)
        }
        let samples = try await Self.decodeWithFFmpeg(ffmpegPath, input: input.url)
        return DecodedAudio(samples: samples, format: format, path: .ffmpeg)
    }

    private static func decodeWithFFmpeg(_ ffmpegPath: String, input: URL) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-nostdin", "-hide_banner", "-loglevel", "error",
                "-i", input.path,
                "-f", "f32le", "-ac", "1", "-ar", String(sampleRate),
                "pipe:1",
            ]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }
            // Drain both pipes concurrently: ffmpeg can block on stderr while
            // we're still waiting for the end of stdout. Keep only 64 KiB of
            // diagnostics, but continue draining the rest.
            let errorReader = Task.detached {
                var diagnostics = Data()
                while let chunk = try stderr.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                    diagnostics.append(chunk.prefix(max(65_536 - diagnostics.count, 0)))
                }
                return diagnostics
            }
            let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
            let errorOutput = try await errorReader.value
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AudioDecodeError.ffmpegFailed(
                    status: process.terminationStatus,
                    stderr: String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return output.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }.value
    }
}

/// An upload written to the temp directory, since both decoders read from a file.
struct TemporaryFile {
    let url: URL

    init(bytes: [UInt8], fileExtension: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-ane-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try Data(bytes).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
