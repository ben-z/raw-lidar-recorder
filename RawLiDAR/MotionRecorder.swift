import CoreMotion
import Foundation

/// Uses the capture queue. A generation token rejects callbacks queued by
/// Core Motion before the preceding recording stopped.
final class MotionRecorder {
    private let manager = CMMotionManager()
    private let operationQueue = OperationQueue()
    private var generation: UUID?

    var availability: [String: Bool] {
        ["accelerometer": manager.isAccelerometerAvailable, "gyro": manager.isGyroAvailable,
         "magnetometer": manager.isMagnetometerAvailable, "deviceMotion": manager.isDeviceMotionAvailable]
    }

    init(queue: DispatchQueue) {
        operationQueue.name = "raw-lidar.motion"
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = queue
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
    }

    func stop() {
        generation = nil
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopMagnetometerUpdates()
        manager.stopDeviceMotionUpdates()
    }
}
