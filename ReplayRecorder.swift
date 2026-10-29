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

// Encodes frames once and feeds the rolling replay and an explicit recording.
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

    func configure(width: Int32, height: Int32, fps: Int) -> Bool {
        queue.sync {
            if let encoder, encoder.width == width, encoder.height == height { return true }
            encoder = ReplayEncoder(width: width, height: height, fps: fps) { [weak self] sample in
                self?.queue.async { self?.store(sample) }
            }
            replay.reset()
            return encoder != nil
        }
    }

    func ingest(_ pixels: CVPixelBuffer, time: CMTime) {
        queue.async { [self] in
            encoder?.encode(pixels, time: time, forceKeyframe: forceKeyframe)
            forceKeyframe = false
        }
    }

    func flush() {
        let encoder = queue.sync { self.encoder }
        encoder?.flush()
        queue.sync {}
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

    func startRecording() {
        queue.sync {
            recording.reset()
            recordingActive = true
            forceKeyframe = true
        }
    }

    func stopRecording() -> [ReplayFrame] {
        queue.sync {
            recordingActive = false
            defer { recording.reset() }
            return recording.frames
        }
    }

    func replayFrames() -> [ReplayFrame] { queue.sync { replay.frames } }

    func reset() {
        queue.sync {
            replay.reset()
            recording.reset()
            recordingActive = false
            encoder = nil
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

    // Writes the MP4 and its key frames into the captures folder and returns the
    // bundle's video media entry.
    static func export(_ frames: [ReplayFrame], source: String, output: String) async throws -> [String: Any] {
        guard let first = frames.first else { throw captureError(source == "recording" ? "The recording captured no frames." : "Instant replay has no frames yet.") }
        let folder = URL(fileURLWithPath: output)
        let stem = "\(source)-\(UUID().uuidString.lowercased())"
        let movie = folder.appendingPathComponent(stem + ".mp4")
        let duration = try await writeMovie(frames, to: movie)
        let keyFrames = try await self.keyFrames(from: movie, folder: folder, stem: stem)
        return [
            "kind": "video",
            "video": movie.path,
            "source": source,
            "startedAt": ISO8601DateFormatter().string(from: date(forHostTime: first.time)),
            "durationSeconds": (duration * 10).rounded() / 10,
            "frames": keyFrames,
        ]
    }
}

// ScreenCaptureKit feeds the pipeline from the display under the focused window,
// excluding Capture Studio's own windows.
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

@MainActor final class ReplayRecorder {
    static let fps = 10
    static let maxSide = 1920.0
    let pipeline = ReplayPipeline()
    private var stream: SCStream?
    private var sink: ReplayStreamSink?
    private(set) var replayEnabled = false
    private(set) var recording = false
    var onChange: (() -> Void)?
    var onRecordingLimit: (() -> Void)?

    var isCapturing: Bool { stream != nil }

    init() {
        pipeline.onRecordingLimit = { [weak self] in Task { @MainActor in self?.onRecordingLimit?() } }
    }

    static func size(width: Int, height: Int, scale: Double) -> (width: Int32, height: Int32) {
        let pixels = (Double(width) * scale, Double(height) * scale)
        let factor = min(1, maxSide / max(pixels.0, pixels.1))
        let even = { (value: Double) in Int32(max(2, (value * factor / 2).rounded(.down) * 2)) }
        return (even(pixels.0), even(pixels.1))
    }

    func setReplay(_ enabled: Bool) async throws {
        replayEnabled = enabled
        pipeline.setReplay(enabled)
        try await updateStream()
    }

    func startRecording() async throws {
        recording = true
        do {
            try await updateStream()
            pipeline.startRecording()
        } catch {
            recording = false
            throw error
        }
        onChange?()
    }

    func stopRecording(output: String) async throws -> [String: Any] {
        let frames = pipeline.stopRecording()
        recording = false
        try? await updateStream()
        return try await ReplayWriter.export(frames, source: "recording", output: output)
    }

    private func updateStream() async throws {
        let wanted = replayEnabled || recording
        if wanted, stream == nil { try await startStream() }
        if !wanted, let stream {
            self.stream = nil
            sink = nil
            try? await stream.stopCapture()
            pipeline.reset()
        }
        onChange?()
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw captureError("No display is available to record.") }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let size = Self.size(width: display.width, height: display.height, scale: Double(screen?.backingScaleFactor ?? 2))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 5
        configuration.capturesAudio = false
        guard pipeline.configure(width: size.width, height: size.height, fps: Self.fps) else { throw captureError("Could not start the video encoder.") }
        let sink = ReplayStreamSink(pipeline: pipeline)
        sink.onStop = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stream = nil
                self.sink = nil
                self.replayEnabled = false
                self.recording = false
                self.pipeline.reset()
                self.onChange?()
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "local.opencode.capturestudio.replay-stream"))
        try await stream.startCapture()
        self.stream = stream
        self.sink = sink
    }
}
