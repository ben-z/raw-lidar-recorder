import CoreLocation
import Foundation
import UIKit

/// Main-run-loop location callbacks and device notifications feed the capture queue.
@MainActor
final class ContextRecorder: NSObject, @preconcurrency CLLocationManagerDelegate {
    var onLocation: ((CLLocation) -> Void)?
    private var manager = CLLocationManager()
    private var emit: (([String: Any]) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var generation: UUID?
    private var unixTimeAtBoot = 0.0

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestLocationAccess() {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    var locationAuthorizationPending: Bool { manager.authorizationStatus == .notDetermined }

    var information: [String: Any] {
        ["file": "context.jsonl", "headingAvailable": CLLocationManager.headingAvailable(),
         "locationAuthorization": manager.authorizationStatus.rawValue,
         "locationAccuracyAuthorization": manager.accuracyAuthorization.rawValue,
         "locationProvider": "Core Location fused fixes; not raw GNSS measurements",
         "headingOrientation": "portrait device axes",
         "locationTimestamps": "original Unix time plus boot-time estimate from a fixed session clock offset; cached fixes are preserved"]
    }

    func start(emit: @escaping ([String: Any]) -> Void) {
        precondition(self.emit == nil, "Context recording is already active")
        // A new manager lets delegate identity reject callbacks from an earlier capture.
        manager.delegate = nil
        manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = kCLHeadingFilterNone
        manager.headingOrientation = .portrait
        manager.pausesLocationUpdatesAutomatically = false
        unixTimeAtBoot = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        self.emit = emit
        let id = UUID()
        generation = id
        UIDevice.current.isBatteryMonitoringEnabled = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                     UIDevice.orientationDidChangeNotification, ProcessInfo.thermalStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    self.deviceState()
                }
            })
        }
        deviceState()
        updateAuthorization()
    }

    func stop() {
        guard emit != nil else { return }
        emit = nil
        generation = nil
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.delegate = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func deviceState() {
        emit?(["sensor": "deviceState", "timestamp": ProcessInfo.processInfo.systemUptime,
               "batteryLevel": UIDevice.current.batteryLevel,
               "batteryState": UIDevice.current.batteryState.rawValue,
               "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
               "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
               "deviceOrientation": UIDevice.current.orientation.rawValue])
    }

    private func updateAuthorization() {
        guard emit != nil else { return }
        emit?(["sensor": "locationStatus", "timestamp": ProcessInfo.processInfo.systemUptime,
               "authorization": manager.authorizationStatus.rawValue,
               "accuracyAuthorization": manager.accuracyAuthorization.rawValue])
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            error("Location access is denied or restricted; no location or heading samples are available.")
        case .notDetermined:
            error("Location access has not been granted; no location or heading samples are available.")
        @unknown default:
            error("Unknown Core Location authorization status: \(manager.authorizationStatus.rawValue)")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager else { return }
        updateAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === self.manager, emit != nil else { return }
        for location in locations {
            onLocation?(location)
            let unix = location.timestamp.timeIntervalSince1970
            var record: [String: Any] = [
                "sensor": "location", "timestamp": unix - unixTimeAtBoot, "timestampUnix": unix,
                "receivedTimestamp": ProcessInfo.processInfo.systemUptime,
                "latitudeDegrees": location.coordinate.latitude, "longitudeDegrees": location.coordinate.longitude,
                "altitudeMeters": location.altitude, "ellipsoidalAltitudeMeters": location.ellipsoidalAltitude,
                "horizontalAccuracyMeters": location.horizontalAccuracy, "verticalAccuracyMeters": location.verticalAccuracy,
                "speedMetersPerSecond": location.speed, "speedAccuracyMetersPerSecond": location.speedAccuracy,
                "courseDegrees": location.course, "courseAccuracyDegrees": location.courseAccuracy,
            ]
            if let floor = location.floor { record["floorLevel"] = floor.level }
            if let source = location.sourceInformation {
                record["source"] = ["simulatedBySoftware": source.isSimulatedBySoftware,
                                    "producedByAccessory": source.isProducedByAccessory]
            }
            emit?(record)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard manager === self.manager, emit != nil else { return }
        emit?(["sensor": "heading", "timestamp": heading.timestamp.timeIntervalSince1970 - unixTimeAtBoot,
               "timestampUnix": heading.timestamp.timeIntervalSince1970,
               "receivedTimestamp": ProcessInfo.processInfo.systemUptime,
               "magneticHeadingDegrees": heading.magneticHeading, "trueHeadingDegrees": heading.trueHeading,
               "headingAccuracyDegrees": heading.headingAccuracy,
               "magneticFieldMicrotesla": [heading.x, heading.y, heading.z]])
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === self.manager else { return }
        self.error(error.localizedDescription)
    }

    private func error(_ message: String) {
        emit?(["sensor": "location", "timestamp": ProcessInfo.processInfo.systemUptime, "error": message])
    }
}
