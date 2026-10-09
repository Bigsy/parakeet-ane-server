import FluidAudio
import Foundation

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

/// Turns an uploaded audio file into 16 kHz mono Float32 samples, the input every
/// Parakeet model expects.
public struct AudioDecoder: Sendable {
    public static let sampleRate = 16_000

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

    public func decode(_ bytes: [UInt8]) async throws -> (samples: [Float], format: AudioFormat?) {
        let format = AudioFormat.sniff(bytes)
        let input = try TemporaryFile(bytes: bytes, fileExtension: format?.fileExtension ?? "bin")
        defer { input.remove() }

        if let format, format.isNativelyDecodable {
            do {
                return (try AudioConverter().resampleAudioFile(input.url), format)
            } catch {
                // A mislabelled or unusual file may still be readable by ffmpeg.
                guard ffmpegPath != nil else { throw AudioDecodeError.nativeDecodeFailed(error) }
            }
        }
        guard let ffmpegPath else {
            throw format == nil ? AudioDecodeError.unrecognisedFormat : AudioDecodeError.ffmpegUnavailable(format)
        }
        return (try await Self.decodeWithFFmpeg(ffmpegPath, input: input.url), format)
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
            // Drain stdout before waiting, or a long clip fills the pipe and deadlocks.
            let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
            let errorOutput = try stderr.fileHandleForReading.readToEnd() ?? Data()
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
