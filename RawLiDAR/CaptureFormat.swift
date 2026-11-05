import Foundation

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: jsonSafe(object), options: [.sortedKeys, .fragmentsAllowed])
}

/// JSON cannot represent nonfinite numbers or arbitrary CV attachment values.
func jsonSafe(_ value: Any) -> Any {
    if let dict = value as? [String: Any] { return dict.mapValues { jsonSafe($0) } }
    if let array = value as? [Any] { return array.map { jsonSafe($0) } }
    if let number = value as? NSNumber { return number.doubleValue.isFinite ? number : NSNull() }
    if let data = value as? Data { return ["encoding": "base64", "data": data.base64EncodedString()] }
    if value is String || value is NSNull { return value }
    return String(describing: value)
}
