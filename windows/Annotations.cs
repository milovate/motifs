using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
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

internal sealed class AnnotationDocument
{
    internal Mark[] Marks { get; private set; }
    readonly Stack<Mark[]> undo = new(), redo = new();
    internal bool CanUndo => undo.Count > 0;
    internal bool CanRedo => redo.Count > 0;
    internal AnnotationDocument(Mark[]? marks = null) { Marks = marks?.ToArray() ?? Array.Empty<Mark>(); Validate(Marks); }

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
    internal void Commit(Mark[] marks)
    {
        Validate(marks);
        undo.Push(Marks); redo.Clear(); Marks = marks;
    }
    internal void Add(Mark mark) => Commit(Marks.Append(mark).ToArray());
    internal void Replace(Mark mark)
    {
        if (Marks.Any(m => m.Id == mark.Id && !m.Equivalent(mark))) Commit(Marks.Select(m => m.Id == mark.Id ? mark : m).ToArray());
    }
    internal void Delete(string id) => Commit(Marks.Where(m => m.Id != id).ToArray());
    internal void Undo() { if (undo.Count > 0) { redo.Push(Marks); Marks = undo.Pop(); } }
    internal void Redo() { if (redo.Count > 0) { undo.Push(Marks); Marks = redo.Pop(); } }

    internal static Snapshot Export(Snapshot shot, AnnotationDocument document, string output)
    {
        string original = shot.originalScreenshot ?? shot.screenshot;
        Program.ValidateImage(original, output);
        Validate(document.Marks);
        using var source = Image.FromFile(original);
        if ((long)source.Width * source.Height > 40_000_000) throw new Exception("Image exceeds 40 million pixels.");
        using var image = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(image))
        {
            graphics.DrawImageUnscaled(source, 0, 0);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            foreach (var mark in document.Marks) mark.Draw(graphics);
        }
        string file = Path.Combine(output, Guid.NewGuid() + ".png");
        var result = shot with { screenshot = file, originalScreenshot = original, windowsAnnotations = document.Marks.ToArray(), annotatedAt = DateTimeOffset.UtcNow.ToString("O") };
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
}
