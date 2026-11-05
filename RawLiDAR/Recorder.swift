import ARKit
import AVFoundation
import Combine
import CoreLocation
import UIKit

/// Owns UI state. CaptureEngine owns sensor and disk work on its serial queue.
@MainActor
final class Recorder: ObservableObject {
    enum Phase { case idle, starting, recording, stopping, exporting, deleting }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "Ready. Record a short test first."
    @Published private(set) var stats = CaptureStats()
    @Published private(set) var recordings: [URL] = []
    @Published private(set) var location: CLLocation?

    let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    var session: ARSession { engine.session }
    var busy: Bool { phase != .idle }

    private let engine = CaptureEngine()
    private let context = ContextRecorder()
    private let fileQueue = DispatchQueue(label: "raw-lidar.files", qos: .utility)
    private var captureID: UUID?
    private var engineStarted = false
    private var previewRequest: UUID?
    private var foreground = true
    private var exportedURL: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var infoResults: [URL: Result<RecordingInfo, Error>] = [:]
    private var infoTasks: [URL: Task<Result<RecordingInfo, Error>, Never>] = [:]

    private var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    init() {
        engine.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
        context.onLocation = { [weak self] location in
            guard let self else { return }
            if let current = self.location, current.timestamp >= location.timestamp { return }
            self.location = location
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
            self.location = nil
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
        fileQueue.async {
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

    func prepareInfo(for directory: URL) async -> Result<RecordingInfo, Error> {
        guard recordings.contains(directory) else {
            return .failure(CaptureError.message("Recording is no longer in the library."))
        }
        if let result = infoResults[directory] { return result }
        if let task = infoTasks[directory] { return await task.value }
        let task = Task<Result<RecordingInfo, Error>, Never> { [fileQueue] in
            let result: Result<RecordingInfo, Error> = await withCheckedContinuation { continuation in
                fileQueue.async {
                    continuation.resume(returning: Result { try RecordingInfo.load(from: directory) })
                }
            }
            guard self.recordings.contains(directory) else {
                self.infoTasks[directory] = nil
                return .failure(CaptureError.message("Recording is no longer in the library."))
            }
            self.infoResults[directory] = result
            self.infoTasks[directory] = nil
            return result
        }
        infoTasks[directory] = task
        return await task.value
    }

    func preparedInfo(for directory: URL) -> Result<RecordingInfo, Error> {
        guard recordings.contains(directory) else {
            return .failure(CaptureError.message("Recording is no longer in the library."))
        }
        guard let result = infoResults[directory] else {
            preconditionFailure("Prepare recording information before opening its detail view.")
        }
        return result
    }

    func manifest(for directory: URL) async throws -> RecordingInfo.Manifest {
        guard recordings.contains(directory) else { throw CaptureError.message("Recording is no longer in the library.") }
        return try await withCheckedThrowingContinuation { continuation in
            fileQueue.async {
                continuation.resume(with: Result { try RecordingInfo.loadManifest(from: directory) })
            }
        }
    }

    func delete(_ directory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard phase == .idle, recordings.contains(directory) else {
            completion(.failure(CaptureError.message("Finish the current operation before deleting a recording.")))
            return
        }
        let root = self.root
        let temporaryRoot = FileManager.default.temporaryDirectory
        let cachedExport = exportedURL.flatMap { $0.lastPathComponent == directory.lastPathComponent + ".zip" ? $0 : nil }
        phase = .deleting
        status = "Deleting recording…"
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Delete recording")
        fileQueue.async {
            let result = Result {
                try ArchiveExporter.removeCachedExports(for: directory, in: temporaryRoot)
                try RecordingLibrary.delete(directory, in: root)
            }
            DispatchQueue.main.async {
                self.phase = .idle
                UIApplication.shared.isIdleTimerDisabled = false
                if self.backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.backgroundTask)
                    self.backgroundTask = .invalid
                }
                switch result {
                case .success:
                    if cachedExport != nil { self.exportedURL = nil }
                    self.infoResults[directory] = nil
                    self.infoTasks[directory] = nil
                    self.reloadRecordings()
                    self.status = "Recording deleted."
                case .failure(let error):
                    self.status = "Delete failed: \(error.localizedDescription)"
                }
                completion(result)
            }
        }
    }

    func refreshRecordings() {
        guard phase == .idle else { return }
        reloadRecordings()
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
        do {
            recordings = try RecordingLibrary.recordings(in: root)
            let existing = Set(recordings)
            infoResults = infoResults.filter { existing.contains($0.key) }
            infoTasks = infoTasks.filter { existing.contains($0.key) }
        }
        catch { status = "Cannot read recordings: \(error.localizedDescription)" }
    }
}
