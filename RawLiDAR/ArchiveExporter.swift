import Foundation

enum ArchiveExporter {
    /// A unique staging directory prevents reusing a partial or outdated ZIP.
    static func create(from directory: URL) throws -> URL {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("RawLiDAR-Export-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = staging.appendingPathComponent(directory.lastPathComponent + ".zip")
        var completed = false
        defer { if !completed { try? manager.removeItem(at: staging) } }

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: directory, options: .forUploading,
                                                        error: &coordinationError) { snapshot in
            do {
                // Foundation removes its snapshot after this accessor returns.
                try manager.copyItem(at: snapshot, to: destination)
                completed = true
            } catch { copyError = error }
        }
        if let coordinationError { completed = false; throw coordinationError }
        if let copyError { throw copyError }
        guard completed else { throw CaptureError.message("Could not create ZIP.") }
        return destination
    }

    static func remove(_ archive: URL) {
        try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
    }
}
