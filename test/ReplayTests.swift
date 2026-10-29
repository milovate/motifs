import AppKit
import AVFoundation
import CoreMedia

func captureError(_ message: String) -> NSError { NSError(domain: "ReplayTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

func pixelBuffer(gray: UInt8, width: Int = 320, height: Int = 240) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    CVPixelBufferLockBaseAddress(buffer!, [])
    memset(CVPixelBufferGetBaseAddress(buffer!), Int32(gray), CVPixelBufferGetBytesPerRow(buffer!) * height)
    CVPixelBufferUnlockBaseAddress(buffer!, [])
    return buffer!
}

func feed(_ pipeline: ReplayPipeline, from start: Double, seconds: Double, fps: Double) {
    let count = Int(seconds * fps)
    for index in 0..<count {
        let time = start + Double(index) / fps
        pipeline.ingest(pixelBuffer(gray: UInt8(20 + (index * 200 / max(1, count - 1)))), time: CMTime(seconds: time, preferredTimescale: 600))
    }
    pipeline.flush()
}

@main struct ReplayTests {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())

        let pipeline = ReplayPipeline()
        precondition(pipeline.configure(width: 320, height: 240, fps: 10), "the H.264 encoder starts")
        pipeline.setReplay(true)
        feed(pipeline, from: 1000, seconds: 60, fps: 10)
        let replay = pipeline.replayFrames()
        let span = (replay.last?.time ?? 0) - (replay.first?.time ?? 0)
        precondition(replay.first?.keyframe == true, "the replay always starts on a keyframe")
        precondition(span >= 28 && span <= 32.1, "the replay keeps about the last 30 seconds (kept \(span) s)")
        precondition(replay.last?.time ?? 0 > 1059, "the newest frames are kept")
        precondition(replay.filter(\.keyframe).count >= 14, "keyframes arrive about every 2 seconds")

        let capped = ReplayBuffer(window: .infinity, maxBytes: replay.reduce(0) { $0 + $1.bytes } / 3)
        for frame in replay { capped.append(frame) }
        precondition(capped.frames.first?.keyframe == true && capped.bytes < replay.reduce(0) { $0 + $1.bytes } / 2, "the byte cap drops whole groups of pictures")
        let empty = ReplayBuffer(window: 30)
        if let delta = replay.first(where: { !$0.keyframe }) { empty.append(delta) }
        precondition(empty.frames.isEmpty, "a buffer never starts with a delta frame")

        pipeline.startRecording()
        feed(pipeline, from: 1060, seconds: 8, fps: 10)
        let recorded = pipeline.stopRecording()
        precondition(recorded.first?.keyframe == true && (recorded.first?.time ?? 0) >= 1060, "recordings start on a forced keyframe at the start")
        precondition(recorded.count >= 78, "recordings keep every frame since the start (kept \(recorded.count))")
        precondition(pipeline.stopRecording().isEmpty, "stopping clears the recording")
        pipeline.setReplay(false)
        precondition(pipeline.replayFrames().isEmpty, "turning replay off discards the buffer")

        let limited = ReplayPipeline()
        _ = limited.configure(width: 320, height: 240, fps: 10)
        var limitReached = false
        limited.onRecordingLimit = { limitReached = true }
        limited.startRecording()
        feed(limited, from: 0, seconds: 320, fps: 1)
        let longest = limited.stopRecording()
        precondition(limitReached && (longest.last?.time ?? 0) - (longest.first?.time ?? 0) <= ReplayPipeline.recordingLimit + 1, "recordings stop at 5 minutes")

        precondition(ReplayWriter.offsets(duration: 30, count: 6).map { ($0 * 100).rounded() / 100 } == [0, 5.98, 11.96, 17.94, 23.92, 29.9], "six evenly spaced key frames")
        precondition(ReplayWriter.offsets(duration: 0, count: 6) == [0], "a single frame for an instant recording")
        let size = ReplayRecorder.size(width: 1512, height: 982, scale: 2)
        precondition(size.width == 1920 && size.height == 1246, "recordings are scaled to a 1920-pixel long side with even dimensions (\(size))")
        precondition(ReplayRecorder.size(width: 1280, height: 720, scale: 1) == (1280, 720), "smaller displays are not upscaled")

        let video = try await ReplayWriter.export(replay, source: "replay", output: output.path)
        let movie = URL(fileURLWithPath: video["video"] as! String)
        precondition(movie.deletingLastPathComponent().standardizedFileURL == output.standardizedFileURL && movie.pathExtension == "mp4", "the MP4 is written into the captures folder")
        let movieMode = (try FileManager.default.attributesOfItem(atPath: movie.path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(movieMode == 0o600, "recordings are owner-only")
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        precondition(tracks.count == 1 && abs(duration - span) < 0.5, "the MP4 plays for the buffered span (\(duration) s)")
        let durationSeconds = (video["durationSeconds"] as? NSNumber)?.doubleValue ?? 0
        precondition(abs(durationSeconds - duration) < 0.3 && video["source"] as? String == "replay" && video["kind"] as? String == "video", "the media entry describes the recording")
        precondition((video["startedAt"] as? String).flatMap(ISO8601DateFormatter().date(from:)) != nil, "the start time is recorded")
        let frames = video["frames"] as? [[String: Any]] ?? []
        let offsets = frames.compactMap { ($0["offsetSeconds"] as? NSNumber)?.doubleValue }
        precondition(frames.count == 6 && offsets == offsets.sorted() && (offsets.last ?? 0) <= duration && (offsets.last ?? 0) > 25, "six key frames span the recording (\(offsets))")
        var images: [Data] = []
        for frame in frames {
            let path = frame["screenshot"] as! String
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
            precondition(data.starts(with: [137, 80, 78, 71]) && mode == 0o600, "key frames are owner-only PNGs")
            let image = NSBitmapImageRep(data: data)!
            precondition(image.pixelsWide <= 1280 && image.pixelsWide == 320, "key frames keep at most a 1280-pixel long side")
            images.append(data)
        }
        func brightness(_ data: Data) -> CGFloat { NSBitmapImageRep(data: data)!.colorAt(x: 160, y: 120)?.brightnessComponent ?? 0 }
        precondition(brightness(images[0]) < brightness(images[5]), "frames come from increasing times in the recording")

        do { _ = try await ReplayWriter.export([], source: "recording", output: output.path); preconditionFailure("empty recordings are refused") } catch {}
        print("Capture Studio replay buffer, recording, MP4 writer and key frame checks passed")
    }
}
