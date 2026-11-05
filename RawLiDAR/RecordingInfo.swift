import Foundation

/// Reads only the manifest and sensor journals, never image/depth payloads.
struct RecordingInfo: Sendable {
    struct Manifest: Decodable, Sendable {
        struct VideoFormat: Decodable, Sendable {
            let width: Int
            let height: Int
            let fps: Int
        }

        fileprivate struct Context: Decodable, Sendable { let file: String }

        let schema: String
        let state: String
        let createdAt: Date
        let finishedAt: Date?
        let durationSeconds: Double?
        let frameCount: Int?
        let payloadBytes: Int64?
        let videoFormat: VideoFormat
        let firstFrameTimestamp: Double?
        let lastFrameTimestamp: Double?
        let requestedMotionHz: Double?
        fileprivate let context: Context?

        private enum CodingKeys: String, CodingKey {
            case schema, state, durationSeconds, frameCount, payloadBytes, videoFormat
            case firstFrameTimestamp, lastFrameTimestamp, requestedMotionHz, context
            case createdAt = "createdUTC", finishedAt = "finishedUTC"
        }
    }

    struct Location: Decodable, Sendable {
        let timestamp: Double
        let timestampUnix: Double
        let receivedTimestamp: Double
        let latitudeDegrees: Double
        let longitudeDegrees: Double
        let horizontalAccuracyMeters: Double
        let altitudeMeters: Double
        let verticalAccuracyMeters: Double
        let ellipsoidalAltitudeMeters: Double?
        let speedMetersPerSecond: Double?
        let speedAccuracyMetersPerSecond: Double?
        let courseDegrees: Double?
        let courseAccuracyDegrees: Double?

        var sampleDate: Date { Date(timeIntervalSince1970: timestampUnix) }
        // Context timestamps use an estimated Unix-to-boot offset; preserve its sign.
        var ageAtReceiptSeconds: Double { receivedTimestamp - timestamp }
    }

    struct Heading: Decodable, Sendable {
        let timestamp: Double
        let timestampUnix: Double
        let magneticHeadingDegrees: Double
        let trueHeadingDegrees: Double
        let headingAccuracyDegrees: Double
        var sampleDate: Date { Date(timeIntervalSince1970: timestampUnix) }
    }

    struct DeviceState: Decodable, Sendable {
        let timestamp: Double
        let batteryLevel: Double
        let batteryState: Int
        let thermalState: Int
        let lowPowerMode: Bool
        let deviceOrientation: Int
    }

    struct Barometer: Decodable, Sendable {
        let timestamp: Double
        let pressureKilopascals: Double
        let relativeAltitudeMeters: Double

        private enum CodingKeys: String, CodingKey {
            case timestamp
            case pressureKilopascals = "pressure_kPa", relativeAltitudeMeters = "relativeAltitude_m"
        }
    }

    struct AbsoluteAltitude: Decodable, Sendable {
        let timestamp: Double
        let altitudeMeters: Double
        let accuracyMeters: Double
        let precisionMeters: Double
        let timestampBasis: String?
        let sourceTimestamp: Double?
        let sourceTimestampClock: String?

        private enum CodingKeys: String, CodingKey {
            case timestamp, timestampBasis, sourceTimestamp, sourceTimestampClock
            case altitudeMeters = "altitude_m", accuracyMeters = "accuracy_m", precisionMeters = "precision_m"
        }
    }

    let manifest: Manifest
    let location: Location?
    let heading: Heading?
    let deviceState: DeviceState?
    let barometer: Barometer?
    let absoluteAltitude: AbsoluteAltitude?
    let sensorErrorCount: Int
    let lastSensorError: String?

    static func loadManifest(from directory: URL) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard ["raw-lidar/1", "raw-lidar/2"].contains(manifest.schema) else {
            throw CaptureError.message("Unsupported recording format: \(manifest.schema).")
        }
        guard manifest.videoFormat.width > 0, manifest.videoFormat.height > 0, manifest.videoFormat.fps > 0,
              manifest.durationSeconds.map({ $0 >= 0 }) != false,
              manifest.frameCount.map({ $0 >= 0 }) != false,
              manifest.payloadBytes.map({ $0 >= 0 }) != false else {
            throw CaptureError.message("Recording manifest contains invalid dimensions or totals.")
        }
        if let context = manifest.context, context.file != "context.jsonl" {
            throw CaptureError.message("Unsupported context journal path: \(context.file).")
        }
        return manifest
    }

    static func load(from directory: URL) throws -> RecordingInfo {
        let manifest = try loadManifest(from: directory)
        let decoder = JSONDecoder()
        var location: Location?
        var heading: Heading?
        var deviceState: DeviceState?
        var barometer: Barometer?
        var absoluteAltitude: AbsoluteAltitude?
        var sensorErrorCount = 0
        var lastSensorError: String?

        if manifest.context != nil {
            try readJournal(directory.appendingPathComponent("context.jsonl")) { data in
                let header = try decoder.decode(RecordHeader.self, from: data)
                switch header.sensor {
                case "location":
                    let sample = try decoder.decode(Location.self, from: data)
                    guard (-90...90).contains(sample.latitudeDegrees), (-180...180).contains(sample.longitudeDegrees) else {
                        throw CaptureError.message("Recorded GPS coordinates are out of range.")
                    }
                    if location == nil || sample.timestampUnix > location!.timestampUnix { location = sample }
                case "heading":
                    let sample = try decoder.decode(Heading.self, from: data)
                    if heading == nil || sample.timestampUnix > heading!.timestampUnix { heading = sample }
                case "deviceState":
                    let sample = try decoder.decode(DeviceState.self, from: data)
                    if deviceState == nil || sample.timestamp > deviceState!.timestamp { deviceState = sample }
                default: break
                }
            }
        }
        try readJournal(directory.appendingPathComponent("motion.jsonl")) { data in
            let header = try decoder.decode(RecordHeader.self, from: data)
            switch header.sensor {
            case "barometer":
                let sample = try decoder.decode(Barometer.self, from: data)
                if barometer == nil || sample.timestamp > barometer!.timestamp { barometer = sample }
            case "absoluteAltitude":
                let sample = try decoder.decode(AbsoluteAltitude.self, from: data)
                if absoluteAltitude == nil || sample.timestamp > absoluteAltitude!.timestamp { absoluteAltitude = sample }
            default: break
            }
        }
        try readJournal(directory.appendingPathComponent("events.jsonl")) { data in
            let header = try decoder.decode(RecordHeader.self, from: data)
            if let message = header.error {
                sensorErrorCount += 1
                lastSensorError = "\(header.sensor): \(message)"
            }
        }
        return RecordingInfo(manifest: manifest, location: location, heading: heading, deviceState: deviceState,
                             barometer: barometer, absoluteAltitude: absoluteAltitude,
                             sensorErrorCount: sensorErrorCount, lastSensorError: lastSensorError)
    }

    private struct RecordHeader: Decodable {
        let sensor: String
        let timestamp: Double
        let error: String?
    }

    private struct JournalConfiguration {
        // Sensor records are small; cap one record to bound memory on damaged files.
        let maximumRecordBytes = 65_536
    }

    private static func readJournal(_ url: URL, consume: (Data) throws -> Void) throws {
        let configuration = JournalConfiguration()
        let file = try FileHandle(forReadingFrom: url)
        let result = Result {
            var pending = Data()
            var lineNumber = 0
            while let chunk = try file.read(upToCount: configuration.maximumRecordBytes), !chunk.isEmpty {
                pending.append(chunk)
                var start = pending.startIndex
                while let end = pending[start...].firstIndex(of: 0x0a) {
                    lineNumber += 1
                    guard end - start <= configuration.maximumRecordBytes else {
                        throw CaptureError.message("\(url.lastPathComponent) record \(lineNumber) is too large.")
                    }
                    if end > start {
                        do { try consume(pending.subdata(in: start..<end)) }
                        catch { throw CaptureError.message("Cannot read \(url.lastPathComponent) record \(lineNumber): \(error.localizedDescription)") }
                    }
                    start = end + 1
                }
                pending.removeSubrange(pending.startIndex..<start)
                guard pending.count <= configuration.maximumRecordBytes else {
                    throw CaptureError.message("\(url.lastPathComponent) record \(lineNumber + 1) is too large.")
                }
            }
            guard pending.isEmpty else {
                throw CaptureError.message("\(url.lastPathComponent) has an incomplete final record.")
            }
        }
        try file.close()
        try result.get()
    }
}
