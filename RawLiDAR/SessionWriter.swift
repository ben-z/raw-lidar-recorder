import ARKit
import Foundation

/// Used only on CaptureEngine's queue. No ARFrame is retained after its delegate callback.
final class SessionWriter {
    let directory: URL
    private let index: FileHandle
    private let motion: FileHandle
    private let events: FileHandle
    private let context: FileHandle
    private var manifest: [String: Any]
    private(set) var frameCount = 0
    private(set) var bytes: Int64 = 0
    private(set) var firstTimestamp: Double?
    private var lastTimestamp: Double?
    private(set) var gapCount = 0
    private var maximumGap = 0.0
    private var uncompressedBufferBytes: Int64 = 0
    private var storedBufferBytes: Int64 = 0
    private var bufferCompressionSeconds = 0.0
    private let expectedInterval: Double

    init(root: URL, videoFormat: ARConfiguration.VideoFormat, motionAvailability: [String: Bool],
         contextInformation: [String: Any]) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folderURL = root.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        directory = folderURL
        try FileManager.default.createDirectory(at: folderURL.appendingPathComponent("frames"), withIntermediateDirectories: true)
        func open(_ name: String) throws -> FileHandle {
            let url = folderURL.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CaptureError.message("Cannot create \(name).")
            }
            return try FileHandle(forWritingTo: url)
        }
        index = try open("frames.jsonl")
        motion = try open("motion.jsonl")
        events = try open("events.jsonl")
        context = try open("context.jsonl")
        expectedInterval = 1.0 / Double(videoFormat.framesPerSecond)
        manifest = [
            "schema": "raw-lidar/2", "state": "recording", "createdUTC": ISO8601DateFormatter().string(from: Date()),
            "systemUptimeAtStart": ProcessInfo.processInfo.systemUptime,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "hardware": hardwareIdentifier(),
            "videoFormat": ["width": Int(videoFormat.imageResolution.width),
                            "height": Int(videoFormat.imageResolution.height), "fps": videoFormat.framesPerSecond,
                            "captureDeviceType": videoFormat.captureDeviceType.rawValue,
                            "captureDevicePosition": videoFormat.captureDevicePosition.rawValue],
            "motionAvailable": motionAvailability, "requestedMotionHz": 100,
            "context": contextInformation,
            "motionReferenceFrame": "xArbitraryZVertical",
            "worldAlignment": "gravity", "matrices": "row-major arrays",
            "binaryByteOrder": "little-endian",
            "cameraConvention": "ARKit camera: +x right, +y up, looks along -z; transform is camera-to-world",
            "pixelCoordinates": "native camera image; not rotated to screen orientation",
            "depthSemantics": "Apple processed axial depth in meters, not raw time-of-flight returns",
            "timestamps": "seconds since device boot; sceneDepth uses associated ARFrame timestamp; no separate sceneDepth hardware timestamp is exposed",
            "rgbEncoding": "original CVPixelBuffer planes, row padding removed; no JPEG/video compression",
            "frameDelivery": "every delivered ARSession callback is written; upstream drops are possible; timestamp gaps are reported",
            "imuCalibration": "Core Motion device coordinates; no assumed camera-to-IMU extrinsic calibration",
        ]
        try saveManifest()
        try Data(Self.formatNotes.utf8).write(to: directory.appendingPathComponent("FORMAT.txt"))
    }

    deinit {
        try? index.close()
        try? motion.close()
        try? events.close()
        try? context.close()
    }

    var duration: Double { (lastTimestamp ?? 0) - (firstTimestamp ?? lastTimestamp ?? 0) }

    var stats: CaptureStats { CaptureStats(frames: frameCount, bytes: bytes, elapsed: duration, gaps: gapCount) }

    func append(frame: ARFrame) throws {
        // Keep at least 1 GiB free, checking approximately once per second.
        if frameCount % 30 == 0 {
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity < 1_073_741_824 {
                throw CaptureError.message("Stopped: less than 1 GB of free storage remains.")
            }
        }
        let name = String(format: "%08d", frameCount)
        let relative = "frames/\(name)"
        let folder = directory.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var committed = false
        let previousBytes = bytes
        let previousUncompressedBufferBytes = uncompressedBufferBytes
        let previousStoredBufferBytes = storedBufferBytes
        let previousCompressionSeconds = bufferCompressionSeconds
        defer {
            if !committed {
                bytes = previousBytes
                uncompressedBufferBytes = previousUncompressedBufferBytes
                storedBufferBytes = previousStoredBufferBytes
                bufferCompressionSeconds = previousCompressionSeconds
                try? FileManager.default.removeItem(at: folder)
            }
        }
        var metadata: [String: Any] = [
            "index": frameCount, "timestamp": frame.timestamp, "path": relative,
            "cameraToWorld": rows(frame.camera.transform), "intrinsics": rows(frame.camera.intrinsics),
            "imageResolution": [Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height)],
            "eulerAngles": [frame.camera.eulerAngles.x, frame.camera.eulerAngles.y, frame.camera.eulerAngles.z],
            "tracking": trackingDescription(frame.camera.trackingState),
            "worldMappingStatus": frame.worldMappingStatus.rawValue,
            "exposureDuration": frame.camera.exposureDuration, "exposureOffset": frame.camera.exposureOffset,
            "exif": frame.exifData,
        ]
        if let estimate = frame.lightEstimate {
            metadata["lightEstimate"] = ["ambientIntensity": estimate.ambientIntensity,
                                         "ambientColorTemperature": estimate.ambientColorTemperature]
        }
        metadata["rgb"] = try write(buffer: frame.capturedImage, prefix: "rgb", folder: folder)
        if let depth = frame.sceneDepth {
            metadata["depth"] = try write(buffer: depth.depthMap, prefix: "depth", folder: folder)
            if let confidence = depth.confidenceMap {
                metadata["confidence"] = try write(buffer: confidence, prefix: "confidence", folder: folder)
            }
        }
        if let depth = frame.smoothedSceneDepth {
            metadata["smoothedDepth"] = try write(buffer: depth.depthMap, prefix: "smoothed_depth", folder: folder)
            if let confidence = depth.confidenceMap {
                metadata["smoothedConfidence"] = try write(buffer: confidence, prefix: "smoothed_confidence", folder: folder)
            }
        }
        if let points = frame.rawFeaturePoints {
            // These are visual SLAM features, NOT raw LiDAR returns.
            var xyz = Data(capacity: points.points.count * 12)
            var ids = Data(capacity: points.identifiers.count * 8)
            for p in points.points { for value in [p.x, p.y, p.z] { xyz.appendLE(value.bitPattern) } }
            for id in points.identifiers { ids.appendLE(id) }
            try write(xyz, to: folder.appendingPathComponent("features_xyz.f32"))
            try write(ids, to: folder.appendingPathComponent("features_ids.u64"))
            metadata["features"] = ["count": points.points.count, "xyz": "features_xyz.f32", "ids": "features_ids.u64"]
        }
        try write(jsonData(metadata), to: folder.appendingPathComponent("metadata.json"))
        try appendJSON(["index": frameCount, "timestamp": frame.timestamp, "path": relative], to: index)
        committed = true
        if let previous = lastTimestamp {
            let gap = frame.timestamp - previous
            maximumGap = max(maximumGap, gap)
            if gap > expectedInterval * 1.5 { gapCount += 1 }
        }
        firstTimestamp = firstTimestamp ?? frame.timestamp
        lastTimestamp = frame.timestamp
        frameCount += 1
        // Incremental index + individual frames remain usable if the app is killed.
        if frameCount % 30 == 0 {
            try index.synchronize()
            try motion.synchronize()
            try context.synchronize()
        }
    }

    func appendMotion(_ record: [String: Any]) throws {
        if record["error"] != nil {
            let event = record.merging(["event": "motionError"]) { _, new in new }
            try appendJSON(event, to: events)
        } else {
            try appendJSON(record, to: motion)
        }
    }

    func appendContext(_ record: [String: Any]) throws {
        if record["error"] != nil {
            try appendJSON(record.merging(["event": "sensorError"]) { _, new in new }, to: events)
        } else {
            try appendJSON(record, to: context)
        }
    }

    func finish(reason: String) throws {
        manifest["state"] = reason == "user" ? "complete" : "stopped"
        manifest["stopReason"] = reason
        manifest["finishedUTC"] = ISO8601DateFormatter().string(from: Date())
        manifest["frameCount"] = frameCount
        manifest["payloadBytes"] = bytes
        manifest["uncompressedBufferBytes"] = uncompressedBufferBytes
        manifest["storedBufferBytes"] = storedBufferBytes
        manifest["bufferCompressionSeconds"] = bufferCompressionSeconds
        manifest["firstFrameTimestamp"] = firstTimestamp.map { $0 as Any } ?? NSNull()
        manifest["lastFrameTimestamp"] = lastTimestamp.map { $0 as Any } ?? NSNull()
        manifest["durationSeconds"] = duration
        manifest["timestampGapsOver1_5FrameIntervals"] = gapCount
        manifest["maximumFrameIntervalSeconds"] = maximumGap
        try index.synchronize()
        try motion.synchronize()
        try events.synchronize()
        try context.synchronize()
        try saveManifest()
    }

    private func write(buffer: CVPixelBuffer, prefix: String, folder: URL) throws -> [String: Any] {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let bytesPerPixel: [OSType: Int] = [kCVPixelFormatType_DepthFloat32: 4, kCVPixelFormatType_DepthFloat16: 2,
                                           kCVPixelFormatType_OneComponent8: 1, kCVPixelFormatType_32BGRA: 4]
        let isNV12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard isNV12 || bytesPerPixel[format] != nil else {
            throw CaptureError.message("Unsupported pixel format \(format); stopped to avoid corrupt output.")
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw CaptureError.message("Could not lock pixel buffer.")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        let count = planar ? CVPixelBufferGetPlaneCount(buffer) : 1
        var planes: [[String: Any]] = []
        for plane in 0..<count {
            let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
            let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
            let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane) : CVPixelBufferGetBaseAddress(buffer)
            guard let base else { throw CaptureError.message("Missing pixel plane.") }
            let bpp = isNV12 ? (plane == 0 ? 1 : 2) : bytesPerPixel[format]!
            let packedStride = width * bpp
            guard packedStride <= stride else { throw CaptureError.message("Invalid pixel plane stride.") }
            var packed = Data(capacity: packedStride * height)
            for y in 0..<height { packed.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: packedStride) }
            let predictor: BufferCompression.Predictor =
                format == kCVPixelFormatType_DepthFloat32 || format == kCVPixelFormatType_DepthFloat16 ? .byteShuffle : .up
            let began = DispatchTime.now().uptimeNanoseconds
            let encoded = try BufferCompression.encode(packed, rowBytes: packedStride,
                                                       elementBytes: bpp, predictor: predictor)
            bufferCompressionSeconds += Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
            let file = "\(prefix)_\(plane).bin.zlib"
            try write(encoded, to: folder.appendingPathComponent(file))
            uncompressedBufferBytes += Int64(packed.count)
            storedBufferBytes += Int64(encoded.count)
            planes.append(["file": file, "width": width, "height": height, "bytesPerPixel": bpp,
                           "rowBytes": packedStride, "sourceRowBytes": stride, "byteCount": packed.count,
                           "encoding": BufferCompression.encoding, "predictor": predictor.rawValue,
                           "storedByteCount": encoded.count])
        }
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
        return ["pixelFormat": format, "pixelFormatFourCC": fourCC(format),
                "width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
                "planes": planes, "attachments": jsonSafe(attachments)]
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        bytes += Int64(data.count)
    }
    private func appendJSON(_ object: [String: Any], to file: FileHandle) throws {
        var data = try jsonData(object)
        data.append(0x0A)
        try file.write(contentsOf: data)
        bytes += Int64(data.count)
    }
    private func saveManifest() throws {
        try jsonData(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static let formatNotes = """
    raw-lidar/2. Read README.md in the source project for the full format.
    frames.jsonl is the committed frame index. Ignore frame folders absent from it.
    Every frame has metadata.json plus binary planes. All paths inside metadata
    are relative to that frame folder. Pixels retain native sensor orientation.
    Depth is Apple-processed axial z in meters. Float buffers are little-endian.
    NV12 RGB has a full-size Y plane and half-size interleaved CbCr plane.
    Each pixel plane is an independent RFC1950 zlib stream with Adler32 checksum.
    Decompress, then reverse its declared predictor. Up: first row unchanged,
    then add the decoded previous row bytewise modulo 256. Byte-shuffle: groups
    all byte-0 values, then all byte-1 values, etc. of bytesPerPixel-byte elements.
    byteCount/rowBytes describe decoded packed bytes; storedByteCount is file size.
    No floating-point conversion, temporal prediction or precision reduction occurs.
    Use pixelFormat/attachments to select color range and YCbCr matrix.
    Matrices are stored as rows. cameraToWorld uses ARKit camera axes (+x right,
    +y up, looking toward -z). Scale intrinsics from imageResolution to depth
    resolution before unprojection, then convert CV axes (+x right,+y down,+z
    forward) to ARKit camera axes with diag(1,-1,-1), then cameraToWorld.
    Confidence: 0 low, 1 medium, 2 high. No validity filtering is applied here.
    Feature points are SLAM landmarks, not original LiDAR points.
    motion.jsonl stores individually timestamped Core Motion events in device
    coordinates: acceleration in g, angular velocity in rad/s, magnetic field
    in microtesla. Attitude quaternion order is x,y,z,w; it is Core Motion's
    device attitude relative to xArbitraryZVertical, not a camera/world pose.
    Hardware time-of-flight returns and camera-to-IMU extrinsics are not exposed.
    context.jsonl stores Core Location fixes, compass headings, and device state.
    Location and heading retain original Unix timestamps and boot-time estimates
    from a fixed session clock offset; receivedTimestamp is callback arrival.
    Cached fixes and invalid accuracy/speed/course sentinel values are preserved.
    Geographic locations do not georeference the ARKit world automatically.
    Altimeter records in motion.jsonl preserve pressure in kPa and altitude in m.
    Altimeter update rates are system-controlled; use actual sample timestamps.
    Absolute-altitude timestamp is boot-relative receipt time (timestampBasis:
    receipt). sourceTimestamp retains the API value with no assumed source clock.
    Device state uses UIKit/ProcessInfo raw enum values; batteryLevel is a 0...1
    fraction, or -1 when unavailable. Heading/speed/accuracy sentinels are not zeros.
    """
}

private func rows(_ m: simd_float4x4) -> [[Float]] { (0..<4).map { r in (0..<4).map { c in m[c][r] } } }
private func rows(_ m: simd_float3x3) -> [[Float]] { (0..<3).map { r in (0..<3).map { c in m[c][r] } } }
private func fourCC(_ value: UInt32) -> String {
    String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "unknown"
}
private func hardwareIdentifier() -> String {
    var info = utsname()
    uname(&info)
    let capacity = MemoryLayout.size(ofValue: info.machine)
    return withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
    }
}
func trackingDescription(_ state: ARCamera.TrackingState) -> String {
    switch state {
    case .normal: return "normal"
    case .notAvailable: return "notAvailable"
    case .limited(let reason):
        switch reason {
        case .initializing: return "limited.initializing"
        case .excessiveMotion: return "limited.excessiveMotion"
        case .insufficientFeatures: return "limited.insufficientFeatures"
        case .relocalizing: return "limited.relocalizing"
        @unknown default: return "limited.unknown"
        }
    @unknown default: return "unknown"
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
