import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import ParakeetANE

/// Echoes the sample count so tests can check what reached the model.
struct StubModel: SpeechModel {
    let id = "stub-model"
    func transcribe(_ samples: [Float]) async throws -> String {
        "heard \(samples.count) samples"
    }
}

@Suite struct ServerTests {
    let boundary = "test-boundary-1234"

    func app(ffmpeg: String? = nil) -> some ApplicationProtocol {
        let logger = Logger(label: "test")
        let router = makeRouter(
            service: TranscriptionService(model: StubModel(), logger: logger),
            decoder: AudioDecoder(ffmpegPath: ffmpeg),
            options: ServerOptions(host: "127.0.0.1", port: 0),
            logger: logger
        )
        return Application(router: router)
    }

    func upload(_ file: [UInt8], fields: [String: String] = [:]) -> (HTTPFields, ByteBuffer) {
        let body = TestAudio.multipart(boundary: boundary, file: file, fields: fields)
        return ([.contentType: "multipart/form-data; boundary=\(boundary)"], ByteBuffer(bytes: body))
    }

    @Test func transcribesUploadAsJSON() async throws {
        let (headers, body) = upload(TestAudio.wav(seconds: 2), fields: ["model": "whisper-1"])
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: body) {
                #expect($0.status == .ok)
                let json = try JSONDecoder().decode([String: String].self, from: Data(buffer: $0.body))
                #expect(json == ["text": "heard 32000 samples"])
            }
        }
    }

    @Test func padsClipsShorterThanOneSecond() async throws {
        let (headers, body) = upload(TestAudio.wav(seconds: 0.25))
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: body) {
                #expect(String(buffer: $0.body).contains("heard 16000 samples"))
            }
        }
    }

    @Test func supportsTextAndVerboseJSON() async throws {
        let (textHeaders, textBody) = upload(TestAudio.wav(seconds: 1), fields: ["response_format": "text"])
        let (verboseHeaders, verboseBody) = upload(
            TestAudio.wav(seconds: 1), fields: ["response_format": "verbose_json"])
        try await app().test(.router) { client in
            try await client.execute(
                uri: "/v1/audio/transcriptions", method: .post, headers: textHeaders, body: textBody
            ) {
                #expect($0.headers[.contentType]?.hasPrefix("text/plain") == true)
                #expect(String(buffer: $0.body) == "heard 16000 samples")
            }
            try await client.execute(
                uri: "/v1/audio/transcriptions", method: .post, headers: verboseHeaders, body: verboseBody
            ) {
                let json = try #require(
                    try JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as? [String: Any])
                #expect(json["text"] as? String == "heard 16000 samples")
                #expect(json["duration"] as? Double == 1.0)
                #expect((json["segments"] as? [[String: Any]])?.first?["end"] as? Double == 1.0)
            }
        }
    }

    @Test(.enabled(if: AudioDecoder.locateFFmpeg() != nil))
    func acceptsBrowserWebMUploads() async throws {
        let ffmpeg = try #require(AudioDecoder.locateFFmpeg())
        let webm = try TestAudio.webm(fromWAV: TestAudio.wav(seconds: 1.5), ffmpeg: ffmpeg)
        let (headers, body) = upload(webm)
        try await app(ffmpeg: ffmpeg).test(.router) { client in
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: body) {
                #expect($0.status == .ok)
                #expect(String(buffer: $0.body).contains("heard 2"))
            }
        }
    }

    @Test func rejectsBadRequestsWithOpenAIErrors() async throws {
        let (headers, garbage) = upload(Array("definitely not audio".utf8))
        let (formatHeaders, badFormat) = upload(TestAudio.wav(seconds: 1), fields: ["response_format": "srt"])
        try await app().test(.router) { client in
            try await client.execute(
                uri: "/v1/audio/transcriptions", method: .post, headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{}")
            ) {
                #expect($0.status == .badRequest)
                #expect(String(buffer: $0.body).contains("invalid_request_error"))
            }
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: garbage) {
                #expect($0.status == .badRequest)
            }
            try await client.execute(
                uri: "/v1/audio/transcriptions", method: .post, headers: formatHeaders, body: badFormat
            ) {
                #expect($0.status == .badRequest)
                #expect(String(buffer: $0.body).contains("srt"))
            }
        }
    }

    @Test func listsModelAndReportsHealth() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) {
                #expect(String(buffer: $0.body).contains("\"id\":\"stub-model\""))
            }
            try await client.execute(uri: "/health", method: .get) {
                #expect($0.status == .ok)
            }
        }
    }

    @Test(arguments: [
        ("multipart/form-data; boundary=abc", "abc"),
        ("multipart/form-data; boundary=\"quoted value\"", "quoted value"),
        ("Multipart/Form-Data;charset=utf-8; BOUNDARY=x-y", "x-y"),
    ])
    func parsesMultipartBoundary(header: String, expected: String) {
        #expect(multipartBoundary(header) == expected)
    }

    @Test func rejectsNonMultipartContentTypes() {
        #expect(multipartBoundary("application/json") == nil)
        #expect(multipartBoundary("multipart/form-data") == nil)
        #expect(multipartBoundary(nil) == nil)
    }
}
