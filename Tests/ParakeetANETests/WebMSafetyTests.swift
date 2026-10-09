import Testing

@testable import ParakeetANE

/// These malformed uploads used to trap before ffmpeg could handle the fallback.
@Suite struct WebMSafetyTests {
    private let header: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x80]
    private var track: [UInt8] {
        [0xAE, 0xFF, 0xD7, 0x81, 1, 0x86, 0x86] + Array("A_OPUS".utf8)
    }
    private let block: [UInt8] = [0xA3, 0x86, 0x81, 0, 0, 0, 0xF8, 0]
    private var maximumPadding: [UInt8] {
        [0x75, 0xA2, 0x88, 0x7F] + [UInt8](repeating: 0xFF, count: 7)
    }

    @Test(arguments: [[UInt8](arrayLiteral: 0), [3], [1, 0, 0, 0, 0], [UInt8](repeating: 0xFF, count: 8)])
    func rejectsInvalidChannelCounts(channels: [UInt8]) {
        let bytes = header + [0xAE, 0xFF, 0x9F, 0x80 | UInt8(channels.count)] + channels
        #expect(throws: WebMOpus.DecodeError.self) { try WebMOpus.demux(bytes) }
    }

    @Test func rejectsElementLargerThanRemainingInput() {
        let bytes = header + [0xEC, 0x01] + [UInt8](repeating: 0xFE, count: 7)
        #expect(throws: WebMOpus.DecodeError.self) { try WebMOpus.demux(bytes) }
    }

    @Test(arguments: [
        [UInt8](arrayLiteral: 0xA3, 0x84, 0x81, 0, 0, 0),
        [UInt8](arrayLiteral: 0xA3, 0x85, 0x81, 0, 0, 4, 0),
    ])
    func rejectsEmptyPackets(emptyBlock: [UInt8]) {
        #expect(throws: WebMOpus.DecodeError.self) { try WebMOpus.demux(header + track + emptyBlock) }
    }

    @Test func convertsExtremePaddingWithoutOverflow() throws {
        let stream = try WebMOpus.demux(header + track + block + maximumPadding)
        #expect(stream.endPadding == 442_721_857_769_029)
    }

    @Test func rejectsPaddingSumOverflow() {
        let bytes = header + track + block + maximumPadding + block + maximumPadding
        #expect(throws: WebMOpus.DecodeError.self) { try WebMOpus.demux(bytes) }
    }

    @Test(arguments: [[UInt8](), [0xFB], [0xFB, 0], [0xFB, 7]])
    func rejectsInvalidPacketDurations(packet: [UInt8]) {
        #expect(WebMOpus.samplesPerPacket(packet[...]) == nil)
    }

    @Test func rejectsEmptyDecoderInput() {
        #expect(throws: WebMOpus.DecodeError.self) { try WebMOpus.decodeOpus(packets: [], channels: 1) }
    }
}
