using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace OpenCode.Appshots;

// Presentation-time helpers shared with the macOS recorder. Paused spans are removed
// from the clip, and six key frames are split across at most three clips.
internal static class ReplayMath
{
    internal const double RecordingLimit = 300;
    internal const int MaxClips = 3;
    internal const int MaxSide = 1280;
    internal const int FramesPerSecond = 8;

    internal static int FramesPerClip(int clips) => 6 / Math.Min(MaxClips, Math.Max(1, clips));

    internal static double[] Offsets(double duration, int count)
    {
        if (duration <= 0.05 || count <= 1) return new double[] { 0 };
        double last = Math.Max(0, duration - 0.1);
        var offsets = new double[count];
        for (int index = 0; index < count; index++) offsets[index] = last * index / (count - 1);
        return offsets;
    }

    internal static (int Width, int Height) OutputSize(int width, int height)
    {
        if (width < 2 || height < 2) throw new InvalidOperationException("The recording area is too small.");
        double scale = Math.Min(1, MaxSide / (double)Math.Max(width, height));
        int evenWidth = Math.Max(2, (int)Math.Round(width * scale) & ~1);
        int evenHeight = Math.Max(2, (int)Math.Round(height * scale) & ~1);
        return (evenWidth, evenHeight);
    }

    internal static string ClockLabel(double seconds, double limit)
    {
        int whole = Math.Max(0, (int)seconds);
        string clock = string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}", whole / 60, whole % 60);
        double remaining = limit - seconds;
        if (remaining > 30) return clock;
        return clock + " · " + ((int)Math.Max(0, remaining)).ToString(CultureInfo.InvariantCulture) + "s left";
    }

    internal static string AreaName(CaptureKind kind)
    {
        switch (kind)
        {
            case CaptureKind.Window: return "window";
            case CaptureKind.Region: return "area";
            case CaptureKind.Display: return "display";
            default:
                throw new InvalidOperationException("Unknown capture.");
        }
    }
}

// Wall-clock pauses become spans in presentation time, matching the macOS pipeline.
internal sealed class RecordingTimeline
{
    readonly List<(double At, double Duration)> pauses = new();
    double origin;
    double pausedTotal;
    double? pausedAt;
    internal bool Active { get; private set; }
    internal bool Paused => pausedAt != null;
    internal IReadOnlyList<(double At, double Duration)> Pauses => pauses;

    internal void Start(double now)
    {
        origin = now;
        pausedTotal = 0;
        pausedAt = null;
        pauses.Clear();
        Active = true;
    }

    internal void Pause(double now)
    {
        if (Active && pausedAt == null) pausedAt = now;
    }

    internal void Resume(double now)
    {
        if (pausedAt is not double at) return;
        double duration = Math.Max(0, now - at);
        if (duration > 0) pauses.Add((Math.Max(0, at - pausedTotal - origin), duration));
        pausedTotal += duration;
        pausedAt = null;
    }

    internal void Toggle(double now)
    {
        if (Paused) Resume(now);
        else Pause(now);
    }

    internal double Seconds(double now) => Active ? Math.Max(0, (pausedAt ?? now) - pausedTotal - origin) : 0;
}

internal readonly struct ReplaySample
{
    internal double Time { get; }
    internal DateTimeOffset At { get; }
    internal byte[] Jpeg { get; }
    internal int Width { get; }
    internal int Height { get; }
    internal ReplaySample(double time, DateTimeOffset at, byte[] jpeg, int width, int height)
    {
        Time = time;
        At = at;
        Jpeg = jpeg;
        Width = width;
        Height = height;
    }
}

// The last 30 seconds of one display, held in memory until a capture attaches them.
internal sealed class ReplayBuffer
{
    internal const double Window = 30;
    internal const int MaxBytes = 150_000_000;
    readonly object gate = new();
    readonly List<ReplaySample> frames = new();
    readonly int maxBytes;
    int bytes;

    internal ReplayBuffer(int maxBytes = MaxBytes) => this.maxBytes = Math.Max(1, maxBytes);

    internal int Count { get { lock (gate) return frames.Count; } }
    internal int Width { get; private set; }
    internal int Height { get; private set; }
    internal double Duration { get { lock (gate) return frames.Count < 2 ? 0 : frames[^1].Time - frames[0].Time; } }

    internal void Clear() { lock (gate) Reset(); }

    internal void Add(double time, byte[] jpeg, int width, int height, bool restart = false)
    {
        if (jpeg.Length == 0 || width < 2 || height < 2) return;
        lock (gate)
        {
            if (restart || (frames.Count > 0 && (width != Width || height != Height))) Reset();
            Width = width;
            Height = height;
            frames.Add(new ReplaySample(time, DateTimeOffset.UtcNow, jpeg, width, height));
            bytes += jpeg.Length;
            while (frames.Count > 1 && (frames[^1].Time - frames[0].Time > Window || bytes > maxBytes))
            {
                bytes -= frames[0].Jpeg.Length;
                frames.RemoveAt(0);
            }
        }
    }

    internal List<ReplaySample> Snapshot() { lock (gate) return frames.ToList(); }

    void Reset()
    {
        frames.Clear();
        bytes = 0;
        Width = 0;
        Height = 0;
    }

    internal static JsonObject? Export(string output, IReadOnlyList<ReplaySample> frames, int frameCount)
    {
        if (frames.Count == 0) return null;
        int width = frames[0].Width;
        int height = frames[0].Height;
        for (int index = 0; index < frames.Count; index++)
            if (frames[index].Width != width || frames[index].Height != height) return null;
        string movie = Path.Combine(output, "replay-" + Guid.NewGuid().ToString("D") + ".mp4");
        var pictures = new JsonArray();
        try
        {
            using (var writer = new Mp4Writer(movie, width, height, ReplayMath.FramesPerSecond))
            {
                double start = frames[0].Time;
                foreach (var frame in frames)
                {
                    using var stream = new MemoryStream(frame.Jpeg);
                    using var image = Image.FromStream(stream);
                    using var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
                    using (var graphics = Graphics.FromImage(bitmap)) graphics.DrawImage(image, new Rectangle(0, 0, width, height));
                    writer.Write(bitmap, (long)((frame.Time - start) * 10_000_000));
                }
                writer.Finish();
            }
            double span = frames.Count < 2 ? 1.0 / ReplayMath.FramesPerSecond : frames[^1].Time - frames[0].Time + (1.0 / ReplayMath.FramesPerSecond);
            double duration = Math.Min(Window, Math.Round(span, 1, MidpointRounding.AwayFromZero));
            string stem = Path.GetFileNameWithoutExtension(movie);
            foreach (double offset in ReplayMath.Offsets(Math.Max(duration, 0), frameCount))
            {
                int best = 0;
                double gap = double.MaxValue;
                for (int index = 0; index < frames.Count; index++)
                {
                    double distance = Math.Abs((frames[index].Time - frames[0].Time) - offset);
                    if (distance < gap) { gap = distance; best = index; }
                }
                string file = Path.Combine(output, stem + "-frame-" + (pictures.Count + 1).ToString(CultureInfo.InvariantCulture) + ".png");
                using (var stream = new MemoryStream(frames[best].Jpeg))
                using (var image = Image.FromStream(stream))
                    image.Save(file, ImageFormat.Png);
                pictures.Add(new JsonObject
                {
                    ["screenshot"] = file,
                    ["offsetSeconds"] = Math.Round(Math.Max(0, frames[best].Time - frames[0].Time), 1, MidpointRounding.AwayFromZero),
                });
            }
            return new JsonObject
            {
                ["kind"] = "video",
                ["video"] = movie,
                ["source"] = "replay",
                ["area"] = "display",
                ["target"] = "",
                ["startedAt"] = ComposerFiles.Iso(frames[0].At),
                ["durationSeconds"] = duration,
                ["frames"] = pictures,
                ["pauses"] = new JsonArray(),
            };
        }
        catch
        {
            try { File.Delete(movie); } catch { /* The failed export leaves no clip to attach. */ }
            foreach (var picture in pictures)
            {
                string? file = picture?["screenshot"]?.GetValue<string>();
                if (!string.IsNullOrEmpty(file)) try { File.Delete(file); } catch { /* The frame file is already gone. */ }
            }
            throw;
        }
    }
}

// Samples the display under the pointer while the tray setting is on. Frames stay in memory.
internal sealed class InstantReplay : IDisposable
{
    readonly ReplayBuffer buffer = new();
    readonly System.Threading.Timer timer;
    readonly System.Diagnostics.Stopwatch clock = new();
    Rectangle? display;
    int capturing;
    int disposed;
    volatile bool enabled;
    volatile bool paused;
    internal bool Enabled => enabled;
    internal bool Paused { get => paused; set => paused = value; }

    internal InstantReplay() => timer = new System.Threading.Timer(_ => Capture(), null, System.Threading.Timeout.Infinite, System.Threading.Timeout.Infinite);

    internal void SetEnabled(bool value)
    {
        enabled = value;
        buffer.Clear();
        display = null;
        if (!value) { timer.Change(System.Threading.Timeout.Infinite, System.Threading.Timeout.Infinite); return; }
        if (!clock.IsRunning) clock.Start();
        timer.Change(0, 1000 / ReplayMath.FramesPerSecond);
    }

    internal List<ReplaySample> Snapshot() => enabled ? buffer.Snapshot() : new List<ReplaySample>();

    void Capture()
    {
        if (System.Threading.Volatile.Read(ref disposed) == 1 || !enabled || paused || RecordingSession.Busy) return;
        if (System.Threading.Interlocked.Exchange(ref capturing, 1) == 1) return;
        try
        {
            if (!enabled || paused || RecordingSession.Busy) return;
            var screen = Screen.FromPoint(Cursor.Position).Bounds;
            if (screen.Width < 2 || screen.Height < 2 || (long)screen.Width * screen.Height > 40_000_000) return;
            bool moved = display is Rectangle previous && previous != screen;
            var (width, height) = ReplayMath.OutputSize(screen.Width, screen.Height);
            using var raw = new Bitmap(screen.Width, screen.Height, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(raw)) graphics.CopyFromScreen(screen.Left, screen.Top, 0, 0, screen.Size, CopyPixelOperation.SourceCopy);
            using var frame = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(frame)) graphics.DrawImage(raw, new Rectangle(0, 0, width, height));
            using var stream = new MemoryStream();
            frame.Save(stream, ImageFormat.Jpeg);
            if (!enabled || paused || RecordingSession.Busy) return;
            display = screen;
            buffer.Add(clock.Elapsed.TotalSeconds, stream.ToArray(), width, height, moved);
        }
        catch { /* A missed sample leaves the previous frames in place. */ }
        finally { System.Threading.Interlocked.Exchange(ref capturing, 0); }
    }

    public void Dispose()
    {
        if (System.Threading.Interlocked.Exchange(ref disposed, 1) == 1) return;
        enabled = false;
        timer.Dispose();
    }
}

// A JPEG about twice a second, so a five-minute recording stays small. The frames
// nearest the shared key-frame offsets are written as PNGs.
sealed class KeyShelf
{
    readonly List<(double Time, byte[] Jpeg)> frames = new();

    internal void Add(Bitmap frame, double time)
    {
        if (frames.Count > 0 && time < frames[^1].Time + 0.5) return;
        using var small = Scale(frame, 480);
        using var stream = new MemoryStream();
        small.Save(stream, ImageFormat.Jpeg);
        frames.Add((time, stream.ToArray()));
    }

    internal void Clear() => frames.Clear();

    internal JsonArray Export(string output, string stem, double duration, int count)
    {
        var saved = new JsonArray();
        if (frames.Count == 0) return saved;
        foreach (double offset in ReplayMath.Offsets(duration, count))
        {
            int best = 0;
            double gap = double.MaxValue;
            for (int index = 0; index < frames.Count; index++)
            {
                double distance = Math.Abs(frames[index].Time - offset);
                if (distance < gap) { gap = distance; best = index; }
            }
            string file = Path.Combine(output, stem + "-frame-" + (saved.Count + 1).ToString(CultureInfo.InvariantCulture) + ".png");
            using (var stream = new MemoryStream(frames[best].Jpeg))
            using (var image = Image.FromStream(stream))
                image.Save(file, ImageFormat.Png);
            saved.Add(new JsonObject
            {
                ["screenshot"] = file,
                ["offsetSeconds"] = Math.Round(frames[best].Time, 1, MidpointRounding.AwayFromZero),
            });
        }
        return saved;
    }

    internal static Bitmap Scale(Bitmap source, int maxSide)
    {
        double scale = Math.Min(1, maxSide / (double)Math.Max(source.Width, source.Height));
        int width = Math.Max(2, (int)Math.Round(source.Width * scale));
        int height = Math.Max(2, (int)Math.Round(source.Height * scale));
        var image = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(image);
        graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
        graphics.DrawImage(source, new Rectangle(0, 0, width, height));
        return image;
    }
}

// Media Foundation sink writer. Slot numbers follow the Windows IDL order; a gap
// would call the wrong method and crash only when a frame is written.
static class MediaFoundation
{
    const uint Version = 0x00020070;

    internal static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    internal static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    internal static readonly Guid AverageBitrate = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    internal static readonly Guid FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    internal static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    internal static readonly Guid InterlaceMode = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    internal static readonly Guid PixelAspect = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    internal static readonly Guid DefaultStride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
    internal static readonly Guid HardwareTransforms = new("a634a91c-822b-41b9-a494-4de4643612b0");
    internal static readonly Guid EnableVideoProcessing = new("fb394f3d-ccf1-42ee-bbb3-f9b845d5681d");
    internal static readonly Guid Video = new("73646976-0000-0010-8000-00aa00389b71");
    internal static readonly Guid H264 = new("34363248-0000-0010-8000-00aa00389b71");
    internal static readonly Guid Rgb32 = new("00000016-0000-0010-8000-00aa00389b71");
    internal const uint FirstVideoStream = 0xFFFFFFFC;

    static readonly object startupGate = new();
    static int startups;

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct PropVariantI8
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public long value;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int Proc(nint self);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int SetU32(nint self, ref Guid key, uint value);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int SetU64(nint self, ref Guid key, ulong value);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int SetGuidFn(nint self, ref Guid key, ref Guid value);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int AddStreamFn(nint self, nint mediaType, out uint index);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int SetInputFn(nint self, uint index, nint mediaType, nint parameters);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int WriteFn(nint self, uint index, nint sample);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int LockFn(nint self, out nint data, nint max, nint current);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int LengthFn(nint self, uint length);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int TimeFn(nint self, long hundredNanoseconds);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int BufferFn(nint self, nint buffer);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int GetU32(nint self, ref Guid key, out uint value);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int GetU64(nint self, ref Guid key, out ulong value);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int OutPtr(nint self, uint stream, out nint result);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int SetTypeFn(nint self, uint stream, nint reserved, nint mediaType);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int SetPosFn(nint self, ref Guid format, nint variant);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int ReadFn(nint self, uint stream, uint flags, out uint actual, out uint streamFlags, out long timestamp, out nint sample);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int SampleBufferFn(nint self, out nint buffer);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int GetLenFn(nint self, out uint length);

    [DllImport("ole32.dll")] static extern int CoInitializeEx(nint reserved, uint model);
    [DllImport("mfplat.dll")] static extern int MFStartup(uint version, uint flags);
    [DllImport("mfplat.dll")] static extern int MFShutdown();
    [DllImport("mfplat.dll")] static extern int MFCreateMediaType(out nint mediaType);
    [DllImport("mfplat.dll")] static extern int MFCreateAttributes(out nint attributes, uint initialSize);
    [DllImport("mfplat.dll")] static extern int MFCreateMemoryBuffer(uint maxLength, out nint buffer);
    [DllImport("mfplat.dll")] static extern int MFCreateSample(out nint sample);
    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)] static extern int MFCreateSinkWriterFromURL(string url, nint stream, nint attributes, out nint writer);
    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)] static extern int MFCreateSourceReaderFromURL(string url, nint attributes, out nint reader);

    internal static void Startup()
    {
        int com = CoInitializeEx(0, 2);
        if (com < 0 && unchecked((uint)com) != 0x80010106) Check(com, "COM startup");
        lock (startupGate)
        {
            if (startups++ > 0) return;
            int started = MFStartup(Version, 0);
            if (started < 0) started = MFStartup(Version, 1);
            if (started < 0) { startups--; Check(started, "Media Foundation startup"); }
        }
    }

    internal static void Shutdown()
    {
        lock (startupGate)
        {
            if (startups == 0) return;
            if (--startups == 0) MFShutdown();
        }
    }

    internal static nint MediaType() { Check(MFCreateMediaType(out nint type), "Media type"); return type; }
    internal static nint Attributes() { Check(MFCreateAttributes(out nint attributes, 4), "Encoder settings"); return attributes; }
    internal static nint MemoryBuffer(int bytes) { Check(MFCreateMemoryBuffer((uint)bytes, out nint buffer), "Frame buffer"); return buffer; }
    internal static nint Sample() { Check(MFCreateSample(out nint sample), "Frame sample"); return sample; }
    internal static nint Sink(string path, nint attributes) { Check(MFCreateSinkWriterFromURL(path, 0, attributes, out nint writer), "Recording file"); return writer; }
    internal static nint SourceReader(string path, nint attributes) { Check(MFCreateSourceReaderFromURL(path, attributes, out nint reader), "Open recording"); return reader; }
    internal static nint ReaderType(nint reader) { Check(Fn<OutPtr>(reader, 6)(reader, FirstVideoStream, out nint type), "Recording format"); return type; }
    internal static void SetReaderType(nint reader, nint mediaType) => Check(Fn<SetTypeFn>(reader, 7)(reader, FirstVideoStream, 0, mediaType), "Decode format");
    internal static void SetPosition(nint reader, long hundredNanoseconds)
    {
        var variant = new PropVariantI8 { vt = 20, value = hundredNanoseconds };
        nint pointer = Marshal.AllocHGlobal(Marshal.SizeOf<PropVariantI8>());
        try
        {
            Marshal.StructureToPtr(variant, pointer, false);
            var format = Guid.Empty;
            Check(Fn<SetPosFn>(reader, 8)(reader, ref format, pointer), "Seek recording");
        }
        finally { Marshal.FreeHGlobal(pointer); }
    }
    internal static void ReadSample(nint reader, out uint flags, out long timestamp, out nint sample) =>
        Check(Fn<ReadFn>(reader, 9)(reader, FirstVideoStream, 0, out _, out flags, out timestamp, out sample), "Read frame");
    internal static nint ContiguousBuffer(nint sample) { Check(Fn<SampleBufferFn>(sample, 41)(sample, out nint buffer), "Read frame"); return buffer; }
    internal static int CurrentLength(nint buffer) { Check(Fn<GetLenFn>(buffer, 5)(buffer, out uint length), "Frame size"); return (int)length; }
    internal static ulong GetUint64(nint target, Guid key) { Check(Fn<GetU64>(target, 8)(target, ref key, out ulong value), "Video setting"); return value; }
    internal static bool TryGetInt32(nint target, Guid key, out int value)
    {
        int code = Fn<GetU32>(target, 7)(target, ref key, out uint raw);
        value = unchecked((int)raw);
        return code >= 0;
    }

    internal static void SetUint32(nint target, Guid key, uint value) => Check(Fn<SetU32>(target, 21)(target, ref key, value), "Video setting");
    internal static void SetUint64(nint target, Guid key, ulong value) => Check(Fn<SetU64>(target, 22)(target, ref key, value), "Video setting");
    internal static void SetGuid(nint target, Guid key, Guid value) => Check(Fn<SetGuidFn>(target, 24)(target, ref key, ref value), "Video setting");
    internal static uint AddStream(nint writer, nint mediaType) { Check(Fn<AddStreamFn>(writer, 3)(writer, mediaType, out uint index), "H.264 stream"); return index; }
    internal static void SetInput(nint writer, uint index, nint mediaType) => Check(Fn<SetInputFn>(writer, 4)(writer, index, mediaType, 0), "Frame format");
    internal static void Begin(nint writer) => Check(Fn<Proc>(writer, 5)(writer), "Start recording file");
    internal static void Write(nint writer, uint index, nint sample) => Check(Fn<WriteFn>(writer, 6)(writer, index, sample), "Write frame");
    internal static void Finalize(nint writer) => Check(Fn<Proc>(writer, 11)(writer), "Finish recording file");
    internal static nint Lock(nint buffer) { Check(Fn<LockFn>(buffer, 3)(buffer, out nint data, 0, 0), "Lock frame"); return data; }
    internal static void SetLength(nint buffer, int length) => Check(Fn<LengthFn>(buffer, 6)(buffer, (uint)length), "Frame size");
    internal static void Unlock(nint buffer) => Check(Fn<Proc>(buffer, 4)(buffer), "Unlock frame");
    internal static void SetTime(nint sample, long time) => Check(Fn<TimeFn>(sample, 36)(sample, time), "Frame time");
    internal static void SetDuration(nint sample, long duration) => Check(Fn<TimeFn>(sample, 38)(sample, duration), "Frame duration");
    internal static void AddBuffer(nint sample, nint buffer) => Check(Fn<BufferFn>(sample, 42)(sample, buffer), "Attach frame");
    internal static void Release(nint unknown) { if (unknown != 0) Fn<Proc>(unknown, 2)(unknown); }

    internal static ulong Pack(uint high, uint low) => ((ulong)high << 32) | low;

    static T Fn<T>(nint unknown, int slot) where T : Delegate =>
        Marshal.GetDelegateForFunctionPointer<T>(Marshal.ReadIntPtr(Marshal.ReadIntPtr(unknown), slot * nint.Size));

    static void Check(int code, string action)
    {
        if (code >= 0) return;
        uint failure = unchecked((uint)code);
        string hint = failure is 0xC00D36B4 or 0xC00D5212
            ? " This PC has no H.264 encoder or decoder. Install the Media Feature Pack and try again."
            : "";
        throw new InvalidOperationException(action + " failed (0x" + failure.ToString("X8", CultureInfo.InvariantCulture) + ")." + hint);
    }
}

internal sealed class Mp4Writer : IDisposable
{
    readonly string path;
    readonly int width;
    readonly int height;
    readonly long frameDuration;
    nint writer;
    uint stream;
    bool finished;
    bool released;

    internal Mp4Writer(string path, int width, int height, int fps)
    {
        if (width < 2 || height < 2 || (width & 1) != 0 || (height & 1) != 0) throw new InvalidOperationException("Recording dimensions must be even.");
        if (fps < 1 || fps > 60) throw new InvalidOperationException("Recording frame rate is unsupported.");
        this.path = path;
        this.width = width;
        this.height = height;
        frameDuration = 10_000_000L / fps;
        MediaFoundation.Startup();
        try { Open(fps); }
        catch { Dispose(); throw; }
    }

    void Open(int fps)
    {
        nint attributes = MediaFoundation.Attributes();
        try { MediaFoundation.SetUint32(attributes, MediaFoundation.HardwareTransforms, 0); writer = MediaFoundation.Sink(path, attributes); }
        finally { MediaFoundation.Release(attributes); }
        nint output = VideoType(MediaFoundation.H264, fps);
        try
        {
            MediaFoundation.SetUint32(output, MediaFoundation.AverageBitrate, (uint)Math.Max(400_000, width * height * 4));
            stream = MediaFoundation.AddStream(writer, output);
        }
        finally { MediaFoundation.Release(output); }
        nint input = VideoType(MediaFoundation.Rgb32, fps);
        try
        {
            MediaFoundation.SetUint32(input, MediaFoundation.DefaultStride, (uint)(width * 4));
            MediaFoundation.SetInput(writer, stream, input);
        }
        finally { MediaFoundation.Release(input); }
        MediaFoundation.Begin(writer);
    }

    nint VideoType(Guid subtype, int fps)
    {
        nint type = MediaFoundation.MediaType();
        MediaFoundation.SetGuid(type, MediaFoundation.MajorType, MediaFoundation.Video);
        MediaFoundation.SetGuid(type, MediaFoundation.Subtype, subtype);
        MediaFoundation.SetUint64(type, MediaFoundation.FrameSize, MediaFoundation.Pack((uint)width, (uint)height));
        MediaFoundation.SetUint64(type, MediaFoundation.FrameRate, MediaFoundation.Pack((uint)fps, 1));
        MediaFoundation.SetUint64(type, MediaFoundation.PixelAspect, MediaFoundation.Pack(1, 1));
        MediaFoundation.SetUint32(type, MediaFoundation.InterlaceMode, 2);
        return type;
    }

    internal void Write(Bitmap frame, long time)
    {
        if (frame.Width != width || frame.Height != height) throw new InvalidOperationException("Frame size changed during recording.");
        byte[] pixels = Pixels(frame);
        nint buffer = MediaFoundation.MemoryBuffer(pixels.Length);
        nint sample = 0;
        bool locked = false;
        try
        {
            Marshal.Copy(pixels, 0, MediaFoundation.Lock(buffer), pixels.Length);
            locked = true;
            MediaFoundation.SetLength(buffer, pixels.Length);
            MediaFoundation.Unlock(buffer);
            locked = false;
            sample = MediaFoundation.Sample();
            MediaFoundation.AddBuffer(sample, buffer);
            MediaFoundation.SetTime(sample, time);
            MediaFoundation.SetDuration(sample, frameDuration);
            MediaFoundation.Write(writer, stream, sample);
        }
        finally
        {
            if (locked) MediaFoundation.Unlock(buffer);
            MediaFoundation.Release(sample);
            MediaFoundation.Release(buffer);
        }
    }

    internal void Finish()
    {
        MediaFoundation.Finalize(writer);
        finished = true;
    }

    public void Dispose()
    {
        if (released) return;
        released = true;
        if (writer != 0) { MediaFoundation.Release(writer); writer = 0; }
        MediaFoundation.Shutdown();
        if (!finished) { try { File.Delete(path); } catch { /* A failed recording leaves nothing to attach. */ } }
    }

    internal static byte[] Pixels(Bitmap bitmap)
    {
        var rect = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            int row = bitmap.Width * 4;
            var pixels = new byte[row * bitmap.Height];
            int step = data.Stride;
            nint start = data.Scan0;
            if (step < 0) { start += step * (bitmap.Height - 1); step = -step; }
            for (int y = 0; y < bitmap.Height; y++) Marshal.Copy(start + (y * step), pixels, y * row, row);
            for (int channel = 3; channel < pixels.Length; channel += 4) pixels[channel] = 255;
            return pixels;
        }
        finally { bitmap.UnlockBits(data); }
    }
}

// A dashed outline just outside a recorded area. It ignores clicks, and each frame
// grab hides it so the dashes are not in the video.
internal sealed class RecordingOutline : Form
{
    internal static Rectangle FrameFor(Rectangle area) => Rectangle.Inflate(area, 4, 4);

    internal RecordingOutline(Rectangle area)
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        BackColor = Color.Magenta;
        TransparencyKey = Color.Magenta;
        Bounds = FrameFor(area);
        DoubleBuffered = true;
        Text = "Recording area";
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle |= 0x00080000 | 0x00000020 | 0x08000000;
            return parameters;
        }
    }

    protected override bool ShowWithoutActivation => true;

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.ExcludeFromCapture(Handle);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        using var pen = new Pen(Color.Red, 2) { DashPattern = new[] { 6f, 4f } };
        e.Graphics.DrawRectangle(pen, 1, 1, Math.Max(1, Width - 3), Math.Max(1, Height - 3));
    }
}

// Timer, restart, pause, and Stop. The bar is excluded from capture APIs that honor
// display affinity, and the recorder also hides it for each GDI grab.
internal sealed class RecordingControls : Form
{
    readonly Label time = new() { AutoSize = false, Text = "00:00", ForeColor = Color.White, TextAlign = ContentAlignment.MiddleLeft };
    readonly Button restart = new() { Text = "Restart" };
    readonly Button pause = new() { Text = "Pause" };
    readonly Button stop = new() { Text = "Stop" };
    bool closing;
    internal event Action? Restarted;
    internal event Action? PauseToggled;
    internal event Action? Stopped;
    internal event Action? Cancelled;

    internal RecordingControls()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        ClientSize = new Size(520, 48);
        BackColor = Color.FromArgb(28, 28, 30);
        ForeColor = Color.White;
        Font = new Font("Segoe UI", 10);
        KeyPreview = true;
        var dot = new Label { Text = "●", ForeColor = Color.IndianRed, Location = new Point(14, 12), AutoSize = true };
        time.Font = new Font("Consolas", 14);
        time.SetBounds(36, 8, 170, 32);
        time.AccessibleName = "Recorded time";
        restart.SetBounds(214, 8, 88, 32);
        pause.SetBounds(308, 8, 88, 32);
        stop.SetBounds(402, 8, 100, 32);
        restart.AccessibleName = "Restart: discard this recording and start again";
        pause.AccessibleName = "Pause recording";
        stop.AccessibleName = "Stop and attach the recording";
        foreach (var button in new[] { restart, pause, stop })
        {
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderColor = Color.FromArgb(80, 80, 84);
            button.BackColor = Color.FromArgb(48, 48, 52);
            button.ForeColor = Color.White;
        }
        stop.BackColor = Color.FromArgb(232, 232, 234);
        stop.ForeColor = Color.FromArgb(20, 20, 20);
        restart.Click += (_, _) => Restarted?.Invoke();
        pause.Click += (_, _) => PauseToggled?.Invoke();
        stop.Click += (_, _) => Stopped?.Invoke();
        Controls.AddRange(new Control[] { dot, time, restart, pause, stop });
        Text = "Recording controls";
    }

    protected override bool ShowWithoutActivation => true;

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.ExcludeFromCapture(Handle);
    }

    internal void Place(Rectangle area)
    {
        var screen = Screen.FromRectangle(area).WorkingArea;
        Location = new Point(screen.Left + Math.Max(0, (screen.Width - Width) / 2), screen.Top + 12);
    }

    internal void ShowTime(double seconds, bool paused)
    {
        time.Text = ReplayMath.ClockLabel(seconds, ReplayMath.RecordingLimit);
        time.ForeColor = ReplayMath.RecordingLimit - seconds <= 30 ? Color.Orange : Color.White;
        pause.Text = paused ? "Resume" : "Pause";
        pause.AccessibleName = paused ? "Resume recording" : "Pause recording";
    }

    internal void CloseFromSession()
    {
        closing = true;
        Close();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!closing) Cancelled?.Invoke();
        base.OnFormClosing(e);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { Cancelled?.Invoke(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }
}

// Records the chosen display, window rectangle, or area to an H.264 MP4 in the
// captures folder. Stopping returns the bundle's video entry; Escape deletes it.
internal sealed class RecordingSession
{
    const string Hint = "Record: drag an area or click a window    ·    Enter full screen    ·    Esc cancel    ·    no audio, 5 min max";
    static RecordingSession? current;
    static bool choosing;
    readonly string output;
    readonly CaptureChoice choice;
    readonly RecordingTimeline timeline = new();
    readonly KeyShelf shelf = new();
    readonly System.Diagnostics.Stopwatch clock = new();
    readonly TaskCompletionSource<JsonObject?> done = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly int frameCount;
    RecordingControls controls;
    RecordingOutline? outline;
    Timer timer;
    Mp4Writer? writer;
    Rectangle source;
    string movie = "";
    int width;
    int height;
    int written;
    double lastPresentation = -1;
    DateTimeOffset? startedAt;
    bool stopping;
    bool finishing;
    bool grabbing;
    bool watching;
    Task? browserSteps;
    bool? deferredSave;
    Exception? deferredError;

    internal static bool Active => current != null;
    internal static bool Busy => choosing || current != null;
    internal static int LastConsolePid { get; private set; }
    internal static bool ResolveConsoleAtStop { get; private set; }
    internal static event Action? StateChanged;

    RecordingSession(string output, CaptureChoice choice, int clipsAlready)
    {
        this.output = output;
        this.choice = choice;
        frameCount = ReplayMath.FramesPerClip(clipsAlready + 1);
        controls = new RecordingControls();
        timer = new Timer { Interval = 100 };
    }

    internal static void RequestStop() => current?.Stop(true, null);

    internal static async Task<JsonObject?> Capture(string output, int clipsAlready)
    {
        if (Busy) return null;
        LastConsolePid = 0;
        ResolveConsoleAtStop = false;
        choosing = true;
        StateChanged?.Invoke();
        CaptureChoice choice;
        try
        {
            using var overlay = new RegionOverlay(Hint);
            if (overlay.ShowDialog() != DialogResult.OK || overlay.Choice is not CaptureChoice chosen) return null;
            choice = chosen;
            if (choice.Kind == CaptureKind.Window) LastConsolePid = AppConsole.TargetPid(choice.Window);
            else ResolveConsoleAtStop = true;
        }
        finally { choosing = false; StateChanged?.Invoke(); }
        if (current != null) return null;
        var session = new RecordingSession(output, choice, clipsAlready);
        current = session;
        StateChanged?.Invoke();
        try { return await session.Run(); }
        finally { if (current == session) { current = null; StateChanged?.Invoke(); } }
    }

    Task<JsonObject?> Run()
    {
        try
        {
            source = InitialBounds();
            if ((long)source.Width * source.Height > 40_000_000) throw new InvalidOperationException("Selection size is unsupported (maximum 40 million pixels).");
            (width, height) = ReplayMath.OutputSize(source.Width, source.Height);
            movie = Path.Combine(output, "recording-" + Guid.NewGuid().ToString("D") + ".mp4");
            writer = new Mp4Writer(movie, width, height, ReplayMath.FramesPerSecond);
            clock.Start();
            timeline.Start(0);
            controls.Restarted += Restart;
            controls.PauseToggled += () => timeline.Toggle(clock.Elapsed.TotalSeconds);
            controls.Stopped += () => Stop(true, null);
            controls.Cancelled += () => Stop(false, null);
            timer.Tick += Tick;
            WriteFrame(0);
            if (stopping) return done.Task;
            controls.Place(source);
            controls.Show();
            if (choice.Kind == CaptureKind.Region)
            {
                outline = new RecordingOutline(source);
                outline.Show();
            }
            if (stopping) return done.Task;
            ClickHistory.Shared.BeginRecording();
            browserSteps = Task.Run(() => { try { BrowserHost.CollectSteps(true); } catch { /* Recording continues when the extension is not connected. */ } });
            watching = true;
            timer.Start();
            Program.Save(output, "status.json", new { phase = "recording" });
        }
        catch (Exception error)
        {
            if (!stopping) Stop(false, error);
        }
        return done.Task;
    }

    void Tick(object? sender, EventArgs args)
    {
        if (stopping) return;
        try
        {
            double now = clock.Elapsed.TotalSeconds;
            double seconds = timeline.Seconds(now);
            controls.ShowTime(seconds, timeline.Paused);
            if (seconds >= ReplayMath.RecordingLimit) { Stop(true, null); return; }
            if (timeline.Paused || (lastPresentation >= 0 && seconds < lastPresentation + 0.1)) return;
            WriteFrame(seconds);
        }
        catch (Exception error)
        {
            if (written == 0) Stop(false, error);
        }
    }

    void WriteFrame(double presentation)
    {
        if (stopping || grabbing) return;
        Rectangle area = CurrentArea();
        if (area.Width < 2 || area.Height < 2) return;
        grabbing = true;
        bool hide = controls.Visible && controls.IsHandleCreated;
        bool hideOutline = outline is { Visible: true, IsHandleCreated: true };
        if (hide) Native.ShowWindow(controls.Handle, 0);
        if (hideOutline) Native.ShowWindow(outline!.Handle, 0);
        Bitmap? raw = null;
        Bitmap? frame = null;
        try
        {
            if (stopping || writer == null) return;
            raw = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(raw)) graphics.CopyFromScreen(area.Left, area.Top, 0, 0, area.Size, CopyPixelOperation.SourceCopy);
            frame = new Bitmap(width, height, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(frame)) graphics.DrawImage(raw, new Rectangle(0, 0, width, height));
            if (stopping || writer == null) return;
            writer.Write(frame, (long)(presentation * 10_000_000));
            shelf.Add(frame, presentation);
            startedAt ??= DateTimeOffset.UtcNow;
            lastPresentation = presentation;
            written++;
        }
        finally
        {
            frame?.Dispose();
            raw?.Dispose();
            if (hide && !controls.IsDisposed) Native.ShowWindow(controls.Handle, 8);
            if (hideOutline && outline is { IsDisposed: false }) Native.ShowWindow(outline.Handle, 8);
            grabbing = false;
            if (deferredSave is bool save) Finish(save, deferredError);
        }
    }

    void Restart()
    {
        if (stopping || grabbing) return;
        try
        {
            writer?.Dispose();
            DeleteFiles();
            shelf.Clear();
            written = 0;
            lastPresentation = -1;
            startedAt = null;
            movie = Path.Combine(output, "recording-" + Guid.NewGuid().ToString("D") + ".mp4");
            writer = new Mp4Writer(movie, width, height, ReplayMath.FramesPerSecond);
            timeline.Start(clock.Elapsed.TotalSeconds);
            WriteFrame(timeline.Seconds(clock.Elapsed.TotalSeconds));
            if (stopping) return;
            controls.ShowTime(0, false);
        }
        catch (Exception error) { Stop(false, error); }
    }

    Rectangle InitialBounds()
    {
        if (choice.Kind == CaptureKind.Window)
        {
            if (!Native.IsWindow(choice.Window) || !Native.GetWindowRect(choice.Window, out var rect)) throw new InvalidOperationException("Could not read the window bounds.");
            var bounds = Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
            if (bounds.Width < 2 || bounds.Height < 2) throw new InvalidOperationException("The recording area is too small.");
            return bounds;
        }
        if (choice.Bounds.Width < 2 || choice.Bounds.Height < 2) throw new InvalidOperationException("The recording area is too small.");
        return choice.Bounds;
    }

    Rectangle CurrentArea()
    {
        Rectangle bounds = source;
        if (choice.Kind == CaptureKind.Window)
        {
            if (!Native.IsWindow(choice.Window) || Native.IsIconic(choice.Window) || !Native.GetWindowRect(choice.Window, out var rect)) return Rectangle.Empty;
            bounds = Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
        }
        var visible = Rectangle.Intersect(bounds, SystemInformation.VirtualScreen);
        return visible.Width < 2 || visible.Height < 2 ? Rectangle.Empty : visible;
    }

    void EndSteps(JsonObject? clip)
    {
        if (!watching) return;
        watching = false;
        var native = ClickHistory.Shared.EndRecording(ComposerFiles.RecordClicks(ComposerFiles.Settings(output)));
        try { browserSteps?.Wait(4000); } catch { /* The start request can still be in flight. */ }
        List<JsonObject> page;
        try { page = BrowserHost.CollectSteps(false); }
        catch { page = new List<JsonObject>(); }
        if (clip != null) ClickHistory.Shared.Publish(page.Count == 0 ? ClickHistory.ForClip(native, clip) : ClickHistory.RecordingEvents(native, page, clip));
    }

    void Stop(bool save, Exception? error)
    {
        if (finishing) return;
        if (grabbing)
        {
            stopping = true;
            timer.Stop();
            deferredSave ??= save;
            deferredError ??= error;
            return;
        }
        Finish(save, error);
    }

    void Finish(bool save, Exception? error)
    {
        if (finishing) return;
        finishing = true;
        stopping = true;
        timer.Stop();
        JsonObject? clip = null;
        try
        {
            if (error == null && save && written > 0 && writer != null)
            {
                writer.Finish();
                writer.Dispose();
                writer = null;
                clip = Describe();
            }
            else
            {
                writer?.Dispose();
                writer = null;
                DeleteFiles();
            }
        }
        catch (Exception blown)
        {
            error ??= blown;
            try { writer?.Dispose(); } catch { /* The partial file is removed below. */ }
            writer = null;
            DeleteFiles();
            clip = null;
        }
        try { controls.CloseFromSession(); outline?.Close(); timer.Dispose(); }
        catch (Exception blown) { error ??= blown; clip = null; }
        try { EndSteps(clip); }
        catch { /* The clip still stands when step collection fails. */ }
        try
        {
            if (clip != null) done.TrySetResult(clip);
            else if (error != null) done.TrySetException(error);
            else if (save) done.TrySetException(new InvalidOperationException("The recording captured no frames."));
            else done.TrySetResult(null);
        }
        catch (Exception blown) { done.TrySetException(blown); }
        try { Program.Save(output, "status.json", new { phase = clip != null ? "recording_ready" : error != null ? "recording_failed" : "recording_cancelled" }); }
        catch { /* The clip or the cancellation still stands when status cannot be written. */ }
    }

    JsonObject Describe()
    {
        double duration = Math.Min(ReplayMath.RecordingLimit, Math.Round(Math.Max(0, lastPresentation) + (1.0 / ReplayMath.FramesPerSecond), 1, MidpointRounding.AwayFromZero));
        string stem = Path.GetFileNameWithoutExtension(movie);
        var pictures = shelf.Export(output, stem, duration, frameCount);
        var pauses = new JsonArray();
        foreach (var pause in timeline.Pauses)
        {
            if (pause.Duration <= 0) continue;
            pauses.Add(new JsonObject
            {
                ["atSeconds"] = Math.Round(pause.At, 1, MidpointRounding.AwayFromZero),
                ["durationSeconds"] = Math.Round(pause.Duration, 1, MidpointRounding.AwayFromZero),
            });
        }
        return new JsonObject
        {
            ["kind"] = "video",
            ["video"] = movie,
            ["source"] = "recording",
            ["area"] = ReplayMath.AreaName(choice.Kind),
            ["target"] = Target(),
            ["startedAt"] = ComposerFiles.Iso(startedAt ?? DateTimeOffset.UtcNow),
            ["durationSeconds"] = duration,
            ["frames"] = pictures,
            ["pauses"] = pauses,
        };
    }

    string Target()
    {
        switch (choice.Kind)
        {
            case CaptureKind.Window:
                var text = new StringBuilder(512);
                Native.GetWindowText(choice.Window, text, text.Capacity);
                string title = text.ToString().Trim();
                return title.Length <= 120 ? title : title[..120];
            case CaptureKind.Region:
                return source.Width.ToString(CultureInfo.InvariantCulture) + "×" + source.Height.ToString(CultureInfo.InvariantCulture);
            case CaptureKind.Display:
                return "";
            default:
                throw new InvalidOperationException("Unknown capture.");
        }
    }

    void DeleteFiles()
    {
        try { if (movie.Length > 0 && File.Exists(movie)) File.Delete(movie); } catch { /* Already gone. */ }
        string stem = Path.GetFileNameWithoutExtension(movie);
        if (stem.Length == 0 || !Directory.Exists(output)) return;
        foreach (string frame in Directory.GetFiles(output, stem + "-frame-*.png"))
            try { File.Delete(frame); } catch { /* Already gone. */ }
    }
}

internal static class RecordingTests
{
    internal static void Run(string output)
    {
        string file = Path.Combine(output, "recording-smoke.mp4");
        using (var writer = new Mp4Writer(file, 64, 64, 8))
        {
            using var bitmap = new Bitmap(64, 64, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(bitmap)) graphics.Clear(Color.Red);
            writer.Write(bitmap, 0);
            using (var graphics = Graphics.FromImage(bitmap)) graphics.Clear(Color.Blue);
            writer.Write(bitmap, 1_250_000);
            writer.Finish();
        }
        var header = new byte[8];
        using (var stream = File.OpenRead(file))
        {
            if (stream.Read(header, 0, 8) != 8) throw new Exception("Recording regression: the MP4 is empty.");
        }
        if (header[4] != (byte)'f' || header[5] != (byte)'t' || header[6] != (byte)'y' || header[7] != (byte)'p' || new FileInfo(file).Length < 32)
            throw new Exception("Recording regression: the file is not an MP4.");
        var clip = new JsonObject
        {
            ["kind"] = "video",
            ["video"] = file,
            ["source"] = "recording",
            ["area"] = "display",
            ["target"] = "",
            ["startedAt"] = "2026-10-29T10:00:00Z",
            ["durationSeconds"] = 1.0,
            ["frames"] = new JsonArray(),
            ["pauses"] = new JsonArray(),
        };
        var trimmed = ClipTrimmer.Trim(output, clip, 0, 1.0, 2);
        string trimmedPath = trimmed["video"]?.GetValue<string>() ?? "";
        if (trimmedPath == file || !File.Exists(file) || !File.Exists(trimmedPath)) throw new Exception("Recording regression: trimming keeps the original.");
        var trimmedHeader = new byte[8];
        using (var stream = File.OpenRead(trimmedPath))
        {
            if (stream.Read(trimmedHeader, 0, 8) != 8) throw new Exception("Recording regression: the trimmed MP4 is empty.");
        }
        if (trimmedHeader[4] != (byte)'f' || trimmedHeader[5] != (byte)'t' || trimmedHeader[6] != (byte)'y' || trimmedHeader[7] != (byte)'p')
            throw new Exception("Recording regression: the trimmed file is not an MP4.");
        var outlined = RecordingOutline.FrameFor(new Rectangle(100, 200, 300, 400));
        if (outlined != new Rectangle(96, 196, 308, 408)) throw new Exception("Recording regression: the area outline sits outside the captured rectangle.");
        if (trimmed["frames"] is not JsonArray frames || frames.Count == 0) throw new Exception("Recording regression: trimming writes key frames.");
        var unchanged = new JsonObject { ["video"] = file, ["durationSeconds"] = 0.2, ["frames"] = new JsonArray(new JsonObject(), new JsonObject()) };
        if (!ReferenceEquals(ClipTrimmer.Reframe(unchanged, 2), unchanged)) throw new Exception("Recording regression: an unchanged frame count is left alone.");
        var missing = new JsonObject { ["video"] = Path.Combine(output, "no-such-recording.mp4"), ["durationSeconds"] = 1, ["frames"] = new JsonArray() };
        if (!ReferenceEquals(ClipTrimmer.Reframe(missing, 2), missing)) throw new Exception("Recording regression: a missing movie keeps its frames.");
        var source = new JsonObject { ["video"] = file, ["durationSeconds"] = 0.2, ["frames"] = new JsonArray(new JsonObject { ["screenshot"] = "placeholder" }) };
        var reframed = ClipTrimmer.Reframe(source, 2);
        if (reframed["frames"] is not JsonArray shared || shared.Count != 2) throw new Exception("Recording regression: a clip is read again for its share of the key frames.");
        var expected = ReplayMath.Offsets(0.2, 2);
        for (int index = 0; index < shared.Count; index++)
        {
            var frame = shared[index] as JsonObject ?? throw new Exception("Recording regression: a key frame is missing.");
            string? picture = frame["screenshot"]?.GetValue<string>();
            if (picture == null || !File.Exists(picture)) throw new Exception("Recording regression: the extracted key frame was not written.");
            if (Math.Abs((frame["offsetSeconds"]?.GetValue<double>() ?? -1) - Math.Round(expected[index], 1)) > 0.001)
                throw new Exception("Recording regression: key frames stay spread across the clip.");
        }
        Console.WriteLine("Windows recording regressions passed");
    }
}
