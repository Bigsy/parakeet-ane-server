import AVFoundation

/// In-process decoding for the WebM/Opus that browser `MediaRecorder`s produce, so
/// the common case skips spawning ffmpeg (~30 ms warm, ~150 ms after idle).
///
/// Only what browser recordings use is supported: a single Opus track, unlaced or
/// fixed-laced blocks, and one frame duration throughout. Anything else throws, and
/// `AudioDecoder` falls back to ffmpeg.
enum WebMOpus {
    enum DecodeError: Error {
        case malformed(String)
        case noOpusTrack
        case unsupported(String)
        case decoderFailed(String)
    }

    struct Track {
        var number: UInt64 = 0
        var codecID = ""
        var channels = 1
        var codecPrivate: [UInt8] = []
    }

    /// Decode to 16 kHz mono Float32 samples.
    static func decode(_ bytes: [UInt8]) throws -> [Float] {
        let (track, packets) = try demux(bytes)
        return try decodeOpus(packets: packets, channels: track.channels, preSkip: preSkip(track.codecPrivate))
    }

    // MARK: - Matroska demuxing

    private enum ID {
        static let ebmlHeader: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let audio: UInt32 = 0xE1
        static let channels: UInt32 = 0x9F
        static let cluster: UInt32 = 0x1F43_B675
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let simpleBlock: UInt32 = 0xA3
    }

    /// Containers whose children we need. They are entered rather than skipped, which
    /// also copes with the "unknown size" Segments and Clusters live recorders write.
    private static let containers: Set<UInt32> = [
        ID.segment, ID.tracks, ID.trackEntry, ID.audio, ID.cluster, ID.blockGroup,
    ]

    static func demux(_ bytes: [UInt8]) throws -> (Track, [ArraySlice<UInt8>]) {
        var tracks: [Track] = []
        var blocks: [(track: UInt64, frames: [ArraySlice<UInt8>])] = []
        var position = 0

        while position < bytes.count {
            guard let (id, idLength) = readID(bytes, at: position),
                let (size, sizeLength) = readVarInt(bytes, at: position + idLength)
            else { break }  // Trailing garbage or a truncated final element.
            let dataStart = position + idLength + sizeLength

            if containers.contains(id) {
                if id == ID.trackEntry { tracks.append(Track()) }
                position = dataStart
                continue
            }
            guard let size, dataStart + Int(size) <= bytes.count else { break }
            let data = bytes[dataStart..<dataStart + Int(size)]
            position = dataStart + Int(size)

            switch id {
            case ID.trackNumber where !tracks.isEmpty:
                tracks[tracks.count - 1].number = readUInt(data)
            case ID.codecID where !tracks.isEmpty:
                tracks[tracks.count - 1].codecID = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .controlCharacters)
            case ID.codecPrivate where !tracks.isEmpty:
                tracks[tracks.count - 1].codecPrivate = Array(data)
            case ID.channels where !tracks.isEmpty:
                tracks[tracks.count - 1].channels = Int(readUInt(data))
            case ID.simpleBlock, ID.block:
                blocks.append(try parseBlock(data))
            default:
                break
            }
        }

        guard let opus = tracks.first(where: { $0.codecID == "A_OPUS" }) else { throw DecodeError.noOpusTrack }
        let packets = blocks.filter { $0.track == opus.number }.flatMap(\.frames)
        guard !packets.isEmpty else { throw DecodeError.malformed("no Opus packets") }
        return (opus, packets)
    }

    private static func parseBlock(_ data: ArraySlice<UInt8>) throws -> (track: UInt64, frames: [ArraySlice<UInt8>]) {
        guard let (trackNumber, length) = readVarInt(data, at: data.startIndex), let trackNumber else {
            throw DecodeError.malformed("block track number")
        }
        // Track number, then a 16-bit relative timecode and a flags byte.
        let flagsIndex = data.startIndex + length + 2
        guard flagsIndex < data.endIndex else { throw DecodeError.malformed("short block") }
        let payload = data[(flagsIndex + 1)...]

        switch (data[flagsIndex] >> 1) & 0b11 {
        case 0:
            return (trackNumber, [payload])
        case 2:  // Fixed-size lacing: a frame count byte, then equal-sized frames.
            guard let countByte = payload.first else { throw DecodeError.malformed("lacing header") }
            let frames = payload.dropFirst()
            let count = Int(countByte) + 1
            guard frames.count % count == 0 else { throw DecodeError.malformed("uneven fixed lacing") }
            let size = frames.count / count
            return (trackNumber, (0..<count).map { frames.dropFirst($0 * size).prefix(size) })
        default:
            throw DecodeError.unsupported("Xiph or EBML lacing")
        }
    }

    /// An element ID, kept with its length marker as Matroska specifies IDs.
    private static func readID(_ bytes: [UInt8], at index: Int) -> (UInt32, Int)? {
        guard index < bytes.count, bytes[index] != 0 else { return nil }
        let length = bytes[index].leadingZeroBitCount + 1
        guard length <= 4, index + length <= bytes.count else { return nil }
        return (bytes[index..<index + length].reduce(0) { $0 << 8 | UInt32($1) }, length)
    }

    /// A variable-length integer with its marker bit removed. The value is nil for
    /// the all-ones "unknown size" encoding.
    private static func readVarInt<C: Collection<UInt8>>(_ bytes: C, at index: C.Index) -> (UInt64?, Int)?
    where C.Index == Int {
        guard index < bytes.endIndex, bytes[index] != 0 else { return nil }
        let length = bytes[index].leadingZeroBitCount + 1
        guard index + length <= bytes.endIndex else { return nil }
        let first = UInt64(bytes[index] & (0xFF >> length))
        let value = bytes[(index + 1)..<(index + length)].reduce(first) { $0 << 8 | UInt64($1) }
        let unknown = value == (UInt64(1) << (7 * length)) - 1
        return (unknown ? nil : value, length)
    }

    private static func readUInt(_ data: ArraySlice<UInt8>) -> UInt64 {
        data.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    // MARK: - Opus decoding

    /// Samples at 48 kHz that `OpusHead` asks the decoder to discard (encoder delay).
    static func preSkip(_ opusHead: [UInt8]) -> Int {
        guard opusHead.count >= 12, opusHead.starts(with: Array("OpusHead".utf8)) else { return 0 }
        return Int(opusHead[10]) | Int(opusHead[11]) << 8
    }

    /// Samples per channel at 48 kHz in one Opus packet, from its TOC byte (RFC 6716 3.1).
    static func samplesPerPacket(_ packet: ArraySlice<UInt8>) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        let frameSize =
            switch config {
            case 0...11: [480, 960, 1920, 2880][config % 4]  // SILK: 10/20/40/60 ms
            case 12...15: [480, 960][config % 2]  // Hybrid: 10/20 ms
            default: [120, 240, 480, 960][config % 4]  // CELT: 2.5/5/10/20 ms
            }
        let frames: Int
        switch toc & 0b11 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return nil }
            frames = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        return frames * frameSize
    }

    private static func decodeOpus(packets: [ArraySlice<UInt8>], channels: Int, preSkip: Int) throws -> [Float] {
        // Core Audio's Opus decoder takes a fixed frames-per-packet, which browsers use.
        guard let framesPerPacket = samplesPerPacket(packets[0]),
            packets.allSatisfy({ samplesPerPacket($0) == framesPerPacket })
        else { throw DecodeError.unsupported("variable Opus frame durations") }

        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(channels, 1)), mBitsPerChannel: 0, mReserved: 0)
        guard let inputFormat = AVAudioFormat(streamDescription: &description),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioDecoder.sampleRate), channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw DecodeError.decoderFailed("Core Audio has no Opus decoder for this stream") }
        converter.downmix = true

        let input = AVAudioCompressedBuffer(
            format: inputFormat, packetCapacity: AVAudioPacketCount(packets.count),
            maximumPacketSize: packets.map(\.count).max() ?? 0)
        var offset = 0
        for (index, packet) in packets.enumerated() {
            packet.withUnsafeBytes { input.data.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            input.packetDescriptions![index] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
            offset += packet.count
        }
        input.packetCount = AVAudioPacketCount(packets.count)
        input.byteLength = UInt32(offset)

        let expectedFrames = packets.count * framesPerPacket * AudioDecoder.sampleRate / 48_000
        var samples: [Float] = []
        samples.reserveCapacity(expectedFrames)
        var inputConsumed = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(expectedFrames + 4_096))
            else { throw DecodeError.decoderFailed("output buffer") }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if inputConsumed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputConsumed = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { throw DecodeError.decoderFailed(error?.localizedDescription ?? "unknown") }
            samples += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
            if status == .endOfStream || output.frameLength == 0 { break }
        }

        // Drop the encoder delay OpusHead declares, scaled from 48 kHz.
        return Array(samples.dropFirst(preSkip * AudioDecoder.sampleRate / 48_000))
    }
}
