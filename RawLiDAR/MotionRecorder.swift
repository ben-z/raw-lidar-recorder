import CoreMotion
import Foundation

/// Uses the capture queue. A generation token rejects callbacks queued by
/// Core Motion before the preceding recording stopped.
final class MotionRecorder {
    private let manager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private var permissionAltimeter: CMAltimeter?
    private let operationQueue = OperationQueue()
    private var generation: UUID?

    var availability: [String: Bool] {
        ["accelerometer": manager.isAccelerometerAvailable, "gyro": manager.isGyroAvailable,
         "magnetometer": manager.isMagnetometerAvailable, "deviceMotion": manager.isDeviceMotionAvailable,
         "relativeAltitude": CMAltimeter.isRelativeAltitudeAvailable(),
         "absoluteAltitude": CMAltimeter.isAbsoluteAltitudeAvailable()]
    }

    init(queue: DispatchQueue) {
        operationQueue.name = "raw-lidar.motion"
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = queue
    }

    static var authorizationPending: Bool {
        (CMAltimeter.isRelativeAltitudeAvailable() || CMAltimeter.isAbsoluteAltitudeAvailable())
            && CMAltimeter.authorizationStatus() == .notDetermined
    }

    /// Altimeter access can prompt even when accelerometer access was already used.
    /// Resolve that prompt in preview so becoming inactive cannot stop a capture.
    func prepareAuthorization(reportError: @escaping (String) -> Void) {
        guard Self.authorizationPending, permissionAltimeter == nil else { return }
        let permission = CMAltimeter()
        permissionAltimeter = permission
        let completed: (Bool, Error?) -> Void = { [weak self] hasData, error in
            guard let self, self.permissionAltimeter === permission else { return }
            permission.stopRelativeAltitudeUpdates()
            permission.stopAbsoluteAltitudeUpdates()
            self.permissionAltimeter = nil
            if let error { reportError("Motion access failed: \(error.localizedDescription)") }
            else if !hasData { reportError("Altimeter returned no data or error while preparing motion access.") }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            permission.startRelativeAltitudeUpdates(to: operationQueue) { data, error in completed(data != nil, error) }
        }
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            permission.startAbsoluteAltitudeUpdates(to: operationQueue) { data, error in completed(data != nil, error) }
        }
    }

    func start(notBefore minimumTimestamp: Double, emit: @escaping ([String: Any]) -> Void) {
        let id = UUID()
        generation = id
        let dt = 0.01
        manager.accelerometerUpdateInterval = dt
        manager.gyroUpdateInterval = dt
        manager.magnetometerUpdateInterval = dt
        manager.deviceMotionUpdateInterval = dt

        let deliver: (String, Double?, [String: Any], Error?) -> Void = { [weak self] sensor, timestamp, values, error in
            guard self?.generation == id else { return }
            if let error {
                emit(["sensor": sensor, "error": error.localizedDescription,
                      "timestamp": ProcessInfo.processInfo.systemUptime])
            } else if let timestamp, timestamp >= minimumTimestamp {
                emit(values.merging(["sensor": sensor, "timestamp": timestamp]) { _, new in new })
            }
        }

        if manager.isAccelerometerAvailable {
            manager.startAccelerometerUpdates(to: operationQueue) { data, error in
                let a = data?.acceleration
                deliver("accelerometer", data?.timestamp, a.map { ["g": [$0.x, $0.y, $0.z]] } ?? [:], error)
            }
        }
        if manager.isGyroAvailable {
            manager.startGyroUpdates(to: operationQueue) { data, error in
                let r = data?.rotationRate
                deliver("gyro", data?.timestamp, r.map { ["rad_s": [$0.x, $0.y, $0.z]] } ?? [:], error)
            }
        }
        if manager.isMagnetometerAvailable {
            manager.startMagnetometerUpdates(to: operationQueue) { data, error in
                let m = data?.magneticField
                deliver("magnetometer", data?.timestamp, m.map { ["microtesla": [$0.x, $0.y, $0.z]] } ?? [:], error)
            }
        }
        if manager.isDeviceMotionAvailable {
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: operationQueue) { data, error in
                guard let data else { deliver("deviceMotion", nil, [:], error); return }
                let q = data.attitude.quaternion
                deliver("deviceMotion", data.timestamp, [
                    "attitude_xyzw": [q.x, q.y, q.z, q.w],
                    "gravity_g": [data.gravity.x, data.gravity.y, data.gravity.z],
                    "userAcceleration_g": [data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z],
                    "rotationRate_rad_s": [data.rotationRate.x, data.rotationRate.y, data.rotationRate.z],
                    "magneticField_microtesla": [data.magneticField.field.x, data.magneticField.field.y, data.magneticField.field.z],
                    "magneticFieldAccuracy": data.magneticField.accuracy.rawValue,
                ], error)
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: operationQueue) { data, error in
                guard let data else {
                    deliver("barometer", nil, [:], error ?? CaptureError.message("Altimeter returned no data or error."))
                    return
                }
                deliver("barometer", data.timestamp,
                        ["pressure_kPa": data.pressure, "relativeAltitude_m": data.relativeAltitude], error)
            }
        }
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: operationQueue) { data, error in
                guard let data else {
                    deliver("absoluteAltitude", nil, [:], error ?? CaptureError.message("Absolute altimeter returned no data or error."))
                    return
                }
                // This API's source clock is not assumed to match the IMU boot clock.
                let received = ProcessInfo.processInfo.systemUptime
                deliver("absoluteAltitude", received,
                        ["altitude_m": data.altitude, "accuracy_m": data.accuracy, "precision_m": data.precision,
                         "timestampBasis": "receipt", "sourceTimestamp": data.timestamp,
                         "sourceTimestampClock": "Core Motion CMAbsoluteAltitudeData.timestamp (unmodified; clock not assumed)"], error)
            }
        }
    }

    func stop() {
        generation = nil
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopMagnetometerUpdates()
        manager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        altimeter.stopAbsoluteAltitudeUpdates()
    }
}
