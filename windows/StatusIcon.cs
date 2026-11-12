using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace OpenCode.Appshots;

internal enum StatusGlyph { Ready, Success, Warning, Replay, Recording }

// Tray hover text follows the macOS menu, with the Windows shortcut and command.
internal static class TrayCopy
{
    internal const string Ready = "Capture Studio — capture and compose (Ctrl+Alt+Shift+A)";
    internal const string Recording = "Capture Studio — recording the screen. Press Ctrl+Alt+Shift+R or use the menu to stop.";
    internal const string Replay = "Capture Studio — instant replay keeps the last 30 seconds in memory. Ctrl+Alt+Shift+A attaches it.";
    internal const string ShortcutUnavailable = "Capture Studio — shortcut unavailable. Use the capture menu.";
    internal const string ReplayMenu = "Keeps the last 30 seconds of the display in memory only; Ctrl+Alt+Shift+A attaches it to the capture. Instant replay may still include Capture Studio windows.";
    internal const string JudgeMenu = "Secrets in known formats are always redacted before anything leaves this PC. A decision model running on this PC (Laya, Clef-flash) can check values that only might be secrets; without it, those are redacted too. Hosted models are not allowed.";
    internal const string CaptureFailedTitle = "Capture Studio could not capture this window";
    internal const string InsertFailedTitle = "Capture Studio could not insert into OpenCode";
    internal const string InsertedLatest = "Inserted latest capture into OpenCode. Add a question and send when ready.";

    internal static string Tip(StatusGlyph shown) => shown switch
    {
        StatusGlyph.Recording => Recording,
        StatusGlyph.Replay => Replay,
        StatusGlyph.Ready or StatusGlyph.Success or StatusGlyph.Warning => Ready,
        _ => throw new InvalidOperationException($"Unexpected tray state {shown}."),
    };

    internal static string RecordTitle(bool recording) => recording ? "Stop screen recording (Ctrl+Alt+Shift+R)" : "Start screen recording… (Ctrl+Alt+Shift+R)";

    internal static string Inserted(string? app) => "Inserted " + (string.IsNullOrWhiteSpace(app) ? "app" : app) + " into OpenCode. Add a question and send when ready.";

    internal static string InsertFailed(string message) => "Capture saved. Could not insert into OpenCode: " + message;

    internal static string InsertFailedBody(string message) => message + "\nYour saved capture is still available through /capture-studio.";

    internal static string Fit(string text) => text.Length <= 127 ? text : text[..127];
}

// The menu-bar mark from the macOS helper: a capture frame and a speech bubble.
// Strokes are black on a light taskbar and white on a dark one, which is how a
// macOS template image adapts. Recording fills the top dot, replay strokes that
// ring, success fills the bottom dot, and warning draws a mark in the bubble.
internal static class StatusIcon
{
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool DestroyIcon(nint handle);

    internal static Icon Create(StatusGlyph status, bool lightBackground)
    {
        using var bitmap = Draw(status, lightBackground);
        nint handle = bitmap.GetHicon();
        try
        {
            using var temporary = Icon.FromHandle(handle);
            return (Icon)temporary.Clone();
        }
        finally { DestroyIcon(handle); }
    }

    internal static bool LightTaskbar()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("SystemUsesLightTheme") is int theme) return theme != 0;
        }
        catch { }
        return true;
    }

    internal static Bitmap Draw(StatusGlyph status, bool lightBackground)
    {
        const int size = 32;
        var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        float scale = size / 18f;
        graphics.TranslateTransform(0, size);
        graphics.ScaleTransform(scale, -scale);
        var color = lightBackground ? Color.Black : Color.White;
        using var ink = new SolidBrush(color);
        using var framePen = new Pen(color, 1.5f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        using var frame = new GraphicsPath();
        Corner(frame, 1.5f, 12.5f, 1.5f, 16.5f, 5.5f, 16.5f);
        Corner(frame, 12.5f, 16.5f, 16.5f, 16.5f, 16.5f, 12.5f);
        Corner(frame, 1.5f, 5.5f, 1.5f, 1.5f, 5.5f, 1.5f);
        Corner(frame, 12.5f, 1.5f, 16.5f, 1.5f, 16.5f, 5.5f);
        graphics.DrawPath(framePen, frame);
        using var bubblePen = new Pen(color, 1.35f) { LineJoin = LineJoin.Round };
        using var bubble = new GraphicsPath();
        bubble.AddLine(6, 12.5f, 12, 12.5f);
        bubble.AddBezier(12, 12.5f, 13, 12.5f, 13.5f, 12, 13.5f, 11);
        bubble.AddLine(13.5f, 11, 13.5f, 8);
        bubble.AddBezier(13.5f, 8, 13.5f, 7, 13, 6.5f, 12, 6.5f);
        bubble.AddLine(12, 6.5f, 8.5f, 6.5f);
        bubble.AddLine(8.5f, 6.5f, 6, 4.5f);
        bubble.AddLine(6, 4.5f, 6, 6.5f);
        bubble.AddBezier(6, 6.5f, 5, 6.5f, 4.5f, 7, 4.5f, 8);
        bubble.AddLine(4.5f, 8, 4.5f, 11);
        bubble.AddBezier(4.5f, 11, 4.5f, 12, 5, 12.5f, 6, 12.5f);
        bubble.CloseFigure();
        graphics.DrawPath(bubblePen, bubble);
        if (status == StatusGlyph.Success) graphics.FillEllipse(ink, 14.5f, 0.5f, 3, 3);
        if (status == StatusGlyph.Recording) graphics.FillEllipse(ink, 12.5f, 12.5f, 5.5f, 5.5f);
        if (status == StatusGlyph.Replay)
        {
            using var ring = new Pen(color, 1.2f);
            graphics.DrawEllipse(ring, 13.25f, 13.25f, 4, 4);
        }
        if (status == StatusGlyph.Warning)
        {
            using var mark = new Pen(color, 1.5f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            graphics.DrawLine(mark, 9, 10.7f, 9, 9.1f);
            graphics.FillEllipse(ink, 8.4f, 7.5f, 1.2f, 1.2f);
        }
        return bitmap;
    }

    static void Corner(GraphicsPath path, float x1, float y1, float x2, float y2, float x3, float y3)
    {
        path.StartFigure();
        path.AddLine(x1, y1, x2, y2);
        path.AddLine(x2, y2, x3, y3);
    }

    internal static void Check()
    {
        using var ready = Draw(StatusGlyph.Ready, true);
        using var recording = Draw(StatusGlyph.Recording, true);
        using var replay = Draw(StatusGlyph.Replay, true);
        using var success = Draw(StatusGlyph.Success, true);
        using var warning = Draw(StatusGlyph.Warning, true);
        using var dark = Draw(StatusGlyph.Ready, false);
        var top = new Rectangle(16, 0, 16, 16);
        var bottom = new Rectangle(16, 16, 16, 16);
        if (Ink(recording, top) <= Ink(ready, top)) throw new Exception("Status icon regression: recording adds the top dot");
        if (Ink(replay, top) <= Ink(ready, top)) throw new Exception("Status icon regression: replay adds the top ring");
        if (Ink(success, bottom) <= Ink(ready, bottom)) throw new Exception("Status icon regression: success adds the bottom dot");
        if (Ink(warning) <= Ink(ready)) throw new Exception("Status icon regression: warning adds the mark");
        if (!Dark(ready, 1.5f, 16.5f) || !Light(dark, 1.5f, 16.5f)) throw new Exception("Status icon regression: strokes follow the taskbar theme");
    }

    static int Ink(Bitmap bitmap) => Ink(bitmap, new Rectangle(0, 0, bitmap.Width, bitmap.Height));

    static int Ink(Bitmap bitmap, Rectangle area)
    {
        int count = 0;
        for (int y = area.Top; y < area.Bottom; y++)
            for (int x = area.Left; x < area.Right; x++)
                if (bitmap.GetPixel(x, y).A > 40) count++;
        return count;
    }

    static bool Dark(Bitmap bitmap, float x, float y) => Near(bitmap, x, y, color => color.A > 80 && color.R < 80);
    static bool Light(Bitmap bitmap, float x, float y) => Near(bitmap, x, y, color => color.A > 80 && color.R > 180);

    static bool Near(Bitmap bitmap, float x, float y, Func<Color, bool> match)
    {
        float scale = bitmap.Width / 18f;
        int px = (int)Math.Round(x * scale);
        int py = (int)Math.Round(bitmap.Height - (y * scale));
        for (int dy = -2; dy <= 2; dy++)
            for (int dx = -2; dx <= 2; dx++)
            {
                int sx = px + dx, sy = py + dy;
                if ((uint)sx >= (uint)bitmap.Width || (uint)sy >= (uint)bitmap.Height) continue;
                if (match(bitmap.GetPixel(sx, sy))) return true;
            }
        return false;
    }
}
