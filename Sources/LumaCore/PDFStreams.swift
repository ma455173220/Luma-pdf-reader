import Foundation
import zlib

/// The most an index or object pack may expand to. Real ones are a few megabytes at most; a file
/// that expands further is built to exhaust memory.
let inflatedSizeLimit = 64 * 1024 * 1024

/// The most all of a file's object packs together may expand to while it is read. Each is kept
/// expanded once read; without a ceiling on the total, a small file of many packs could still
/// exhaust memory.
let inflatedTotalLimit = 128 * 1024 * 1024

/// Decompresses a zlib stream. Returns nil unless the stream decodes completely and cleanly, and
/// to no more than `limit` bytes: a half-decoded index must never be mistaken for a whole one.
func inflateCompletely(_ input: [UInt8], limit: Int = inflatedSizeLimit) -> [UInt8]? {
    guard !input.isEmpty else { return nil }
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { inflateEnd(&stream) }
    var output: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    var source = input
    let finished: Bool = source.withUnsafeMutableBufferPointer { src in
        stream.next_in = src.baseAddress
        stream.avail_in = uInt(src.count)
        while true {
            let status: Int32 = chunk.withUnsafeMutableBufferPointer { dst in
                stream.next_out = dst.baseAddress
                stream.avail_out = uInt(dst.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            let produced = chunk.count - Int(stream.avail_out)
            output.append(contentsOf: chunk[0..<produced])
            if output.count > limit { return false }
            if status == Z_STREAM_END { return true }
            if status != Z_OK || (produced == 0 && stream.avail_in == 0) { return false }
        }
    }
    return finished ? output : nil
}

/// Undoes the PNG row predictor that cross-reference and object streams are usually stored with.
/// Returns nil if the data is not a whole number of rows or uses an unknown filter.
func removePNGPredictor(_ data: [UInt8], columns: Int) -> [UInt8]? {
    // An index row is a few bytes wide. The upper bound also keeps the arithmetic below from overflowing.
    guard columns > 0, columns <= 4096 else { return nil }
    let rowLength = columns + 1
    guard data.count % rowLength == 0 else { return nil }
    var output: [UInt8] = []
    output.reserveCapacity(data.count)
    var previous = [UInt8](repeating: 0, count: columns)
    var position = 0
    while position < data.count {
        let filter = data[position]
        var row = Array(data[(position + 1)..<(position + rowLength)])
        switch filter {
        case 0:
            break
        case 1:
            for k in 1..<columns { row[k] = row[k] &+ row[k - 1] }
        case 2:
            for k in 0..<columns { row[k] = row[k] &+ previous[k] }
        case 3:
            for k in 0..<columns {
                let left = k > 0 ? Int(row[k - 1]) : 0
                row[k] = row[k] &+ UInt8((left + Int(previous[k])) / 2)
            }
        case 4:
            for k in 0..<columns {
                let a = k > 0 ? Int(row[k - 1]) : 0, b = Int(previous[k]), c = k > 0 ? Int(previous[k - 1]) : 0
                let p = a + b - c
                let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                row[k] = row[k] &+ UInt8((pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c))
            }
        default:
            return nil
        }
        output.append(contentsOf: row)
        previous = row
        position += rowLength
    }
    return output
}
