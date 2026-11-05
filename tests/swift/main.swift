import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CaptureError.message(message) }
}

// Foundation-only integration checks. Compile these with the production exporter
// and JSON helpers; no iOS SDK, XCTest target, or duplicated implementation.
let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try manager.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: root) }

let serialized = try jsonData([
    "finite": 1.25, "nan": Double.nan, "infinity": Double.infinity,
    "nested": ["flag": true], "binary": Data([0, 1, 255]), "id": UInt64.max,
])
let object = try JSONSerialization.jsonObject(with: serialized) as! [String: Any]
try require(object["nan"] is NSNull, "NaN must become null")
try require(object["infinity"] is NSNull, "Infinity must become null")
try require((object["nested"] as? [String: Bool])?["flag"] == true, "Boolean was lost")
try require((object["id"] as? NSNumber)?.uint64Value == UInt64.max, "UInt64 lost precision")
try require((object["binary"] as? [String: String])?["data"] == "AAH/", "Binary attachment was lost")

let planeRoot = root.appendingPathComponent("planes", isDirectory: true)
try manager.createDirectory(at: planeRoot, withIntermediateDirectories: true)
func littleEndianBytes<T: FixedWidthInteger>(_ values: [T]) -> Data {
    var result = Data()
    for value in values {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
    }
    return result
}
let bytePlane = Data((0..<48).map { UInt8(truncatingIfNeeded: $0 * 83) })
let float32 = littleEndianBytes([UInt32(0), 0x80000000, 0x7f800000, 0xff800000,
                              0x7fc00001, 0x7fa12345, 0xffc00001, 1,
                              0x7f7fffff, 0x00800000, 0x3f800000, 0xbf800000])
let float16 = littleEndianBytes([UInt16(0), 0x8000, 0x7c00, 0xfc00, 0x7e01, 0x7d55, 1, 0x7bff])
let cases: [(String, Data, Int, Int, BufferCompression.Predictor)] = [
    ("nv12-y", bytePlane, 8, 1, .up), ("nv12-cbcr", bytePlane, 8, 2, .up),
    ("bgra", bytePlane, 16, 4, .up), ("confidence", bytePlane, 8, 1, .up),
    ("float32", float32, 16, 4, .byteShuffle), ("float16", float16, 8, 2, .byteShuffle),
    ("one-row", bytePlane, 48, 1, .up),
]
var fixtures: [[String: Any]] = []
for (name, raw, rowBytes, elementBytes, predictor) in cases {
    let encoded = try BufferCompression.encode(raw, rowBytes: rowBytes, elementBytes: elementBytes, predictor: predictor)
    try raw.write(to: planeRoot.appendingPathComponent(name + ".raw"))
    try encoded.write(to: planeRoot.appendingPathComponent(name + ".zlib"))
    fixtures.append(["name": name, "rowBytes": rowBytes, "elementBytes": elementBytes, "predictor": predictor.rawValue])
}
try JSONSerialization.data(withJSONObject: fixtures, options: [.sortedKeys])
    .write(to: planeRoot.appendingPathComponent("fixtures.json"))
let decode = Process()
decode.executableURL = URL(fileURLWithPath: "/usr/bin/env")
decode.arguments = ["python3", "-c", """
import json, pathlib, sys, zlib
root = pathlib.Path(sys.argv[1])
for case in json.loads((root / 'fixtures.json').read_text()):
    raw = (root / (case['name'] + '.raw')).read_bytes()
    encoded = (root / (case['name'] + '.zlib')).read_bytes()
    decoder = zlib.decompressobj()
    decoded = bytearray(decoder.decompress(encoded, len(raw) + 1))
    assert decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
    assert len(decoded) == len(raw)
    if case['predictor'] == 'up':
        stride = case['rowBytes']
        for i in range(stride, len(decoded)):
            decoded[i] = (decoded[i] + decoded[i - stride]) & 255
    else:
        width = case['elementBytes']
        elements = len(decoded) // width
        decoded = bytes(decoded[b * elements + i] for i in range(elements) for b in range(width))
    assert bytes(decoded) == raw, case['name']
""", planeRoot.path]
try decode.run()
decode.waitUntilExit()
try require(decode.terminationStatus == 0, "Python could not recover exact production-compressed plane bytes")
for (raw, rowBytes, elementBytes) in [(Data(), 8, 1), (bytePlane, 7, 1), (bytePlane, 8, 3)] {
    var failed = false
    do { _ = try BufferCompression.encode(raw, rowBytes: rowBytes, elementBytes: elementBytes, predictor: .up) }
    catch { failed = true }
    try require(failed, "Invalid compression layout was accepted")
}

let session = root.appendingPathComponent("session", isDirectory: true)
try manager.createDirectory(at: session, withIntermediateDirectories: true)
try Data("first".utf8).write(to: session.appendingPathComponent("payload.bin"))
let first = try ArchiveExporter.create(from: session)
defer { ArchiveExporter.remove(first) }
try require(manager.fileExists(atPath: first.path), "Export does not exist")
try Data("second".utf8).write(to: session.appendingPathComponent("payload.bin"))
let second = try ArchiveExporter.create(from: session)
defer { ArchiveExporter.remove(second) }
try require(first != second, "Export unexpectedly reused an old ZIP")

// Python's standard library independently checks ZIP checksums and payload bytes.
let check = Process()
check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
check.arguments = ["python3", "-c", """
import sys, zipfile
for path, expected in zip(sys.argv[1:], [b'first', b'second']):
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None
        name = next(n for n in z.namelist() if n.endswith('payload.bin'))
        assert z.read(name) == expected
""", first.path, second.path]
try check.run()
check.waitUntilExit()
try require(check.terminationStatus == 0, "ZIP payload validation failed")

var rejected = false
do { _ = try ArchiveExporter.create(from: root.appendingPathComponent("missing")) }
catch { rejected = true }
try require(rejected, "Missing source unexpectedly exported")
print("Swift JSON, byte-exact compression, and real ZIP export checks passed")
