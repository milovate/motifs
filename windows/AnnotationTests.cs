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
            Check(canvas.Tool == "Box" && canvas.Selected == null, "drawing tools stay active and new marks stay unselected");
            canvas.Tool = "Select";
            Mouse("OnMouseDown", 20, 160); Mouse("OnMouseMove", 30, 180); Mouse("OnMouseUp", 30, 180);
            Check(canvas.Document.Marks.Single().Points[0] == new Vec(15, 30), "mouse drag moves selected object");
            canvas.Document.Undo(); Check(canvas.Document.Marks.Single().Points[0] == new Vec(10, 20), "one undo per mouse gesture");
            Mouse("OnMouseDown", 20, 160); Mouse("OnMouseUp", 20, 160);
            canvas.Document.Undo(); Check(canvas.Document.Marks.Length == 0, "selection click does not create undo entry");
        }
        using (var canvas = new AnnotationCanvas(new Bitmap(200, 100), null))
        {
            canvas.Size = new Size(400, 400);
            canvas.Tool = "Text";
            void Mouse(string method, int x, int y) => typeof(AnnotationCanvas).GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(canvas, new object[] { new Forms.MouseEventArgs(Forms.MouseButtons.Left, 1, x, y, 0) });
            bool copied = false;
            canvas.CopyRequested += () => copied = true;
            Mouse("OnMouseDown", 40, 160);
            Check(canvas.IsEditing && canvas.InlineEditor != null && canvas.Tool == "Text", "text starts in an inline editor");
            Check(canvas.InlineEditor!.AcceptsReturn && canvas.InlineEditor.MaxLength == 10000, "inline text accepts a newline and the annotation limit");
            canvas.InlineEditor.Text = "Hello";
            Check(canvas.Key(Forms.Keys.Enter) && !canvas.IsEditing, "enter commits inline text");
            Check(canvas.Document.Marks.Length == 1 && canvas.Document.Marks[0].Text == "Hello" && canvas.Document.Marks[0].FontSize == 22, "inline text commits into image-space markup");
            Check(canvas.Tool == "Text" && canvas.Selected == null, "Text remains active and the new label stays unselected");
            var committed = canvas.Document.Marks[0];
            Mouse("OnMouseDown", 80, 180);
            Check(canvas.IsEditing, "another click starts another label");
            canvas.InlineEditor!.Text = "Cancelled";
            Check(canvas.Key(Forms.Keys.Escape) && !canvas.IsEditing, "escape cancels inline text");
            Check(canvas.Document.Marks.Length == 1 && canvas.Document.Marks[0] == committed, "cancel does not overwrite existing text");
            Check(canvas.Key(Forms.Keys.Control | Forms.Keys.C) && copied, "Ctrl+C outside an edit copies the image");
            canvas.Tool = "Select";
            canvas.Selected = committed.Id;
            canvas.EditText();
            Check(canvas.IsEditing, "edit text reopens the caret on the image");
            canvas.InlineEditor!.Text = "   ";
            canvas.CommitInline();
            Check(canvas.Document.Marks.Length == 0, "blank text removes the label");
            canvas.Tool = "Text";
            Mouse("OnMouseDown", 40, 160);
            canvas.InlineEditor!.Text = "Hello";
            canvas.CommitInline();
            bool imageCopy = false;
            canvas.CopyRequested += () => imageCopy = true;
            canvas.Tool = "Text";
            Mouse("OnMouseDown", 80, 180);
            Check(canvas.IsEditing && !canvas.Key(Forms.Keys.Control | Forms.Keys.C) && !imageCopy, "Ctrl+C while editing does not copy the image");
            canvas.CancelInline();
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
        Check(AnnotationDocument.ValidCrop(new RectangleF(10.2f, 10.2f, 20.2f, 20.2f), new Size(300, 160)) == new ImageCrop(10, 10, 21, 21), "crop snaps outward to whole pixels");
        Check(AnnotationDocument.ValidCrop(new RectangleF(30, 40, -20, -10), new Size(300, 160)) == new ImageCrop(10, 30, 20, 10), "negative crop is standardized");
        Check(AnnotationDocument.ValidCrop(new RectangleF(-5, -5, 20, 20), new Size(300, 160)) == new ImageCrop(0, 0, 15, 15), "crop intersects the image");
        Check(AnnotationDocument.ValidCrop(new RectangleF(0, 0, 1, 10), new Size(300, 160)) == null, "crop must cover 2 pixels");
        Check(AnnotationDocument.ValidCrop(new RectangleF(float.NaN, 0, 10, 10), new Size(300, 160)) == null, "crop rejects non-finite values");
        var kept = Mark.Create("Box", new PointF(20, 20), Color.Red, 4) with { Points = new[] { new Vec(20, 20), new Vec(120, 50) } };
        using (var canvas = new AnnotationCanvas(new Bitmap(300, 160), null))
        {
            canvas.Size = new Size(600, 320);
            canvas.Document.Add(kept);
            bool copied = false;
            canvas.CopyRequested += () => copied = true;
            Check(canvas.Key(Forms.Keys.C) && canvas.Tool == "Crop", "C chooses crop");
            Check(canvas.Key(Forms.Keys.Control | Forms.Keys.C) && copied, "Ctrl+C copies the image");
            void Mouse(string method, int x, int y) => typeof(AnnotationCanvas).GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(canvas, new object[] { new Forms.MouseEventArgs(Forms.MouseButtons.Left, 1, x, y, 0) });
            Mouse("OnMouseDown", 20, 20); Mouse("OnMouseMove", 320, 220); Mouse("OnMouseUp", 320, 220);
            Check(canvas.CropSelection is RectangleF chosen && chosen.Equals(new RectangleF(10, 10, 150, 100)), "crop drag stays in source pixels");
            Check(canvas.Document.Marks.Length == 1 && canvas.Document.Crop == null, "a crop drag does not change marks or apply itself");
            canvas.Key(Forms.Keys.Enter);
            Check(canvas.Document.Crop == new ImageCrop(10, 10, 150, 100) && canvas.Document.Marks[0].Points.SequenceEqual(kept.Points), "Enter applies the crop without flattening marks");
            var mapped = canvas.ToImage(new PointF(canvas.ImageRect.X, canvas.ImageRect.Y));
            Check(Math.Abs(mapped.X - 10) < 0.001f && Math.Abs(mapped.Y - 10) < 0.001f, "cropped viewport maps back to the original image");
            canvas.Document.Undo();
            Check(canvas.Document.Crop == null && canvas.Document.Marks.Length == 1, "undo restores the full image and the marks");
            canvas.Document.Redo();
            Check(canvas.Document.Crop == new ImageCrop(10, 10, 150, 100), "redo restores the crop");
            canvas.CropSelection = new RectangleF(0, 0, 1, 1);
            canvas.ApplyCrop();
            Check(canvas.CropSelection != null && canvas.Document.Crop == new ImageCrop(10, 10, 150, 100), "a crop under 2 pixels is ignored");
            canvas.Key(Forms.Keys.Escape);
            Check(canvas.Tool == "Select" && canvas.CropSelection == null && canvas.Document.Crop != null, "Escape cancels the pending crop and leaves the applied one");
        }
        string wide = Path.Combine(output, "synthetic-wide.png");
        using (var image = new Bitmap(300, 160))
        {
            using var g = Graphics.FromImage(image);
            g.Clear(Color.White);
            g.FillRectangle(Brushes.Blue, 0, 80, 300, 80);
            image.Save(wide, System.Drawing.Imaging.ImageFormat.Png);
        }
        var privateShot = new Snapshot("Test", "Synthetic", "test-time", wide, "Private text outside the crop", Array.Empty<string>());
        var croppedDoc = new AnnotationDocument(new[] { kept }, new ImageCrop(10, 10, 100, 100));
        var cropped = AnnotationDocument.Export(privateShot, croppedDoc, output);
        Check(cropped.text == "" && cropped.originalAccessibilityText == "Private text outside the crop", "crop keeps the original text locally and omits it from delivery");
        Check(cropped.warnings.SequenceEqual(new[] { AnnotationDocument.CropWarning }) && cropped.crop == new ImageCrop(10, 10, 100, 100), "crop warning and source rectangle are saved once");
        Check(cropped.originalScreenshot == wide && cropped.windowsAnnotations![0].Points.SequenceEqual(kept.Points), "crop keeps the original file and editable marks");
        using (var rendered = new Bitmap(cropped.screenshot))
        {
            Check(rendered.Size == new Size(100, 100), "cropped export uses only the selected pixels");
            var edge = rendered.GetPixel(10, 25);
            Check(edge.R > 200 && edge.G < 50, "crop keeps annotation alignment in source pixels");
            var lower = rendered.GetPixel(90, 90);
            Check(lower.B > 200 && lower.R < 50, "crop samples the original image upright");
            Check(rendered.GetPixel(40, 5).ToArgb() == Color.White.ToArgb(), "selection chrome is not exported");
        }
        var croppedAgain = AnnotationDocument.Export(cropped, new AnnotationDocument(cropped.windowsAnnotations, cropped.crop), output);
        Check(croppedAgain.warnings.Count(warning => warning == AnnotationDocument.CropWarning) == 1 && croppedAgain.originalAccessibilityText == "Private text outside the crop", "saving a crop again does not duplicate the warning or lose the hidden text");
        var reset = AnnotationDocument.Export(croppedAgain, new AnnotationDocument(croppedAgain.windowsAnnotations), output);
        Check(reset.crop == null && reset.text == "Private text outside the crop" && !reset.warnings.Contains(AnnotationDocument.CropWarning), "reset crop restores the original accessibility text");
        using (var restoredImage = new Bitmap(reset.screenshot)) Check(restoredImage.Size == new Size(300, 160), "reset export is the full image");
        string huge = Path.Combine(output, "synthetic-huge.png");
        using (var image = new Bitmap(4000, 2000)) { using var g = Graphics.FromImage(image); g.Clear(Color.White); image.Save(huge, System.Drawing.Imaging.ImageFormat.Png); }
        var scaled = AnnotationDocument.Export(new Snapshot("Test", "Synthetic", "test-time", huge, "", Array.Empty<string>()), new AnnotationDocument(), output);
        using (var rendered = new Bitmap(scaled.screenshot)) Check(rendered.Size == new Size(2560, 1280), "long side scales to 2560");
        using (var tiny = new Bitmap(100, 100))
        try { _ = AnnotationDocument.Render(tiny, Array.Empty<Mark>(), new ImageCrop(0, 0, 1, 1)); throw new Exception("Invalid crop accepted"); }
        catch (Exception e) when (e.Message == "Crop must contain at least 2 × 2 image pixels.") { }
        Console.WriteLine("Windows annotation regressions passed");
    }
}
