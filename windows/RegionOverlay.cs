using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Motifs;

internal enum CaptureKind { Window, Region, Display }

// The chooser names the window under the pointer and shows the dragged size.
internal static class CaptureChrome
{
    internal static string WindowLabel(string app) => " " + (string.IsNullOrWhiteSpace(app) ? "Window" : app.Trim()) + " ";

    internal static string SizeLabel(int width, int height) => width.ToString(System.Globalization.CultureInfo.InvariantCulture) + " × " + height.ToString(System.Globalization.CultureInfo.InvariantCulture);

    internal static string AppName(nint window)
    {
        try
        {
            Native.GetWindowThreadProcessId(window, out uint pid);
            using var process = Process.GetProcessById((int)pid);
            string? path = null;
            try { path = process.MainModule?.FileName; } catch { path = null; }
            if (!string.IsNullOrWhiteSpace(path))
            {
                string description = FileVersionInfo.GetVersionInfo(path).FileDescription ?? "";
                if (!string.IsNullOrWhiteSpace(description)) return description.Trim();
            }
            return process.ProcessName;
        }
        catch { return ""; }
    }

    internal static Point WindowLabelOrigin(Rectangle window, Size label, Rectangle bounds)
    {
        int x = Math.Max(bounds.Left + 8, Math.Min(window.Left + 8, bounds.Right - label.Width - 8));
        int y = window.Bottom - label.Height - 8;
        if (y < bounds.Top + 8) y = Math.Min(bounds.Bottom - label.Height - 8, window.Top + 8);
        return new Point(x, Math.Max(bounds.Top + 8, y));
    }

    internal static Point SizeLabelOrigin(Rectangle selection, Size label, Rectangle bounds)
    {
        int x = Math.Min(bounds.Right - label.Width - 8, Math.Max(bounds.Left + 8, selection.Left + 6));
        int below = selection.Bottom + 6;
        int y = below + label.Height <= bounds.Bottom - 8 ? below : Math.Max(bounds.Top + 8, selection.Top - label.Height - 6);
        return new Point(x, y);
    }
}

internal sealed record CaptureChoice(CaptureKind Kind, nint Window, Rectangle Bounds);

// The chooser closes when another application is in front. This process, including the composer button, stays up.
internal static class ChooserFocus
{
    internal static bool ShouldCancel(uint ourPid, uint foregroundPid) => foregroundPid != 0 && foregroundPid != ourPid;
}

// Full-screen dimmer. Drag chooses a visible region. A click chooses the window
// under the pointer, or the display when the pointer is not over an app window.
internal sealed class RegionOverlay : Form
{
    const string HintText = "Drag an area or click a window    ·    Enter full screen    ·    Esc cancel";
    readonly string hint;
    readonly string? captures;
    Point? anchor;
    Rectangle selection;
    nint hovered;
    Rectangle hoveredBounds;
    string hoveredApp = "";
    readonly Timer otherApps = new() { Interval = 200 };
    ComposerBubble? bubble;
    bool armed;
    internal CaptureChoice? Choice;
    internal bool OpenComposerInstead { get; private set; }

    internal RegionOverlay(string? hint = null, string? output = null)
    {
        captures = output;
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
        Text = "Motifs";
        otherApps.Tick += (_, _) => CancelIfAnotherApp();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.ExcludeFromCapture(Handle);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        ActiveSurface.Push(this);
        Activate();
        Focus();
        UpdateHover(PointToClient(Cursor.Position));
        if (!string.IsNullOrEmpty(captures) && ComposerFiles.ShowBubble(ComposerFiles.Settings(captures)))
            bubble = ComposerBubble.Show(this, SkipToComposer, HideBubble);
        armed = true;
        otherApps.Start();
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        if (!armed || IsDisposed || !IsHandleCreated || DialogResult != DialogResult.None) return;
        try { BeginInvoke(CancelIfAnotherApp); }
        catch (InvalidOperationException) { /* The chooser is already closing. */ }
    }

    void CancelIfAnotherApp()
    {
        if (!armed || IsDisposed || DialogResult != DialogResult.None) return;
        nint foreground = Native.GetForegroundWindow();
        Native.GetWindowThreadProcessId(foreground, out uint pid);
        if (!ChooserFocus.ShouldCancel((uint)Environment.ProcessId, pid)) return;
        DialogResult = DialogResult.Cancel;
    }

    void SkipToComposer()
    {
        OpenComposerInstead = true;
        DialogResult = DialogResult.Cancel;
    }

    void HideBubble()
    {
        if (string.IsNullOrEmpty(captures)) return;
        var settings = ComposerFiles.Settings(captures);
        settings["showBubble"] = false;
        ComposerFiles.SaveSettings(captures, settings, false);
        bubble?.Hide();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        otherApps.Stop();
        ActiveSurface.Pop(this);
        base.OnFormClosed(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            otherApps.Dispose();
            bubble?.Dispose();
        }
        base.Dispose(disposing);
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
            if (next is Rectangle chosen)
            {
                var opening = Rectangle.Inflate(chosen, -2, -2);
                if (opening.Width > 0 && opening.Height > 0) hole.Exclude(opening);
            }
            var previous = Region;
            Region = hole.Clone();
            previous?.Dispose();
            Invalidate();
            return;
        }
        UpdateHover(e.Location);
    }

    void UpdateHover(Point client)
    {
        var screen = PointToScreen(client);
        nint window = TopWindow(Native.WindowFromPoint(new Native.NativePoint { X = screen.X, Y = screen.Y }));
        if (!UsableWindow(window)) window = 0;
        var bounds = window == 0 || !Native.GetWindowRect(window, out var rect)
            ? Rectangle.Empty
            : RectangleToClient(Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom));
        if (window == hovered && bounds == hoveredBounds) return;
        hovered = window;
        hoveredBounds = bounds;
        hoveredApp = window == 0 ? "" : CaptureChrome.AppName(window);
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
        if (!selection.IsEmpty)
        {
            using var border = new Pen(Color.White, 1.5f);
            e.Graphics.DrawRectangle(border, selection.X, selection.Y, Math.Max(1, selection.Width - 1), Math.Max(1, selection.Height - 1));
            var captured = ScreenRect(selection);
            DrawTag(e.Graphics, CaptureChrome.SizeLabel(captured.Width, captured.Height), CaptureChrome.SizeLabelOrigin(selection, new Size(120, 18), ClientRectangle));
        }
        else if (hoveredBounds.Width > 40 && hoveredBounds.Height > 40)
        {
            using var fill = new SolidBrush(Color.FromArgb(40, 110, 200, 255));
            using var pen = new Pen(Color.DeepSkyBlue, 3);
            e.Graphics.FillRectangle(fill, hoveredBounds);
            e.Graphics.DrawRectangle(pen, hoveredBounds);
            DrawTag(e.Graphics, CaptureChrome.WindowLabel(hoveredApp), CaptureChrome.WindowLabelOrigin(hoveredBounds, new Size(160, 18), ClientRectangle));
        }
        var font = new Font("Segoe UI", 11, FontStyle.Regular, GraphicsUnit.Point);
        var size = e.Graphics.MeasureString(hint, font);
        var pill = new RectangleF((ClientSize.Width - size.Width) / 2 - 16, ClientSize.Height - 78, size.Width + 32, size.Height + 14);
        using var background = new SolidBrush(Color.FromArgb(210, 20, 20, 20));
        e.Graphics.FillRectangle(background, pill);
        e.Graphics.DrawString(hint, font, Brushes.White, pill.X + 16, pill.Y + 7);
        font.Dispose();
    }

    static void DrawTag(Graphics graphics, string text, Point origin)
    {
        using var font = new Font("Segoe UI", 12, FontStyle.Regular, GraphicsUnit.Point);
        var size = graphics.MeasureString(text, font);
        using var background = new SolidBrush(Color.FromArgb(160, 0, 0, 0));
        graphics.FillRectangle(background, origin.X, origin.Y, size.Width + 6, size.Height + 2);
        graphics.DrawString(text, font, Brushes.White, origin.X + 3, origin.Y);
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

// A circle above the capture hint. Clicking it skips the screenshot and opens the composer.
internal sealed class ComposerBubble : Form
{
    internal const int Diameter = 44;
    internal const int Gap = 88;
    internal const string MenuTitle = "Show composer button while capturing";
    internal const string MenuTip = "While Ctrl+Alt+Shift+A is choosing what to capture, a small circle skips the capture and opens the composer with Recents, so you can write a note or reopen a recent capture.";
    internal const string Tip = "Skip the capture and open the composer, with Recents";

    internal static Rectangle BoundsOn(Rectangle screen)
    {
        int x = screen.Left + Math.Max(0, (screen.Width - Diameter) / 2);
        int y = screen.Bottom - Gap - Diameter;
        if (y < screen.Top) y = screen.Top;
        return new Rectangle(x, y, Diameter, Diameter);
    }

    internal static ComposerBubble Show(Form owner, Action open, Action hideFromMenu)
    {
        var bubble = new ComposerBubble(open, hideFromMenu);
        bubble.Show(owner);
        return bubble;
    }

    ComposerBubble(Action open, Action hideFromMenu)
    {
        var screen = Screen.FromPoint(Cursor.Position).Bounds;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        Bounds = BoundsOn(screen);
        BackColor = Color.White;
        using (var path = new GraphicsPath())
        {
            path.AddEllipse(0, 0, Diameter, Diameter);
            Region = new Region(path);
        }
        var button = new Button
        {
            Text = "✎",
            Dock = DockStyle.Fill,
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.White,
            ForeColor = Color.FromArgb(20, 20, 20),
            Font = new Font("Segoe UI", 14, FontStyle.Bold),
            TabStop = false,
        };
        button.FlatAppearance.BorderSize = 0;
        button.AccessibleName = "Skip capture and open the composer";
        var tips = new ToolTip { ShowAlways = true };
        tips.SetToolTip(button, Tip);
        Disposed += (_, _) => tips.Dispose();
        button.Click += (_, _) => open();
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open composer", null, (_, _) => open());
        menu.Items.Add("Hide floating button", null, (_, _) => hideFromMenu());
        button.ContextMenuStrip = menu;
        Controls.Add(button);
        Text = "Motifs composer button";
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.ExcludeFromCapture(Handle);
    }

    protected override bool ShowWithoutActivation => true;
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
