import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import ParakeetANE
@testable import ParakeetCore

/// Echoes the sample count so tests can check what reached the model.
struct StubModel: SpeechModel {
    let id = "stub-model"
    func transcribe(_ samples: [Float]) async throws -> String {
        "heard \(samples.count) samples"
    }
}

actor BlockingServerModel: SpeechModel {
    nonisolated let id = "blocking"
    private var continuation: CheckedContinuation<String, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func transcribe(_ samples: [Float]) async throws -> String {
        await withCheckedContinuation {
            continuation = $0
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { continuation?.resume(returning: "ok"); continuation = nil }
}

struct FailingServerModel: SpeechModel {
    let id = "failure"
    func transcribe(_ samples: [Float]) async throws -> String {
        throw NSError(domain: "private transcript diagnostics", code: 1)
    }
}

@Suite struct ServerTests {
    let boundary = "test-boundary-1234"

    func app(ffmpeg: String? = nil) -> some ApplicationProtocol {
        let logger = Logger(label: "test")
        let router = makeRouter(
            service: TranscriptionService(engine: ParakeetEngine(preparedModel: StubModel())),
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
        let webm = try TestAudio.opus(fromWAV: TestAudio.wav(seconds: 1.5), ffmpeg: ffmpeg)
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

    @Test func malformedWebMMetadataReturnsAnError() async throws {
        // A 17-byte upload whose channel count cannot fit in Int used to trap.
        let bytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x80, 0xAE, 0x8A, 0x9F, 0x88]
            + [UInt8](repeating: 0xFF, count: 8)
        let (headers, body) = upload(bytes)
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: body) {
                #expect($0.status == .badRequest)
                #expect(String(buffer: $0.body).contains("invalid_request_error"))
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

    @Test func preservesUnpaddedVerboseDuration() async throws {
        let (headers, body) = upload(TestAudio.wav(seconds: 0.25), fields: ["response_format": "verbose_json"])
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: body) {
                let json = try #require(try JSONSerialization.jsonObject(with: Data(buffer: $0.body)) as? [String: Any])
                #expect(json["text"] as? String == "heard 16000 samples")
                #expect(json["duration"] as? Double == 0.25)
                #expect((json["segments"] as? [[String: Any]])?.first?["end"] as? Double == 0.25)
            }
        }
    }

    @Test func mapsLimitsAndFailedReadiness() async throws {
        let engine = ParakeetEngine(configuration: .init(maximumAudioSamples: 1), preparedModel: StubModel())
        let router = makeRouter(service: .init(engine: engine), decoder: .init(ffmpegPath: nil),
                                options: .init(host: "127.0.0.1", port: 0), logger: .init(label: "test"))
        let (headers, body) = upload(TestAudio.wav(seconds: 0.25))
        try await Application(router: router).test(.router) { client in
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: body) {
                #expect($0.status == .contentTooLarge)
                #expect(String(buffer: $0.body).contains("invalid_request_error"))
            }
            try await engine.unload()
            try await client.execute(uri: "/health", method: .get) { #expect($0.status == .serviceUnavailable) }
        }
    }

    @Test func queueFullIs503AndErrorsAreSanitized() async throws {
        let model = BlockingServerModel()
        let engine = ParakeetEngine(configuration: .init(queueCapacity: 0), preparedModel: model)
        let active = Task { try await engine.transcribe(PCM16kMono(samples: [0])) }
        await model.waitForStart()
        let logger = Logger(label: "test")
        let router = makeRouter(service: .init(engine: engine), decoder: .init(ffmpegPath: nil),
                                options: .init(host: "127.0.0.1", port: 0), logger: logger)
        let (headers, body) = upload(TestAudio.wav(seconds: 0.25))
        try await Application(router: router).test(.router) { client in
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: body) {
                #expect($0.status == .serviceUnavailable)
                #expect(String(buffer: $0.body).contains("server_error"))
            }
        }
        await model.release(); _ = try await active.value
        let failing = makeRouter(service: .init(engine: ParakeetEngine(preparedModel: FailingServerModel())),
                                 decoder: .init(ffmpegPath: nil), options: .init(host: "127.0.0.1", port: 0), logger: logger)
        try await Application(router: failing).test(.router) { client in
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post, headers: headers, body: body) {
                #expect($0.status == .internalServerError)
                #expect(!String(buffer: $0.body).contains("private transcript"))
            }
        }
    }

    @Test func rejectsMissingFile() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post,
                                     headers: [.contentType: "multipart/form-data; boundary=empty"],
                                     body: ByteBuffer(string: "--empty--\r\n")) {
                #expect($0.status == .badRequest)
                #expect(String(buffer: $0.body).contains("invalid_request_error"))
            }
        }
    }

    @Test func rejectsNonMultipartContentTypes() {
        #expect(multipartBoundary("application/json") == nil)
        #expect(multipartBoundary("multipart/form-data") == nil)
        #expect(multipartBoundary(nil) == nil)
    }
}
