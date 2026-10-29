using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace OpenCode.Appshots;

internal enum ClipMarkerKind { Click, Step, Error, Warning }

internal enum ClipReviewOutcome { Keep, Remove, Replace }

internal readonly struct ClipMarker
{
    internal double Time { get; }
    internal ClipMarkerKind Kind { get; }
    internal string Label { get; }
    internal string Title => ClipReviewMath.KindName(Kind) + " · " + ContextReview.ClipTime(Time);
    internal ClipMarker(double time, ClipMarkerKind kind, string label)
    {
        Time = time;
        Kind = kind;
        Label = label;
    }
}

// Marker placement, the selection label, and the pause shift. The macOS review
// uses the same rules; the Windows tests lock them without opening a window.
internal static class ClipReviewMath
{
    internal const int Inset = 14;
    internal const int FilmstripCount = 14;

    internal static string KindName(ClipMarkerKind kind) => kind switch
    {
        ClipMarkerKind.Click => "Click",
        ClipMarkerKind.Step => "Step",
        ClipMarkerKind.Error => "Error",
        ClipMarkerKind.Warning => "Warning",
        _ => throw new InvalidOperationException("Unknown marker."),
    };

    internal static Color KindColor(ClipMarkerKind kind) => kind switch
    {
        ClipMarkerKind.Click => Color.FromArgb(10, 132, 255),
        ClipMarkerKind.Step => Color.MediumPurple,
        ClipMarkerKind.Error => Color.OrangeRed,
        ClipMarkerKind.Warning => Color.Orange,
        _ => throw new InvalidOperationException("Unknown marker."),
    };

    internal static bool IsTrimmed(double trimIn, double trimOut, double duration) => trimIn > 0.05 || trimOut < duration - 0.05;

    internal static string SelectionLabel(double trimIn, double trimOut, double duration) =>
        ContextReview.ClipTime(trimIn) + " in · " + ContextReview.ClipTime(Math.Max(0, trimOut - trimIn)) + " selected of " + ContextReview.ClipTime(duration) + " · " + ContextReview.ClipTime(trimOut) + " out";

    internal static double MoveIn(double value, double trimOut) => Math.Max(0, Math.Min(value, trimOut - 0.5));
    internal static double MoveOut(double value, double trimIn, double duration) => Math.Min(duration, Math.Max(value, trimIn + 0.5));

    internal static double X(double time, double duration, int width)
    {
        double span = Math.Max(duration, 0.1);
        return Inset + (time / span) * Math.Max(0, width - (Inset * 2));
    }

    internal static double TimeAt(double x, double duration, int width)
    {
        double inner = Math.Max(1, width - (Inset * 2));
        return Math.Min(duration, Math.Max(0, ((x - Inset) / inner) * duration));
    }

    internal static ClipMarker? MarkerNear(IReadOnlyList<ClipMarker> markers, double point, double duration, int width)
    {
        ClipMarker? best = null;
        double gap = 7;
        foreach (var marker in markers)
        {
            double distance = Math.Abs(X(marker.Time, duration, width) - point);
            if (distance <= 6 && distance < gap) { gap = distance; best = marker; }
        }
        return best;
    }

    internal static List<ClipMarker> Markers(JsonObject video, JsonObject context)
    {
        var markers = new List<ClipMarker>();
        foreach (var entry in Entries(context, "events"))
        {
            if (Text(entry, "kind") == "app-switch" || !TryWhen(entry, video, out double time)) continue;
            markers.Add(new ClipMarker(time, Text(entry, "kind") == "click" ? ClipMarkerKind.Click : ClipMarkerKind.Step, ContextReview.Describe(entry)));
        }
        foreach (var entry in Entries(context, "console"))
        {
            string level = (Text(entry, "level") ?? "").ToLowerInvariant();
            ClipMarkerKind? kind = level is "error" or "fault" ? ClipMarkerKind.Error : level.StartsWith("warn", StringComparison.Ordinal) ? ClipMarkerKind.Warning : null;
            if (kind is not ClipMarkerKind marker || !TryWhen(entry, video, out double time)) continue;
            string message = Text(entry, "message") ?? level;
            markers.Add(new ClipMarker(time, marker, message.Length <= 120 ? message : message[..120]));
        }
        foreach (var entry in Entries(context, "network"))
        {
            if (!TryWhen(entry, video, out double time)) continue;
            string path = Route(Text(entry, "url") ?? "");
            if (path.Length > 100) path = path[..100];
            markers.Add(new ClipMarker(time, ClipMarkerKind.Error, (Text(entry, "method") ?? "GET") + " " + Status(entry) + " " + path));
        }
        markers.Sort((left, right) => left.Time.CompareTo(right.Time));
        return markers;
    }

    // The new clip starts later by the selection plus any pause that ended before it.
    // Pauses that fall inside the selection stay, measured from the new start.
    internal static JsonObject Describe(JsonObject video, double start, double end)
    {
        if (end - start < 0.5) throw new InvalidOperationException("Select at least half a second.");
        var copy = ComposerFiles.Clone(video);
        double skipped = 0;
        var kept = new JsonArray();
        if (video["pauses"] is JsonArray pauses)
        {
            foreach (var pause in pauses.OfType<JsonObject>().OrderBy(item => Number(item, "atSeconds") ?? 0))
            {
                double at = Number(pause, "atSeconds") ?? 0;
                double span = Number(pause, "durationSeconds") ?? 0;
                if (at <= start) skipped += span;
                else if (at < end) kept.Add(new JsonObject { ["atSeconds"] = Round(at - start), ["durationSeconds"] = Round(span) });
            }
        }
        if (Text(video, "startedAt") is string started && DateTimeOffset.TryParse(started, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var began))
            copy["startedAt"] = ComposerFiles.Iso(began.AddSeconds(start + skipped));
        copy["durationSeconds"] = Round(end - start);
        copy["pauses"] = kept;
        return copy;
    }

    static bool TryWhen(JsonObject entry, JsonObject video, out double time)
    {
        time = 0;
        if (Text(entry, "time") is not string text || !DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var moment)) return false;
        if (ContextReview.Offset(moment, video) is not double offset) return false;
        time = offset;
        return true;
    }

    static List<JsonObject> Entries(JsonObject context, string key) =>
        context[key] is JsonObject group && group["entries"] is JsonArray entries ? entries.OfType<JsonObject>().ToList() : new List<JsonObject>();

    static string? Text(JsonObject entry, string key) => entry[key] is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    static double? Number(JsonObject entry, string key)
    {
        if (entry[key] is not JsonValue value) return null;
        if (value.TryGetValue(out double real)) return real;
        if (value.TryGetValue(out int number)) return number;
        if (value.TryGetValue(out long wide)) return wide;
        return null;
    }

    static string Status(JsonObject entry)
    {
        if (entry["status"] is JsonValue value)
        {
            if (value.TryGetValue(out int number)) return number.ToString(CultureInfo.InvariantCulture);
            if (value.TryGetValue(out long wide)) return wide.ToString(CultureInfo.InvariantCulture);
            if (value.TryGetValue(out double real)) return real.ToString(CultureInfo.InvariantCulture);
            if (value.TryGetValue(out string text) && text.Length > 0) return text;
        }
        return Text(entry, "error") is string message && message.Length > 0 ? message : "failed";
    }

    static string Route(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var parsed)) return parsed.AbsolutePath.Length == 0 ? "/" : parsed.AbsolutePath;
        return url.Length == 0 ? "/" : url;
    }

    static double Round(double value) => Math.Round(value, 1, MidpointRounding.AwayFromZero);
}

// Decodes H.264 to RGB32. Slot numbers live on MediaFoundation and follow the IDL.
internal sealed class FrameReader : IDisposable
{
    nint reader;
    int width;
    int height;
    int stride;
    bool released;
    internal int Width => width;
    internal int Height => height;

    internal FrameReader(string path)
    {
        MediaFoundation.Startup();
        try { Open(path); }
        catch { Dispose(); throw; }
    }

    void Open(string path)
    {
        nint attributes = MediaFoundation.Attributes();
        try
        {
            MediaFoundation.SetUint32(attributes, MediaFoundation.EnableVideoProcessing, 1);
            reader = MediaFoundation.SourceReader(path, attributes);
        }
        finally { MediaFoundation.Release(attributes); }
        nint type = MediaFoundation.MediaType();
        try
        {
            MediaFoundation.SetGuid(type, MediaFoundation.MajorType, MediaFoundation.Video);
            MediaFoundation.SetGuid(type, MediaFoundation.Subtype, MediaFoundation.Rgb32);
            MediaFoundation.SetReaderType(reader, type);
        }
        finally { MediaFoundation.Release(type); }
        ReadFormat();
    }

    void ReadFormat()
    {
        nint type = MediaFoundation.ReaderType(reader);
        try
        {
            ulong size = MediaFoundation.GetUint64(type, MediaFoundation.FrameSize);
            width = (int)(size >> 32);
            height = (int)(size & 0xffffffff);
            stride = MediaFoundation.TryGetInt32(type, MediaFoundation.DefaultStride, out int stored) && stored != 0 ? stored : width * 4;
        }
        finally { MediaFoundation.Release(type); }
        if (width < 2 || height < 2) throw new InvalidOperationException("This recording cannot be trimmed.");
    }

    internal Bitmap? ReadAt(double seconds)
    {
        MediaFoundation.SetPosition(reader, (long)(Math.Max(0, seconds) * 10_000_000));
        for (int attempt = 0; attempt < 8; attempt++)
        {
            MediaFoundation.ReadSample(reader, out uint flags, out _, out nint sample);
            if ((flags & 0x20) != 0) ReadFormat();
            if (sample != 0) return Take(sample);
            if ((flags & 0x3) != 0) return null;
        }
        return null;
    }

    internal void ReadRange(double start, double end, Action<double, Bitmap> consume)
    {
        long startTick = (long)(Math.Max(0, start) * 10_000_000);
        long endTick = (long)(Math.Max(start, end) * 10_000_000);
        long frameDuration = 10_000_000L / ReplayMath.FramesPerSecond;
        MediaFoundation.SetPosition(reader, startTick);
        for (int guard = 0; guard < 20_000; guard++)
        {
            MediaFoundation.ReadSample(reader, out uint flags, out long timestamp, out nint sample);
            if ((flags & 0x20) != 0) ReadFormat();
            if ((flags & 0x1) != 0) { MediaFoundation.Release(sample); throw new InvalidOperationException("Could not trim the recording."); }
            if (sample == 0)
            {
                if ((flags & 0x2) != 0) return;
                continue;
            }
            if (timestamp >= endTick) { MediaFoundation.Release(sample); return; }
            if (timestamp + frameDuration < startTick) { MediaFoundation.Release(sample); continue; }
            Bitmap? bitmap = Take(sample);
            if (bitmap == null) continue;
            try { consume(Math.Max(0, (timestamp - startTick) / 10_000_000d), bitmap); }
            finally { bitmap.Dispose(); }
        }
    }

    Bitmap? Take(nint sample)
    {
        nint buffer = 0;
        bool locked = false;
        try
        {
            buffer = MediaFoundation.ContiguousBuffer(sample);
            int length = MediaFoundation.CurrentLength(buffer);
            if (length <= 0) return null;
            nint data = MediaFoundation.Lock(buffer);
            locked = true;
            var pixels = new byte[length];
            Marshal.Copy(data, pixels, 0, length);
            MediaFoundation.Unlock(buffer);
            locked = false;
            return ImageFrom(pixels);
        }
        finally
        {
            if (locked) MediaFoundation.Unlock(buffer);
            MediaFoundation.Release(buffer);
            MediaFoundation.Release(sample);
        }
    }

    Bitmap ImageFrom(byte[] pixels)
    {
        int evenWidth = Math.Max(2, width & ~1);
        int evenHeight = Math.Max(2, height & ~1);
        var bitmap = new Bitmap(evenWidth, evenHeight, PixelFormat.Format32bppArgb);
        var bits = bitmap.LockBits(new Rectangle(0, 0, evenWidth, evenHeight), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            int row = evenWidth * 4;
            int abs = Math.Max(row, Math.Abs(stride));
            bool bottomUp = stride < 0;
            for (int y = 0; y < evenHeight; y++)
            {
                int sourceY = bottomUp ? height - 1 - y : y;
                int source = sourceY * abs;
                if (source < 0 || source + row > pixels.Length) continue;
                for (int channel = source + 3; channel < source + row; channel += 4) pixels[channel] = 255;
                Marshal.Copy(pixels, source, bits.Scan0 + (y * bits.Stride), row);
            }
        }
        finally { bitmap.UnlockBits(bits); }
        return bitmap;
    }

    public void Dispose()
    {
        if (released) return;
        released = true;
        MediaFoundation.Release(reader);
        reader = 0;
        MediaFoundation.Shutdown();
    }
}

internal static class ClipTrimmer
{
    internal static JsonObject Trim(string output, JsonObject video, double start, double end, int frameCount)
    {
        var described = ClipReviewMath.Describe(video, start, end);
        string? source = video["video"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(source) || !File.Exists(source)) throw new InvalidOperationException("This recording cannot be trimmed.");
        string folder = Path.GetDirectoryName(source) ?? output;
        string kind = video["source"]?.GetValue<string>() == "replay" ? "replay" : "recording";
        string stem = kind + "-" + Guid.NewGuid().ToString("D");
        string movie = Path.Combine(folder, stem + ".mp4");
        var shelf = new KeyShelf();
        int written = 0;
        double last = 0;
        try
        {
            using var decoder = new FrameReader(source);
            using var writer = new Mp4Writer(movie, Math.Max(2, decoder.Width & ~1), Math.Max(2, decoder.Height & ~1), ReplayMath.FramesPerSecond);
            decoder.ReadRange(start, end, (time, bitmap) =>
            {
                writer.Write(bitmap, (long)(time * 10_000_000));
                shelf.Add(bitmap, time);
                last = time;
                written++;
            });
            if (written == 0) throw new InvalidOperationException("Could not trim the recording.");
            writer.Finish();
            double span = written < 2 ? 1.0 / ReplayMath.FramesPerSecond : last + (1.0 / ReplayMath.FramesPerSecond);
            double duration = Math.Min(end - start, Math.Round(span, 1, MidpointRounding.AwayFromZero));
            described["video"] = movie;
            described["durationSeconds"] = Math.Max(0.1, duration);
            described["frames"] = shelf.Export(folder, stem, Math.Max(duration, 0.1), frameCount);
            return described;
        }
        catch
        {
            try { File.Delete(movie); } catch { /* The failed trim leaves the original clip. */ }
            if (Directory.Exists(folder))
                foreach (string frame in Directory.GetFiles(folder, stem + "-frame-*.png"))
                    try { File.Delete(frame); } catch { /* The frame file is already gone. */ }
            throw;
        }
    }
}

// Filmstrip, yellow handles, and the dots for clicks, steps, errors, and warnings.
internal sealed class ClipTimeline : Control
{
    readonly List<Image> frames = new();
    readonly List<ClipMarker> markers = new();
    enum Drag { None, TrimIn, TrimOut, Playhead }
    Drag drag;
    ClipMarker? hovered;
    internal double Duration { get; private set; } = 1;
    internal double TrimIn { get; private set; }
    internal double TrimOut { get; private set; } = 1;
    internal double Playhead { get; set; }
    internal event Action? TrimChanged;
    internal event Action<double>? Seeked;

    internal ClipTimeline()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = 70;
        TabStop = true;
        AccessibleName = "Clip timeline. Drag the yellow handles to trim. I and O set the in and out points, Space plays or pauses.";
    }

    internal void Load(double duration, IReadOnlyList<ClipMarker> marks)
    {
        Duration = Math.Max(0.1, duration);
        TrimIn = 0;
        TrimOut = Duration;
        Playhead = 0;
        markers.Clear();
        markers.AddRange(marks);
        AccessibleDescription = markers.Count == 0 ? "No steps, errors or warnings during this clip." : string.Join("\n", markers.Select(marker => marker.Title + ": " + marker.Label));
        Invalidate();
    }

    internal void SetFrames(IReadOnlyList<Image> images)
    {
        foreach (var frame in frames) frame.Dispose();
        frames.Clear();
        frames.AddRange(images);
        Invalidate();
    }

    internal void SetTrim(double trimIn, double trimOut)
    {
        double nextOut = ClipReviewMath.MoveOut(trimOut, trimIn, Duration);
        TrimIn = ClipReviewMath.MoveIn(trimIn, nextOut);
        TrimOut = nextOut;
        Invalidate();
        TrimChanged?.Invoke();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var graphics = e.Graphics;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var strip = new Rectangle(ClipReviewMath.Inset, 2, Math.Max(1, Width - (ClipReviewMath.Inset * 2)), Math.Max(1, Height - 22));
        using var stripClip = Rounded(strip, 6);
        graphics.SetClip(stripClip);
        using (var wash = new SolidBrush(Color.FromArgb(30, 255, 255, 255))) graphics.FillRectangle(wash, strip);
        if (frames.Count > 0)
        {
            float cell = strip.Width / (float)frames.Count;
            for (int index = 0; index < frames.Count; index++)
            {
                var target = new RectangleF(strip.X + (index * cell), strip.Y, cell, strip.Height);
                var image = frames[index];
                float scale = Math.Max(target.Width / Math.Max(1, image.Width), target.Height / Math.Max(1, image.Height));
                float drawnWidth = image.Width * scale;
                float drawnHeight = image.Height * scale;
                graphics.SetClip(target);
                graphics.DrawImage(image, target.X + ((target.Width - drawnWidth) / 2), target.Y + ((target.Height - drawnHeight) / 2), drawnWidth, drawnHeight);
            }
            graphics.SetClip(stripClip);
        }
        using (var dim = new SolidBrush(Color.FromArgb(140, 0, 0, 0)))
        {
            graphics.FillRectangle(dim, strip.X, strip.Y, Math.Max(0, (float)X(TrimIn) - strip.X), strip.Height);
            graphics.FillRectangle(dim, (float)X(TrimOut), strip.Y, Math.Max(0, strip.Right - (float)X(TrimOut)), strip.Height);
        }
        graphics.ResetClip();
        const int handle = 11;
        float left = (float)X(TrimIn) - handle;
        float right = (float)X(TrimOut) + handle;
        var selection = new RectangleF(left, strip.Y - 2, Math.Max(handle * 2, right - left), strip.Height + 4);
        using (var outline = Rounded(Rectangle.Round(selection), 6))
        using (var pen = new Pen(Color.Gold, 3)) graphics.DrawPath(pen, outline);
        for (int side = 0; side < 2; side++)
        {
            bool start = side == 0;
            var grip = new RectangleF(start ? selection.X : selection.Right - handle, selection.Y, handle, selection.Height);
            using var brush = new SolidBrush(Color.Gold);
            using var gripShape = Rounded(Rectangle.Round(grip), 4);
            graphics.FillPath(brush, gripShape);
            using var chevron = new Pen(Color.FromArgb(160, 0, 0, 0), 2) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            float mid = grip.X + (grip.Width / 2);
            float y = grip.Y + (grip.Height / 2);
            float direction = start ? -1.5f : 1.5f;
            graphics.DrawLines(chevron, new[] { new PointF(mid - direction, y - 5), new PointF(mid + direction, y), new PointF(mid - direction, y + 5) });
        }
        foreach (var marker in markers)
        {
            float size = hovered is ClipMarker over && over.Time == marker.Time && over.Kind == marker.Kind ? 10 : 7;
            using var brush = new SolidBrush(ClipReviewMath.KindColor(marker.Kind));
            graphics.FillEllipse(brush, (float)X(marker.Time) - (size / 2), Height - 12 - (size / 2), size, size);
        }
        float head = (float)X(Playhead);
        using (var shadow = new SolidBrush(Color.FromArgb(90, 0, 0, 0))) graphics.FillRectangle(shadow, head - 2, strip.Y - 3, 4, strip.Height + 6);
        using (var white = new SolidBrush(Color.White)) graphics.FillRectangle(white, head - 1, strip.Y - 3, 2, strip.Height + 6);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        Focus();
        hovered = null;
        const int handle = 11;
        if (e.X >= X(TrimIn) - handle - 2 && e.X <= X(TrimIn) + 3) drag = Drag.TrimIn;
        else if (e.X >= X(TrimOut) - 3 && e.X <= X(TrimOut) + handle + 2) drag = Drag.TrimOut;
        else drag = Drag.Playhead;
        Apply(e.X);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (drag != Drag.None) { Apply(e.X); return; }
        var next = ClipReviewMath.MarkerNear(markers, e.X, Duration, Width);
        if (next?.Time == hovered?.Time && next?.Kind == hovered?.Kind) return;
        hovered = next;
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        drag = Drag.None;
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (drag != Drag.None || hovered == null) return;
        hovered = null;
        Invalidate();
    }

    void Apply(int x)
    {
        double value = ClipReviewMath.TimeAt(x, Duration, Width);
        switch (drag)
        {
            case Drag.TrimIn:
                TrimIn = ClipReviewMath.MoveIn(value, TrimOut);
                Playhead = TrimIn;
                TrimChanged?.Invoke();
                Seeked?.Invoke(TrimIn);
                break;
            case Drag.TrimOut:
                TrimOut = ClipReviewMath.MoveOut(value, TrimIn, Duration);
                Playhead = TrimOut;
                TrimChanged?.Invoke();
                Seeked?.Invoke(TrimOut);
                break;
            case Drag.Playhead:
                Playhead = value;
                Seeked?.Invoke(value);
                break;
            case Drag.None:
                break;
            default:
                throw new InvalidOperationException("Unknown trim drag.");
        }
        Invalidate();
    }

    double X(double time) => ClipReviewMath.X(time, Duration, Width);

    static GraphicsPath Rounded(Rectangle bounds, int radius)
    {
        int diameter = Math.Min(Math.Max(1, radius * 2), Math.Max(1, Math.Min(bounds.Width, bounds.Height)));
        var path = new GraphicsPath();
        path.AddArc(bounds.X, bounds.Y, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Y, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) foreach (var frame in frames) frame.Dispose();
        base.Dispose(disposing);
    }
}

internal sealed class ClipReviewForm : Form
{
    readonly string output;
    readonly JsonObject video;
    readonly string videoPath;
    readonly int frameCount;
    readonly double duration;
    readonly ClipTimeline timeline = new();
    readonly Label selection = new() { AutoSize = true, ForeColor = Color.FromArgb(180, 180, 184) };
    readonly Label status = new() { AutoSize = true, ForeColor = Color.FromArgb(180, 180, 184), MaximumSize = new Size(280, 0) };
    readonly Button removeButton = new() { Text = "Remove clip", AutoSize = true };
    readonly Button cancelButton = new() { Text = "Cancel", AutoSize = true };
    readonly Button useButton = new() { Text = "Use clip", AutoSize = true };
    readonly ToolTip hover = new();
    readonly Timer clock = new() { Interval = 50 };
    System.Windows.Controls.MediaElement? player;
    bool playing;
    bool playbackFailed;
    bool trimming;
    bool finished;
    volatile bool closed;

    internal ClipReviewOutcome Outcome { get; private set; } = ClipReviewOutcome.Keep;
    internal JsonObject? Replacement { get; private set; }

    internal ClipReviewForm(string output, JsonObject video, JsonObject context, int frameCount)
    {
        this.output = output;
        this.video = video;
        this.frameCount = frameCount;
        videoPath = video["video"]?.GetValue<string>() ?? "";
        duration = DurationOf(video);
        string label = video["source"]?.GetValue<string>() == "recording" ? "Screen recording" : "Instant replay";
        string target = video["target"]?.GetValue<string>() ?? "";
        var markers = ClipReviewMath.Markers(video, context);
        Text = "Review clip · " + label;
        FormBorderStyle = FormBorderStyle.Sizable;
        StartPosition = FormStartPosition.CenterParent;
        MinimumSize = new Size(560, 420);
        ClientSize = new Size(780, 560);
        BackColor = Color.FromArgb(32, 32, 34);
        ForeColor = Color.White;
        Font = new Font("Segoe UI", 10);
        KeyPreview = true;
        var heading = new Label { Text = label + (target.Length == 0 ? "" : " · " + target), AutoSize = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Font = new Font("Segoe UI", 11, FontStyle.Bold) };
        var close = new Button { Text = "×", Dock = DockStyle.Right, Width = 32 };
        close.AccessibleName = "Close without changes";
        close.Click += (_, _) => { if (!trimming) Finish(ClipReviewOutcome.Keep); };
        var header = new Panel { Height = 32, Dock = DockStyle.Top };
        header.Controls.Add(heading);
        header.Controls.Add(close);
        var playerHost = MakePlayer();
        playerHost.Dock = DockStyle.Fill;
        timeline.Load(duration, markers);
        timeline.Dock = DockStyle.Bottom;
        timeline.TrimChanged += RefreshSelection;
        timeline.Seeked += Seek;
        timeline.MouseMove += (_, args) =>
        {
            var marker = ClipReviewMath.MarkerNear(markers, args.X, timeline.Duration, timeline.Width);
            hover.SetToolTip(timeline, marker is ClipMarker found ? found.Title + "\n" + found.Label : "Drag the yellow handles to trim · I / O set in and out · ← → step · Space play/pause");
        };
        var legend = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Dock = DockStyle.Right };
        foreach (ClipMarkerKind kind in new[] { ClipMarkerKind.Click, ClipMarkerKind.Step, ClipMarkerKind.Error, ClipMarkerKind.Warning })
        {
            int count = markers.Count(marker => marker.Kind == kind);
            legend.Controls.Add(new Label { Text = "● " + ClipReviewMath.KindName(kind) + " " + count.ToString(CultureInfo.InvariantCulture), AutoSize = true, ForeColor = ClipReviewMath.KindColor(kind), Margin = new Padding(12, 6, 0, 0) });
        }
        var info = new Panel { Height = 28, Dock = DockStyle.Bottom };
        selection.Dock = DockStyle.Left;
        info.Controls.Add(legend);
        info.Controls.Add(selection);
        Style(removeButton);
        Style(cancelButton);
        Style(useButton);
        useButton.BackColor = Color.FromArgb(232, 232, 234);
        useButton.ForeColor = Color.FromArgb(20, 20, 20);
        removeButton.Click += (_, _) => Finish(ClipReviewOutcome.Remove);
        removeButton.AccessibleName = "Remove this clip from the capture. The MP4 stays in the captures folder.";
        cancelButton.Click += (_, _) => Finish(ClipReviewOutcome.Keep);
        useButton.Click += (_, _) => Use();
        AcceptButton = useButton;
        CancelButton = cancelButton;
        var buttons = new FlowLayoutPanel { Height = 40, Dock = DockStyle.Bottom, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Padding = new Padding(0, 6, 0, 0) };
        status.Margin = new Padding(12, 8, 0, 0);
        buttons.Controls.Add(removeButton);
        buttons.Controls.Add(status);
        buttons.Controls.Add(cancelButton);
        buttons.Controls.Add(useButton);
        var body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(18, 8, 18, 12) };
        body.Controls.Add(playerHost);
        body.Controls.Add(timeline);
        body.Controls.Add(info);
        body.Controls.Add(buttons);
        Controls.Add(body);
        Controls.Add(header);
        clock.Tick += (_, _) => SyncPlayhead();
        clock.Start();
        RefreshSelection();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.ExcludeFromCapture(Handle);
    }

    Control MakePlayer()
    {
        try
        {
            var element = new System.Windows.Controls.MediaElement
            {
                LoadedBehavior = System.Windows.Controls.MediaState.Manual,
                UnloadedBehavior = System.Windows.Controls.MediaState.Manual,
                ScrubbingEnabled = true,
                Stretch = System.Windows.Media.Stretch.Uniform,
            };
            element.MediaFailed += (_, args) => { playbackFailed = true; status.Text = args.ErrorException?.Message ?? "Playback is unavailable. The trim handles still work."; };
            if (File.Exists(videoPath)) element.Source = new Uri(videoPath);
            else { playbackFailed = true; status.Text = "This recording cannot be trimmed."; }
            player = element;
            return new System.Windows.Forms.Integration.ElementHost { Child = element, BackColor = Color.Black };
        }
        catch (Exception error)
        {
            playbackFailed = true;
            status.Text = error.Message;
            return new Panel { BackColor = Color.Black };
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        string path = videoPath;
        double span = duration;
        _ = Task.Run(() =>
        {
            var images = new List<Image>();
            try
            {
                if (!File.Exists(path)) return;
                using var reader = new FrameReader(path);
                for (int index = 0; index < ClipReviewMath.FilmstripCount; index++)
                {
                    if (closed) return;
                    using var frame = reader.ReadAt(span * (index + 0.5) / ClipReviewMath.FilmstripCount);
                    if (frame == null) break;
                    images.Add(Fit(frame, 240, 150));
                }
            }
            catch { /* The strip stays empty and trimming still uses the file. */ }
            try
            {
                BeginInvoke(new Action(() =>
                {
                    if (closed) { foreach (var image in images) image.Dispose(); return; }
                    timeline.SetFrames(images);
                }));
            }
            catch { foreach (var image in images) image.Dispose(); }
        });
    }

    void RefreshSelection()
    {
        selection.Text = ClipReviewMath.SelectionLabel(timeline.TrimIn, timeline.TrimOut, duration);
        bool trimmed = ClipReviewMath.IsTrimmed(timeline.TrimIn, timeline.TrimOut, duration);
        useButton.Text = trimmed ? "Use trimmed clip" : "Use clip";
        useButton.AccessibleName = (trimmed ? "Save the selection as a new clip and take key frames from it" : "Keep the whole clip") + " (Enter)";
    }

    void Seek(double seconds)
    {
        timeline.Playhead = Math.Min(duration, Math.Max(0, seconds));
        timeline.Invalidate();
        if (player == null || playbackFailed) return;
        try { player.Position = TimeSpan.FromSeconds(timeline.Playhead); }
        catch { playbackFailed = true; }
    }

    void TogglePlayback()
    {
        if (player == null || playbackFailed) { Seek(Math.Min(duration, timeline.Playhead + 0.5)); return; }
        try
        {
            if (playing) { player.Pause(); playing = false; return; }
            if (timeline.Playhead >= timeline.TrimOut - 0.05 || timeline.Playhead < timeline.TrimIn) Seek(timeline.TrimIn);
            player.Play();
            playing = true;
        }
        catch (Exception error) { playbackFailed = true; status.Text = error.Message; }
    }

    void SyncPlayhead()
    {
        if (!playing || player == null || playbackFailed) return;
        try
        {
            double now = player.Position.TotalSeconds;
            timeline.Playhead = now;
            timeline.Invalidate();
            if (now >= timeline.TrimOut) { player.Pause(); playing = false; Seek(timeline.TrimIn); }
        }
        catch { playbackFailed = true; playing = false; }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        switch (e.KeyCode)
        {
            case Keys.I:
                timeline.SetTrim(ClipReviewMath.MoveIn(timeline.Playhead, timeline.TrimOut), timeline.TrimOut);
                Seek(timeline.TrimIn);
                e.Handled = true;
                e.SuppressKeyPress = true;
                break;
            case Keys.O:
                timeline.SetTrim(timeline.TrimIn, ClipReviewMath.MoveOut(timeline.Playhead, timeline.TrimIn, duration));
                Seek(timeline.TrimOut);
                e.Handled = true;
                e.SuppressKeyPress = true;
                break;
            case Keys.Space:
                TogglePlayback();
                e.Handled = true;
                e.SuppressKeyPress = true;
                break;
            case Keys.Left:
                Seek(Math.Max(0, timeline.Playhead - 0.5));
                e.Handled = true;
                break;
            case Keys.Right:
                Seek(Math.Min(duration, timeline.Playhead + 0.5));
                e.Handled = true;
                break;
            default:
                break;
        }
    }

    void Use()
    {
        if (!ClipReviewMath.IsTrimmed(timeline.TrimIn, timeline.TrimOut, duration)) { Finish(ClipReviewOutcome.Keep); return; }
        trimming = true;
        removeButton.Enabled = false;
        cancelButton.Enabled = false;
        useButton.Enabled = false;
        status.Text = "Trimming…";
        if (playing) { try { player?.Pause(); } catch { /* Playback can stop while the file is copied. */ } playing = false; }
        double start = timeline.TrimIn;
        double end = timeline.TrimOut;
        var source = video;
        int frames = frameCount;
        string folder = output;
        _ = Task.Run(() => ClipTrimmer.Trim(folder, source, start, end, frames)).ContinueWith(task =>
        {
            try
            {
                BeginInvoke(new Action(() =>
                {
                    trimming = false;
                    if (closed) return;
                    if (task.IsFaulted)
                    {
                        status.Text = task.Exception?.GetBaseException().Message ?? "Could not trim the recording.";
                        removeButton.Enabled = true;
                        cancelButton.Enabled = true;
                        useButton.Enabled = true;
                        return;
                    }
                    Replacement = task.Result;
                    Finish(ClipReviewOutcome.Replace);
                }));
            }
            catch { /* The window closed before the trim finished. The original clip stays attached. */ }
        });
    }

    void Finish(ClipReviewOutcome outcome)
    {
        if (finished) return;
        finished = true;
        Outcome = outcome;
        closed = true;
        clock.Stop();
        try { player?.Stop(); player?.Close(); } catch { /* The player is already gone. */ }
        DialogResult = DialogResult.OK;
        Close();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (trimming) { e.Cancel = true; return; }
        if (!finished) { finished = true; Outcome = ClipReviewOutcome.Keep; closed = true; }
        base.OnFormClosing(e);
    }

    static double DurationOf(JsonObject video)
    {
        if (video["durationSeconds"] is JsonValue value)
        {
            if (value.TryGetValue(out double seconds)) return Math.Max(0.1, seconds);
            if (value.TryGetValue(out int whole)) return Math.Max(0.1, whole);
        }
        return 0.1;
    }

    static void Style(Button button)
    {
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderColor = Color.FromArgb(80, 80, 84);
        button.BackColor = Color.FromArgb(48, 48, 52);
        button.ForeColor = Color.White;
        button.Margin = new Padding(0, 4, 8, 0);
    }

    static Bitmap Fit(Bitmap source, int maxWidth, int maxHeight)
    {
        double scale = Math.Min(1, Math.Min(maxWidth / (double)source.Width, maxHeight / (double)source.Height));
        int width = Math.Max(1, (int)Math.Round(source.Width * scale));
        int height = Math.Max(1, (int)Math.Round(source.Height * scale));
        var image = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(image);
        graphics.DrawImage(source, new Rectangle(0, 0, width, height));
        return image;
    }
}
