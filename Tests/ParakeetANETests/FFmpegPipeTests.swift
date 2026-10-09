import Foundation
import Testing

@testable import ParakeetANE

@Suite struct FFmpegPipeTests {
    @Test func drainsNoisyErrorsWhileWaitingForStdout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("noisy-ffmpeg")
        // Write well beyond pipe capacity before closing stdout. A sequential
        // stdout/stderr reader hangs here. A watchdog bounds a regression failure.
        let script = """
            #!/bin/sh
            (sleep 5; kill -TERM $$ 2>/dev/null) >/dev/null 2>&1 &
            watchdog=$!
            /usr/bin/awk 'BEGIN { for (i = 0; i < 20000; i++) print "decode error" }' >&2
            kill "$watchdog" 2>/dev/null
            exit 42
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let start = ContinuousClock.now
        do {
            _ = try await AudioDecoder(ffmpegPath: executable.path).decode(Array("OggSinvalid".utf8))
            Issue.record("Expected an ffmpeg failure")
        } catch AudioDecodeError.ffmpegFailed(let status, let stderr) {
            #expect(status == 42)
            #expect(stderr.hasPrefix("decode error"))
            #expect(stderr.utf8.count <= 65_536)
        }
        #expect(start.duration(to: .now) < .seconds(5))
    }
}
