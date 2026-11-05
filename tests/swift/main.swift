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

func writeFixture(_ object: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
}

func rejects(_ message: String, _ operation: () throws -> Void) throws {
    var failed = false
    do { try operation() } catch { failed = true }
    try require(failed, message)
}

let infoRoot = root.appendingPathComponent("recording-info", isDirectory: true)
try manager.createDirectory(at: infoRoot, withIntermediateDirectories: true)
var infoManifest: [String: Any] = [
    "schema": "raw-lidar/2", "state": "complete", "createdUTC": "2026-01-02T03:04:05Z",
    "finishedUTC": "2026-01-02T03:04:15Z", "frameCount": 300, "durationSeconds": 10.0,
    "payloadBytes": Int64(5_000_000_000), "videoFormat": ["width": 1280, "height": 720, "fps": 30],
    "firstFrameTimestamp": 100.0, "lastFrameTimestamp": 110.0, "requestedMotionHz": 100.0,
    "context": ["file": "context.jsonl"],
]
let infoManifestURL = infoRoot.appendingPathComponent("manifest.json")
try writeFixture(infoManifest, to: infoManifestURL)
func locationFixture(timestamp: Double, latitude: Double) -> [String: Any] {
    ["sensor": "location", "timestamp": timestamp, "timestampUnix": 1_000_000 + timestamp,
     "receivedTimestamp": 130.0, "latitudeDegrees": latitude, "longitudeDegrees": -122.0,
     "horizontalAccuracyMeters": 4.5, "altitudeMeters": 20.0, "verticalAccuracyMeters": 6.0,
     "ellipsoidalAltitudeMeters": -10.0, "speedMetersPerSecond": -1.0, "courseDegrees": -1.0]
}
func journal(_ records: [[String: Any]]) throws -> Data {
    var data = Data()
    for record in records { data.append(try jsonData(record)); data.append(0x0a) }
    return data
}
let deviceRecord: [String: Any] = [
    "sensor": "deviceState", "timestamp": 125.0, "batteryLevel": 0.75, "batteryState": 1,
    "thermalState": 1, "lowPowerMode": false, "deviceOrientation": 1,
]
var contextRecords: [[String: Any]] = [
    locationFixture(timestamp: 101, latitude: 37.1),
    locationFixture(timestamp: 120, latitude: 37.2),
    locationFixture(timestamp: 90, latitude: 37.3), // An older cached fix delivered last.
    deviceRecord,
]
for i in 0..<2000 {
    contextRecords.append(["sensor": "heading", "timestamp": 100.0 + Double(i),
                           "timestampUnix": 1_000_100.0 + Double(i), "magneticHeadingDegrees": 123.0,
                           "trueHeadingDegrees": -1.0, "headingAccuracyDegrees": 12.0])
}
try journal(contextRecords).write(to: infoRoot.appendingPathComponent("context.jsonl"))
try journal([
    ["sensor": "accelerometer", "timestamp": 100.0, "g": [0.0, 0.0, -1.0]],
    ["sensor": "barometer", "timestamp": 122.0, "pressure_kPa": 101.3, "relativeAltitude_m": 0.4],
    ["sensor": "absoluteAltitude", "timestamp": 123.0, "altitude_m": 25.0, "accuracy_m": 8.0,
     "precision_m": 0.5, "timestampBasis": "receipt", "sourceTimestamp": 815_000_000.0,
     "sourceTimestampClock": "API source clock"],
]).write(to: infoRoot.appendingPathComponent("motion.jsonl"))
try journal([
    ["event": "sensorError", "sensor": "location", "timestamp": 126.0, "error": "Location access denied"],
]).write(to: infoRoot.appendingPathComponent("events.jsonl"))
let info = try RecordingInfo.load(from: infoRoot)
try require(info.manifest.payloadBytes == 5_000_000_000, "Manifest payload bytes lost Int64 precision")
try require(info.manifest.createdAt == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"), "Recording date is incorrect")
try require(info.manifest.videoFormat.width == 1280 && info.manifest.videoFormat.fps == 30, "Camera format was lost")
try require(info.location?.latitudeDegrees == 37.2, "Cached older GPS replaced the newest acquisition")
try require(info.location?.ageAtReceiptSeconds == 10.0, "GPS acquisition-to-receipt age was lost")
try require(info.location?.speedMetersPerSecond == -1 && info.location?.courseDegrees == -1, "Invalid GPS sentinels were silently changed")
try require(info.heading?.timestamp == 2099.0 && info.heading?.trueHeadingDegrees == -1, "Streamed latest heading is incorrect")
try require(info.deviceState?.batteryLevel == 0.75 && info.deviceState?.thermalState == 1, "Device state was lost")
try require(info.barometer?.relativeAltitudeMeters == 0.4, "Barometer was lost")
try require(info.absoluteAltitude?.timestampBasis == "receipt" && info.absoluteAltitude?.sourceTimestamp == 815_000_000.0, "Absolute-altimeter clock provenance was lost")
try require(info.sensorErrorCount == 1 && info.lastSensorError == "location: Location access denied", "Acquisition error was hidden")

// The manifest remains readable without opening any binary or journal payload.
try manager.removeItem(at: infoRoot.appendingPathComponent("motion.jsonl"))
let manifestOnly = try RecordingInfo.loadManifest(from: infoRoot)
try require(manifestOnly.frameCount == 300, "Lightweight manifest read required payloads")
try rejects("Missing motion journal was accepted") { _ = try RecordingInfo.load(from: infoRoot) }
try Data().write(to: infoRoot.appendingPathComponent("motion.jsonl"))
try manager.removeItem(at: infoRoot.appendingPathComponent("context.jsonl"))
try rejects("Declared but missing context journal was accepted") { _ = try RecordingInfo.load(from: infoRoot) }
try Data("{\"sensor\":\"location\",\"timestamp\":123}\n".utf8).write(to: infoRoot.appendingPathComponent("context.jsonl"))
try rejects("Malformed location record was accepted") { _ = try RecordingInfo.load(from: infoRoot) }
try Data("{\"sensor\":\"location\",\"timestamp\":123}".utf8).write(to: infoRoot.appendingPathComponent("context.jsonl"))
try rejects("Incomplete final journal record was accepted") { _ = try RecordingInfo.load(from: infoRoot) }
try Data(repeating: 0x20, count: 1_000_000).write(to: infoRoot.appendingPathComponent("context.jsonl"))
var oversizedRecordError: String?
do { _ = try RecordingInfo.load(from: infoRoot) }
catch { oversizedRecordError = error.localizedDescription }
try require(oversizedRecordError?.contains("too large") == true, "Oversized sensor record did not fail at the memory bound")
infoManifest["context"] = ["file": "../outside.jsonl"]
try writeFixture(infoManifest, to: infoManifestURL)
try rejects("Context journal escaped the recording directory") { _ = try RecordingInfo.loadManifest(from: infoRoot) }

infoManifest.removeValue(forKey: "context")
infoManifest["schema"] = "raw-lidar/1"
try writeFixture(infoManifest, to: infoManifestURL)
let legacyInfo = try RecordingInfo.load(from: infoRoot)
try require(legacyInfo.location == nil && legacyInfo.heading == nil && legacyInfo.absoluteAltitude == nil, "Legacy recording invented absent sensor values")
infoManifest["state"] = "recording"
for key in ["finishedUTC", "frameCount", "durationSeconds", "payloadBytes"] { infoManifest.removeValue(forKey: key) }
try writeFixture(infoManifest, to: infoManifestURL)
let unfinished = try RecordingInfo.loadManifest(from: infoRoot)
try require(unfinished.frameCount == nil && unfinished.payloadBytes == nil && unfinished.finishedAt == nil, "Unfinished recording invented final totals")
infoManifest["payloadBytes"] = -1
try writeFixture(infoManifest, to: infoManifestURL)
try rejects("Invalid manifest totals were accepted") { _ = try RecordingInfo.loadManifest(from: infoRoot) }

let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
try manager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
func libraryRecording(_ name: String, under parent: URL) throws -> URL {
    let directory = parent.appendingPathComponent(name, isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
    return directory
}
let alpha = try libraryRecording("alpha", under: libraryRoot)
let zeta = try libraryRecording("zeta", under: libraryRoot)
let outside = try libraryRecording("outside", under: root)
let nested = try libraryRecording("nested", under: zeta)
let partial = libraryRoot.appendingPathComponent("partial", isDirectory: true)
try manager.createDirectory(at: partial, withIntermediateDirectories: true)
try Data("Keep other scans".utf8).write(to: zeta.appendingPathComponent("payload.bin"))
let directoryLink = libraryRoot.appendingPathComponent("linked", isDirectory: true)
try manager.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
let badManifest = libraryRoot.appendingPathComponent("symlink-manifest", isDirectory: true)
try manager.createDirectory(at: badManifest, withIntermediateDirectories: true)
try manager.createSymbolicLink(at: badManifest.appendingPathComponent("manifest.json"), withDestinationURL: outside.appendingPathComponent("manifest.json"))
let manifestDirectory = libraryRoot.appendingPathComponent("manifest-directory", isDirectory: true)
try manager.createDirectory(at: manifestDirectory.appendingPathComponent("manifest.json", isDirectory: true), withIntermediateDirectories: true)
try Data("Not a recording".utf8).write(to: libraryRoot.appendingPathComponent("notes.txt"))
try manager.createDirectory(at: libraryRoot.appendingPathComponent(".hidden", isDirectory: true), withIntermediateDirectories: true)
let listed = try RecordingLibrary.recordings(in: libraryRoot)
try require(listed.map(\.lastPathComponent) == ["zeta", "symlink-manifest", "partial", "manifest-directory", "alpha"], "Library hid an interrupted recording, included files/symlink directories, or sorted incorrectly")
for target in [libraryRoot, outside, nested, directoryLink] {
    try rejects("Delete accepted a root, external, nested or symlink target") { try RecordingLibrary.delete(target, in: libraryRoot) }
}
let dotPath = URL(string: libraryRoot.absoluteString + "zeta/../zeta/")!
try rejects("Delete accepted a dot-segment path") { try RecordingLibrary.delete(dotPath, in: libraryRoot) }
try require(manager.fileExists(atPath: outside.appendingPathComponent("manifest.json").path), "Rejected delete modified an external recording")
try RecordingLibrary.delete(alpha, in: libraryRoot)
try require(!manager.fileExists(atPath: alpha.path), "Selected recording was not deleted")
let otherPayload = try Data(contentsOf: zeta.appendingPathComponent("payload.bin"))
try require(otherPayload == Data("Keep other scans".utf8), "Deleting one recording modified another")
try RecordingLibrary.delete(partial, in: libraryRoot)
try require(!manager.fileExists(atPath: partial.path), "Partially removed recording could not be cleaned up")
try RecordingLibrary.delete(badManifest, in: libraryRoot)
try require(manager.fileExists(atPath: outside.appendingPathComponent("manifest.json").path), "Deleting a recording followed a contained symbolic link")
try rejects("Missing recording deletion silently succeeded") { try RecordingLibrary.delete(alpha, in: libraryRoot) }
print("Recording metadata streaming and recording-library deletion checks passed")

// Cached exports from earlier app processes must not outlive source deletion.
let cacheRoot = root.appendingPathComponent("export-cache", isDirectory: true)
try manager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
let matchingCache = cacheRoot.appendingPathComponent("RawLiDAR-Export-old-process", isDirectory: true)
let unrelatedCache = cacheRoot.appendingPathComponent("RawLiDAR-Export-other-scan", isDirectory: true)
let ordinaryCache = cacheRoot.appendingPathComponent("another-cache", isDirectory: true)
for folder in [matchingCache, unrelatedCache, ordinaryCache] {
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
}
try Data([1]).write(to: matchingCache.appendingPathComponent("selected.zip"))
try Data([2]).write(to: unrelatedCache.appendingPathComponent("other.zip"))
try Data([3]).write(to: ordinaryCache.appendingPathComponent("selected.zip"))
let linkedCache = cacheRoot.appendingPathComponent("RawLiDAR-Export-symlink")
try manager.createSymbolicLink(at: linkedCache, withDestinationURL: ordinaryCache)
try ArchiveExporter.removeCachedExports(for: URL(fileURLWithPath: "/Recordings/selected"), in: cacheRoot)
try require(!manager.fileExists(atPath: matchingCache.path), "Selected scan's old cached export was retained")
try require(manager.fileExists(atPath: unrelatedCache.path), "Another scan's export was deleted")
try require(manager.fileExists(atPath: ordinaryCache.path), "An unrelated cache was deleted")
try require(manager.fileExists(atPath: linkedCache.path), "Cached-export cleanup followed a symbolic link")
print("Cached export cleanup checks passed")
