import Foundation

enum RecordingLibrary {
    static func recordings(in root: URL) throws -> [URL] {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let children = try manager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var recordings: [URL] = []
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true { recordings.append(child) }
        }
        return recordings.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func delete(_ directory: URL, in root: URL) throws {
        guard directory.isFileURL, root.isFileURL,
              !directory.pathComponents.contains(where: { $0 == "." || $0 == ".." }),
              directory.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
                == root.standardizedFileURL.resolvingSymlinksInPath() else {
            throw CaptureError.message("Only recording folders directly inside Recordings can be deleted.")
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CaptureError.message("The selected recording must be a real folder.")
        }
        try FileManager.default.removeItem(at: directory)
    }
}
