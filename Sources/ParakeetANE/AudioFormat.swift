/// Container formats recognised from an upload's leading bytes.
///
/// Uploads are sniffed rather than trusted by filename or content type: browser
/// recorders (OpenWhispr included) send `audio/webm` blobs with generic names.
public enum AudioFormat: String, Sendable, CaseIterable {
    case wav, aiff, caf, flac, mp3, mp4, webm, ogg

    /// Formats Core Audio decodes natively. Anything else goes through ffmpeg.
    public var isNativelyDecodable: Bool {
        switch self {
        case .wav, .aiff, .caf, .flac, .mp3, .mp4: true
        case .webm, .ogg: false
        }
    }

    /// File extension Core Audio uses to pick a parser for the temp file.
    public var fileExtension: String {
        switch self {
        case .mp4: "m4a"
        default: rawValue
        }
    }

    /// Identify the container from its magic bytes, or nil if unrecognised.
    public static func sniff<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> AudioFormat? {
        let head = Array(bytes.prefix(12))
        func matches(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + signature.count
                && Array(head[offset..<offset + signature.count]) == signature
        }
        let ascii = { (s: String) in Array(s.utf8) }

        if matches(ascii("RIFF")) && matches(ascii("WAVE"), at: 8) { return .wav }
        if matches(ascii("FORM")) && (matches(ascii("AIFF"), at: 8) || matches(ascii("AIFC"), at: 8)) {
            return .aiff
        }
        if matches(ascii("caff")) { return .caf }
        if matches(ascii("fLaC")) { return .flac }
        if matches(ascii("ftyp"), at: 4) { return .mp4 }
        if matches([0x1A, 0x45, 0xDF, 0xA3]) { return .webm }
        if matches(ascii("OggS")) { return .ogg }
        if matches(ascii("ID3")) { return .mp3 }
        // Bare MPEG audio frame sync (11 set bits), as written without an ID3 tag.
        if head.count >= 2 && head[0] == 0xFF && head[1] & 0xE0 == 0xE0 { return .mp3 }
        return nil
    }
}
