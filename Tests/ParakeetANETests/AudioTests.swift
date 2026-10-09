import Foundation
import Testing

@testable import ParakeetANE

private let ffmpeg = AudioDecoder.locateFFmpeg()

@Suite struct AudioFormatTests {
    @Test(arguments: [
        (Array("RIFF\0\0\0\0WAVEfmt ".utf8), AudioFormat.wav),
        (Array("FORM\0\0\0\0AIFF".utf8), .aiff),
        (Array("FORM\0\0\0\0AIFC".utf8), .aiff),
        (Array("caff\0\u{1}\0\0".utf8), .caf),
        (Array("fLaC\0\0\0\"".utf8), .flac),
        (Array("\0\0\0\u{20}ftypM4A ".utf8), .mp4),
        ([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42], .webm),
        (Array("OggS\0\u{2}".utf8), .ogg),
        (Array("ID3\u{4}\0".utf8), .mp3),
        ([0xFF, 0xFB, 0x90, 0x64], .mp3),
    ])
    func sniffsKnownContainers(bytes: [UInt8], expected: AudioFormat) {
        #expect(AudioFormat.sniff(bytes) == expected)
    }

    @Test func rejectsUnknownAndTruncatedInput() {
        #expect(AudioFormat.sniff(Array("hello world!".utf8)) == nil)
        #expect(AudioFormat.sniff(Array("RIFF".utf8)) == nil)
        #expect(AudioFormat.sniff([UInt8]()) == nil)
    }

    @Test func onlyWebMAndOggNeedFFmpeg() {
        let viaFFmpeg = AudioFormat.allCases.filter { !$0.isNativelyDecodable }
        #expect(Set(viaFFmpeg) == [.webm, .ogg])
    }
}

@Suite struct AudioDecoderTests {
    @Test func decodesWAVNativelyTo16kMono() async throws {
        let wav = TestAudio.wav(seconds: 1.5, sampleRate: 44_100, channels: 2)
        let decoded = try await AudioDecoder(ffmpegPath: nil).decode(wav)
        #expect(decoded.format == .wav)
        #expect(decoded.path == .coreAudio)
        #expect(abs(decoded.samples.count - 24_000) < 160)
        #expect(decoded.samples.contains { abs($0) > 0.1 })
    }

    @Test(.enabled(if: ffmpeg != nil))
    func decodesWebMInProcessWithoutFFmpeg() async throws {
        let webm = try TestAudio.opus(fromWAV: TestAudio.wav(seconds: 1), ffmpeg: try #require(ffmpeg))
        let decoded = try await AudioDecoder(ffmpegPath: nil).decode(webm)
        #expect(decoded.format == .webm)
        #expect(decoded.path == .webmOpus)
        #expect(abs(decoded.samples.count - 16_000) < 400)
    }

    @Test(.enabled(if: ffmpeg != nil))
    func decodesOggThroughFFmpeg() async throws {
        let ffmpeg = try #require(ffmpeg)
        let ogg = try TestAudio.opus(fromWAV: TestAudio.wav(seconds: 1), ffmpeg: ffmpeg, container: "ogg")
        let decoded = try await AudioDecoder(ffmpegPath: ffmpeg).decode(ogg)
        #expect(decoded.format == .ogg)
        #expect(decoded.path == .ffmpeg)
        #expect(abs(decoded.samples.count - 16_000) < 800)
    }

    @Test func undecodableWebMWithoutFFmpegIsAnError() async {
        let webm: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 64)
        await #expect(throws: AudioDecodeError.self) {
            try await AudioDecoder(ffmpegPath: nil).decode(webm)
        }
    }
}

@Suite(.enabled(if: ffmpeg != nil)) struct WebMOpusTests {
    /// The in-process decoder should agree with ffmpeg on length and level. Mono, as
    /// ffmpeg and Core Audio downmix stereo with different gains (sum at -3 dB vs mean).
    @Test func matchesFFmpegOutput() async throws {
        let ffmpeg = try #require(ffmpeg)
        let wav = TestAudio.wav(seconds: 3, channels: 1)
        let ours = try WebMOpus.decode(TestAudio.opus(fromWAV: wav, ffmpeg: ffmpeg))
        let theirs = try await AudioDecoder(ffmpegPath: ffmpeg).decode(
            TestAudio.opus(fromWAV: wav, ffmpeg: ffmpeg, container: "ogg")
        ).samples
        #expect(abs(ours.count - theirs.count) < 400)
        #expect(abs(TestAudio.rms(ours) - TestAudio.rms(theirs)) < 0.1 * TestAudio.rms(theirs))
    }

    /// Same samples as ffmpeg, not just the same length: pre-skip, Core Audio's decoder
    /// delay and DiscardPadding all trimmed. A misaligned start or a padded tail was
    /// enough to change Parakeet's punctuation at the end of a clip.
    @Test func alignsSampleExactlyWithFFmpeg() throws {
        let ffmpeg = try #require(ffmpeg)
        let webm = try TestAudio.opus(fromWAV: TestAudio.noiseWAV(seconds: 2), ffmpeg: ffmpeg)
        let ours = try WebMOpus.decode(webm)
        let theirs = try TestAudio.ffmpegDecode(webm, ffmpeg: ffmpeg)
        let overlap = 2_000..<(min(ours.count, theirs.count) - 2_000)
        let bestLag = (-200...200).max { a, b in
            overlap.reduce(Float(0)) { $0 + ours[$1] * theirs[$1 + a] }
                < overlap.reduce(Float(0)) { $0 + ours[$1] * theirs[$1 + b] }
        }
        #expect(bestLag == 0)
        #expect(abs(ours.count - theirs.count) <= 2)
    }

    /// Live recorders write Segments and Clusters with unknown sizes.
    @Test func decodesLiveStreamWithUnknownSizes() throws {
        let webm = try TestAudio.opus(
            fromWAV: TestAudio.wav(seconds: 2), ffmpeg: try #require(ffmpeg), extraArguments: ["-live", "1"])
        #expect(abs(try WebMOpus.decode(webm).count - 32_000) < 400)
    }

    @Test func downmixesStereoToMono() throws {
        let webm = try TestAudio.opus(
            fromWAV: TestAudio.wav(seconds: 1, channels: 2), ffmpeg: try #require(ffmpeg), extraArguments: ["-ac", "2"])
        #expect(try WebMOpus.demux(webm).track.channels == 2)
        #expect(abs(try WebMOpus.decode(webm).count - 16_000) < 400)
    }

    @Test func rejectsTruncatedAndForeignInput() {
        #expect(throws: WebMOpus.DecodeError.self) { try WebMOpus.decode([0x1A, 0x45, 0xDF, 0xA3, 0x80]) }
        #expect(throws: WebMOpus.DecodeError.self) { try WebMOpus.decode(TestAudio.wav(seconds: 1)) }
    }
}

@Suite struct OpusPacketTests {
    @Test(arguments: [
        ([UInt8](arrayLiteral: 0b11111_0_00), 960),  // CELT 20 ms, one frame
        ([0b11110_0_00], 480),  // CELT 10 ms
        ([0b00001_0_00], 960),  // SILK 20 ms
        ([0b00011_0_00], 2_880),  // SILK 60 ms
        ([0b01101_0_00], 960),  // Hybrid 20 ms
        ([0b11111_0_01], 1_920),  // two frames
        ([0b11111_0_11, 0x03], 2_880),  // code 3 with three frames
    ])
    func readsFrameDurationFromTOC(packet: [UInt8], expected: Int) {
        #expect(WebMOpus.samplesPerPacket(packet[...]) == expected)
    }

    @Test func readsPreSkipFromOpusHead() {
        let head = Array("OpusHead".utf8) + [1, 1, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0]
        #expect(WebMOpus.preSkip(head) == 312)
        #expect(WebMOpus.preSkip([]) == 0)
    }
}
