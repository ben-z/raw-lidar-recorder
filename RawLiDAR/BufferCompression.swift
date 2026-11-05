import Foundation
import zlib

/// Independent, checksummed zlib streams preserve the packed sensor bytes.
enum BufferCompression {
    enum Predictor: String { case up; case byteShuffle = "byte-shuffle" }
    static let encoding = "zlib"

    static func encode(_ input: Data, rowBytes: Int, elementBytes: Int, predictor: Predictor) throws -> Data {
        guard rowBytes > 0, elementBytes > 0, rowBytes % elementBytes == 0,
              !input.isEmpty, input.count % rowBytes == 0, input.count <= Int(uInt.max) else {
            throw CaptureError.message("Invalid packed plane layout for compression.")
        }
        let count = input.count
        var filtered = Data(count: count)
        filtered.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                let src = source.bindMemory(to: UInt8.self).baseAddress!
                let dst = destination.bindMemory(to: UInt8.self).baseAddress!
                switch predictor {
                case .up:
                    dst.update(from: src, count: rowBytes)
                    for i in rowBytes..<count { dst[i] = src[i] &- src[i - rowBytes] }
                case .byteShuffle:
                    let elements = count / elementBytes
                    for byte in 0..<elementBytes {
                        for element in 0..<elements {
                            dst[byte * elements + element] = src[element * elementBytes + byte]
                        }
                    }
                }
            }
        }
        // RLE avoids general match searching on already predicted sensor bytes.
        var stream = z_stream()
        let initialized = deflateInit2_(&stream, Z_BEST_SPEED, Z_DEFLATED, MAX_WBITS, 8,
                                       Z_RLE, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw CaptureError.message("Could not initialize pixel compression: zlib status \(initialized).") }
        let bound = deflateBound(&stream, uLong(count))
        guard bound <= uLong(uInt.max) else {
            let ended = deflateEnd(&stream)
            throw CaptureError.message("Pixel plane exceeds zlib's single-buffer size; cleanup status \(ended).")
        }
        var encoded = Data(count: Int(bound))
        let status = encoded.withUnsafeMutableBytes { destination in
            filtered.withUnsafeBytes { source in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = uInt(count)
                stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(bound)
                return deflate(&stream, Z_FINISH)
            }
        }
        let remaining = stream.avail_in
        let size = stream.total_out
        let ended = deflateEnd(&stream)
        guard status == Z_STREAM_END, remaining == 0 else {
            throw CaptureError.message("Pixel-plane compression failed: zlib status \(status), \(remaining) input bytes remain.")
        }
        guard ended == Z_OK else { throw CaptureError.message("Could not finish pixel compression: zlib status \(ended).") }
        encoded.count = Int(size)
        return encoded
    }
}
