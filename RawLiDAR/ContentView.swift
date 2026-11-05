import ARKit
import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSessions = false
    @State private var pendingExport: URL?
    @State private var shareItem: ExportItem?

    var body: some View {
        ZStack {
            CameraPreview(session: recorder.session).ignoresSafeArea()
            Color.black.opacity(0.28).ignoresSafeArea()
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
                Button {
                    if let url = recorder.recordings.first { export(url) }
                } label: {
                    Label("Export latest", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(12)
                }
                .buttonStyle(.bordered).disabled(recorder.busy || recorder.recordings.isEmpty)
                Text("Lossless RGB · depth · confidence · pose · IMU")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            .padding(24).foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .onAppear { recorder.preparePreview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recorder.preparePreview() }
            else if phase == .background || phase == .inactive { recorder.suspend() }
        }
        .sheet(isPresented: $showSessions, onDismiss: exportPendingRecording) {
            NavigationStack {
                List(recorder.recordings, id: \.self) { url in
                    Button {
                        pendingExport = url
                        showSessions = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(url.lastPathComponent).font(.subheadline.monospaced())
                                Text("Tap to export ZIP").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .overlay {
                    if recorder.recordings.isEmpty { Text("No recordings yet.").foregroundStyle(.secondary) }
                }
                .navigationTitle("Recordings")
                .toolbar { Button("Done") { showSessions = false } }
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
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
