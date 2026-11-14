using System;
using System.Drawing;
using System.Threading.Tasks;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using Forms = System.Windows.Forms;

namespace Motifs;

internal sealed class AnnotationCanvas : Forms.Control
{
    readonly Bitmap image;
    internal readonly AnnotationDocument Document;
    string tool = "Arrow";
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
    Forms.TextBox? inline;
    Font? inlineFont;
    Mark? editing;
    bool closingInline;
    internal bool IsEditing => inline != null;
    internal Forms.TextBox? InlineEditor => inline;
    internal string Tool
    {
        get => tool;
        set
        {
            if (tool == value) return;
            CommitInline();
            tool = value;
            CropSelection = null;
            cropStart = null;
        }
    }

    internal const string Hint = "V Select · A Arrow · R Box · P Draw · T Text · C Crop. Text edits directly on the image. Drawing tools stay active.";

    internal AnnotationCanvas(Bitmap image, Mark[]? marks, ImageCrop? crop = null)
    {
        this.image = image;
        Document = new AnnotationDocument(marks, crop);
        Dock = Forms.DockStyle.Fill;
        DoubleBuffered = true; TabStop = true; BackColor = Color.FromArgb(35, 35, 35);
        AccessibleName = "Screenshot annotation canvas";
        AccessibleRole = Forms.AccessibleRole.Graphic;
        SetStyle(Forms.ControlStyles.ResizeRedraw, true);
    }

    RectangleF ShownPixels => Document.Crop?.Rectangle ?? new RectangleF(0, 0, image.Width, image.Height);
    internal Size PixelSize => image.Size;
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
        foreach (var mark in Document.Marks) if (editing?.Id != mark.Id) (draft?.Id == mark.Id ? draft : mark).Draw(e.Graphics);
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
        if (e.Button == Forms.MouseButtons.Right) { CommitInline(); ShowMenu(e.Location); return; }
        CommitInline();
        if (e.Button != Forms.MouseButtons.Left || !ImageRect.Contains(e.Location)) return;
        Focus(); start = ToImage(e.Location); handle = -1;
        if (Tool == "Crop")
        {
            cropStart = start; CropSelection = null; draft = null; startingMark = null;
            dragging = true; Capture = true; RefreshState(); return;
        }
        if (Tool == "Text") { Selected = null; BeginText(start, null); return; }
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
            Apply(() => { if (original != null) Document.Replace(finished); else { Document.Add(finished); Selected = null; } });
        RefreshState();
    }

    protected override void OnMouseCaptureChanged(EventArgs e)
    {
        base.OnMouseCaptureChanged(e);
        if (!Capture && dragging) { dragging = false; draft = null; startingMark = null; cropStart = null; Invalidate(); }
    }
    protected override void OnMouseDoubleClick(Forms.MouseEventArgs e)
    {
        base.OnMouseDoubleClick(e);
        if (Tool != "Select" || Selection?.Kind != "Text") return;
        dragging = false; draft = null; startingMark = null; Capture = false;
        EditText();
    }
    protected override void OnResize(EventArgs e) { base.OnResize(e); LayoutInline(); }
    internal void EditText()
    {
        var selected = Selection;
        if (selected?.Kind != "Text") return;
        BeginText(selected.Points[0].Point, selected);
    }
    void BeginText(PointF point, Mark? existing)
    {
        CommitInline();
        float size = existing?.FontSize ?? Math.Clamp(Math.Max(22, 18f * image.Width / Math.Max(1, ImageRect.Width)), 6, 400);
        var mark = existing ?? Mark.Create("Text", point, Ink, Stroke) with { FontSize = size, Points = new[] { Vec.From(point) } };
        editing = mark;
        inline = new Forms.TextBox
        {
            Multiline = true,
            AcceptsReturn = true,
            MaxLength = 10000,
            WordWrap = false,
            BorderStyle = Forms.BorderStyle.None,
            BackColor = Color.White,
            ForeColor = Color.FromArgb(mark.Color),
            Text = mark.Text,
            AccessibleName = "Edit annotation text directly on the image",
            ScrollBars = Forms.ScrollBars.None,
        };
        Controls.Add(inline);
        LayoutInline();
        inline.TextChanged += (_, _) => { LayoutInline(); Changed?.Invoke(); };
        inline.LostFocus += (_, _) => { if (!closingInline) CommitInline(); };
        inline.KeyDown += (_, args) =>
        {
            if (args.KeyCode == Forms.Keys.Escape) { args.SuppressKeyPress = true; CancelInline(); }
            else if (args.KeyCode == Forms.Keys.Enter && !args.Shift) { args.SuppressKeyPress = true; CommitInline(); }
        };
        inline.SelectionStart = inline.TextLength;
        inline.Focus();
        Invalidate();
    }
    void LayoutInline()
    {
        if (inline == null || editing is not Mark mark) return;
        float scale = ImageRect.Width / Math.Max(1, ShownPixels.Width);
        var next = new Font("Segoe UI", Math.Max(1, mark.FontSize * scale), FontStyle.Bold, GraphicsUnit.Pixel);
        var previous = inlineFont;
        inline.Font = next;
        inlineFont = next;
        if (!ReferenceEquals(previous, next)) previous?.Dispose();
        var origin = new PointF(ImageRect.X + (mark.Points[0].X - ShownPixels.X) * scale, ImageRect.Y + (mark.Points[0].Y - ShownPixels.Y) * scale);
        var measured = Forms.TextRenderer.MeasureText(string.IsNullOrEmpty(inline.Text) ? " " : inline.Text, inline.Font, new Size(10000, 10000), Forms.TextFormatFlags.NoPadding);
        int width = (int)Math.Max(30, Math.Min(Math.Max(140, measured.Width + 12), Math.Max(30, ImageRect.Right - origin.X)));
        int height = Math.Max(26, measured.Height + 6);
        inline.Bounds = new Rectangle(Point.Round(origin), new Size(width, height));
    }
    internal void CommitInline()
    {
        if (inline == null || editing is not Mark mark) return;
        string text = inline.Text;
        CloseInline();
        var updated = mark with { Text = text };
        if (string.IsNullOrWhiteSpace(text))
        {
            if (Document.Marks.Any(m => m.Id == mark.Id)) Apply(() => Document.Delete(mark.Id));
            else RefreshState();
        }
        else if (Document.Marks.Any(m => m.Id == mark.Id))
        {
            if (!Document.Marks.First(m => m.Id == mark.Id).Equivalent(updated)) Apply(() => Document.Replace(updated));
            else RefreshState();
        }
        else Apply(() => Document.Add(updated));
        Selected = Tool == "Select" && Document.Marks.Any(m => m.Id == mark.Id) ? mark.Id : null;
        RefreshState();
    }
    internal bool EditUndo()
    {
        if (inline is not Forms.TextBox box) return false;
        if (box.CanUndo) box.Undo();
        return true;
    }
    internal bool EditCopy()
    {
        if (inline is not Forms.TextBox box) return false;
        box.Copy();
        return true;
    }
    internal void CancelInline()
    {
        if (inline == null) return;
        CloseInline();
        RefreshState();
    }
    void CloseInline()
    {
        var box = inline;
        if (box == null) { inlineFont?.Dispose(); inlineFont = null; editing = null; return; }
        closingInline = true;
        var font = inlineFont;
        inline = null;
        editing = null;
        inlineFont = null;
        try
        {
            if (!IsDisposed && IsHandleCreated && CanFocus && !Focused) Focus();
            // The text box disposes the font it still holds. Detach ours first so it is released once.
            if (font != null) box.Font = DefaultFont;
            box.Dispose();
            font?.Dispose();
        }
        finally { closingInline = false; }
    }
    internal void Style(Color? color = null, float? width = null)
    {
        if (color.HasValue) Ink = color.Value;
        if (width.HasValue) Stroke = width.Value;
        if (editing is Mark current)
        {
            editing = current with { Color = color?.ToArgb() ?? current.Color, Width = width ?? current.Width };
            if (inline != null && color.HasValue) inline.ForeColor = color.Value;
            return;
        }
        var mark = Selection;
        if (mark != null) Apply(() => Document.Replace(mark with { Color = color?.ToArgb() ?? mark.Color, Width = width ?? mark.Width }));
    }
    internal void Apply(Action action)
    {
        try { action(); }
        catch (Exception error) { Forms.MessageBox.Show(FindForm(), error.Message, "Motifs"); }
        RefreshState();
    }
    internal bool Key(Forms.Keys key)
    {
        if (dragging) return false;
        if (IsEditing && key == Forms.Keys.Escape) { CancelInline(); return true; }
        if (IsEditing && key == Forms.Keys.Enter) { CommitInline(); return true; }
        if (IsEditing) return false;
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
    protected override void Dispose(bool disposing) { if (disposing) { CloseInline(); image.Dispose(); } base.Dispose(disposing); }
}

internal readonly record struct ToolbarOffset(int Center, int Bottom);

// Same limits as the macOS tray: centered, at least 8px from the edges, and clear of the title area.
internal static class ToolbarPlacement
{
    internal static ToolbarOffset Move(ToolbarOffset current, Size client, Size tray, int dx, int dy)
    {
        int halfTravel = Math.Max(0, (client.Width - tray.Width) / 2 - 8);
        int center = Math.Clamp(current.Center + dx, -halfTravel, halfTravel);
        int maxHeight = Math.Max(8, client.Height - tray.Height - 36);
        int bottom = Math.Clamp(current.Bottom - dy, 8, maxHeight);
        return new ToolbarOffset(center, bottom);
    }
}

internal sealed class Preview : Forms.Form
{
    readonly AnnotationCanvas canvas;
    readonly Forms.FlowLayoutPanel toolRow;
    readonly Forms.Panel tray;
    readonly Forms.ToolTip tips = new();
    readonly bool returnOnly;
    readonly float[] widths = { 2, 4, 8 };
    ToolbarOffset toolbarOffset = new(0, 16);
    Forms.Label? hint;
    bool adjustingWidth;
    bool inserting;
    bool arranged;
    internal Snapshot? Result { get; private set; }
    internal bool Inserted { get; private set; }
    internal string? InsertError { get; private set; }
    internal bool Saved { get; private set; }
    internal bool Completed { get; private set; }
    internal Preview(Snapshot shot, string output, bool returnOnly = false)
    {
        this.returnOnly = returnOnly;
        Text = "Annotate — " + (string.IsNullOrWhiteSpace(shot.app) ? "Image" : shot.app);
        StartPosition = Forms.FormStartPosition.Manual;
        MinimumSize = new Size(720, 480);
        BackColor = Color.FromArgb(35, 35, 35);
        string original = shot.originalScreenshot ?? shot.screenshot;
        Program.ValidateImage(original, output);
        using var source = Image.FromFile(original);
        if ((long)source.Width * source.Height > 40_000_000) throw new Exception("Image exceeds 40 million pixels.");
        ImageCrop? savedCrop = shot.crop == null ? null : AnnotationDocument.ValidCrop(shot.crop.Rectangle, source.Size);
        canvas = new AnnotationCanvas(new Bitmap(source), shot.windowsAnnotations, savedCrop);
        tips.SetToolTip(canvas, AnnotationCanvas.Hint);
        var tools = new System.Collections.Generic.Dictionary<string, Forms.Button>();
        toolRow = new Forms.FlowLayoutPanel { AutoSize = true, WrapContents = true, FlowDirection = Forms.FlowDirection.LeftToRight, Margin = new Forms.Padding(0), Padding = new Forms.Padding(0) };
        var grip = new Forms.Label
        {
            Text = "≡",
            AutoSize = false,
            Size = new Size(22, 28),
            TextAlign = ContentAlignment.MiddleCenter,
            Cursor = Forms.Cursors.SizeAll,
            AccessibleName = "Move annotation toolbar",
            Margin = new Forms.Padding(0, 4, 6, 0),
        };
        tips.SetToolTip(grip, "Drag to move toolbar");
        toolRow.Controls.Add(grip);
        foreach (string tool in new[] { "Select", "Arrow", "Box", "Draw", "Text", "Crop" })
        {
            var button = new Forms.Button { Text = tool, AutoSize = true, Margin = new Forms.Padding(2) };
            button.Click += (_, _) => { canvas.Tool = tool; canvas.RefreshState(); canvas.Focus(); };
            tools[tool] = button; toolRow.Controls.Add(button);
        }
        var color = new Forms.Button { Text = "Color", AutoSize = true, Margin = new Forms.Padding(2) };
        color.Click += (_, _) =>
        {
            using var dialog = new Forms.ColorDialog { Color = canvas.Ink };
            if (dialog.ShowDialog(this) == Forms.DialogResult.OK) { canvas.Style(color: dialog.Color); ShowInk(color, dialog.Color); }
            canvas.Focus();
        };
        var width = new Forms.ComboBox { DropDownStyle = Forms.ComboBoxStyle.DropDownList, Width = 88, AccessibleName = "Stroke width", Margin = new Forms.Padding(2) };
        width.Items.AddRange(new object[] { "Thin", "Medium", "Thick" });
        adjustingWidth = true;
        width.SelectedIndex = 1;
        adjustingWidth = false;
        tips.SetToolTip(width, "Stroke width");
        width.SelectedIndexChanged += (_, _) =>
        {
            if (adjustingWidth || width.SelectedIndex < 0) return;
            canvas.Style(width: widths[width.SelectedIndex]);
        };
        var undo = new Forms.Button { Text = "Undo", AutoSize = true, Margin = new Forms.Padding(2) };
        var redo = new Forms.Button { Text = "Redo", AutoSize = true, Margin = new Forms.Padding(2) };
        undo.Click += (_, _) =>
        {
            if (canvas.EditUndo()) return;
            canvas.Document.Undo(); canvas.CropSelection = null; canvas.RefreshState(); canvas.Focus();
        };
        redo.Click += (_, _) =>
        {
            if (canvas.IsEditing) return;
            canvas.Document.Redo(); canvas.CropSelection = null; canvas.RefreshState(); canvas.Focus();
        };
        var copy = new Forms.Button { Text = "Copy image", AutoSize = true, AccessibleName = "Copy image", Margin = new Forms.Padding(2) };
        copy.Click += (_, _) => { if (canvas.EditCopy()) return; CopyImage(shot, output, copy); canvas.Focus(); };
        var applyCrop = new Forms.Button { Text = "Apply Crop", AutoSize = true, Visible = false, Margin = new Forms.Padding(2) };
        var resetCrop = new Forms.Button { Text = "Reset Crop", AutoSize = true, Visible = false, Margin = new Forms.Padding(2) };
        var cancelCrop = new Forms.Button { Text = "Cancel Crop", AutoSize = true, Visible = false, Margin = new Forms.Padding(2) };
        applyCrop.Click += (_, _) => { canvas.ApplyCrop(); canvas.Focus(); };
        resetCrop.Click += (_, _) => { canvas.ResetCrop(); canvas.Focus(); };
        cancelCrop.Click += (_, _) => { canvas.CancelCrop(); canvas.Focus(); };
        var edit = new Forms.Button { Text = "Edit text", AutoSize = true, Margin = new Forms.Padding(2) };
        edit.Click += (_, _) => canvas.EditText();
        var delete = new Forms.Button { Text = "Delete", AutoSize = true, Margin = new Forms.Padding(2) };
        delete.Click += (_, _) => { if (canvas.Selected is string id) canvas.Apply(() => canvas.Document.Delete(id)); canvas.Focus(); };
        var cancel = new Forms.Button { Text = "Cancel", AutoSize = true, Margin = new Forms.Padding(2) };
        cancel.Click += (_, _) => Close();
        var save = new Forms.Button { Text = returnOnly ? "Done" : "Save only", AutoSize = true, Margin = new Forms.Padding(2) };
        save.Click += (_, _) => SaveAnnotated(shot, output);
        var insert = new Forms.Button { Text = "Insert into OpenCode", AutoSize = true, Margin = new Forms.Padding(2) };
        tips.SetToolTip(insert, "Insert into OpenCode's draft (Ctrl+Enter)");
        tips.SetToolTip(save, returnOnly ? "Return to composer (Ctrl+Enter)" : "Save without inserting");
        toolRow.Controls.AddRange(new Forms.Control[] { color, width, undo, redo, copy, edit, delete, cancel, save });
        if (!returnOnly) toolRow.Controls.Add(insert);
        var crops = new Forms.FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Forms.Padding(0, 4, 0, 0), Visible = false };
        crops.Controls.AddRange(new Forms.Control[] { applyCrop, resetCrop, cancelCrop });
        hint = new Forms.Label
        {
            Text = "Drag ≡ to move · V select · A arrow · R box · P draw · T text · C crop · Enter commits text · Shift+Enter newline · Escape cancels · Ctrl+Enter confirms · Ctrl+C copy · Ctrl+Z undo · Ctrl+D duplicate",
            AutoSize = true,
            Margin = new Forms.Padding(0, 6, 0, 0),
        };
        var stack = new Forms.FlowLayoutPanel { AutoSize = true, FlowDirection = Forms.FlowDirection.TopDown, WrapContents = false, Margin = new Forms.Padding(0), Padding = new Forms.Padding(0) };
        stack.Controls.Add(toolRow);
        stack.Controls.Add(crops);
        stack.Controls.Add(hint);
        tray = new Forms.Panel { AutoSize = true, AutoSizeMode = Forms.AutoSizeMode.GrowAndShrink, BackColor = Color.FromArgb(245, 245, 247), Padding = new Forms.Padding(12, 10, 12, 10) };
        tray.Controls.Add(stack);
        Point? gripScreen = null;
        grip.MouseDown += (_, e) => { if (e.Button == Forms.MouseButtons.Left) { gripScreen = grip.PointToScreen(e.Location); grip.Capture = true; } };
        grip.MouseMove += (_, e) =>
        {
            if (gripScreen is not Point previous || e.Button != Forms.MouseButtons.Left) return;
            var now = grip.PointToScreen(e.Location);
            toolbarOffset = ToolbarPlacement.Move(toolbarOffset, ClientSize, tray.Size, now.X - previous.X, now.Y - previous.Y);
            gripScreen = now;
            PlaceToolbar();
        };
        grip.MouseUp += (_, _) => gripScreen = null;
        canvas.CopyRequested += () => CopyImage(shot, output, copy);
        canvas.Changed += () =>
        {
            foreach (var pair in tools) pair.Value.BackColor = pair.Key == canvas.Tool ? Color.LightSkyBlue : SystemColors.Control;
            undo.Enabled = canvas.IsEditing ? canvas.InlineEditor!.CanUndo : canvas.Document.CanUndo;
            redo.Enabled = !canvas.IsEditing && canvas.Document.CanRedo;
            edit.Enabled = canvas.Selection?.Kind == "Text"; delete.Enabled = canvas.Selection != null;
            bool cropping = canvas.Tool == "Crop";
            crops.Visible = applyCrop.Visible = resetCrop.Visible = cancelCrop.Visible = cropping;
            applyCrop.Enabled = canvas.CropSelection != null;
            if (canvas.Selection is Mark mark)
            {
                ShowInk(color, Color.FromArgb(mark.Color));
                int nearest = 0;
                float best = float.MaxValue;
                for (int i = 0; i < widths.Length; i++)
                {
                    float distance = Math.Abs(widths[i] - mark.Width);
                    if (distance < best) { best = distance; nearest = i; }
                }
                if (width.SelectedIndex != nearest) { adjustingWidth = true; width.SelectedIndex = nearest; adjustingWidth = false; }
            }
            PlaceToolbar();
        };
        Controls.Add(canvas);
        Controls.Add(tray);
        tray.BringToFront();
        ShowInk(color, canvas.Ink);
        if (!returnOnly) insert.Click += async (_, _) => await InsertIntoOpenCode(shot, output);
        arranged = true;
        canvas.RefreshState();
    }

    static void ShowInk(Forms.Button color, Color ink)
    {
        color.BackColor = ink;
        color.ForeColor = ink.GetBrightness() > 0.6f ? Color.Black : Color.White;
    }

    void PlaceToolbar()
    {
        if (!arranged || tray.IsDisposed || ClientSize.Width < 80 || ClientSize.Height < 80) return;
        int limit = Math.Max(280, ClientSize.Width - 16);
        toolRow.MaximumSize = new Size(Math.Max(200, limit - 28), 0);
        if (hint != null) hint.MaximumSize = new Size(Math.Max(160, limit - 36), 0);
        tray.MaximumSize = new Size(limit, 0);
        tray.PerformLayout();
        toolbarOffset = ToolbarPlacement.Move(toolbarOffset, ClientSize, tray.Size, 0, 0);
        tray.Location = new Point((ClientSize.Width - tray.Width) / 2 + toolbarOffset.Center, ClientSize.Height - tray.Height - toolbarOffset.Bottom);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        ActiveSurface.Push(this);
        var area = Forms.Screen.FromPoint(Forms.Cursor.Position).WorkingArea;
        int maxW = Math.Max(320, area.Width - 24);
        int maxH = Math.Max(240, area.Height - 24);
        MinimumSize = new Size(Math.Min(720, maxW), Math.Min(480, maxH));
        var pixels = canvas.PixelSize;
        float scale = Math.Min(maxW / (float)Math.Max(1, pixels.Width), maxH / (float)Math.Max(1, pixels.Height));
        int width = Math.Min(maxW, Math.Max(MinimumSize.Width, (int)Math.Round(pixels.Width * scale)));
        int height = Math.Min(maxH, Math.Max(MinimumSize.Height, (int)Math.Round(pixels.Height * scale)));
        ClientSize = new Size(width, height);
        int x = Math.Clamp(area.Left + (area.Width - Width) / 2, area.Left, Math.Max(area.Left, area.Right - Width));
        int y = Math.Clamp(area.Top + (area.Height - Height) / 2, area.Top, Math.Max(area.Top, area.Bottom - Height));
        Location = new Point(x, y);
        PlaceToolbar();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        PlaceToolbar();
    }

    protected override void OnFormClosed(Forms.FormClosedEventArgs e)
    {
        ActiveSurface.Pop(this);
        tips.Dispose();
        base.OnFormClosed(e);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.ExcludeFromCapture(Handle);
    }
    protected override bool ProcessCmdKey(ref Forms.Message msg, Forms.Keys keyData)
    {
        if (ActiveControl is Forms.ComboBox) return base.ProcessCmdKey(ref msg, keyData);
        if (canvas.IsEditing && keyData == Forms.Keys.Escape) { canvas.CancelInline(); return true; }
        bool enter = (keyData & Forms.Keys.KeyCode) == Forms.Keys.Enter;
        bool shift = (keyData & Forms.Keys.Shift) != 0;
        if (canvas.IsEditing && enter && !shift) { canvas.CommitInline(); return true; }
        if (canvas.IsEditing) return base.ProcessCmdKey(ref msg, keyData);
        if (canvas.Enabled && keyData == (Forms.Keys.Control | Forms.Keys.Enter)) { PrimaryAction(); return true; }
        if (canvas.Enabled && canvas.Key(keyData)) return true;
        if (keyData == Forms.Keys.Escape && canvas.Enabled) { Close(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    void PrimaryAction()
    {
        if (!canvas.Enabled || inserting) return;
        foreach (Forms.Control button in toolRow.Controls)
            if (button is Forms.Button choice && ((returnOnly && choice.Text == "Done") || (!returnOnly && choice.Text.StartsWith("Insert"))))
            {
                choice.PerformClick();
                return;
            }
    }

    void SaveAnnotated(Snapshot shot, string output)
    {
        try
        {
            canvas.CommitInline();
            if (canvas.Tool == "Crop") canvas.ApplyCrop();
            var exported = AnnotationDocument.Export(shot, canvas.Document, output);
            Saved = true;
            Completed = true;
            if (returnOnly) { Result = exported; DialogResult = Forms.DialogResult.OK; }
            Close();
        }
        catch (Exception error) { Forms.MessageBox.Show(this, error.Message, "Motifs"); }
    }

    async Task InsertIntoOpenCode(Snapshot shot, string output)
    {
        if (inserting) return;
        inserting = true;
        canvas.Enabled = tray.Enabled = false;
        try
        {
            canvas.CommitInline();
            if (canvas.Tool == "Crop") canvas.ApplyCrop();
            var annotated = AnnotationDocument.Export(shot, canvas.Document, output);
            Saved = true;
            await Inserter.Insert(annotated, output);
            Inserted = true;
            Completed = true;
            Close();
        }
        catch (Exception error)
        {
            InsertError = error.Message;
            Forms.MessageBox.Show(this, TrayCopy.InsertFailedBody(error.Message), TrayCopy.InsertFailedTitle);
        }
        finally
        {
            inserting = false;
            if (!IsDisposed) canvas.Enabled = tray.Enabled = true;
        }
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
