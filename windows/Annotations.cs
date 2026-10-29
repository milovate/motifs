using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace OpenCode.Appshots;

internal sealed record Vec(float X, float Y)
{
    internal PointF Point => new(X, Y);
    internal static Vec From(PointF point) => new(point.X, point.Y);
}

// All coordinates, font sizes, and widths are image pixels, never editor/window pixels.
internal sealed record Mark(string Id, string Kind, Vec[] Points, int Color, float Width, string Text = "", float FontSize = 28)
{
    internal static Mark Create(string kind, PointF point, Color color, float width, string text = "") =>
        new(Guid.NewGuid().ToString(), kind, new[] { Vec.From(point), Vec.From(point) }, color.ToArgb(), width, text);

    internal Mark Move(float dx, float dy) => this with { Points = Points.Select(p => new Vec(p.X + dx, p.Y + dy)).ToArray() };
    internal bool Equivalent(Mark other) => (this with { Points = other.Points }) == other && Points.SequenceEqual(other.Points);
    internal RectangleF Bounds()
    {
        if (Kind == "Text")
        {
            using var bitmap = new Bitmap(1, 1);
            using var graphics = Graphics.FromImage(bitmap);
            using var font = Font();
            var size = graphics.MeasureString(Text, font, 10000, StringFormat.GenericTypographic);
            return new RectangleF(Points[0].Point, new SizeF(Math.Max(8, size.Width), Math.Max(8, size.Height)));
        }
        float left = Points.Min(p => p.X), top = Points.Min(p => p.Y);
        return new RectangleF(left, top, Math.Max(1, Points.Max(p => p.X) - left), Math.Max(1, Points.Max(p => p.Y) - top));
    }

    internal Font Font() => new("Segoe UI", FontSize, FontStyle.Bold, GraphicsUnit.Pixel);

    internal PointF[] Handles()
    {
        if (Kind == "Arrow") return new[] { Points[0].Point, Points[^1].Point };
        var b = Bounds();
        return new[] { new PointF(b.Left, b.Top), new PointF(b.Right, b.Top), new PointF(b.Right, b.Bottom), new PointF(b.Left, b.Bottom) };
    }

    internal Mark Resize(int handle, PointF target)
    {
        if (Kind == "Arrow")
        {
            var points = Points.ToArray();
            points[handle == 0 ? 0 : points.Length - 1] = Vec.From(target);
            return this with { Points = points };
        }
        var b = Bounds();
        var anchor = Handles()[(handle + 2) % 4];
        // Keep positive extents and the opposite corner fixed. No accidental mirroring on crossing.
        bool left = handle == 0 || handle == 3, top = handle < 2;
        float x = left ? Math.Min(target.X, anchor.X - 2) : Math.Max(target.X, anchor.X + 2);
        float y = top ? Math.Min(target.Y, anchor.Y - 2) : Math.Max(target.Y, anchor.Y + 2);
        var next = RectangleF.FromLTRB(Math.Min(anchor.X, x), Math.Min(anchor.Y, y), Math.Max(anchor.X, x), Math.Max(anchor.Y, y));
        if (Kind == "Text")
        {
            float size = Math.Clamp(FontSize * Math.Max(next.Width / b.Width, next.Height / b.Height), 6, 400);
            var resized = this with { FontSize = size };
            var measured = resized.Bounds();
            return resized with { Points = new[] { new Vec(left ? anchor.X - measured.Width : anchor.X, top ? anchor.Y - measured.Height : anchor.Y) } };
        }
        return this with { Points = Points.Select(p => new Vec(next.Left + (p.X - b.Left) * next.Width / b.Width, next.Top + (p.Y - b.Top) * next.Height / b.Height)).ToArray() };
    }

    internal bool Hit(PointF point, float tolerance)
    {
        var bounds = Bounds();
        if (Kind == "Text") { bounds.Inflate(tolerance, tolerance); return bounds.Contains(point); }
        if (Kind == "Box")
        {
            var inner = bounds; inner.Inflate(-tolerance, -tolerance); bounds.Inflate(tolerance, tolerance);
            return bounds.Contains(point) && !inner.Contains(point);
        }
        for (int i = 1; i < Points.Length; i++)
        {
            var a = Points[i - 1]; var b = Points[i];
            float dx = b.X - a.X, dy = b.Y - a.Y;
            float t = Math.Clamp(((point.X - a.X) * dx + (point.Y - a.Y) * dy) / Math.Max(0.001f, dx * dx + dy * dy), 0, 1);
            if (MathF.Pow(point.X - a.X - t * dx, 2) + MathF.Pow(point.Y - a.Y - t * dy, 2) <= tolerance * tolerance) return true;
        }
        return false;
    }

    internal void Draw(Graphics graphics)
    {
        using var pen = new Pen(System.Drawing.Color.FromArgb(Color), Width) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        if (Kind == "Text")
        {
            using var font = Font(); using var brush = new SolidBrush(pen.Color);
            graphics.DrawString(Text, font, brush, Points[0].Point, StringFormat.GenericTypographic);
        }
        else if (Kind == "Box") { var b = Bounds(); graphics.DrawRectangle(pen, b.X, b.Y, b.Width, b.Height); }
        else if (Kind == "Arrow")
        {
            using var cap = new AdjustableArrowCap(4, 5, true);
            pen.CustomEndCap = cap;
            graphics.DrawLine(pen, Points[0].Point, Points[^1].Point);
        }
        else if (Points.Length > 1) graphics.DrawLines(pen, Points.Select(p => p.Point).ToArray());
    }
}

// Image-pixel rectangle. JSON names match the macOS crop object: x, y, width, height.
internal sealed record ImageCrop(double x, double y, double width, double height)
{
    internal RectangleF Rectangle => new((float)x, (float)y, (float)width, (float)height);
    internal Rectangle Bounds => new((int)x, (int)y, (int)width, (int)height);
}

internal sealed class AnnotationDocument
{
    internal const string CropWarning = "Cropped screenshot: original-window accessibility text is omitted so content outside the crop is not shared.";
    internal Mark[] Marks { get; private set; }
    internal ImageCrop? Crop { get; private set; }
    readonly record struct History(Mark[] Marks, ImageCrop? Crop);
    readonly Stack<History> undo = new(), redo = new();
    internal bool CanUndo => undo.Count > 0;
    internal bool CanRedo => redo.Count > 0;
    internal AnnotationDocument(Mark[]? marks = null, ImageCrop? crop = null)
    {
        Marks = marks?.ToArray() ?? Array.Empty<Mark>();
        Crop = crop;
        Validate(Marks);
    }

    // Intersection with the image, expanded to whole pixels. Null when fewer than 2×2 pixels remain.
    internal static ImageCrop? ValidCrop(RectangleF rect, Size pixels)
    {
        if (pixels.Width < 2 || pixels.Height < 2) return null;
        if (!float.IsFinite(rect.X) || !float.IsFinite(rect.Y) || !float.IsFinite(rect.Width) || !float.IsFinite(rect.Height)) return null;
        float x = rect.Width < 0 ? rect.X + rect.Width : rect.X;
        float y = rect.Height < 0 ? rect.Y + rect.Height : rect.Y;
        float left = MathF.Floor(x);
        float top = MathF.Floor(y);
        float right = MathF.Ceiling(x + Math.Abs(rect.Width));
        float bottom = MathF.Ceiling(y + Math.Abs(rect.Height));
        float x1 = Math.Max(0, left), y1 = Math.Max(0, top);
        float x2 = Math.Min(pixels.Width, right), y2 = Math.Min(pixels.Height, bottom);
        if (x2 - x1 < 2 || y2 - y1 < 2) return null;
        return new ImageCrop(x1, y1, x2 - x1, y2 - y1);
    }

    internal static void Validate(Mark[] marks)
    {
        if (marks.Length > 500 || marks.Sum(m => m.Points?.Length ?? 0) > 20000) throw new Exception("Annotation limit: 500 objects or 20000 points.");
        var ids = new HashSet<string>();
        foreach (var mark in marks)
        {
            if (mark.Id == null || !ids.Add(mark.Id) || !new[] { "Arrow", "Box", "Draw", "Text" }.Contains(mark.Kind) || mark.Points == null
                || mark.Points.Length < (mark.Kind == "Text" ? 1 : 2) || mark.Points.Any(p => p == null || !float.IsFinite(p.X) || !float.IsFinite(p.Y) || Math.Abs(p.X) > 100000 || Math.Abs(p.Y) > 100000)
                || !float.IsFinite(mark.Width) || mark.Width < 1 || mark.Width > 40 || !float.IsFinite(mark.FontSize) || mark.FontSize < 6 || mark.FontSize > 400 || mark.Text == null || mark.Text.Length > 10000)
                throw new Exception("Invalid annotation object.");
        }
    }
    internal void Commit(Mark[] marks) => CommitState(marks, Crop);
    internal void SetCrop(ImageCrop? crop) => CommitState(Marks, crop);
    void CommitState(Mark[] marks, ImageCrop? crop)
    {
        Validate(marks);
        if (marks == Marks && crop == Crop) return;
        undo.Push(new History(Marks, Crop)); redo.Clear(); Marks = marks; Crop = crop;
    }
    internal void Add(Mark mark) => Commit(Marks.Append(mark).ToArray());
    internal void Replace(Mark mark)
    {
        if (Marks.Any(m => m.Id == mark.Id && !m.Equivalent(mark))) Commit(Marks.Select(m => m.Id == mark.Id ? mark : m).ToArray());
    }
    internal void Delete(string id) => Commit(Marks.Where(m => m.Id != id).ToArray());
    internal void Undo()
    {
        if (undo.Count == 0) return;
        redo.Push(new History(Marks, Crop));
        var previous = undo.Pop();
        Marks = previous.Marks; Crop = previous.Crop;
    }
    internal void Redo()
    {
        if (redo.Count == 0) return;
        undo.Push(new History(Marks, Crop));
        var next = redo.Pop();
        Marks = next.Marks; Crop = next.Crop;
    }

    internal static Snapshot Export(Snapshot shot, AnnotationDocument document, string output)
    {
        string original = shot.originalScreenshot ?? shot.screenshot;
        Program.ValidateImage(original, output);
        using var source = Image.FromFile(original);
        using var image = Render(source, document.Marks, document.Crop);
        string file = Path.Combine(output, Guid.NewGuid() + ".png");
        var result = WithCrop(shot, document, file, source.Size);
        if (JsonSerializer.SerializeToUtf8Bytes(result, Program.Json).Length > 4_000_000) throw new Exception("Annotated capture manifest exceeds 4 MB.");
        try
        {
            image.Save(file, ImageFormat.Png);
            Program.ValidateImage(file, output);
            Program.Save(output, "latest.json", result);
        }
        catch { if (File.Exists(file)) File.Delete(file); throw; }
        return result;
    }

    // Draws marks in original image pixels, then keeps only the crop. The long side is at most 2560.
    internal static Bitmap Render(Image source, Mark[] marks, ImageCrop? crop)
    {
        Validate(marks);
        if (source.Width < 1 || source.Height < 1 || source.Width > 16_384 || source.Height > 16_384) throw new Exception("Image dimensions must be between 1 and 16384 pixels.");
        if ((long)source.Width * source.Height > 40_000_000) throw new Exception("Image exceeds 40 million pixels.");
        var viewport = new Rectangle(0, 0, source.Width, source.Height);
        if (crop != null)
        {
            var valid = ValidCrop(crop.Rectangle, source.Size) ?? throw new Exception("Crop must contain at least 2 × 2 image pixels.");
            viewport = valid.Bounds;
        }
        double scale = Math.Min(1, 2560.0 / Math.Max(viewport.Width, viewport.Height));
        int width = Math.Max(1, (int)(viewport.Width * scale));
        int height = Math.Max(1, (int)(viewport.Height * scale));
        var image = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        try
        {
            bool whole = viewport.X == 0 && viewport.Y == 0 && viewport.Width == source.Width && viewport.Height == source.Height && width == source.Width && height == source.Height;
            if (!whole && width == viewport.Width && height == viewport.Height) CopyPixels(source, image, viewport);
            using (var graphics = Graphics.FromImage(image))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                if (whole) graphics.DrawImageUnscaled(source, 0, 0);
                else if (width != viewport.Width || height != viewport.Height)
                {
                    graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    graphics.DrawImage(source, new Rectangle(0, 0, width, height), viewport, GraphicsUnit.Pixel);
                }
                graphics.TranslateTransform(-viewport.X * (float)scale, -viewport.Y * (float)scale);
                graphics.ScaleTransform((float)scale, (float)scale);
                foreach (var mark in marks) mark.Draw(graphics);
            }
            return image;
        }
        catch { image.Dispose(); throw; }
    }

    static void CopyPixels(Image source, Bitmap dest, Rectangle viewport)
    {
        using var full = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(full)) graphics.DrawImageUnscaled(source, 0, 0);
        var src = full.LockBits(new Rectangle(0, 0, full.Width, full.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var dst = dest.LockBits(new Rectangle(0, 0, dest.Width, dest.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            int rowBytes = viewport.Width * 4;
            var buffer = new byte[rowBytes];
            for (int y = 0; y < viewport.Height; y++)
            {
                Marshal.Copy(src.Scan0 + ((viewport.Y + y) * src.Stride) + (viewport.X * 4), buffer, 0, rowBytes);
                Marshal.Copy(buffer, 0, dst.Scan0 + (y * dst.Stride), rowBytes);
            }
        }
        finally { full.UnlockBits(src); dest.UnlockBits(dst); }
    }

    static Snapshot WithCrop(Snapshot shot, AnnotationDocument document, string file, Size pixels)
    {
        string original = shot.originalScreenshot ?? shot.screenshot;
        ImageCrop? crop = document.Crop == null ? null : ValidCrop(document.Crop.Rectangle, pixels) ?? throw new Exception("Crop must contain at least 2 × 2 image pixels.");
        var warnings = (shot.warnings ?? Array.Empty<string>()).Where(warning => warning != CropWarning).ToArray();
        var saved = shot with
        {
            screenshot = file,
            originalScreenshot = original,
            windowsAnnotations = document.Marks.ToArray(),
            annotatedAt = DateTimeOffset.UtcNow.ToString("O"),
            warnings = warnings,
            crop = crop,
        };
        if (crop == null) return saved with { text = shot.originalAccessibilityText ?? shot.text };
        return saved with { text = "", originalAccessibilityText = shot.originalAccessibilityText ?? shot.text, warnings = warnings.Append(CropWarning).ToArray() };
    }
}
