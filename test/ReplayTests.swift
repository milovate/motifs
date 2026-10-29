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

        pipeline.seal(at: 1075)
        let sealed = pipeline.replayFrames()
        precondition(abs((sealed.last?.time ?? 0) - 1075) < 0.01 && (sealed.last?.time ?? 0) - (sealed.first?.time ?? 0) <= 32.1, "a still screen keeps the replay ending now")
        pipeline.setReplay(false)
        precondition(pipeline.replayFrames().isEmpty, "turning replay off discards the buffer")

        let recorder = ReplayPipeline()
        _ = recorder.configure(width: 320, height: 240, fps: 10)
        recorder.startRecording(at: 2000)
        feed(recorder, from: 2000, seconds: 8, fps: 10)
        let recorded = recorder.stopRecording().frames
        precondition(recorded.first?.keyframe == true && (recorded.first?.time ?? 0) >= 2000, "recordings start on a forced keyframe at the start")
        precondition(recorded.count >= 78, "recordings keep every frame since the start (kept \(recorded.count))")
        precondition(recorder.stopRecording().frames.isEmpty, "stopping clears the recording")

        recorder.startRecording(at: 3000)
        feed(recorder, from: 3000, seconds: 5, fps: 10)
        precondition(abs(recorder.recordedSeconds(at: 3005) - 5) < 0.01, "the timer counts recorded time")
        recorder.pauseRecording(at: 3005)
        feed(recorder, from: 3005, seconds: 20, fps: 10)
        precondition(recorder.isPaused && abs(recorder.recordedSeconds(at: 3020) - 5) < 0.01, "the timer stops while paused")
        recorder.resumeRecording(at: 3025)
        feed(recorder, from: 3010, seconds: 1, fps: 10)
        feed(recorder, from: 3025, seconds: 5, fps: 10)
        recorder.seal(at: 3035)
        let paused = recorder.stopRecording()
        let pausedSpan = (paused.frames.last?.time ?? 0) - (paused.frames.first?.time ?? 0)
        precondition(abs(pausedSpan - 15) < 0.2, "paused time is cut from the clip and a still ending is kept (span \(pausedSpan))")
        precondition(zip(paused.frames, paused.frames.dropFirst()).allSatisfy { $0.time < $1.time }, "frames captured during a pause never go back in time")
        precondition(paused.pauses.count == 1 && abs(paused.pauses[0].at - 5) < 0.2 && abs(paused.pauses[0].duration - 20) < 0.01, "pauses are recorded in clip time (\(paused.pauses))")
        precondition(paused.frames.contains { $0.keyframe && $0.time > 3005 }, "resuming starts a new keyframe")

        recorder.startRecording(at: 4000)
        feed(recorder, from: 4000, seconds: 3, fps: 10)
        recorder.startRecording(at: 4003)
        feed(recorder, from: 4003, seconds: 2, fps: 10)
        let restarted = recorder.stopRecording().frames
        precondition((restarted.first?.time ?? 0) >= 4003 && restarted.first?.keyframe == true, "restarting discards what was recorded")

        let limited = ReplayPipeline()
        _ = limited.configure(width: 320, height: 240, fps: 10)
        var limitReached = false
        limited.onRecordingLimit = { limitReached = true }
        limited.startRecording(at: 0)
        feed(limited, from: 0, seconds: 320, fps: 1)
        let longest = limited.stopRecording().frames
        precondition(limitReached && (longest.last?.time ?? 0) - (longest.first?.time ?? 0) <= ReplayPipeline.recordingLimit + 1, "recordings stop at 5 minutes")

        let clip: [String: Any] = ["startedAt": "2026-10-29T10:00:00.000Z", "durationSeconds": 30, "pauses": [["atSeconds": 10, "durationSeconds": 60]]]
        let base = ReplayWriter.parseDate("2026-10-29T10:00:00Z")!
        precondition(ReplayWriter.offset(of: base.addingTimeInterval(4), in: clip) == 4, "events before a pause keep their time")
        precondition(ReplayWriter.offset(of: base.addingTimeInterval(30), in: clip) == nil, "events during a pause are not in the clip")
        precondition(ReplayWriter.offset(of: base.addingTimeInterval(75), in: clip) == 15, "events after a pause skip the paused time")
        precondition(ReplayWriter.offset(of: base.addingTimeInterval(-1), in: clip) == nil && ReplayWriter.offset(of: base.addingTimeInterval(200), in: clip) == nil, "events outside the clip have no offset")
        precondition(abs((ReplayWriter.parseDate("2026-10-29 15:30:00.123456+0530")?.timeIntervalSince(base) ?? 99) - 0.123) < 0.001, "unified log times parse")
        precondition([1, 2, 3, 4].map(ReplayWriter.framesPerClip) == [6, 3, 2, 2], "six frames are split across up to three clips")
        precondition(RecordingArea.window(pid: 1, app: "Safari").details["target"] as? String == "Safari" && RecordingArea.area(CGRect(x: 0, y: 0, width: 400, height: 300), display: 1, scale: 2).details["area"] as? String == "area", "recordings describe what they captured")

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
        precondition((video["startedAt"] as? String).flatMap(ReplayWriter.parseDate) != nil, "the start time is recorded")
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

        let three = try await ReplayWriter.reframe(video, count: 3)
        let threeFrames = three["frames"] as? [[String: Any]] ?? []
        precondition(threeFrames.count == 3 && threeFrames.allSatisfy { ($0["screenshot"] as? String)?.contains("-3-frame-") == true } && (video["frames"] as? [[String: Any]])?.allSatisfy { FileManager.default.fileExists(atPath: $0["screenshot"] as! String) } == true, "fewer frames per clip are extracted without touching the originals")
        let unchanged = try await ReplayWriter.reframe(video, count: 6)
        precondition((unchanged["frames"] as? [[String: Any]])?.map { $0["screenshot"] as! String } == (video["frames"] as? [[String: Any]])?.map { $0["screenshot"] as! String }, "an unchanged count is kept")

        var withPauses = video
        withPauses["pauses"] = [["atSeconds": 2, "durationSeconds": 50], ["atSeconds": 20, "durationSeconds": 5]]
        let trimmed = try await ReplayWriter.trim(withPauses, from: 10, to: 22, frameCount: 2)
        let trimmedMovie = trimmed["video"] as! String
        let trimmedDuration = try await AVURLAsset(url: URL(fileURLWithPath: trimmedMovie)).load(.duration).seconds
        precondition(trimmedMovie != movie.path && FileManager.default.fileExists(atPath: movie.path), "trimming writes a new MP4 and keeps the original")
        precondition(abs(trimmedDuration - 12) < 0.3 && abs(((trimmed["durationSeconds"] as? NSNumber)?.doubleValue ?? 0) - 12) < 0.3, "the trimmed clip covers the selection (\(trimmedDuration) s)")
        let trimmedStart = (trimmed["startedAt"] as? String).flatMap(ReplayWriter.parseDate)!
        let originalStart = (video["startedAt"] as? String).flatMap(ReplayWriter.parseDate)!
        precondition(abs(trimmedStart.timeIntervalSince(originalStart) - 60) < 0.01, "the start moves by the trimmed time plus earlier pauses")
        precondition(ReplayWriter.pauses(of: trimmed) == [RecordingPause(at: 10, duration: 5)], "pauses inside the selection are kept in clip time")
        let trimmedFrames = trimmed["frames"] as? [[String: Any]] ?? []
        let firstTrimmed = try Data(contentsOf: URL(fileURLWithPath: trimmedFrames[0]["screenshot"] as! String))
        precondition(trimmedFrames.count == 2 && brightness(firstTrimmed) > brightness(images[0]), "key frames come from the selected range")
        do { _ = try await ReplayWriter.trim(video, from: 3, to: 3.2, frameCount: 6); preconditionFailure("tiny selections are refused") } catch {}
        print("Capture Studio replay buffer, recording, MP4 writer and key frame checks passed")
    }
}
