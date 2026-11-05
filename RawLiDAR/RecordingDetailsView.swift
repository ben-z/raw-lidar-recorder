import SwiftUI

struct RecordingDetailsView: View {
    @ObservedObject var recorder: Recorder
    let directory: URL
    let export: (URL) -> Void
    let delete: (URL) -> Void

    @State private var info: RecordingInfo?
    @State private var loadError: String?

    var body: some View {
        Form {
            if let info {
                recordingSection(info.manifest)
                locationSection(info)
                headingSection(info)
                altitudeSection(info)
                deviceSection(info)
                if info.sensorErrorCount > 0 {
                    Section("Sensor errors") {
                        LabeledContent("Recorded errors", value: info.sensorErrorCount.formatted())
                        if let message = info.lastSensorError {
                            Text(message).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
            } else if let loadError {
                Section {
                    Label("Couldn’t read recording", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(loadError).textSelection(.enabled)
                }
            } else {
                Section { ProgressView("Loading recording…") }
            }

            Section {
                Button { export(directory) } label: {
                    Label("Export ZIP", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) { delete(directory) } label: {
                    Label("Delete recording", systemImage: "trash")
                }
            }
            .disabled(recorder.busy)

            Section("Recording ID") {
                Text(directory.lastPathComponent)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: directory) {
            info = nil
            loadError = nil
            do {
                let loaded = try await recorder.info(for: directory)
                guard !Task.isCancelled else { return }
                info = loaded
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }

    private func recordingSection(_ manifest: RecordingInfo.Manifest) -> some View {
        Section("Recording") {
            LabeledContent("Recorded") {
                Text(recordingDate(manifest.createdAt))
            }
            LabeledContent("Status", value: recordingState(manifest.state))
            LabeledContent("Duration") {
                if let duration = manifest.durationSeconds {
                    Text("\(duration.formatted(.number.precision(.fractionLength(1)))) s")
                } else { Text("Unavailable") }
            }
            LabeledContent("Frames") {
                if let count = manifest.frameCount { Text(count.formatted()) }
                else { Text("Unavailable") }
            }
            LabeledContent("Size") {
                if let bytes = manifest.payloadBytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                } else { Text("Unavailable") }
            }
            LabeledContent("Camera format") {
                Text("\(manifest.videoFormat.width) × \(manifest.videoFormat.height) · \(manifest.videoFormat.fps) fps")
            }
        }
    }

    private func locationSection(_ info: RecordingInfo) -> some View {
        Section {
            if let location = info.location {
                LabeledContent("Latitude") {
                    Text(coordinate(location.latitudeDegrees)).monospacedDigit().textSelection(.enabled)
                }
                LabeledContent("Longitude") {
                    Text(coordinate(location.longitudeDegrees)).monospacedDigit().textSelection(.enabled)
                }
                LabeledContent("Reported accuracy", value: accuracy(location.horizontalAccuracyMeters, unit: "m"))
                LabeledContent("Fix recorded") {
                    Text(recordingDate(location.sampleDate))
                }
                if location.sampleDate < info.manifest.createdAt {
                    Text("This fix was taken before the recording started.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Altitude") {
                    if location.verticalAccuracyMeters >= 0 {
                        Text(measurement(location.altitudeMeters, unit: "m", decimals: 1))
                    } else { Text("Unavailable") }
                }
                LabeledContent("Vertical accuracy", value: accuracy(location.verticalAccuracyMeters, unit: "m"))
                if let speed = location.speedMetersPerSecond, speed >= 0 {
                    LabeledContent("Speed", value: measurement(speed, unit: "m/s", decimals: 1))
                }
                if let course = location.courseDegrees, course >= 0 {
                    LabeledContent("Course", value: measurement(course, unit: "°", decimals: 1))
                }
            } else {
                Text("No location was recorded.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Last recorded location")
        } footer: {
            Text("Coordinates are the phone’s location estimate. Reported accuracy describes its uncertainty.")
        }
    }

    private func headingSection(_ info: RecordingInfo) -> some View {
        Section("Last recorded heading") {
            if let heading = info.heading {
                LabeledContent("True heading") {
                    if heading.trueHeadingDegrees >= 0 {
                        Text(measurement(heading.trueHeadingDegrees, unit: "°", decimals: 1))
                    } else { Text("Unavailable") }
                }
                LabeledContent("Magnetic heading", value: measurement(heading.magneticHeadingDegrees, unit: "°", decimals: 1))
                LabeledContent("Reported accuracy", value: accuracy(heading.headingAccuracyDegrees, unit: "°"))
                LabeledContent("Recorded") {
                    Text(recordingDate(heading.sampleDate))
                }
            } else {
                Text("No heading was recorded.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func altitudeSection(_ info: RecordingInfo) -> some View {
        if info.barometer != nil || info.absoluteAltitude != nil {
            Section("Last recorded altimeter values") {
                if let barometer = info.barometer {
                    LabeledContent("Pressure", value: measurement(barometer.pressureKilopascals, unit: "kPa", decimals: 2))
                    LabeledContent("Relative altitude", value: measurement(barometer.relativeAltitudeMeters, unit: "m", decimals: 2))
                }
                if let altitude = info.absoluteAltitude {
                    LabeledContent("Absolute altitude", value: measurement(altitude.altitudeMeters, unit: "m", decimals: 1))
                    LabeledContent("Reported accuracy", value: accuracy(altitude.accuracyMeters, unit: "m"))
                }
            }
        }
    }

    @ViewBuilder
    private func deviceSection(_ info: RecordingInfo) -> some View {
        if let device = info.deviceState {
            Section("Last recorded device state") {
                LabeledContent("Battery") {
                    if (0...1).contains(device.batteryLevel) {
                        Text(device.batteryLevel, format: .percent.precision(.fractionLength(0)))
                    } else { Text("Unavailable") }
                }
                LabeledContent("Thermal state", value: thermalState(device.thermalState))
                LabeledContent("Low Power Mode", value: device.lowPowerMode ? "On" : "Off")
            }
        }
    }

    private func coordinate(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(6))) + "°"
    }

    private func measurement(_ value: Double, unit: String, decimals: Int) -> String {
        value.formatted(.number.precision(.fractionLength(decimals))) + " " + unit
    }

    private func accuracy(_ value: Double, unit: String) -> String {
        value >= 0 ? "±" + measurement(value, unit: unit, decimals: 1) : "Unavailable"
    }

    private func recordingState(_ value: String) -> String {
        switch value {
        case "complete": return "Saved"
        case "stopped": return "Stopped"
        case "recording": return "Unfinished"
        default: return value
        }
    }

    private func thermalState(_ value: Int) -> String {
        switch value {
        case 0: return "Normal"
        case 1: return "Fair"
        case 2: return "Serious"
        case 3: return "Critical"
        default: return "Unknown (\(value))"
        }
    }
}

func recordingDate(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: value)
}
