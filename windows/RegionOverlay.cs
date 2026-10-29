using System;
using System.Drawing;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace OpenCode.Appshots;

internal enum CaptureKind { Window, Region, Display }

internal sealed record CaptureChoice(CaptureKind Kind, nint Window, Rectangle Bounds);

// Full-screen dimmer. Drag chooses a visible region. A click chooses the window
// under the pointer, or the display when the pointer is not over an app window.
internal sealed class RegionOverlay : Form
{
    const string HintText = "Drag an area or click a window    ·    Enter full screen    ·    Esc cancel";
    readonly string hint;
    Point? anchor;
    Rectangle selection;
    nint hovered;
    Rectangle hoveredBounds;
    internal CaptureChoice? Choice;

    internal RegionOverlay(string? hint = null)
    {
        this.hint = hint ?? HintText;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = SystemInformation.VirtualScreen;
        BackColor = Color.Black;
        Opacity = 0.45;
        TopMost = true;
        ShowInTaskbar = false;
        Cursor = Cursors.Cross;
        KeyPreview = true;
        DoubleBuffered = true;
        Text = "Capture Studio";
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Activate();
        Focus();
        UpdateHover(PointToClient(Cursor.Position));
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        UpdateHover(e.Location);
        anchor = e.Location;
        selection = Rectangle.Empty;
        Capture = true;
        ClearRegion();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (anchor is Point start)
        {
            var next = ComposerFiles.Selection(start, e.Location, ClientRectangle);
            selection = next ?? Rectangle.Empty;
            using var hole = new Region(ClientRectangle);
            if (next is Rectangle chosen) hole.Exclude(chosen);
            var previous = Region;
            Region = hole.Clone();
            previous?.Dispose();
            return;
        }
        UpdateHover(e.Location);
    }

    void UpdateHover(Point client)
    {
        var screen = PointToScreen(client);
        nint window = TopWindow(Native.WindowFromPoint(new Native.NativePoint { X = screen.X, Y = screen.Y }));
        if (!UsableWindow(window)) window = 0;
        hovered = window;
        hoveredBounds = window == 0 || !Native.GetWindowRect(window, out var rect)
            ? Rectangle.Empty
            : RectangleToClient(Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom));
        Invalidate();
    }

    void ClearRegion()
    {
        var previous = Region;
        Region = null;
        previous?.Dispose();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left || anchor == null) return;
        Capture = false;
        var chosen = ComposerFiles.Selection(anchor.Value, e.Location, ClientRectangle);
        anchor = null;
        if (chosen is Rectangle region)
        {
            Choice = new CaptureChoice(CaptureKind.Region, 0, ScreenRect(region));
            DialogResult = DialogResult.OK;
            return;
        }
        if (hovered != 0)
        {
            Choice = new CaptureChoice(CaptureKind.Window, hovered, Rectangle.Empty);
            DialogResult = DialogResult.OK;
            return;
        }
        ChooseDisplay();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (selection.IsEmpty && hoveredBounds.Width > 40 && hoveredBounds.Height > 40)
        {
            using var fill = new SolidBrush(Color.FromArgb(40, 110, 200, 255));
            using var pen = new Pen(Color.DeepSkyBlue, 3);
            e.Graphics.FillRectangle(fill, hoveredBounds);
            e.Graphics.DrawRectangle(pen, hoveredBounds);
        }
        var font = new Font("Segoe UI", 11, FontStyle.Regular, GraphicsUnit.Point);
        var size = e.Graphics.MeasureString(hint, font);
        var pill = new RectangleF((ClientSize.Width - size.Width) / 2 - 16, ClientSize.Height - 78, size.Width + 32, size.Height + 14);
        using var background = new SolidBrush(Color.FromArgb(210, 20, 20, 20));
        e.Graphics.FillRectangle(background, pill);
        e.Graphics.DrawString(hint, font, Brushes.White, pill.X + 16, pill.Y + 7);
        font.Dispose();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { DialogResult = DialogResult.Cancel; return true; }
        if (keyData == Keys.Enter) { ChooseDisplay(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    void ChooseDisplay()
    {
        var screen = Screen.FromPoint(Cursor.Position);
        Choice = new CaptureChoice(CaptureKind.Display, 0, screen.Bounds);
        DialogResult = DialogResult.OK;
    }

    Rectangle ScreenRect(Rectangle client)
    {
        var origin = PointToScreen(client.Location);
        var far = PointToScreen(new Point(client.Right, client.Bottom));
        return Rectangle.FromLTRB(origin.X, origin.Y, far.X, far.Y);
    }

    static nint TopWindow(nint window)
    {
        if (window == 0) return 0;
        nint root = Native.GetAncestor(window, 2);
        return root == 0 ? window : root;
    }

    bool UsableWindow(nint window)
    {
        if (window == 0 || window == Handle || !Native.IsWindowVisible(window) || Native.IsIconic(window)) return false;
        Native.GetWindowThreadProcessId(window, out uint pid);
        if (pid == (uint)Environment.ProcessId || Native.GetWindowTextLength(window) == 0) return false;
        return Native.GetWindowRect(window, out var rect) && rect.Right - rect.Left >= 40 && rect.Bottom - rect.Top >= 40;
    }
}

internal static class CaptureSelector
{
    internal static async Task<Snapshot> Take(CaptureChoice choice, string output)
    {
        switch (choice.Kind)
        {
            case CaptureKind.Window:
                return await Program.CaptureIsolated(choice.Window, output);
            case CaptureKind.Region:
                return Program.CaptureBounds(choice.Bounds, output, "Region");
            case CaptureKind.Display:
                return Program.CaptureBounds(choice.Bounds, output, "Full screen");
            default:
                throw new InvalidOperationException("Unknown capture.");
        }
    }
}
