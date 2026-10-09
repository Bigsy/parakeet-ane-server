import AVFoundation
import os

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

    struct Stream {
        let track: Track
        let packets: [ArraySlice<UInt8>]
        /// Encoder padding to drop from the end, in 48 kHz samples (Matroska DiscardPadding).
        let endPadding: Int
    }

    /// Samples Core Audio's Opus decoder already drops from the start of a stream:
    /// Opus's 2.5 ms decoder delay. It isn't reported through `primeInfo`, so it is
    /// measured: `WebMOpusTests.alignsSampleExactlyWithFFmpeg` fails if macOS changes it.
    static let coreAudioDecoderDelay = 120

    /// Decode to 16 kHz mono Float32 samples.
    static func decode(_ bytes: [UInt8]) throws -> [Float] {
        let stream = try demux(bytes)
        let samples = try decodeOpus(packets: stream.packets, channels: stream.track.channels)
        // Opus trims are defined in 48 kHz samples: the encoder delay OpusHead declares
        // (less what the decoder already dropped) and the padding the container marks.
        // The converter compensates for its own resampling latency, so they scale to
        // the output rate directly.
        let scale = 48_000 / AudioDecoder.sampleRate
        let leading = max(preSkip(stream.track.codecPrivate) - coreAudioDecoderDelay, 0) / scale
        let trailing = stream.endPadding / scale
        guard leading <= samples.count, trailing <= samples.count - leading else {
            throw DecodeError.malformed("Opus padding exceeds decoded audio")
        }
        return Array(samples.dropFirst(leading).dropLast(trailing))
    }

    /// Feed `input` through `converter` in one go and collect the mono Float32 output.
    private static func convertAll(
        _ converter: AVAudioConverter, input: AVAudioBuffer, expectedFrames: Int
    ) throws -> [Float] {
        // Core Audio may call the input block on another thread, so its one bit of
        // state is locked; the buffer is only read once handed over.
        let input = UncheckedSendable(value: input)
        let handedOver = OSAllocatedUnfairLock(initialState: false)
        var samples: [Float] = []
        samples.reserveCapacity(expectedFrames)
        while true {
            guard let output = AVAudioPCMBuffer(
                    pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(expectedFrames + 4_096))
            else { throw DecodeError.decoderFailed("output buffer") }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                let first = handedOver.withLock { done in
                    defer { done = true }
                    return !done
                }
                inputStatus.pointee = first ? .haveData : .endOfStream
                return first ? input.value : nil
            }
            if status == .error { throw DecodeError.decoderFailed(error?.localizedDescription ?? "conversion") }
            samples += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
            if status == .endOfStream || output.frameLength == 0 { return samples }
        }
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
        static let discardPadding: UInt32 = 0x75A2
        static let simpleBlock: UInt32 = 0xA3
    }

    /// Containers whose children we need. They are entered rather than skipped, which
    /// also copes with the "unknown size" Segments and Clusters live recorders write.
    private static let containers: Set<UInt32> = [
        ID.segment, ID.tracks, ID.trackEntry, ID.audio, ID.cluster, ID.blockGroup,
    ]

    static func demux(_ bytes: [UInt8]) throws -> Stream {
        var tracks: [Track] = []
        var blocks: [(track: UInt64, frames: [ArraySlice<UInt8>], discardNanoseconds: Int64)] = []
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
            guard let size, size <= UInt64(bytes.count - dataStart) else {
                throw DecodeError.malformed("element size exceeds remaining input")
            }
            let dataEnd = dataStart + Int(size)
            let data = bytes[dataStart..<dataEnd]
            position = dataEnd

            switch id {
            case ID.trackNumber where !tracks.isEmpty:
                tracks[tracks.count - 1].number = readUInt(data)
            case ID.codecID where !tracks.isEmpty:
                tracks[tracks.count - 1].codecID = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .controlCharacters)
            case ID.codecPrivate where !tracks.isEmpty:
                tracks[tracks.count - 1].codecPrivate = Array(data)
            case ID.channels where !tracks.isEmpty:
                let channels = readUInt(data)
                guard (1...2).contains(channels) else {
                    throw DecodeError.unsupported("only mono and stereo Opus are supported")
                }
                tracks[tracks.count - 1].channels = Int(channels)
            case ID.simpleBlock, ID.block:
                let (track, frames) = try parseBlock(data)
                blocks.append((track, frames, 0))
            case ID.discardPadding where !blocks.isEmpty:
                // Follows its Block inside the same BlockGroup.
                blocks[blocks.count - 1].discardNanoseconds = readInt(data)
            default:
                break
            }
        }

        guard let opus = tracks.first(where: { $0.codecID == "A_OPUS" }) else { throw DecodeError.noOpusTrack }
        let opusBlocks = blocks.filter { $0.track == opus.number }
        let packets = opusBlocks.flatMap(\.frames)
        guard !packets.isEmpty else { throw DecodeError.malformed("no Opus packets") }
        var discard: Int64 = 0
        for block in opusBlocks {
            guard block.discardNanoseconds >= 0 else {
                throw DecodeError.unsupported("negative DiscardPadding")
            }
            let (sum, overflow) = discard.addingReportingOverflow(block.discardNanoseconds)
            guard !overflow else { throw DecodeError.malformed("DiscardPadding overflow") }
            discard = sum
        }
        // Divide the whole seconds first: even Int64.max nanoseconds must not
        // overflow while being converted to samples.
        let endPadding = discard / 1_000_000_000 * 48_000
            + discard % 1_000_000_000 * 48_000 / 1_000_000_000
        return Stream(track: opus, packets: packets, endPadding: Int(endPadding))
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
            guard !payload.isEmpty else { throw DecodeError.malformed("empty Opus packet") }
            return (trackNumber, [payload])
        case 2:  // Fixed-size lacing: a frame count byte, then equal-sized frames.
            guard let countByte = payload.first else { throw DecodeError.malformed("lacing header") }
            let frames = payload.dropFirst()
            let count = Int(countByte) + 1
            guard !frames.isEmpty, frames.count % count == 0 else {
                throw DecodeError.malformed("empty or uneven fixed lacing")
            }
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

    /// A big-endian two's complement integer of 1-8 bytes.
    private static func readInt(_ data: ArraySlice<UInt8>) -> Int64 {
        guard let first = data.first, data.count <= 8 else { return 0 }
        let initial: Int64 = first & 0x80 != 0 ? -1 : 0
        return data.reduce(initial) { $0 << 8 | Int64($1) }
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
        let samples = frames * frameSize
        // RFC 6716 limits each packet to 120 ms of audio.
        return (1...5_760).contains(samples) ? samples : nil
    }

    /// Decode Opus packets straight to 16 kHz mono, untrimmed.
    static func decodeOpus(packets: [ArraySlice<UInt8>], channels: Int) throws -> [Float] {
        guard let first = packets.first, !first.isEmpty,
            (1...2).contains(channels), packets.count <= Int(UInt32.max)
        else { throw DecodeError.malformed("invalid Opus packets or channels") }
        // Core Audio's Opus decoder takes a fixed frames-per-packet, which browsers use.
        guard let framesPerPacket = samplesPerPacket(first),
            packets.allSatisfy({ samplesPerPacket($0) == framesPerPacket })
        else { throw DecodeError.unsupported("variable Opus frame durations") }

        let (framesAt48k, frameOverflow) = packets.count.multipliedReportingOverflow(by: framesPerPacket)
        guard !frameOverflow, framesAt48k / 3 <= Int(UInt32.max) - 4_096 else {
            throw DecodeError.unsupported("Opus stream is too long")
        }
        let expectedFrames = framesAt48k / 3
        let maximumPacketSize = packets.map(\.count).max() ?? 0
        let (bufferBytes, bufferOverflow) = packets.count.multipliedReportingOverflow(by: maximumPacketSize)
        guard !bufferOverflow, bufferBytes <= Int(UInt32.max) else {
            throw DecodeError.unsupported("Opus packet buffer is too large")
        }

        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let inputFormat = AVAudioFormat(streamDescription: &description),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioDecoder.sampleRate), channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw DecodeError.decoderFailed("Core Audio has no Opus decoder for this stream") }
        converter.downmix = true

        let input = AVAudioCompressedBuffer(
            format: inputFormat, packetCapacity: AVAudioPacketCount(packets.count),
            maximumPacketSize: maximumPacketSize)
        var offset = 0
        for (index, packet) in packets.enumerated() {
            packet.withUnsafeBytes { input.data.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            input.packetDescriptions![index] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
            offset += packet.count
        }
        input.packetCount = AVAudioPacketCount(packets.count)
        input.byteLength = UInt32(offset)
        return try convertAll(
            converter, input: input, expectedFrames: expectedFrames)
    }
}

/// Carries a non-Sendable value into a `@Sendable` closure that is known to run
/// before the value is touched again.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
