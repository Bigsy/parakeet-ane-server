import Foundation

/// Test fixtures built in code, so the repo carries no binary audio.
enum TestAudio {
    /// A 16-bit PCM WAV of a 440 Hz tone.
    static func wav(seconds: Double, sampleRate: Int = 44_100, channels: Int = 2) -> [UInt8] {
        let frames = Int(seconds * Double(sampleRate))
        var pcm: [UInt8] = []
        pcm.reserveCapacity(frames * channels * 2)
        for frame in 0..<frames {
            let value = Int16(sin(2 * .pi * 440 * Double(frame) / Double(sampleRate)) * 8_000)
            for _ in 0..<channels { pcm += le(UInt16(bitPattern: value)) }
        }
        let byteRate = sampleRate * channels * 2
        return Array("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Array("WAVE".utf8)
            + Array("fmt ".utf8) + le(UInt32(16)) + le(UInt16(1)) + le(UInt16(channels))
            + le(UInt32(sampleRate)) + le(UInt32(byteRate)) + le(UInt16(channels * 2)) + le(UInt16(16))
            + Array("data".utf8) + le(UInt32(pcm.count)) + pcm
    }

    /// Encode a WAV to WebM/Opus with ffmpeg, as a browser recorder would produce.
    static func webm(fromWAV wav: [UInt8], ffmpeg: String) throws -> [UInt8] {
        let dir = FileManager.default.temporaryDirectory
        let input = dir.appendingPathComponent("parakeet-test-\(UUID().uuidString).wav")
        let output = dir.appendingPathComponent("parakeet-test-\(UUID().uuidString).webm")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try Data(wav).write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-loglevel", "error", "-i", input.path, "-c:a", "libopus", output.path]
        try process.run()
        process.waitUntilExit()
        return Array(try Data(contentsOf: output))
    }

    /// A multipart/form-data body with a `file` part plus plain text fields.
    static func multipart(
        boundary: String, file: [UInt8], fileName: String = "audio.webm", fields: [String: String] = [:]
    ) -> [UInt8] {
        var body: [UInt8] = []
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body += Array("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        body += Array(
            """
            --\(boundary)\r
            Content-Disposition: form-data; name="file"; filename="\(fileName)"\r
            Content-Type: application/octet-stream\r
            \r

            """.utf8)
        body += file
        body += Array("\r\n--\(boundary)--\r\n".utf8)
        return body
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }
}
