import ARKit
import Foundation

struct CaptureStats {
    var frames = 0
    var bytes: Int64 = 0
    var elapsed = 0.0
    var gaps = 0
}

/// Session controls, delegates, motion handlers and the writer share one queue.
/// Recording IDs keep late callbacks from affecting another session.
final class CaptureEngine: NSObject, ARSessionDelegate {
    enum Event {
        case started(UUID)
        case updated(UUID, CaptureStats, tracking: String, hasDepth: Bool)
        case stopped(UUID, CaptureStats, message: String)
        case previewFailed(String)

        var id: UUID? {
            switch self {
            case .started(let id), .updated(let id, _, _, _), .stopped(let id, _, _): return id
            case .previewFailed: return nil
            }
        }
    }

    let session = ARSession()
    var onEvent: ((Event) -> Void)? // Set once before capture starts.

    private let queue = DispatchQueue(label: "raw-lidar.capture", qos: .userInitiated)
    private lazy var motion = MotionRecorder(queue: queue)
    private var writer: SessionWriter?
    private var activeID: UUID?
    private var minimumTimestamp = 0.0
    private var lastUIUpdate = 0.0
    private var running = false

    override init() {
        super.init()
        session.delegateQueue = queue
        session.delegate = self
    }

    func preview() {
        queue.async {
            guard !self.running else { return }
            self.session.run(Self.configuration())
            self.running = true
        }
    }

    func pause() {
        queue.async {
            self.session.pause()
            self.running = false
        }
    }

    func start(id: UUID, root: URL) {
        queue.async {
            guard self.activeID == nil else { return }
            do {
                let config = Self.configuration()
                self.writer = try SessionWriter(root: root, videoFormat: config.videoFormat,
                                                motionAvailability: self.motion.availability)
                self.activeID = id
                self.lastUIUpdate = 0
                self.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                self.running = true
                // Reject frames queued from the preview before the tracking reset.
                self.minimumTimestamp = ProcessInfo.processInfo.systemUptime
                self.motion.start(notBefore: self.minimumTimestamp) { [weak self] record in
                    guard let self, self.activeID == id else { return }
                    do { try self.writer?.appendMotion(record) }
                    catch { self.finish(reason: "Motion write failed: \(error.localizedDescription)") }
                }
                self.onEvent?(.started(id))
            } catch {
                self.onEvent?(.stopped(id, CaptureStats(), message: "Could not start: \(error.localizedDescription)"))
            }
        }
    }

    func stop(id: UUID, reason: String) {
        queue.async {
            guard self.activeID == id else { return }
            self.finish(reason: reason)
        }
    }

    private func finish(reason: String) {
        guard let id = activeID, let writer else { return }
        // Clear ownership first, making queued sensor callbacks no-ops.
        activeID = nil
        self.writer = nil
        motion.stop()
        var message = reason == "user" ? "Saved. Ready to export." : "Stopped: \(reason)"
        do { try writer.finish(reason: reason) }
        catch { message = "Final metadata write failed: \(error.localizedDescription). Earlier frames remain available." }
        if reason == "user", writer.stats.gaps > 0 { message += " \(writer.stats.gaps) frame timing gaps; see manifest." }
        onEvent?(.stopped(id, writer.stats, message: message))
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let id = activeID, let writer, frame.timestamp >= minimumTimestamp else { return }
        autoreleasepool {
            do {
                try writer.append(frame: frame)
                if frame.timestamp - lastUIUpdate >= 0.25 {
                    lastUIUpdate = frame.timestamp
                    onEvent?(.updated(id, writer.stats, tracking: trackingDescription(frame.camera.trackingState),
                                      hasDepth: frame.sceneDepth != nil))
                }
            } catch { finish(reason: error.localizedDescription) }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        running = false
        if activeID != nil { finish(reason: error.localizedDescription) }
        else { onEvent?(.previewFailed(error.localizedDescription)) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        running = false
        finish(reason: "AR session interrupted")
    }

    private static func configuration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        if ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth]) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        config.worldAlignment = .gravity
        config.videoHDRAllowed = false
        // Favor sustainable uncompressed I/O over maximum camera resolution.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let slower = formats.filter { $0.framesPerSecond <= 30 }
        let candidates = slower.isEmpty ? formats : slower
        if let format = candidates.min(by: {
            let a = $0.imageResolution.width * $0.imageResolution.height
            let b = $1.imageResolution.width * $1.imageResolution.height
            return a == b ? $0.framesPerSecond < $1.framesPerSecond : a < b
        }) { config.videoFormat = format }
        return config
    }
}
