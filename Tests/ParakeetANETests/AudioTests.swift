import Foundation
import Testing

@testable import ParakeetANE

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
        let (samples, format) = try await AudioDecoder(ffmpegPath: nil).decode(wav)
        #expect(format == .wav)
        #expect(abs(samples.count - 24_000) < 160)
        #expect(samples.contains { abs($0) > 0.1 })
    }

    @Test(.enabled(if: AudioDecoder.locateFFmpeg() != nil))
    func decodesWebMThroughFFmpeg() async throws {
        let ffmpeg = try #require(AudioDecoder.locateFFmpeg())
        let webm = try TestAudio.webm(fromWAV: TestAudio.wav(seconds: 1), ffmpeg: ffmpeg)
        let (samples, format) = try await AudioDecoder(ffmpegPath: ffmpeg).decode(webm)
        #expect(format == .webm)
        #expect(abs(samples.count - 16_000) < 800)
        #expect(samples.contains { abs($0) > 0.1 })
    }

    @Test func webMWithoutFFmpegIsAnError() async {
        let webm: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 64)
        await #expect(throws: AudioDecodeError.self) {
            try await AudioDecoder(ffmpegPath: nil).decode(webm)
        }
    }
}
