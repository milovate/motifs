using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using Forms = System.Windows.Forms;

namespace OpenCode.Appshots;

internal sealed class AnnotationCanvas : Forms.Control
{
    readonly Bitmap image;
    internal readonly AnnotationDocument Document;
    internal string Tool = "Select";
    internal Color Ink = Color.Red;
    internal float Stroke = 4;
    internal string? Selected;
    internal event Action? Changed;
    Mark? draft, startingMark;
    PointF start;
    int handle = -1;
    bool dragging;
    internal Mark? Selection => Document.Marks.FirstOrDefault(m => m.Id == Selected);

    internal AnnotationCanvas(Bitmap image, Mark[]? marks)
    {
        this.image = image;
        Document = new AnnotationDocument(marks);
        Dock = Forms.DockStyle.Fill;
        DoubleBuffered = true; TabStop = true; BackColor = Color.FromArgb(35, 35, 35);
        SetStyle(Forms.ControlStyles.ResizeRedraw, true);
    }

    internal RectangleF ImageRect
    {
        get
        {
            float scale = Math.Min((float)Math.Max(1, ClientSize.Width) / image.Width, (float)Math.Max(1, ClientSize.Height) / image.Height);
            return new RectangleF((ClientSize.Width - image.Width * scale) / 2, (ClientSize.Height - image.Height * scale) / 2, image.Width * scale, image.Height * scale);
        }
    }
    internal PointF ToImage(PointF point)
    {
        var r = ImageRect; float scale = r.Width / image.Width;
        return new PointF(Math.Clamp((point.X - r.X) / scale, 0, image.Width), Math.Clamp((point.Y - r.Y) / scale, 0, image.Height));
    }
    internal void RefreshState()
    {
        if (Selection == null) Selected = null;
        Invalidate(); Changed?.Invoke();
    }

    protected override void OnPaint(Forms.PaintEventArgs e)
    {
        base.OnPaint(e);
        var r = ImageRect;
        e.Graphics.DrawImage(image, r);
        var state = e.Graphics.Save();
        float scale = r.Width / image.Width;
        e.Graphics.SetClip(r);
        e.Graphics.TranslateTransform(r.X, r.Y); e.Graphics.ScaleTransform(scale, scale);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        foreach (var mark in Document.Marks) (draft?.Id == mark.Id ? draft : mark).Draw(e.Graphics);
        if (draft != null && !Document.Marks.Any(m => m.Id == draft.Id)) draft.Draw(e.Graphics);
        var selection = draft ?? Selection;
        if (selection != null && Tool == "Select")
        {
            using var pen = new Pen(Color.DeepSkyBlue, 1 / scale) { DashStyle = DashStyle.Dash };
            var bounds = selection.Bounds();
            e.Graphics.DrawRectangle(pen, bounds.X, bounds.Y, bounds.Width, bounds.Height);
            foreach (var p in selection.Handles())
            {
                var box = new RectangleF(p.X - 4 / scale, p.Y - 4 / scale, 8 / scale, 8 / scale);
                e.Graphics.FillRectangle(Brushes.White, box);
                e.Graphics.DrawRectangle(pen, box.X, box.Y, box.Width, box.Height);
            }
        }
        e.Graphics.Restore(state);
    }

    protected override void OnMouseDown(Forms.MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != Forms.MouseButtons.Left || !ImageRect.Contains(e.Location)) return;
        Focus(); start = ToImage(e.Location); handle = -1;
        if (Tool == "Text")
        {
            string? text = TextDialog.Ask(FindForm(), "");
            if (!string.IsNullOrWhiteSpace(text)) Apply(() => { var mark = Mark.Create("Text", start, Ink, Stroke, text); Document.Add(mark); Selected = mark.Id; Tool = "Select"; });
            return;
        }
        if (Tool == "Select")
        {
            float tolerance = 7 * image.Width / ImageRect.Width;
            if (Selection != null)
            {
                var handles = Selection.Handles();
                handle = Array.FindIndex(handles, p => Math.Abs(p.X - start.X) <= tolerance && Math.Abs(p.Y - start.Y) <= tolerance);
            }
            if (handle < 0) Selected = Document.Marks.LastOrDefault(m => m.Hit(start, Math.Max(tolerance, m.Width / 2)))?.Id;
            startingMark = Selection; draft = startingMark;
        }
        else { Selected = null; draft = Mark.Create(Tool, start, Ink, Stroke); startingMark = null; }
        dragging = draft != null; Capture = dragging; RefreshState();
    }

    protected override void OnMouseMove(Forms.MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Cursor = Tool == "Text" ? Forms.Cursors.IBeam : Tool == "Select" ? Forms.Cursors.Default : Forms.Cursors.Cross;
        if (!dragging || draft == null) return;
        var point = ToImage(e.Location);
        if (startingMark != null) draft = handle >= 0 ? startingMark.Resize(handle, point) : startingMark.Move(point.X - start.X, point.Y - start.Y);
        else if (Tool == "Draw")
        {
            var last = draft.Points[^1];
            if (Math.Abs(last.X - point.X) + Math.Abs(last.Y - point.Y) >= 1 && draft.Points.Length < 20000) draft = draft with { Points = draft.Points.Append(Vec.From(point)).ToArray() };
        }
        else draft = draft with { Points = new[] { Vec.From(start), Vec.From(point) } };
        Invalidate();
    }

    protected override void OnMouseUp(Forms.MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (!dragging || e.Button != Forms.MouseButtons.Left) return;
        OnMouseMove(e);
        var finished = draft; var original = startingMark;
        dragging = false; draft = null; startingMark = null; Capture = false;
        if (finished != null && (original == null || !finished.Equivalent(original)) && (original != null || (Tool == "Draw" && finished.Points.Length > 2) || Math.Abs(ToImage(e.Location).X - start.X) + Math.Abs(ToImage(e.Location).Y - start.Y) > 1))
            Apply(() => { if (original != null) Document.Replace(finished); else Document.Add(finished); Selected = finished.Id; Tool = "Select"; });
        RefreshState();
    }

    protected override void OnMouseCaptureChanged(EventArgs e)
    {
        base.OnMouseCaptureChanged(e);
        if (!Capture && dragging) { dragging = false; draft = null; startingMark = null; Invalidate(); }
    }
    protected override void OnMouseDoubleClick(Forms.MouseEventArgs e) { base.OnMouseDoubleClick(e); if (Tool == "Select" && Selection?.Kind == "Text") EditText(); }
    internal void EditText()
    {
        var selected = Selection;
        if (selected?.Kind != "Text") return;
        string? text = TextDialog.Ask(FindForm(), selected.Text);
        if (!string.IsNullOrWhiteSpace(text) && text != selected.Text) Apply(() => Document.Replace(selected with { Text = text }));
    }
    internal void Style(Color? color = null, float? width = null)
    {
        if (color.HasValue) Ink = color.Value;
        if (width.HasValue) Stroke = width.Value;
        var mark = Selection;
        if (mark != null) Apply(() => Document.Replace(mark with { Color = color?.ToArgb() ?? mark.Color, Width = width ?? mark.Width }));
    }
    internal void Apply(Action action)
    {
        try { action(); }
        catch (Exception error) { Forms.MessageBox.Show(FindForm(), error.Message, "Appshots"); }
        RefreshState();
    }
    internal bool Key(Forms.Keys key)
    {
        if (dragging) return false;
        if (key == (Forms.Keys.Control | Forms.Keys.Z)) { Document.Undo(); RefreshState(); return true; }
        if (key == (Forms.Keys.Control | Forms.Keys.Y) || key == (Forms.Keys.Control | Forms.Keys.Shift | Forms.Keys.Z)) { Document.Redo(); RefreshState(); return true; }
        var mark = Selection;
        if (key == Forms.Keys.Escape && mark != null) { Selected = null; RefreshState(); return true; }
        if (key == Forms.Keys.Delete && mark != null) { Apply(() => Document.Delete(mark.Id)); return true; }
        if (key == (Forms.Keys.Control | Forms.Keys.D) && mark != null) { Apply(() => { var copy = mark.Move(12, 12) with { Id = Guid.NewGuid().ToString() }; Document.Add(copy); Selected = copy.Id; }); return true; }
        if (key == Forms.Keys.Enter && mark?.Kind == "Text") { EditText(); return true; }
        var code = key & Forms.Keys.KeyCode;
        if (mark != null && (key & (Forms.Keys.Control | Forms.Keys.Alt)) == 0 && new[] { Forms.Keys.Left, Forms.Keys.Right, Forms.Keys.Up, Forms.Keys.Down }.Contains(code))
        {
            int step = (key & Forms.Keys.Shift) != 0 ? 10 : 1;
            Apply(() => Document.Replace(mark.Move(code == Forms.Keys.Left ? -step : code == Forms.Keys.Right ? step : 0, code == Forms.Keys.Up ? -step : code == Forms.Keys.Down ? step : 0))); return true;
        }
        string? tool = key switch { Forms.Keys.V => "Select", Forms.Keys.A => "Arrow", Forms.Keys.R => "Box", Forms.Keys.P => "Draw", Forms.Keys.T => "Text", _ => null };
        if (tool == null) return false;
        Tool = tool; RefreshState(); return true;
    }
    protected override void Dispose(bool disposing) { if (disposing) image.Dispose(); base.Dispose(disposing); }
}

internal sealed class Preview : Forms.Form
{
    readonly AnnotationCanvas canvas;
    internal Preview(Snapshot shot, string output)
    {
        Text = "Appshot — annotate, review, and insert";
        Width = 1200; Height = 850; StartPosition = Forms.FormStartPosition.CenterScreen;
        MinimumSize = new Size(700, 400);
        string original = shot.originalScreenshot ?? shot.screenshot;
        Program.ValidateImage(original, output);
        using var source = Image.FromFile(original);
        if ((long)source.Width * source.Height > 40_000_000) throw new Exception("Image exceeds 40 million pixels.");
        canvas = new AnnotationCanvas(new Bitmap(source), shot.windowsAnnotations);
        var toolbar = new Forms.FlowLayoutPanel { Dock = Forms.DockStyle.Top, AutoSize = true, WrapContents = true, Padding = new Forms.Padding(4) };
        var tools = new System.Collections.Generic.Dictionary<string, Forms.Button>();
        foreach (string tool in new[] { "Select", "Arrow", "Box", "Draw", "Text" })
        {
            var button = new Forms.Button { Text = tool, AutoSize = true };
            button.Click += (_, _) => { canvas.Tool = tool; canvas.RefreshState(); canvas.Focus(); };
            tools[tool] = button; toolbar.Controls.Add(button);
        }
        var color = new Forms.Button { Text = "Color", AutoSize = true, ForeColor = canvas.Ink };
        color.Click += (_, _) => { using var dialog = new Forms.ColorDialog { Color = canvas.Ink }; if (dialog.ShowDialog(this) == Forms.DialogResult.OK) { canvas.Style(color: dialog.Color); color.ForeColor = dialog.Color; } canvas.Focus(); };
        var width = new Forms.NumericUpDown { Minimum = 1, Maximum = 40, Value = 4, Width = 55, AccessibleName = "Stroke width in image pixels" };
        width.ValueChanged += (_, _) => canvas.Style(width: (float)width.Value);
        var undo = new Forms.Button { Text = "Undo", AutoSize = true };
        var redo = new Forms.Button { Text = "Redo", AutoSize = true };
        undo.Click += (_, _) => { canvas.Document.Undo(); canvas.RefreshState(); canvas.Focus(); };
        redo.Click += (_, _) => { canvas.Document.Redo(); canvas.RefreshState(); canvas.Focus(); };
        var edit = new Forms.Button { Text = "Edit text", AutoSize = true };
        edit.Click += (_, _) => canvas.EditText();
        var delete = new Forms.Button { Text = "Delete", AutoSize = true };
        delete.Click += (_, _) => { if (canvas.Selected is string id) canvas.Apply(() => canvas.Document.Delete(id)); canvas.Focus(); };
        toolbar.Controls.AddRange(new Forms.Control[] { color, width, undo, redo, edit, delete });
        canvas.Changed += () => {
            foreach (var pair in tools) pair.Value.BackColor = pair.Key == canvas.Tool ? Color.LightSkyBlue : SystemColors.Control;
            undo.Enabled = canvas.Document.CanUndo; redo.Enabled = canvas.Document.CanRedo;
            edit.Enabled = canvas.Selection?.Kind == "Text"; delete.Enabled = canvas.Selection != null;
        };
        var bottom = new Forms.FlowLayoutPanel { Dock = Forms.DockStyle.Bottom, Height = 48, Padding = new Forms.Padding(4) };
        var insert = new Forms.Button { Text = "Insert into OpenCode", AutoSize = true };
        var save = new Forms.Button { Text = "Save only", AutoSize = true };
        var cancel = new Forms.Button { Text = "Cancel", AutoSize = true };
        cancel.Click += (_, _) => Close();
        save.Click += (_, _) => { try { AnnotationDocument.Export(shot, canvas.Document, output); Close(); } catch (Exception e) { Forms.MessageBox.Show(this, e.Message, "Appshots"); } };
        bottom.Controls.AddRange(new Forms.Control[] { insert, save, cancel });
        var hint = new Forms.Label { Text = "V select · A arrow · R box · P draw · T text · Ctrl+Z undo · Ctrl+D duplicate", AutoSize = true, Padding = new Forms.Padding(8) };
        bottom.Controls.Add(hint);
        Controls.Add(canvas); Controls.Add(toolbar); Controls.Add(bottom);
        // Freeze the editor while an insertion awaits focus/clipboard operations.
        insert.Click += async (_, _) => {
            canvas.Enabled = toolbar.Enabled = bottom.Enabled = false;
            try { var annotated = AnnotationDocument.Export(shot, canvas.Document, output); await Inserter.Insert(annotated, output); Close(); }
            catch (Exception e) { Forms.MessageBox.Show(this, e.Message, "Appshot saved — insertion failed"); }
            finally { if (!IsDisposed) canvas.Enabled = toolbar.Enabled = bottom.Enabled = true; }
        };
        canvas.RefreshState();
    }
    protected override bool ProcessCmdKey(ref Forms.Message msg, Forms.Keys keyData)
    {
        // Let numeric/text controls handle their own editing shortcuts and arrow keys.
        if (ActiveControl is Forms.NumericUpDown) return base.ProcessCmdKey(ref msg, keyData);
        if (canvas.Enabled && canvas.Key(keyData)) return true;
        if (keyData == Forms.Keys.Escape && canvas.Enabled) { Close(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }
}

internal static class TextDialog
{
    internal static string? Ask(Forms.IWin32Window? owner, string value)
    {
        using var dialog = new Forms.Form { Text = "Annotation text", Width = 500, Height = 260, StartPosition = Forms.FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false };
        var input = new Forms.TextBox { Multiline = true, Dock = Forms.DockStyle.Fill, Text = value, MaxLength = 10000, AcceptsReturn = true, ScrollBars = Forms.ScrollBars.Vertical };
        var buttons = new Forms.FlowLayoutPanel { Dock = Forms.DockStyle.Bottom, Height = 40 };
        var ok = new Forms.Button { Text = "OK", DialogResult = Forms.DialogResult.OK };
        var cancel = new Forms.Button { Text = "Cancel", DialogResult = Forms.DialogResult.Cancel };
        buttons.Controls.AddRange(new Forms.Control[] { ok, cancel });
        dialog.Controls.Add(input); dialog.Controls.Add(buttons); dialog.CancelButton = cancel;
        dialog.Shown += (_, _) => input.Focus();
        return dialog.ShowDialog(owner) == Forms.DialogResult.OK ? input.Text : null;
    }
}
