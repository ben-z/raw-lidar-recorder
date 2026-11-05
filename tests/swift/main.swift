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
print("Swift JSON serialization and real ZIP export checks passed")
