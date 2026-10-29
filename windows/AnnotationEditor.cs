using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using Forms = System.Windows.Forms;

namespace OpenCode.Appshots;

internal sealed class AnnotationCanvas : Forms.Control
{
    readonly Bitmap image;
    internal readonly AnnotationDocument Document;
    string tool = "Select";
    internal Color Ink = Color.Red;
    internal float Stroke = 4;
    internal string? Selected;
    internal RectangleF? CropSelection;
    internal event Action? Changed;
    internal event Action? CopyRequested;
    Mark? draft, startingMark;
    PointF start;
    PointF? cropStart;
    int handle = -1;
    bool dragging;
    internal Mark? Selection => Document.Marks.FirstOrDefault(m => m.Id == Selected);
    internal string Tool
    {
        get => tool;
        set
        {
            if (tool == value) return;
            tool = value;
            CropSelection = null;
            cropStart = null;
        }
    }

    internal AnnotationCanvas(Bitmap image, Mark[]? marks, ImageCrop? crop = null)
    {
        this.image = image;
        Document = new AnnotationDocument(marks, crop);
        Dock = Forms.DockStyle.Fill;
        DoubleBuffered = true; TabStop = true; BackColor = Color.FromArgb(35, 35, 35);
        SetStyle(Forms.ControlStyles.ResizeRedraw, true);
    }

    RectangleF ShownPixels => Document.Crop?.Rectangle ?? new RectangleF(0, 0, image.Width, image.Height);
    internal RectangleF ImageRect
    {
        get
        {
            var visible = ShownPixels;
            float scale = Math.Min(Math.Max(1, ClientSize.Width) / visible.Width, Math.Max(1, ClientSize.Height) / visible.Height);
            float width = visible.Width * scale, height = visible.Height * scale;
            return new RectangleF((ClientSize.Width - width) / 2, (ClientSize.Height - height) / 2, width, height);
        }
    }
    internal PointF ToImage(PointF point)
    {
        var visible = ShownPixels;
        var r = ImageRect;
        float scale = r.Width / visible.Width;
        return new PointF(Math.Clamp((point.X - r.X) / scale + visible.X, visible.X, visible.Right), Math.Clamp((point.Y - r.Y) / scale + visible.Y, visible.Y, visible.Bottom));
    }
    float Tolerance => 7 * ShownPixels.Width / Math.Max(1, ImageRect.Width);
    internal void RefreshState()
    {
        if (Selection == null) Selected = null;
        Invalidate(); Changed?.Invoke();
    }
    internal void ApplyCrop()
    {
        if (CropSelection is not RectangleF selection) return;
        var crop = AnnotationDocument.ValidCrop(selection, image.Size);
        if (crop == null) return;
        Apply(() => { Document.SetCrop(crop); CropSelection = null; cropStart = null; Selected = null; });
    }
    internal void ResetCrop()
    {
        CropSelection = null; cropStart = null;
        Apply(() => Document.SetCrop(null));
    }
    internal void CancelCrop()
    {
        CropSelection = null; cropStart = null; Tool = "Select"; RefreshState();
    }

    protected override void OnPaint(Forms.PaintEventArgs e)
    {
        base.OnPaint(e);
        var visible = ShownPixels;
        var r = ImageRect;
        float scale = r.Width / visible.Width;
        float originX = r.X - visible.X * scale, originY = r.Y - visible.Y * scale;
        var state = e.Graphics.Save();
        e.Graphics.SetClip(r);
        e.Graphics.DrawImage(image, originX, originY, image.Width * scale, image.Height * scale);
        e.Graphics.TranslateTransform(originX, originY); e.Graphics.ScaleTransform(scale, scale);
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
        if (Tool == "Crop" && CropSelection is RectangleF chosen)
        {
            var shadeRect = new RectangleF(r.X + (chosen.X - visible.X) * scale, r.Y + (chosen.Y - visible.Y) * scale, chosen.Width * scale, chosen.Height * scale);
            using var shade = new SolidBrush(Color.FromArgb(128, Color.Black));
            using var region = new Region(r);
            region.Exclude(shadeRect);
            e.Graphics.FillRegion(shade, region);
            using var border = new Pen(Color.White, 1.5f);
            e.Graphics.DrawRectangle(border, shadeRect.X, shadeRect.Y, shadeRect.Width, shadeRect.Height);
        }
    }

    protected override void OnMouseDown(Forms.MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button == Forms.MouseButtons.Right) { ShowMenu(e.Location); return; }
        if (e.Button != Forms.MouseButtons.Left || !ImageRect.Contains(e.Location)) return;
        Focus(); start = ToImage(e.Location); handle = -1;
        if (Tool == "Crop")
        {
            cropStart = start; CropSelection = null; draft = null; startingMark = null;
            dragging = true; Capture = true; RefreshState(); return;
        }
        if (Tool == "Text")
        {
            string? text = TextDialog.Ask(FindForm(), "");
            if (!string.IsNullOrWhiteSpace(text)) Apply(() => { var mark = Mark.Create("Text", start, Ink, Stroke, text); Document.Add(mark); Selected = mark.Id; Tool = "Select"; });
            return;
        }
        if (Tool == "Select")
        {
            float tolerance = Tolerance;
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

    void ShowMenu(Point location)
    {
        var menu = new Forms.ContextMenuStrip();
        if (!ImageRect.Contains(location)) menu.Items.Add("Copy image", null, (_, _) => CopyRequested?.Invoke());
        else
        {
            var point = ToImage(location);
            var hit = Document.Marks.LastOrDefault(m => m.Hit(point, Math.Max(Tolerance, m.Width / 2)));
            if (hit == null) menu.Items.Add("Copy image", null, (_, _) => CopyRequested?.Invoke());
            else
            {
                Selected = hit.Id; Tool = "Select"; RefreshState();
                if (hit.Kind == "Text") menu.Items.Add("Edit text", null, (_, _) => EditText());
                menu.Items.Add("Duplicate", null, (_, _) => Key(Forms.Keys.Control | Forms.Keys.D));
                menu.Items.Add("Delete", null, (_, _) => Key(Forms.Keys.Delete));
            }
        }
        menu.Closed += (_, _) => menu.Dispose();
        menu.Show(this, location);
    }

    protected override void OnMouseMove(Forms.MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Cursor = Tool == "Text" ? Forms.Cursors.IBeam : Tool == "Select" ? Forms.Cursors.Default : Forms.Cursors.Cross;
        if (Tool == "Crop" && dragging && cropStart is PointF origin)
        {
            var corner = ToImage(e.Location);
            CropSelection = new RectangleF(Math.Min(origin.X, corner.X), Math.Min(origin.Y, corner.Y), Math.Abs(corner.X - origin.X), Math.Abs(corner.Y - origin.Y));
            RefreshState(); return;
        }
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
        if (Tool == "Crop")
        {
            if (!dragging || e.Button != Forms.MouseButtons.Left) return;
            dragging = false; cropStart = null; Capture = false; RefreshState(); return;
        }
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
        if (!Capture && dragging) { dragging = false; draft = null; startingMark = null; cropStart = null; Invalidate(); }
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
        if (key == (Forms.Keys.Control | Forms.Keys.C)) { CopyRequested?.Invoke(); return true; }
        if (key == (Forms.Keys.Control | Forms.Keys.Z)) { Document.Undo(); CropSelection = null; RefreshState(); return true; }
        if (key == (Forms.Keys.Control | Forms.Keys.Y) || key == (Forms.Keys.Control | Forms.Keys.Shift | Forms.Keys.Z)) { Document.Redo(); CropSelection = null; RefreshState(); return true; }
        if (Tool == "Crop" && key == Forms.Keys.Escape) { CancelCrop(); return true; }
        if (Tool == "Crop" && key == Forms.Keys.Enter) { ApplyCrop(); return true; }
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
        string? next = key switch { Forms.Keys.V => "Select", Forms.Keys.A => "Arrow", Forms.Keys.R => "Box", Forms.Keys.P => "Draw", Forms.Keys.T => "Text", Forms.Keys.C => "Crop", _ => null };
        if (next == null) return false;
        Tool = next; RefreshState(); return true;
    }
    protected override void Dispose(bool disposing) { if (disposing) image.Dispose(); base.Dispose(disposing); }
}

internal sealed class Preview : Forms.Form
{
    readonly AnnotationCanvas canvas;
    internal Snapshot? Result { get; private set; }
    internal bool Inserted { get; private set; }
    internal bool Saved { get; private set; }
    internal Preview(Snapshot shot, string output, bool returnOnly = false)
    {
        Text = returnOnly ? "Annotate screenshot" : "Appshot — annotate, review, and insert";
        Width = 1200; Height = 850; StartPosition = Forms.FormStartPosition.CenterScreen;
        MinimumSize = new Size(700, 400);
        string original = shot.originalScreenshot ?? shot.screenshot;
        Program.ValidateImage(original, output);
        using var source = Image.FromFile(original);
        if ((long)source.Width * source.Height > 40_000_000) throw new Exception("Image exceeds 40 million pixels.");
        ImageCrop? savedCrop = shot.crop == null ? null : AnnotationDocument.ValidCrop(shot.crop.Rectangle, source.Size);
        canvas = new AnnotationCanvas(new Bitmap(source), shot.windowsAnnotations, savedCrop);
        var toolbar = new Forms.FlowLayoutPanel { Dock = Forms.DockStyle.Top, AutoSize = true, WrapContents = true, Padding = new Forms.Padding(4) };
        var tools = new System.Collections.Generic.Dictionary<string, Forms.Button>();
        foreach (string tool in new[] { "Select", "Arrow", "Box", "Draw", "Text", "Crop" })
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
        undo.Click += (_, _) => { canvas.Document.Undo(); canvas.CropSelection = null; canvas.RefreshState(); canvas.Focus(); };
        redo.Click += (_, _) => { canvas.Document.Redo(); canvas.CropSelection = null; canvas.RefreshState(); canvas.Focus(); };
        var copy = new Forms.Button { Text = "Copy image", AutoSize = true, AccessibleName = "Copy image" };
        copy.Click += (_, _) => { CopyImage(shot, output, copy); canvas.Focus(); };
        var applyCrop = new Forms.Button { Text = "Apply Crop", AutoSize = true, Visible = false };
        var resetCrop = new Forms.Button { Text = "Reset Crop", AutoSize = true, Visible = false };
        var cancelCrop = new Forms.Button { Text = "Cancel Crop", AutoSize = true, Visible = false };
        applyCrop.Click += (_, _) => { canvas.ApplyCrop(); canvas.Focus(); };
        resetCrop.Click += (_, _) => { canvas.ResetCrop(); canvas.Focus(); };
        cancelCrop.Click += (_, _) => { canvas.CancelCrop(); canvas.Focus(); };
        var edit = new Forms.Button { Text = "Edit text", AutoSize = true };
        edit.Click += (_, _) => canvas.EditText();
        var delete = new Forms.Button { Text = "Delete", AutoSize = true };
        delete.Click += (_, _) => { if (canvas.Selected is string id) canvas.Apply(() => canvas.Document.Delete(id)); canvas.Focus(); };
        toolbar.Controls.AddRange(new Forms.Control[] { color, width, undo, redo, copy, edit, delete, applyCrop, resetCrop, cancelCrop });
        canvas.CopyRequested += () => CopyImage(shot, output, copy);
        canvas.Changed += () => {
            foreach (var pair in tools) pair.Value.BackColor = pair.Key == canvas.Tool ? Color.LightSkyBlue : SystemColors.Control;
            undo.Enabled = canvas.Document.CanUndo; redo.Enabled = canvas.Document.CanRedo;
            edit.Enabled = canvas.Selection?.Kind == "Text"; delete.Enabled = canvas.Selection != null;
            bool cropping = canvas.Tool == "Crop";
            applyCrop.Visible = resetCrop.Visible = cancelCrop.Visible = cropping;
            applyCrop.Enabled = canvas.CropSelection != null;
        };
        var bottom = new Forms.FlowLayoutPanel { Dock = Forms.DockStyle.Bottom, Height = 48, Padding = new Forms.Padding(4) };
        var insert = new Forms.Button { Text = "Insert into OpenCode", AutoSize = true };
        var save = new Forms.Button { Text = returnOnly ? "Done" : "Save only", AutoSize = true };
        var cancel = new Forms.Button { Text = "Cancel", AutoSize = true };
        cancel.Click += (_, _) => Close();
        save.Click += (_, _) => {
            try
            {
                if (canvas.Tool == "Crop") canvas.ApplyCrop();
                var exported = AnnotationDocument.Export(shot, canvas.Document, output);
                Saved = true;
                if (returnOnly) { Result = exported; DialogResult = Forms.DialogResult.OK; }
                Close();
            }
            catch (Exception e) { Forms.MessageBox.Show(this, e.Message, "Capture Studio"); }
        };
        if (!returnOnly) bottom.Controls.Add(insert);
        bottom.Controls.Add(save);
        bottom.Controls.Add(cancel);
        var hint = new Forms.Label { Text = "V select · A arrow · R box · P draw · T text · C crop · Ctrl+C copy · Ctrl+Z undo · Ctrl+D duplicate", AutoSize = true, Padding = new Forms.Padding(8) };
        bottom.Controls.Add(hint);
        Controls.Add(canvas); Controls.Add(toolbar); Controls.Add(bottom);
        // Freeze the editor while an insertion awaits focus/clipboard operations.
        if (!returnOnly) insert.Click += async (_, _) => {
            canvas.Enabled = toolbar.Enabled = bottom.Enabled = false;
            try
            {
                if (canvas.Tool == "Crop") canvas.ApplyCrop();
                var annotated = AnnotationDocument.Export(shot, canvas.Document, output);
                Saved = true;
                await Inserter.Insert(annotated, output);
                Inserted = true;
                Close();
            }
            catch (Exception e) { Forms.MessageBox.Show(this, e.Message, "Appshot saved — insertion failed"); }
            finally { if (!IsDisposed) canvas.Enabled = toolbar.Enabled = bottom.Enabled = true; }
        };
        canvas.RefreshState();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.ExcludeFromCapture(Handle);
    }
    protected override bool ProcessCmdKey(ref Forms.Message msg, Forms.Keys keyData)
    {
        // Let numeric/text controls handle their own editing shortcuts and arrow keys.
        if (ActiveControl is Forms.NumericUpDown) return base.ProcessCmdKey(ref msg, keyData);
        if (canvas.Enabled && canvas.Key(keyData)) return true;
        if (keyData == Forms.Keys.Escape && canvas.Enabled) { Close(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    void CopyImage(Snapshot shot, string output, Forms.Button copy)
    {
        try
        {
            string original = shot.originalScreenshot ?? shot.screenshot;
            Program.ValidateImage(original, output);
            using var source = Image.FromFile(original);
            using var rendered = AnnotationDocument.Render(source, canvas.Document.Marks, canvas.Document.Crop);
            using var png = new MemoryStream();
            rendered.Save(png, ImageFormat.Png);
            if (png.Length > 15_000_000) throw new Exception("The annotated PNG exceeds 15 MB. Use a smaller image.");
            png.Position = 0;
            var data = new Forms.DataObject();
            data.SetData("PNG", false, png);
            data.SetImage(rendered);
            Forms.Clipboard.SetDataObject(data, true);
            copy.Text = "Copied";
            var timer = new Forms.Timer { Interval = 1200 };
            timer.Tick += (_, _) => { if (!copy.IsDisposed) copy.Text = "Copy image"; timer.Stop(); timer.Dispose(); };
            timer.Start();
        }
        catch (Exception error) { Forms.MessageBox.Show(this, error.Message, "Could not copy the image"); }
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
