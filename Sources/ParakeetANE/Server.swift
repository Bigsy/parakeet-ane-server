import Foundation
import Hummingbird
import Logging
import MultipartKit

public struct ServerOptions: Sendable {
    public var host: String
    public var port: Int
    /// Log transcript text. Off by default: dictation can contain anything.
    public var logTranscripts: Bool
    public var maxUploadBytes: Int

    public init(host: String, port: Int, logTranscripts: Bool = false, maxUploadBytes: Int = 100 * 1024 * 1024) {
        self.host = host
        self.port = port
        self.logTranscripts = logTranscripts
        self.maxUploadBytes = maxUploadBytes
    }
}

/// Router for the OpenAI-compatible endpoints. Separate from `makeApplication` so
/// tests can drive it with a stub model.
public func makeRouter(
    service: TranscriptionService, decoder: AudioDecoder, options: ServerOptions, logger: Logger
) -> Router<BasicRequestContext> {
    let router = Router()

    router.get("/health") { _, _ in
        jsonResponse(["status": "ok"])
    }

    router.get("/v1/models") { _, _ in
        jsonResponse(ModelList(data: [.init(id: service.model.id)]))
    }

    router.post("/v1/audio/transcriptions") { request, _ in
        let start = ContinuousClock.now
        guard let boundary = multipartBoundary(request.headers[.contentType]) else {
            return errorResponse(.badRequest, "Expected a multipart/form-data upload.")
        }
        let body = try await request.body.collect(upTo: options.maxUploadBytes)
        let form: TranscriptionForm
        do {
            form = try FormDataDecoder().decode(TranscriptionForm.self, from: body, boundary: boundary)
        } catch {
            return errorResponse(.badRequest, "Missing or invalid 'file' field: \(error)")
        }
        guard let format = ResponseFormat(rawValue: form.responseFormat ?? "json") else {
            return errorResponse(.badRequest, "Unsupported response_format '\(form.responseFormat ?? "")'.")
        }

        let samples: [Float]
        let audioFormat: AudioFormat?
        do {
            (samples, audioFormat) = try await decoder.decode(form.file.bytes)
        } catch {
            return errorResponse(.badRequest, "\(error)")
        }
        let decoded = ContinuousClock.now

        let text: String
        do {
            text = try await service.transcribe(samples)
        } catch {
            logger.error("Transcription failed: \(error)")
            return errorResponse(.internalServerError, "Transcription failed: \(error)")
        }
        let finished = ContinuousClock.now

        let audioSeconds = Double(samples.count) / Double(AudioDecoder.sampleRate)
        logger.info(
            """
            Transcribed \(String(format: "%.2f", audioSeconds)) s \
            \(audioFormat?.rawValue ?? form.file.contentType ?? "unknown") \
            (\(form.file.bytes.count) bytes): decode \(start.duration(to: decoded).milliseconds) ms, \
            asr \(decoded.duration(to: finished).milliseconds) ms, \
            total \(start.duration(to: finished).milliseconds) ms
            """)
        if options.logTranscripts {
            logger.info("Text: \(text)")
        }

        switch format {
        case .json:
            return jsonResponse(TranscriptionJSON(text: text))
        case .verboseJSON:
            return jsonResponse(VerboseTranscriptionJSON(text: text, duration: audioSeconds))
        case .text:
            return Response(
                status: .ok,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: text))
            )
        }
    }

    return router
}

public func makeApplication(
    service: TranscriptionService, decoder: AudioDecoder, options: ServerOptions, logger: Logger
) -> some ApplicationProtocol {
    Application(
        router: makeRouter(service: service, decoder: decoder, options: options, logger: logger),
        configuration: .init(address: .hostname(options.host, port: options.port), serverName: "parakeet-ane-server"),
        logger: logger
    )
}

/// The `boundary` parameter of a `multipart/form-data` content type.
func multipartBoundary(_ contentType: String?) -> String? {
    guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data") else { return nil }
    for parameter in contentType.split(separator: ";").dropFirst() {
        let pair = parameter.split(separator: "=", maxSplits: 1)
        guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else {
            continue
        }
        let value = pair[1].trimmingCharacters(in: .whitespaces)
        return value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
            ? String(value.dropFirst().dropLast()) : value
    }
    return nil
}

private func jsonResponse(_ value: some Encodable, status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
}

private func errorResponse(_ status: HTTPResponse.Status, _ message: String) -> Response {
    let type = status.code >= 500 ? "server_error" : "invalid_request_error"
    return jsonResponse(OpenAIErrorBody(error: .init(message: message, type: type)), status: status)
}
