import ARKit
import CoreLocation
import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSessions = false
    @State private var pendingExport: URL?
    @State private var shareItem: ExportItem?
    @State private var recordingsPath: [URL] = []
    @State private var recordingAlert: RecordingAlert?
    @State private var openingRecording: URL?

    var body: some View {
        ZStack {
            CameraPreview(session: recorder.session).ignoresSafeArea()
            Color.black.opacity(0.28).ignoresSafeArea()
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            Label("Raw LiDAR", systemImage: "viewfinder")
                                .font(.headline)
                            Spacer()
                            Button { showSessions = true } label: {
                                Image(systemName: "folder").padding(12)
                            }
                            .disabled(recorder.busy)
                            .accessibilityLabel("Recordings")
                        }
                        Spacer()
                        if recorder.phase == .recording {
                            Text(recorder.stats.elapsed, format: .number.precision(.fractionLength(1)))
                                .font(.system(size: 54, weight: .light, design: .monospaced))
                            Text("\(recorder.stats.frames) frames · \(ByteCountFormatter.string(fromByteCount: recorder.stats.bytes, countStyle: .file))")
                                .font(.subheadline.monospacedDigit())
                        }
                        Text(recorder.status)
                            .font(.subheadline).multilineTextAlignment(.center)
                        if let location = recorder.location {
                            VStack(spacing: 4) {
                                Text(recorder.phase == .recording ? "GPS fix" : "Last GPS fix")
                                    .font(.caption)
                                Text(String(format: "%.6f°, %.6f°", location.coordinate.latitude, location.coordinate.longitude))
                                    .font(.subheadline.monospacedDigit()).textSelection(.enabled)
                                HStack(spacing: 8) {
                                    if location.horizontalAccuracy >= 0 {
                                        Text("±\(location.horizontalAccuracy, specifier: "%.1f") m reported")
                                    } else { Text("Accuracy unavailable") }
                                    Text(location.timestamp, style: .time)
                                }
                                .font(.caption)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Button {
                            if recorder.phase == .recording { recorder.stop() }
                            else { recorder.start() }
                        } label: {
                            Label(recorder.phase == .recording ? "Stop" : "Record",
                                  systemImage: recorder.phase == .recording ? "stop.fill" : "record.circle")
                                .font(.title3.bold()).frame(maxWidth: .infinity).padding(18)
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(!recorder.supported || (recorder.busy && recorder.phase != .recording))
                        Text("Lossless RGB · depth · confidence · pose · IMU")
                            .font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(24).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { recorder.preparePreview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recorder.preparePreview() }
            else if phase == .background || phase == .inactive { recorder.suspend() }
        }
        .sheet(isPresented: $showSessions, onDismiss: exportPendingRecording) {
            NavigationStack(path: $recordingsPath) {
                List(recorder.recordings, id: \.self) { url in
                    Button {
                        guard openingRecording == nil else { return }
                        openingRecording = url
                    } label: {
                        HStack {
                            RecordingRow(recorder: recorder, directory: url)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            guard openingRecording == nil else { return }
                            recordingAlert = .delete(url)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { selectExport(url) } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }.tint(.blue)
                    }
                    .disabled(recorder.busy)
                    .allowsHitTesting(openingRecording == nil)
                }
                .overlay {
                    if recorder.recordings.isEmpty { Text("No recordings yet.").foregroundStyle(.secondary) }
                }
                .navigationTitle("Recordings")
                .navigationDestination(for: URL.self) { url in
                    RecordingDetailsView(recorder: recorder, directory: url, result: recorder.preparedInfo(for: url),
                                         export: selectExport, delete: { recordingAlert = .delete($0) })
                }
                .toolbar {
                    if recorder.phase == .deleting {
                        ToolbarItem(placement: .status) { ProgressView("Deleting…") }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSessions = false }.disabled(recorder.busy)
                    }
                }
                .onAppear { recorder.refreshRecordings() }
                .onDisappear { openingRecording = nil }
                .task(id: openingRecording) {
                    guard let url = openingRecording else { return }
                    _ = await recorder.prepareInfo(for: url)
                    guard !Task.isCancelled, showSessions, openingRecording == url else { return }
                    recordingsPath.append(url)
                    openingRecording = nil
                }
                .interactiveDismissDisabled(recorder.busy)
                .alert(item: $recordingAlert) { alert in
                    switch alert {
                    case .delete(let url):
                        return Alert(title: Text("Delete recording?"),
                            message: Text("Permanently remove \(url.lastPathComponent) from this iPhone? Copies saved elsewhere are kept."),
                            primaryButton: .destructive(Text("Delete")) { delete(url) }, secondaryButton: .cancel())
                    case .failure(let message):
                        return Alert(title: Text("Delete failed"), message: Text(message), dismissButton: .default(Text("OK")))
                    }
                }
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
    }

    private func selectExport(_ url: URL) {
        guard openingRecording == nil else { return }
        pendingExport = url
        showSessions = false
    }

    private func delete(_ url: URL) {
        recordingAlert = nil
        recorder.delete(url) { result in
            switch result {
            case .success: recordingsPath.removeAll()
            case .failure(let error): recordingAlert = .failure(error.localizedDescription)
            }
        }
    }

    private func export(_ url: URL) {
        recorder.export(url) { result in
            if case .success(let archive) = result { shareItem = ExportItem(url: archive) }
        }
    }

    private func exportPendingRecording() {
        guard let url = pendingExport else { return }
        pendingExport = nil
        export(url)
    }
}

private enum RecordingAlert: Identifiable {
    case delete(URL)
    case failure(String)

    var id: String {
        switch self {
        case .delete(let url): return "delete:" + url.absoluteString
        case .failure(let message): return "failure:" + message
        }
    }
}

private struct RecordingRow: View {
    @ObservedObject var recorder: Recorder
    let directory: URL
    @State private var manifest: RecordingInfo.Manifest?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let manifest {
                Text(recordingDate(manifest.createdAt))
                HStack {
                    if let duration = manifest.durationSeconds { Text("\(duration, specifier: "%.1f") s") }
                    if let bytes = manifest.payloadBytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                    if let frames = manifest.frameCount { Text("\(frames) frames") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if manifest.state == "recording" {
                    Text("Unfinished recording").font(.caption).foregroundStyle(.orange)
                } else if manifest.state == "stopped" {
                    Text("Stopped").font(.caption).foregroundStyle(.secondary)
                } else if manifest.state != "complete" {
                    Text(manifest.state).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(directory.lastPathComponent).font(.subheadline.monospaced())
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task(id: directory) {
            do {
                let loaded = try await recorder.manifest(for: directory)
                guard !Task.isCancelled else { return }
                manifest = loaded
                _ = await recorder.prepareInfo(for: directory)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Details unavailable: \(error.localizedDescription)"
            }
        }
    }
}

private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct CameraPreview: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) {}
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
