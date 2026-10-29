import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

struct ReplayFrame {
    let sample: CMSampleBuffer
    let time: Double
    let keyframe: Bool
    let bytes: Int
}

// Compressed frames held in memory. Trimming drops whole groups of pictures so
// the buffer always begins with a keyframe and can be written as a playable MP4.
final class ReplayBuffer {
    let window: TimeInterval
    let maxBytes: Int
    private(set) var frames: [ReplayFrame] = []
    private(set) var bytes = 0

    init(window: TimeInterval, maxBytes: Int = 150_000_000) {
        self.window = window
        self.maxBytes = maxBytes
    }

    var duration: Double { (frames.last?.time ?? 0) - (frames.first?.time ?? 0) }

    func append(_ frame: ReplayFrame) {
        guard !frames.isEmpty || frame.keyframe else { return }
        frames.append(frame)
        bytes += frame.bytes
        let cutoff = frame.time - window
        while let next = frames.dropFirst().firstIndex(where: \.keyframe), frames[next].time <= cutoff || bytes > maxBytes {
            bytes -= frames[..<next].reduce(0) { $0 + $1.bytes }
            frames.removeFirst(next)
        }
    }

    func reset() {
        frames.removeAll()
        bytes = 0
    }
}

final class ReplayEncoder {
    private var session: VTCompressionSession?
    private let onFrame: (CMSampleBuffer) -> Void
    let width: Int32
    let height: Int32

    init?(width: Int32, height: Int32, fps: Int, onFrame: @escaping (CMSampleBuffer) -> Void) {
        self.width = width
        self.height = height
        self.onFrame = onFrame
        guard VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else { return nil }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 2,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_AverageBitRate: 2_500_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ pixels: CVPixelBuffer, time: CMTime, forceKeyframe: Bool = false) {
        guard let session else { return }
        let properties = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { [onFrame] status, _, sample in
            if status == noErr, let sample { onFrame(sample) }
        }
    }

    func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]], let first = attachments.first else { return true }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool != true
    }
}

// A paused span in recording time: the clip skips `duration` seconds of wall-clock
// time at `at` seconds into the video.
struct RecordingPause: Equatable {
    let at: Double
    let duration: Double
    var dictionary: [String: Any] { ["atSeconds": (at * 10).rounded() / 10, "durationSeconds": (duration * 10).rounded() / 10] }
}

struct RecordedClip {
    let frames: [ReplayFrame]
    let pauses: [RecordingPause]
}

var hostSeconds: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

// Encodes frames and feeds either the rolling replay or an explicit recording.
// Paused time is removed from presentation times so the clip plays continuously.
// All buffer access happens on `queue`.
final class ReplayPipeline {
    static let replayWindow: TimeInterval = 30
    static let recordingLimit: TimeInterval = 300
    let queue = DispatchQueue(label: "local.opencode.capturestudio.replay")
    let replay = ReplayBuffer(window: ReplayPipeline.replayWindow)
    let recording = ReplayBuffer(window: .infinity, maxBytes: 400_000_000)
    var replayEnabled = false
    var recordingActive = false
    var onRecordingLimit: (() -> Void)?
    private var encoder: ReplayEncoder?
    private var forceKeyframe = false
    private var lastPixels: CVPixelBuffer?
    private var lastTime = -Double.infinity
    private var startedAt = 0.0
    private var pausedAt: Double?
    private var pausedTotal = 0.0
    private var pauses: [(adjusted: Double, duration: Double)] = []

    func configure(width: Int32, height: Int32, fps: Int) -> Bool {
        queue.sync {
            if let encoder, encoder.width == width, encoder.height == height { return true }
            encoder = ReplayEncoder(width: width, height: height, fps: fps) { [weak self] sample in
                self?.queue.async { self?.store(sample) }
            }
            replay.reset()
            lastPixels = nil
            lastTime = -.infinity
            return encoder != nil
        }
    }

    func ingest(_ pixels: CVPixelBuffer, time: CMTime) {
        queue.async { [self] in
            if let pausedAt, time.seconds >= pausedAt { return }
            let adjusted = time.seconds - pausedTotal
            // Frames captured during a pause can arrive after resuming; they would go back in time.
            guard adjusted > lastTime else { return }
            encoder?.encode(pixels, time: CMTime(seconds: adjusted, preferredTimescale: 600), forceKeyframe: forceKeyframe)
            forceKeyframe = false
            lastPixels = pixels
            lastTime = adjusted
        }
    }

    func flush() {
        let encoder = queue.sync { self.encoder }
        encoder?.flush()
        queue.sync {}
    }

    // ScreenCaptureKit sends frames only when the screen changes. Re-encoding the
    // last image at `time` keeps a still screen at its real length.
    func seal(at time: Double = hostSeconds) {
        queue.sync {
            let adjusted = (pausedAt ?? time) - pausedTotal
            guard let lastPixels, let encoder, adjusted > lastTime + 0.05 else { return }
            encoder.encode(lastPixels, time: CMTime(seconds: adjusted, preferredTimescale: 600))
            lastTime = adjusted
        }
        flush()
    }

    private func store(_ sample: CMSampleBuffer) {
        let frame = ReplayFrame(sample: sample, time: sample.presentationTimeStamp.seconds, keyframe: ReplayEncoder.isKeyframe(sample), bytes: CMSampleBufferGetTotalSampleSize(sample))
        if replayEnabled { replay.append(frame) }
        guard recordingActive else { return }
        recording.append(frame)
        if recording.duration >= Self.recordingLimit {
            recordingActive = false
            onRecordingLimit?()
        }
    }

    func setReplay(_ enabled: Bool) {
        queue.sync {
            replayEnabled = enabled
            if !enabled { replay.reset() }
        }
    }

    // Also restarts: anything recorded so far is discarded.
    func startRecording(at time: Double = hostSeconds) {
        queue.sync {
            recording.reset()
            recordingActive = true
            forceKeyframe = true
            pausedAt = nil
            pauses = []
            pausedTotal = 0
            startedAt = time
        }
    }

    func pauseRecording(at time: Double = hostSeconds) {
        queue.sync { if recordingActive, pausedAt == nil { pausedAt = time } }
    }

    func resumeRecording(at time: Double = hostSeconds) {
        queue.sync {
            guard let pausedAt else { return }
            pauses.append((pausedAt - pausedTotal, time - pausedAt))
            pausedTotal += time - pausedAt
            self.pausedAt = nil
            forceKeyframe = true
        }
    }

    var isPaused: Bool { queue.sync { pausedAt != nil } }

    func recordedSeconds(at time: Double = hostSeconds) -> Double {
        queue.sync { recordingActive ? max(0, (pausedAt ?? time) - pausedTotal - startedAt) : 0 }
    }

    func stopRecording() -> RecordedClip {
        queue.sync {
            recordingActive = false
            pausedAt = nil
            defer { recording.reset(); pauses = [] }
            let start = recording.frames.first?.time ?? 0
            return RecordedClip(frames: recording.frames, pauses: pauses.map { RecordingPause(at: max(0, $0.adjusted - start), duration: $0.duration) })
        }
    }

    func replayFrames() -> [ReplayFrame] { queue.sync { replay.frames } }

    func reset() {
        queue.sync {
            replay.reset()
            recording.reset()
            recordingActive = false
            encoder = nil
            lastPixels = nil
            lastTime = -.infinity
            pausedAt = nil
            pausedTotal = 0
            pauses = []
        }
    }
}

enum ReplayWriter {
    // Host-clock times from ScreenCaptureKit, mapped to wall-clock dates.
    static func date(forHostTime time: Double) -> Date {
        Date().addingTimeInterval(time - CMClockGetTime(CMClockGetHostTimeClock()).seconds)
    }

    static func writeMovie(_ frames: [ReplayFrame], to url: URL) async throws -> Double {
        guard let first = frames.first, let last = frames.last, let format = CMSampleBufferGetFormatDescription(first.sample) else { throw captureError("The recording has no frames yet.") }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw captureError("Could not prepare the recording file.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? captureError("Could not write the recording.") }
        writer.startSession(atSourceTime: first.sample.presentationTimeStamp)
        for frame in frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            guard input.append(frame.sample) else { throw writer.error ?? captureError("Could not write the recording.") }
        }
        input.markAsFinished()
        let end = CMTimeAdd(last.sample.presentationTimeStamp, CMTime(value: 1, timescale: 10))
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? captureError("Could not finish the recording.") }
        chmod(url.path, 0o600)
        return end.seconds - first.time
    }

    static func offsets(duration: Double, count: Int) -> [Double] {
        guard duration > 0.05, count > 1 else { return [0] }
        let last = max(0, duration - 0.1)
        return (0..<count).map { last * Double($0) / Double(count - 1) }
    }

    static func keyFrames(from movie: URL, count: Int = 6, maxSide: CGFloat = 1280, folder: URL, stem: String) async throws -> [[String: Any]] {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        var frames: [[String: Any]] = []
        for (index, offset) in offsets(duration: duration, count: count).enumerated() {
            let (image, actual) = try await generator.image(at: CMTime(seconds: offset, preferredTimescale: 600))
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            let file = folder.appendingPathComponent("\(stem)-frame-\(index + 1).png")
            guard FileManager.default.createFile(atPath: file.path, contents: png, attributes: [.posixPermissions: 0o600]) else { continue }
            frames.append(["screenshot": file.path, "offsetSeconds": (max(0, actual.seconds) * 10).rounded() / 10])
        }
        return frames
    }

    static let maxClips = 3

    // OpenCode receives six key frames in total, split across the clips.
    static func framesPerClip(_ clips: Int) -> Int { 6 / min(maxClips, max(1, clips)) }

    // Writes the MP4 and its key frames into the captures folder and returns the
    // bundle's video media entry.
    static func export(_ frames: [ReplayFrame], source: String, output: String, frameCount: Int = 6, pauses: [RecordingPause] = [], details: [String: Any] = [:]) async throws -> [String: Any] {
        guard let first = frames.first else { throw captureError(source == "recording" ? "The recording captured no frames." : "Instant replay has no frames yet.") }
        let folder = URL(fileURLWithPath: output)
        let stem = "\(source)-\(UUID().uuidString.lowercased())"
        let movie = folder.appendingPathComponent(stem + ".mp4")
        let duration = try await writeMovie(frames, to: movie)
        let keyFrames = try await self.keyFrames(from: movie, count: frameCount, folder: folder, stem: stem)
        return details.merging([
            "kind": "video",
            "video": movie.path,
            "source": source,
            "startedAt": isoString(date(forHostTime: first.time)),
            "durationSeconds": (duration * 10).rounded() / 10,
            "frames": keyFrames,
            "pauses": pauses.map(\.dictionary),
        ]) { _, new in new }
    }

    static func pauses(of video: [String: Any]) -> [RecordingPause] {
        (video["pauses"] as? [[String: Any]] ?? []).compactMap { pause in
            guard let at = (pause["atSeconds"] as? NSNumber)?.doubleValue, let duration = (pause["durationSeconds"] as? NSNumber)?.doubleValue else { return nil }
            return RecordingPause(at: at, duration: duration)
        }.sorted { $0.at < $1.at }
    }

    // Seconds into the clip for a wall-clock time, skipping paused spans. Nil
    // outside the clip or while it was paused.
    static func offset(of date: Date, in video: [String: Any]) -> Double? {
        guard let start = (video["startedAt"] as? String).flatMap(parseDate) else { return nil }
        let duration = (video["durationSeconds"] as? NSNumber)?.doubleValue ?? 0
        var elapsed = date.timeIntervalSince(start)
        guard elapsed >= 0 else { return nil }
        for pause in pauses(of: video) {
            if elapsed < pause.at { break }
            if elapsed < pause.at + pause.duration { return nil }
            elapsed -= pause.duration
        }
        return elapsed <= duration + 1 ? elapsed : nil
    }

    static func isoString(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.string(from: date)
    }

    // Context times are ISO 8601 (events, browser) or the unified log's own format.
    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        let log = DateFormatter()
        log.locale = Locale(identifier: "en_US_POSIX")
        log.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return log.date(from: text)
    }

    static func movieStem(_ video: [String: Any]) -> String? {
        (video["video"] as? String).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }

    // Re-extracts key frames when the number of clips changes the per-clip share.
    static func reframe(_ video: [String: Any], count: Int) async throws -> [String: Any] {
        guard (video["frames"] as? [[String: Any]])?.count != count, let path = video["video"] as? String, let stem = movieStem(video) else { return video }
        let movie = URL(fileURLWithPath: path)
        var updated = video
        updated["frames"] = try await keyFrames(from: movie, count: count, folder: movie.deletingLastPathComponent(), stem: count == 6 ? stem : "\(stem)-\(count)")
        return updated
    }

    // Writes the selected range as a new MP4 next to the original, which stays untouched.
    static func trim(_ video: [String: Any], from start: Double, to end: Double, frameCount: Int) async throws -> [String: Any] {
        guard let path = video["video"] as? String, end - start >= 0.5 else { throw captureError("Select at least half a second.") }
        let source = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw captureError("This recording cannot be trimmed.") }
        let stem = "\(video["source"] as? String ?? "recording")-\(UUID().uuidString.lowercased())"
        let movie = source.deletingLastPathComponent().appendingPathComponent(stem + ".mp4")
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        if #available(macOS 15, *) {
            try await session.export(to: movie, as: .mp4)
        } else {
            session.outputURL = movie
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else { throw session.error ?? captureError("Could not trim the recording.") }
        }
        chmod(movie.path, 0o600)
        let duration = try await AVURLAsset(url: movie).load(.duration).seconds
        let pauses = pauses(of: video)
        let skipped = pauses.filter { $0.at <= start }.reduce(0) { $0 + $1.duration }
        var trimmed = video
        trimmed["video"] = movie.path
        if let began = (video["startedAt"] as? String).flatMap(parseDate) {
            trimmed["startedAt"] = isoString(began.addingTimeInterval(start + skipped))
        }
        trimmed["durationSeconds"] = (duration * 10).rounded() / 10
        trimmed["pauses"] = pauses.filter { $0.at > start && $0.at < end }.map { RecordingPause(at: $0.at - start, duration: $0.duration).dictionary }
        trimmed["frames"] = try await keyFrames(from: movie, count: frameCount, folder: movie.deletingLastPathComponent(), stem: stem)
        return trimmed
    }
}

// What an explicit recording captures. Instant replay always uses the display.
enum RecordingArea: Equatable {
    case display
    case window(pid: pid_t, app: String)
    case area(CGRect, display: CGDirectDisplayID, scale: CGFloat)

    var details: [String: Any] {
        switch self {
        case .display: return ["area": "display"]
        case let .window(_, app): return ["area": "window", "target": String(app.prefix(120))]
        case let .area(rect, _, _): return ["area": "area", "target": "\(Int(rect.width)) × \(Int(rect.height)) area"]
        }
    }
}

final class ReplayStreamSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let pipeline: ReplayPipeline
    var onStop: ((Error) -> Void)?
    init(pipeline: ReplayPipeline) { self.pipeline = pipeline }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        pipeline.ingest(pixels, time: sample.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}

// One ScreenCaptureKit stream feeding one pipeline. Capture Studio's own
// windows are excluded from display and area streams; a window stream shows only that window.
@MainActor final class ReplayStream {
    let stream: SCStream
    let sink: ReplayStreamSink

    private init(stream: SCStream, sink: ReplayStreamSink) {
        self.stream = stream
        self.sink = sink
    }

    static func start(_ area: RecordingArea, pipeline: ReplayPipeline, onStop: @escaping () -> Void) async throws -> ReplayStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter: SCContentFilter
        let size: (width: Int32, height: Int32)
        let configuration = SCStreamConfiguration()
        switch area {
        case .display:
            let screen = NSScreen.main ?? NSScreen.screens.first
            let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw captureError("No display is available to record.") }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            size = ReplayRecorder.size(width: display.width, height: display.height, scale: Double(screen?.backingScaleFactor ?? 2))
        case let .window(pid, app):
            let order = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? UInt32 }
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 }
            guard let window = candidates.min(by: { (order.firstIndex(of: $0.windowID) ?? .max) < (order.firstIndex(of: $1.windowID) ?? .max) }) else { throw captureError("No visible window found for \(app). Bring its window on screen and retry.") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.ignoreShadowsSingleWindow = true
            let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor ?? 2
            size = ReplayRecorder.size(width: Int(window.frame.width), height: Int(window.frame.height), scale: Double(scale))
        case let .area(rect, displayID, scale):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw captureError("The selected display is no longer available.") }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            configuration.sourceRect = rect
            size = ReplayRecorder.size(width: Int(rect.width), height: Int(rect.height), scale: Double(scale))
        }
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ReplayRecorder.fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 5
        configuration.capturesAudio = false
        guard pipeline.configure(width: size.width, height: size.height, fps: ReplayRecorder.fps) else { throw captureError("Could not start the video encoder.") }
        let sink = ReplayStreamSink(pipeline: pipeline)
        sink.onStop = { _ in Task { @MainActor in onStop() } }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "local.opencode.capturestudio.replay-stream"))
        try await stream.startCapture()
        return ReplayStream(stream: stream, sink: sink)
    }

    func stop() async { try? await stream.stopCapture() }
}

@MainActor final class ReplayRecorder {
    static let fps = 10
    static let maxSide = 1920.0
    let pipeline = ReplayPipeline()
    let recordingPipeline = ReplayPipeline()
    private var replayStream: ReplayStream?
    private var recordingStream: ReplayStream?
    private(set) var replayEnabled = false
    private(set) var recording = false
    private(set) var area = RecordingArea.display
    var onChange: (() -> Void)?
    var onRecordingLimit: (() -> Void)?

    init() {
        recordingPipeline.onRecordingLimit = { [weak self] in Task { @MainActor in self?.onRecordingLimit?() } }
    }

    static func size(width: Int, height: Int, scale: Double) -> (width: Int32, height: Int32) {
        let pixels = (Double(width) * scale, Double(height) * scale)
        let factor = min(1, maxSide / max(pixels.0, pixels.1))
        let even = { (value: Double) in Int32(max(2, (value * factor / 2).rounded(.down) * 2)) }
        return (even(pixels.0), even(pixels.1))
    }

    var paused: Bool { recordingPipeline.isPaused }
    var recordedSeconds: Double { recordingPipeline.recordedSeconds() }

    func setReplay(_ enabled: Bool) async throws {
        replayEnabled = enabled
        pipeline.setReplay(enabled)
        if enabled, replayStream == nil {
            do {
                replayStream = try await ReplayStream.start(.display, pipeline: pipeline) { [weak self] in
                    self?.replayStream = nil
                    self?.replayEnabled = false
                    self?.pipeline.reset()
                    self?.onChange?()
                }
            } catch {
                replayEnabled = false
                pipeline.setReplay(false)
                throw error
            }
        } else if !enabled, let stream = replayStream {
            replayStream = nil
            await stream.stop()
            pipeline.reset()
        }
        onChange?()
    }

    // The last 30 seconds, ending now even if the screen has been still.
    func replayClip() -> [ReplayFrame] {
        guard replayEnabled else { return [] }
        pipeline.seal()
        return pipeline.replayFrames()
    }

    func startRecording(_ area: RecordingArea = .display) async throws {
        guard !recording else { return }
        recordingStream = try await ReplayStream.start(area, pipeline: recordingPipeline) { [weak self] in
            guard let self, self.recording else { return }
            self.onRecordingLimit?()
        }
        recordingPipeline.startRecording()
        self.area = area
        recording = true
        onChange?()
    }

    func restartRecording() {
        guard recording else { return }
        recordingPipeline.startRecording()
        onChange?()
    }

    func setPaused(_ paused: Bool) {
        guard recording else { return }
        if paused { recordingPipeline.pauseRecording() } else { recordingPipeline.resumeRecording() }
        onChange?()
    }

    func stopRecording(output: String, frameCount: Int = 6) async throws -> [String: Any] {
        recordingPipeline.seal()
        let clip = recordingPipeline.stopRecording()
        recording = false
        if let stream = recordingStream {
            recordingStream = nil
            await stream.stop()
        }
        recordingPipeline.reset()
        onChange?()
        return try await ReplayWriter.export(clip.frames, source: "recording", output: output, frameCount: frameCount, pauses: clip.pauses, details: area.details)
    }
}

