import ARKit
import AVFoundation
import Combine
import UIKit

/// Owns UI state. CaptureEngine owns sensor and disk work on its serial queue.
@MainActor
final class Recorder: ObservableObject {
    enum Phase { case idle, starting, recording, stopping, exporting }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "Ready. Record a short test first."
    @Published private(set) var stats = CaptureStats()
    @Published private(set) var recordings: [URL] = []

    let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    var session: ARSession { engine.session }
    var busy: Bool { phase != .idle }

    private let engine = CaptureEngine()
    private let context = ContextRecorder()
    private let exportQueue = DispatchQueue(label: "raw-lidar.export", qos: .utility)
    private var captureID: UUID?
    private var engineStarted = false
    private var previewRequest: UUID?
    private var foreground = true
    private var exportedURL: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    init() {
        engine.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
        if !supported { status = "Requires an iPhone or iPad with a rear LiDAR scanner." }
        reloadRecordings()
    }

    func preparePreview() {
        foreground = true
        if supported, phase == .stopping {
            // Resume after the queued finalization/pause if foregrounding wins
            // the race with the final UI event from the preceding session.
            engine.preview()
            return
        }
        guard supported, phase == .idle else { return }
        let request = UUID()
        previewRequest = request
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.cameraAccess()
            guard self.previewRequest == request, self.foreground, self.phase == .idle else { return }
            if allowed {
                self.context.requestLocationAccess()
                self.engine.preview()
            }
            else { self.status = "Allow Camera access in Settings to record." }
        }
    }

    func start() {
        guard supported, phase == .idle, foreground else { return }
        guard !context.locationAuthorizationPending, !MotionRecorder.authorizationPending else {
            preparePreview()
            status = "Choose location and motion permissions before recording."
            return
        }
        previewRequest = nil
        let id = UUID()
        captureID = id
        phase = .starting
        status = "Starting…"
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.cameraAccess()
            guard self.captureID == id, self.phase == .starting else { return }
            guard allowed, self.foreground else {
                self.captureID = nil
                self.phase = .idle
                self.status = allowed ? "Recording cancelled." : "Allow Camera access in Settings to record."
                return
            }
            self.stats = CaptureStats()
            self.engineStarted = true
            UIApplication.shared.isIdleTimerDisabled = true
            self.engine.start(id: id, root: self.root, contextInformation: self.context.information)
        }
    }

    func stop(reason: String = "user") {
        guard let id = captureID, phase == .recording || phase == .starting else { return }
        if engineStarted {
            context.stop()
            phase = .stopping
            status = "Saving…"
            engine.stop(id: id, reason: reason)
        } else {
            // Invalidate a permission callback that may still be pending.
            captureID = nil
            phase = .idle
            status = "Recording cancelled."
        }
    }

    func suspend() {
        foreground = false
        previewRequest = nil
        if engineStarted, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish recording")
        }
        stop(reason: "app left foreground")
        engine.pause()
    }

    func export(_ directory: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard phase == .idle else { return }
        phase = .exporting
        UIApplication.shared.isIdleTimerDisabled = true
        status = "Preparing ZIP…"
        // The preceding share UI has closed before another export can start.
        if let exportedURL { ArchiveExporter.remove(exportedURL) }
        exportedURL = nil
        exportQueue.async {
            let result = Result { try ArchiveExporter.create(from: directory) }
            DispatchQueue.main.async {
                self.phase = .idle
                UIApplication.shared.isIdleTimerDisabled = false
                switch result {
                case .success(let url):
                    self.exportedURL = url
                    self.status = "Choose AirDrop or Save to Files."
                case .failure(let error):
                    self.status = "Export failed: \(error.localizedDescription). The recording is still in Files."
                }
                completion(result)
            }
        }
    }

    private func receive(_ event: CaptureEngine.Event) {
        if case .previewFailed(let message) = event {
            if phase == .idle { status = message }
            return
        }
        guard event.id == captureID else { return }
        switch event {
        case .started:
            guard phase == .starting else { return }
            if let id = captureID {
                context.start { [weak self] record in self?.engine.appendContext(id: id, record: record) }
            }
            phase = .recording
            status = "Recording · keep this app open"
        case .updated(_, let update, let tracking, let hasDepth):
            guard phase == .recording else { return }
            stats = update
            status = hasDepth ? "Recording · tracking: \(tracking)" : "Recording · waiting for depth"
        case .stopped(_, let final, let message):
            context.stop()
            stats = final
            captureID = nil
            engineStarted = false
            phase = .idle
            status = message
            UIApplication.shared.isIdleTimerDisabled = false
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            reloadRecordings()
        case .previewFailed: break // Handled above; it has no recording ID.
        }
    }

    private func cameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func reloadRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        recordings = files.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
