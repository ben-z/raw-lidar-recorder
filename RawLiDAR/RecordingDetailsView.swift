import MapKit
import SwiftUI

struct RecordingDetailsView: View {
    @ObservedObject var recorder: Recorder
    let directory: URL
    let result: Result<RecordingInfo, Error>
    let export: (URL) -> Void
    let delete: (URL) -> Void

    private struct MapConfiguration {
        // Keep nearby streets visible even when the reported uncertainty is small.
        let minimumSpanMeters: CLLocationDistance = 300
        // Fit the uncertainty circle with space around it.
        let accuracySpanMultiplier: Double = 4
        let height: CGFloat = 220
    }

    var body: some View {
        Form {
            switch result {
            case .success(let info):
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
            case .failure(let error):
                Section {
                    Label("Couldn’t read recording", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(error.localizedDescription).textSelection(.enabled)
                }
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
                let validFix = location.horizontalAccuracyMeters >= 0
                if validFix {
                    locationMap(location)
                } else {
                    Text("The recorded GPS fix is invalid.")
                        .foregroundStyle(.secondary)
                }
                LabeledContent(validFix ? "Latitude" : "Raw latitude") {
                    Text(coordinate(location.latitudeDegrees)).monospacedDigit().textSelection(.enabled)
                }
                LabeledContent(validFix ? "Longitude" : "Raw longitude") {
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

    private func locationMap(_ location: RecordingInfo.Location) -> some View {
        let configuration = MapConfiguration()
        let coordinate = CLLocationCoordinate2D(latitude: location.latitudeDegrees,
                                              longitude: location.longitudeDegrees)
        let span = max(configuration.minimumSpanMeters,
                       location.horizontalAccuracyMeters * configuration.accuracySpanMultiplier)
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: span, longitudinalMeters: span)
        return Map(initialPosition: .region(region), interactionModes: [.pan, .zoom]) {
            if location.horizontalAccuracyMeters >= 0 {
                MapCircle(center: coordinate, radius: location.horizontalAccuracyMeters)
                    .foregroundStyle(.blue.opacity(0.15))
                    .stroke(.blue.opacity(0.7), lineWidth: 1)
            }
            Marker("Recording", coordinate: coordinate)
        }
        .mapStyle(.standard)
        .mapControls { MapScaleView(anchorEdge: .leading) }
        .frame(height: configuration.height)
        .accessibilityLabel("Saved recording location")
        .accessibilityHint("Pan or zoom to inspect the saved location.")
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
