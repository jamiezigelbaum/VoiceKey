@testable import VoiceKey
import XCTest

final class RealtimePCM16CodecTests: XCTestCase {
    func testEncodeClampsAndWritesLittleEndianPCM16() {
        let encoded = RealtimePCM16Codec.encode(samples: [-1.5, -1.0, -0.5, 0, 0.5, 1.0, 1.5])

        XCTAssertEqual(
            Array(encoded),
            [
                0x00, 0x80, // -32768
                0x00, 0x80, // -32768
                0x00, 0xC0, // -16384
                0x00, 0x00, // 0
                0xFF, 0x3F, // 16383
                0xFF, 0x7F, // 32767
                0xFF, 0x7F  // 32767
            ]
        )
    }

    func testDecodeReadsLittleEndianPCM16() {
        let decoded = RealtimePCM16Codec.decode(Data([
            0x00, 0x80, // -32768
            0x00, 0xC0, // -16384
            0x00, 0x00, // 0
            0x00, 0x40, // 16384
            0xFF, 0x7F  // 32767
        ]))

        XCTAssertEqual(decoded.count, 5)
        XCTAssertEqual(decoded[0], -1.0, accuracy: 0.0001)
        XCTAssertEqual(decoded[1], -0.5, accuracy: 0.0001)
        XCTAssertEqual(decoded[2], 0.0, accuracy: 0.0001)
        XCTAssertEqual(decoded[3], 0.5, accuracy: 0.0001)
        XCTAssertEqual(decoded[4], 0.9999, accuracy: 0.0001)
    }

    func testDecodeIgnoresTrailingOddByte() {
        let decoded = RealtimePCM16Codec.decode(Data([0x00, 0x40, 0xFF]))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0], 0.5, accuracy: 0.0001)
    }

    func testEncodeDecodeRoundTripsRepresentativeSamples() {
        let samples: [Float] = [-1, -0.25, 0, 0.25, 0.75, 1]

        let decoded = RealtimePCM16Codec.decode(RealtimePCM16Codec.encode(samples: samples))

        XCTAssertEqual(decoded.count, samples.count)
        for (actual, expected) in zip(decoded, samples) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
    }
}
