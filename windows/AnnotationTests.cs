using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using Forms = System.Windows.Forms;

namespace OpenCode.Appshots;

// Uses only synthetic pixels and objects. Never captures a real window or inserts a draft.
internal static class AnnotationTests
{
    static void Check(bool condition, string message) { if (!condition) throw new Exception("Annotation regression: " + message); }
    internal static void Run(string output)
    {
        var box = Mark.Create("Box", new PointF(10, 20), Color.Red, 4) with { Points = new[] { new Vec(10, 20), new Vec(40, 50) } };
        var document = new AnnotationDocument();
        document.Add(box);
        document.Replace(box.Move(5, 10));
        Check(document.Marks[0].Points[0] == new Vec(15, 30), "move in image coordinates");
        document.Undo(); Check(document.Marks[0] == box, "undo move");
        document.Redo(); Check(document.Marks[0].Points[0].X == 15, "redo move");
        document.Undo(); document.Delete(box.Id); Check(document.Marks.Length == 0 && !document.CanRedo, "delete clears redo");
        document.Undo(); Check(document.Marks.Length == 1, "undo deletion");
        var resized = box.Resize(2, new PointF(80, 100));
        Check(resized.Bounds() == new RectangleF(10, 20, 70, 80), "resize opposite corner fixed");
        Check(box.Hit(new PointF(10, 30), 3) && !box.Hit(new PointF(25, 35), 3), "box edge hit test");
        var arrow = Mark.Create("Arrow", new PointF(5, 5), Color.Blue, 3) with { Points = new[] { new Vec(5, 5), new Vec(40, 40) } };
        Check(arrow.Resize(0, new PointF(8, 9)).Points[0] == new Vec(8, 9), "arrow endpoint resize");
        var text = Mark.Create("Text", new PointF(20, 20), Color.Red, 3, "Hello");
        var b = text.Bounds(); var bigger = text.Resize(2, new PointF(b.Right + b.Width, b.Bottom + b.Height));
        Check(bigger.FontSize > text.FontSize && bigger.Points[0] == text.Points[0], "text resize");
        var path = Mark.Create("Draw", new PointF(10, 10), Color.Green, 3) with { Points = new[] { new Vec(10, 10), new Vec(20, 30), new Vec(30, 10) } };
        Check(path.Hit(new PointF(20, 30), 2), "freehand hit test");
        Check(path.Resize(2, new PointF(50, 50)).Points[1] == new Vec(30, 50), "freehand resize");
        using (var canvas = new AnnotationCanvas(new Bitmap(200, 100), null))
        {
            canvas.Size = new Size(400, 400);
            Check(canvas.ToImage(new PointF(100, 150)) == new PointF(50, 25), "letterboxed coordinate conversion");
            canvas.Document.Add(box); canvas.Selected = box.Id;
            Check(canvas.Key(Forms.Keys.Control | Forms.Keys.D) && canvas.Document.Marks.Length == 2, "duplicate shortcut");
            canvas.Key(Forms.Keys.Shift | Forms.Keys.Right);
            Check(canvas.Selection!.Points[0].X == 32, "ten-pixel keyboard move");
            canvas.Key(Forms.Keys.Delete); canvas.Key(Forms.Keys.Control | Forms.Keys.Z);
            Check(canvas.Document.Marks.Length == 2, "undo keyboard deletion");
        }
        using (var canvas = new AnnotationCanvas(new Bitmap(200, 100), null))
        {
            canvas.Size = new Size(400, 400); canvas.Tool = "Box";
            void Mouse(string method, int x, int y) => typeof(AnnotationCanvas).GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(canvas, new object[] { new Forms.MouseEventArgs(Forms.MouseButtons.Left, 1, x, y, 0) });
            Mouse("OnMouseDown", 20, 140); Mouse("OnMouseMove", 80, 200); Mouse("OnMouseUp", 80, 200);
            Check(canvas.Document.Marks.Single().Bounds() == box.Bounds(), "mouse drawing maps through letterbox");
            Mouse("OnMouseDown", 20, 160); Mouse("OnMouseMove", 30, 180); Mouse("OnMouseUp", 30, 180);
            Check(canvas.Document.Marks.Single().Points[0] == new Vec(15, 30), "mouse drag moves selected object");
            canvas.Document.Undo(); Check(canvas.Document.Marks.Single().Points[0] == new Vec(10, 20), "one undo per mouse gesture");
            Mouse("OnMouseDown", 20, 160); Mouse("OnMouseUp", 20, 160);
            canvas.Document.Undo(); Check(canvas.Document.Marks.Length == 0, "selection click does not create undo entry");
        }
        string original = Path.Combine(output, "synthetic-original.png");
        using (var image = new Bitmap(100, 100)) { using var g = Graphics.FromImage(image); g.Clear(Color.White); image.Save(original, System.Drawing.Imaging.ImageFormat.Png); }
        byte[] before = File.ReadAllBytes(original);
        var shot = new Snapshot("Test", "Synthetic", "test-time", original, "original accessibility", Array.Empty<string>());
        var saved = AnnotationDocument.Export(shot, new AnnotationDocument(new[] { box }), output);
        Check(File.ReadAllBytes(original).SequenceEqual(before), "original image unchanged");
        Check(saved.originalScreenshot == original && saved.text == shot.text && saved.capturedAt == shot.capturedAt && saved.annotatedAt != null, "capture metadata preserved");
        using (var rendered = new Bitmap(saved.screenshot))
        {
            Check(rendered.Size == new Size(100, 100), "export dimensions");
            Check(rendered.GetPixel(10, 30).R > 200 && rendered.GetPixel(10, 30).G < 50, "annotation pixels exported");
            Check(rendered.GetPixel(70, 70).ToArgb() == Color.White.ToArgb(), "selection UI not exported");
        }
        var reopened = Program.Latest(output);
        var restored = new AnnotationDocument(reopened.windowsAnnotations);
        Check(restored.Marks[0].Points.SequenceEqual(box.Points) && !restored.CanUndo, "editable manifest round trip, fresh undo history");
        restored.Delete(box.Id);
        var cleared = AnnotationDocument.Export(reopened, restored, output);
        using (var image = new Bitmap(cleared.screenshot)) Check(image.GetPixel(10, 30).ToArgb() == Color.White.ToArgb(), "reopen uses original, does not flatten old marks");
        var parsed = JsonSerializer.Deserialize<Snapshot>(JsonSerializer.Serialize(saved, Program.Json));
        Check(parsed!.windowsAnnotations![0].Text == box.Text, "serialization contract");
        try { _ = new AnnotationDocument(new[] { box with { Width = float.NaN } }); throw new Exception("Invalid width accepted"); }
        catch (Exception e) when (e.Message == "Invalid annotation object.") { }
        Console.WriteLine("Windows annotation regressions passed");
    }
}
