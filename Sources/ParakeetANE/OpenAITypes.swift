import Foundation
import MultipartKit

/// Fields of an OpenAI `/v1/audio/transcriptions` multipart upload. Only `file` is
/// required; `model`, `language` and `prompt` are accepted and ignored, since the
/// server runs one model and Parakeet takes no prompt.
struct TranscriptionForm: Decodable {
    var file: AudioUpload
    var model: String?
    var language: String?
    var prompt: String?
    var responseFormat: String?

    enum CodingKeys: String, CodingKey {
        case file, model, language, prompt
        case responseFormat = "response_format"
    }
}

/// The `file` part of the upload. Decoded straight from the multipart part so the
/// raw bytes survive; the plain `Decodable` path is never used.
struct AudioUpload: Decodable, MultipartPartConvertible {
    let bytes: [UInt8]
    let contentType: String?

    var multipart: MultipartPart? { nil }

    init?(multipart: MultipartPart) {
        bytes = Array(multipart.body.readableBytesView)
        contentType = multipart.headers.first(name: "Content-Type")
    }

    init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "file must be a multipart file part"))
    }
}

enum ResponseFormat: String {
    case json, text
    case verboseJSON = "verbose_json"
}

struct TranscriptionJSON: Encodable {
    let text: String
}

/// `verbose_json` as OpenAI shapes it. Parakeet gives no Whisper-style segment
/// statistics, so the whole clip is one segment with neutral values.
struct VerboseTranscriptionJSON: Encodable {
    struct Segment: Encodable {
        let id = 0
        let seek = 0
        let start = 0.0
        let end: Double
        let text: String
        let tokens: [Int] = []
        let temperature = 0.0
        let avgLogprob = 0.0
        let compressionRatio = 0.0
        let noSpeechProb = 0.0

        enum CodingKeys: String, CodingKey {
            case id, seek, start, end, text, tokens, temperature
            case avgLogprob = "avg_logprob"
            case compressionRatio = "compression_ratio"
            case noSpeechProb = "no_speech_prob"
        }
    }

    let task = "transcribe"
    let language = "english"
    let duration: Double
    let text: String
    let segments: [Segment]

    init(text: String, duration: Double) {
        self.text = text
        self.duration = duration
        // Strict clients reject segments with empty text, so silence gets none.
        segments = text.isEmpty ? [] : [Segment(end: duration, text: text)]
    }
}

struct ModelList: Encodable {
    struct Model: Encodable {
        let id: String
        let object = "model"
        let ownedBy = "fluidaudio"

        enum CodingKeys: String, CodingKey {
            case id, object
            case ownedBy = "owned_by"
        }
    }

    let object = "list"
    let data: [Model]
}

struct OpenAIErrorBody: Encodable {
    struct Detail: Encodable {
        let message: String
        let type: String
    }

    let error: Detail
}
