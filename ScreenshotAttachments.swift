import Foundation

struct ScreenshotAttachment {
    let snapshot: [String: Any]
    let png: Data
}

func screenshotManifestParts(_ manifest: [String: Any]) throws -> [[String: Any]] {
    guard manifest.keys.contains("screenshots") else { return [manifest] }
    guard let parts = manifest["screenshots"] as? [[String: Any]], parts.count <= 14 else {
        throw captureError("A draft can contain up to 8 screenshots and 6 recording frames.")
    }
    return parts
}

func loadScreenshotAttachments(_ manifest: [String: Any], output: String) throws -> [ScreenshotAttachment] {
    let parts = try screenshotManifestParts(manifest)
    let root = URL(fileURLWithPath: output).resolvingSymlinksInPath()
    var total = 0
    return try parts.map { shot in
        guard let path = shot["screenshot"] as? String else { throw captureError("The capture has no screenshot.") }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard file.deletingLastPathComponent() == root, file.pathExtension == "png" else { throw captureError("Screenshots must be PNGs in the Capture Studio capture folder.") }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= 15_000_000, total + size <= 30_000_000 else { throw captureError("Screenshots must be under 15 MB each and 30 MB combined.") }
        let png = try Data(contentsOf: file)
        guard png.count <= 15_000_000, png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw captureError("A screenshot is not a valid PNG under 15 MB.") }
        total += png.count
        guard total <= 30_000_000 else { throw captureError("Screenshots exceed the combined 30 MB limit.") }
        return ScreenshotAttachment(snapshot: shot, png: png)
    }
}
