import Foundation

enum RealtimePCM16Codec {
    static func encode(samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { buffer in
            encode(samples: buffer)
        }
    }

    static func encode(samples: UnsafeBufferPointer<Float>) -> Data {
        var output = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let intSample = Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
            var littleEndian = intSample.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                output.append(contentsOf: bytes)
            }
        }
        return output
    }

    static func decode(_ data: Data) -> [Float] {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return [] }

        var samples: [Float] = []
        samples.reserveCapacity(frameCount)
        for frameIndex in 0..<frameCount {
            let byteIndex = frameIndex * MemoryLayout<Int16>.size
            let low = UInt16(data[byteIndex])
            let high = UInt16(data[byteIndex + 1]) << 8
            let value = Int16(bitPattern: low | high)
            samples.append(Float(value) / 32768.0)
        }
        return samples
    }
}
