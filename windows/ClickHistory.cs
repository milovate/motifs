using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Windows.Automation;

namespace OpenCode.Appshots;

// Memory-only click history. Outside a recording it is opt-in and keeps clicks and
// app switches. A screen recording also keeps scrolls, drags, selected text, and
// which field was typed into. The virtual key is never stored.
internal sealed class ClickHistory
{
    internal const int Limit = 300;
    internal const double MaxAge = 600;
    internal static readonly HashSet<string> RecordingKinds = new(StringComparer.Ordinal) { "scroll", "drag", "select", "type" };
    internal static readonly ClickHistory Shared = new();

    readonly object gate = new();
    readonly object scrollGate = new();
    readonly List<Step> entries = new();
    ScrollGesture scroll = new();
    Timer? scrollTimer;
    long sequence;
    bool running;
    bool recording;
    bool hooks;
    string lastTypingKey = "";
    DateTimeOffset lastTypingAt;
    List<JsonObject>? published;
    int dragX;
    int dragY;
    bool dragging;
    bool pendingDouble;
    bool ignoreDrag;
    int lastDownX;
    int lastDownY;
    int lastDownTick = int.MinValue;

    internal bool IsRunning { get { lock (gate) return running; } }
    internal bool IsRecording { get { lock (gate) return recording; } }
    internal bool Watching => ClickHooks.MouseInstalled;

    internal void EnableHooks()
    {
        hooks = true;
        if (IsRunning || IsRecording) ClickHooks.Install(IsRunning, IsRecording);
    }

    internal void DisableHooks()
    {
        hooks = false;
        ClickHooks.Uninstall();
    }

    internal void Start()
    {
        lock (gate)
        {
            if (running) return;
            running = true;
        }
        if (hooks) ClickHooks.Install(true, IsRecording);
    }

    internal void Stop()
    {
        lock (scrollGate)
        {
            scroll = new ScrollGesture();
            scrollTimer?.Dispose();
            scrollTimer = null;
        }
        lock (gate)
        {
            running = false;
            recording = false;
            entries.Clear();
            lastTypingKey = "";
        }
        if (hooks) ClickHooks.Install(false, false);
    }

    internal void BeginRecording()
    {
        Start();
        bool startHooks;
        lock (gate)
        {
            published = null;
            if (recording) return;
            recording = true;
            lastTypingKey = "";
            startHooks = hooks;
        }
        if (startHooks) ClickHooks.Install(true, true);
    }

    internal List<JsonObject> EndRecording(bool keepClicks)
    {
        FlushScroll(false);
        var recorded = Snapshot();
        lock (gate)
        {
            recording = false;
            lastTypingKey = "";
            if (keepClicks) entries.RemoveAll(item => IsRecordingKind(item.Entry));
            else
            {
                running = false;
                entries.Clear();
            }
        }
        if (!keepClicks)
        {
            lock (scrollGate)
            {
                scroll = new ScrollGesture();
                scrollTimer?.Dispose();
                scrollTimer = null;
            }
        }
        if (hooks) ClickHooks.Install(IsRunning, false);
        return recorded;
    }

    internal void Publish(List<JsonObject> events)
    {
        lock (gate) published = events;
    }

    internal List<JsonObject> TakePublished()
    {
        lock (gate)
        {
            var taken = published ?? new List<JsonObject>();
            published = null;
            return taken;
        }
    }

    internal void RecordAppSwitch(string? app)
    {
        if (!IsRunning || string.IsNullOrWhiteSpace(app)) return;
        Append(new JsonObject { ["kind"] = "app-switch", ["app"] = app.Trim() });
    }

    internal void Append(JsonObject entry, DateTimeOffset? now = null)
    {
        var moment = now ?? DateTimeOffset.UtcNow;
        var copy = ComposerFiles.Clone(entry);
        copy["time"] = EventTime(moment);
        lock (gate)
        {
            entries.Add(new Step(sequence++, copy));
            entries.Sort((left, right) =>
            {
                int compared = string.Compare(Text(left.Entry, "time"), Text(right.Entry, "time"), StringComparison.Ordinal);
                return compared != 0 ? compared : left.Seq.CompareTo(right.Seq);
            });
            Trim(moment);
        }
    }

    internal List<JsonObject> Snapshot(DateTimeOffset? now = null)
    {
        var moment = now ?? DateTimeOffset.UtcNow;
        lock (gate)
        {
            Trim(moment);
            return entries.Select(item => ComposerFiles.Clone(item.Entry)).ToList();
        }
    }

    internal void NoteClick(int x, int y, bool left)
    {
        if (!IsRunning) return;
        if (left && ClickProbe.InThisProcess(x, y)) { ignoreDrag = true; return; }
        if (left)
        {
            ignoreDrag = false;
            int tick = Environment.TickCount;
            pendingDouble = tick - lastDownTick <= ClickHooks.DoubleClickTime && Math.Abs(x - lastDownX) < 5 && Math.Abs(y - lastDownY) < 5;
            lastDownTick = tick;
            lastDownX = x;
            lastDownY = y;
            if (IsRecording) { dragX = x; dragY = y; dragging = true; }
        }
        else if (ClickProbe.InThisProcess(x, y)) return;
        ThreadPool.QueueUserWorkItem(_ =>
        {
            var entry = ClickProbe.At(x, y);
            entry["kind"] = "click";
            entry["app"] = ClickProbe.AppAt(x, y);
            Append(entry);
        });
    }

    internal void NoteRelease(int x, int y)
    {
        if (!IsRecording || ignoreDrag) { dragging = false; pendingDouble = false; ignoreDrag = false; return; }
        bool dragged = dragging && Math.Sqrt(((x - dragX) * (double)(x - dragX)) + ((y - dragY) * (double)(y - dragY))) > 5;
        bool twice = pendingDouble;
        dragging = false;
        pendingDouble = false;
        if (!dragged && !twice) return;
        string app = ClickProbe.QuickAppAt(x, y);
        ThreadPool.QueueUserWorkItem(_ =>
        {
            Thread.Sleep(80);
            var selection = ClickProbe.Selection();
            if (selection != null)
            {
                selection["kind"] = "select";
                selection["app"] = app;
                Append(selection);
                return;
            }
            if (dragged) Append(new JsonObject { ["kind"] = "drag", ["app"] = app });
        });
    }

    internal void NoteWheel(int x, int y, double dx, double dy)
    {
        if (!IsRecording || (dx == 0 && dy == 0)) return;
        string app = ClickProbe.QuickAppAt(x, y);
        ScrollGesture rejected;
        bool split;
        lock (scrollGate)
        {
            var now = DateTimeOffset.UtcNow;
            split = !scroll.Add(app, x, y, dx, dy, now);
            rejected = split ? scroll : new ScrollGesture();
            if (split)
            {
                scroll = new ScrollGesture();
                scroll.Add(app, x, y, dx, dy, now);
            }
            scrollTimer ??= new Timer(_ => FlushScroll(true), null, Timeout.Infinite, Timeout.Infinite);
            scrollTimer.Change(TimeSpan.FromSeconds(ScrollGesture.Gap), Timeout.InfiniteTimeSpan);
        }
        if (split)
        {
            var earlier = rejected;
            ThreadPool.QueueUserWorkItem(_ => CommitScroll(earlier, true));
        }
    }

    // The key code is used only to ignore shortcuts. It is not written into the entry.
    internal void NoteTyping(int virtualKey)
    {
        if (!IsRecording || ClickHooks.IsModifier(virtualKey) || ClickHooks.ShortcutHeld()) return;
        string app = ClickProbe.ForegroundApp(false);
        ThreadPool.QueueUserWorkItem(_ =>
        {
            if (!ClickProbe.TryFocus(out string key, out var described)) return;
            var now = DateTimeOffset.UtcNow;
            lock (gate)
            {
                bool same = key.Length > 0 && key == lastTypingKey && (now - lastTypingAt).TotalSeconds < 30;
                lastTypingKey = key;
                lastTypingAt = now;
                if (same) return;
            }
            described["kind"] = "type";
            described["app"] = app;
            Append(described, now);
        });
    }

    internal void NoteForeground(nint window)
    {
        if (!IsRunning) return;
        ThreadPool.QueueUserWorkItem(_ => RecordAppSwitch(ClickProbe.AppFromWindow(window)));
    }

    internal static string EventTime(DateTimeOffset time) => time.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", System.Globalization.CultureInfo.InvariantCulture);

    internal static JsonObject Describe(string? role, string? subrole, string? title)
    {
        var result = new JsonObject();
        if (!string.IsNullOrEmpty(role)) result["role"] = role;
        if (!IsSecure(role, subrole) && title != null)
        {
            string trimmed = title.Trim();
            if (trimmed.Length > 0) result["title"] = trimmed.Length <= 120 ? trimmed : trimmed[..120];
        }
        return result;
    }

    internal static JsonObject? SelectionEntry(string? text, string? role, string? subrole, string? title)
    {
        if (IsSecure(role, subrole) || text == null) return null;
        string trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        var result = Describe(role, subrole, title);
        result["text"] = trimmed.Length <= 200 ? trimmed : trimmed[..200];
        return result;
    }

    internal static bool IsSecure(string? role, string? subrole) => role == "AXSecureTextField" || subrole == "AXSecureTextField";

    // Keeps steps that fall inside the clip. Page steps will replace these for browser apps once that host exists.
    internal static List<JsonObject> ForClip(IReadOnlyList<JsonObject> native, JsonObject video)
    {
        var timed = new List<(DateTimeOffset When, JsonObject Entry)>();
        foreach (var entry in native)
        {
            if (Text(entry, "time") is not string text || !DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out var when)) continue;
            if (ContextReview.Offset(when, video) == null) continue;
            var copy = ComposerFiles.Clone(entry);
            copy["source"] = "app";
            timed.Add((when, copy));
        }
        return timed.OrderBy(item => item.When).TakeLast(Limit).Select(item => item.Entry).ToList();
    }

    void FlushScroll(bool describe)
    {
        ScrollGesture finished;
        lock (scrollGate)
        {
            finished = scroll;
            scroll = new ScrollGesture();
            scrollTimer?.Dispose();
            scrollTimer = null;
        }
        CommitScroll(finished, describe);
    }

    void CommitScroll(ScrollGesture finished, bool describe)
    {
        if (finished.Entry() is not JsonObject entry) return;
        if (describe)
        {
            var described = ClickProbe.At(finished.X, finished.Y);
            foreach (var pair in described)
            {
                if (pair.Value != null && !entry.ContainsKey(pair.Key)) entry[pair.Key] = pair.Value.DeepClone();
            }
        }
        Append(entry, finished.Started);
    }

    void Trim(DateTimeOffset now)
    {
        entries.RemoveAll(item =>
        {
            if (Text(item.Entry, "time") is not string text || !DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out var when)) return true;
            return (now - when).TotalSeconds > MaxAge;
        });
        if (entries.Count > Limit) entries.RemoveRange(0, entries.Count - Limit);
    }

    static bool IsRecordingKind(JsonObject entry) => Text(entry, "kind") is string kind && RecordingKinds.Contains(kind);

    static string? Text(JsonObject entry, string key) => entry[key] is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    readonly record struct Step(long Seq, JsonObject Entry);
}

// Joins wheel notches into one gesture while they keep arriving in the same app.
internal struct ScrollGesture
{
    internal const double Gap = 0.8;
    string app;
    int x;
    int y;
    DateTimeOffset started;
    DateTimeOffset last;
    double dx;
    double dy;
    bool open;

    internal int X => x;
    internal int Y => y;
    internal DateTimeOffset Started => started;
    internal bool IsEmpty => !open;

    internal bool Add(string app, int x, int y, double dx, double dy, DateTimeOffset now)
    {
        if (open && (app != this.app || (now - last).TotalSeconds > Gap)) return false;
        if (!open)
        {
            this.app = app;
            this.x = x;
            this.y = y;
            started = now;
            open = true;
        }
        this.dx += dx;
        this.dy += dy;
        last = now;
        return true;
    }

    internal JsonObject? Entry()
    {
        if (Math.Abs(dx) < 1 && Math.Abs(dy) < 1) return null;
        bool vertical = Math.Abs(dy) >= Math.Abs(dx);
        string direction = vertical ? (dy < 0 ? "down" : "up") : (dx < 0 ? "right" : "left");
        int distance = (int)Math.Round(Math.Abs(vertical ? dy : dx), MidpointRounding.AwayFromZero);
        return new JsonObject
        {
            ["kind"] = "scroll",
            ["app"] = app,
            ["direction"] = direction,
            ["distance"] = distance,
        };
    }
}

// The last 64 KB of the log files chosen in the tray. Read only when a capture is composed.
internal static class CustomLogs
{
    internal static JsonArray Tail(IReadOnlyList<string> paths, int maxBytes = 64_000)
    {
        var logs = new JsonArray();
        foreach (string path in paths.Take(4))
        {
            try
            {
                if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) continue;
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                long size = stream.Length;
                long start = size > maxBytes ? size - maxBytes : 0;
                stream.Seek(start, SeekOrigin.Begin);
                var buffer = new byte[size - start];
                int read = stream.Read(buffer, 0, buffer.Length);
                string text = Encoding.UTF8.GetString(buffer, 0, read);
                if (start > 0)
                {
                    int newline = text.IndexOf('\n');
                    if (newline >= 0) text = newline + 1 < text.Length ? text[(newline + 1)..] : "";
                }
                logs.Add(new JsonObject
                {
                    ["name"] = Path.GetFileName(path),
                    ["path"] = path,
                    ["text"] = text,
                    ["truncated"] = start > 0,
                });
            }
            catch { /* A missing or locked file is left out of this capture. */ }
        }
        return logs;
    }
}

internal static class CaptureContext
{
    internal static void Apply(JsonObject context, JsonObject settings, IReadOnlyList<JsonObject>? events)
    {
        events ??= ClickHistory.Shared.Snapshot();
        if (events.Count == 0) context.Remove("events");
        else
        {
            var list = new JsonArray();
            foreach (var entry in events) list.Add(ComposerFiles.Clone(entry));
            context["events"] = new JsonObject { ["entries"] = list };
        }
        var logs = CustomLogs.Tail(ComposerFiles.CustomLogFiles(settings));
        if (logs.Count == 0) context.Remove("customLogs");
        else context["customLogs"] = logs;
    }
}

internal static class ClickProbe
{
    internal static bool InThisProcess(int x, int y)
    {
        try
        {
            nint window = Native.WindowFromPoint(new Native.NativePoint { X = x, Y = y });
            if (window == 0) return false;
            Native.GetWindowThreadProcessId(window, out uint pid);
            return pid == (uint)Environment.ProcessId;
        }
        catch { return false; }
    }

    internal static string AppAt(int x, int y) => AppFromWindow(Root(x, y), true);

    internal static string QuickAppAt(int x, int y) => AppFromWindow(Root(x, y), false);

    internal static string ForegroundApp(bool rich) => AppFromWindow(Native.GetForegroundWindow(), rich);

    static nint Root(int x, int y)
    {
        try
        {
            nint window = Native.WindowFromPoint(new Native.NativePoint { X = x, Y = y });
            if (window == 0) return 0;
            nint root = Native.GetAncestor(window, 2);
            return root == 0 ? window : root;
        }
        catch { return 0; }
    }

    internal static string AppFromWindow(nint window) => AppFromWindow(window, true);

    static string AppFromWindow(nint window, bool rich)
    {
        if (window == 0) return "";
        try
        {
            Native.GetWindowThreadProcessId(window, out uint pid);
            if (pid == 0) return "";
            using var process = Process.GetProcessById((int)pid);
            if (rich)
            {
                try
                {
                    string description = process.MainModule?.FileVersionInfo.FileDescription ?? "";
                    if (!string.IsNullOrWhiteSpace(description)) return description.Trim();
                }
                catch { /* Elevated processes hide their module path. The process name still works. */ }
            }
            return process.ProcessName ?? "";
        }
        catch { return ""; }
    }

    internal static JsonObject At(int x, int y)
    {
        try { return Describe(AutomationElement.FromPoint(new System.Windows.Point(x, y))); }
        catch { return new JsonObject(); }
    }

    internal static JsonObject? Selection()
    {
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element == null) return null;
            string? selected = null;
            if (element.TryGetCurrentPattern(TextPattern.Pattern, out object raw) && raw is TextPattern pattern)
            {
                var ranges = pattern.GetSelection();
                if (ranges != null && ranges.Length > 0) selected = ranges[0].GetText(400);
            }
            var current = element.Current;
            return ClickHistory.SelectionEntry(selected, Role(element), null, current.IsPassword ? null : current.Name);
        }
        catch { return null; }
    }

    internal static bool TryFocus(out string key, out JsonObject described)
    {
        key = "";
        described = new JsonObject();
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element == null) return false;
            int[] id = element.GetRuntimeId();
            key = id == null ? "" : string.Join(",", id);
            described = Describe(element);
            return true;
        }
        catch { return false; }
    }

    static JsonObject Describe(AutomationElement element)
    {
        var current = element.Current;
        return ClickHistory.Describe(Role(element), null, current.IsPassword ? null : current.Name);
    }

    static string? Role(AutomationElement element)
    {
        var current = element.Current;
        if (current.IsPassword) return "AXSecureTextField";
        string name = current.ControlType.ProgrammaticName;
        int dot = name.LastIndexOf('.');
        string shortName = (dot >= 0 ? name[(dot + 1)..] : name).ToLowerInvariant();
        return shortName.Length == 0 ? null : shortName;
    }
}

internal static class ClickHooks
{
    const int WhMouse = 14;
    const int WhKeyboard = 13;
    const int MouseDown = 0x0201;
    const int MouseUp = 0x0202;
    const int RightDown = 0x0204;
    const int MouseWheel = 0x020A;
    const int MouseHWheel = 0x020E;
    const int KeyDown = 0x0100;
    const int SysKeyDown = 0x0104;
    const uint ForegroundEvent = 0x0003;
    const uint OutOfContext = 0x0000;
    const uint SkipOwnProcess = 0x0002;

    static readonly HookProc MouseProc = OnMouse;
    static readonly HookProc KeyboardProc = OnKeyboard;
    static readonly WinEventProc ForegroundProc = OnForeground;
    static nint mouseHook;
    static nint keyboardHook;
    static nint foregroundHook;

    internal static bool MouseInstalled => mouseHook != 0;
    internal static int DoubleClickTime => (int)GetDoubleClickTime();

    internal static void Install(bool watch, bool recording)
    {
        if (watch) InstallMouse();
        else UninstallMouse();
        if (watch) InstallForeground();
        else UninstallForeground();
        if (recording) InstallKeyboard();
        else UninstallKeyboard();
    }

    internal static void Uninstall()
    {
        UninstallMouse();
        UninstallKeyboard();
        UninstallForeground();
    }

    internal static bool IsModifier(int virtualKey) => virtualKey is 0x10 or 0x11 or 0x12 or 0x5B or 0x5C or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5;

    internal static bool ShortcutHeld() => Down(0x11) || Down(0x12) || Down(0x5B) || Down(0x5C);

    static void InstallMouse()
    {
        if (mouseHook != 0) return;
        mouseHook = SetWindowsHookEx(WhMouse, MouseProc, Module(), 0);
    }

    static void InstallKeyboard()
    {
        if (keyboardHook != 0) return;
        keyboardHook = SetWindowsHookEx(WhKeyboard, KeyboardProc, Module(), 0);
    }

    static void InstallForeground()
    {
        if (foregroundHook != 0) return;
        foregroundHook = SetWinEventHook(ForegroundEvent, ForegroundEvent, 0, ForegroundProc, 0, 0, OutOfContext | SkipOwnProcess);
    }

    static void UninstallMouse()
    {
        if (mouseHook == 0) return;
        UnhookWindowsHookEx(mouseHook);
        mouseHook = 0;
    }

    static void UninstallKeyboard()
    {
        if (keyboardHook == 0) return;
        UnhookWindowsHookEx(keyboardHook);
        keyboardHook = 0;
    }

    static void UninstallForeground()
    {
        if (foregroundHook == 0) return;
        UnhookWinEvent(foregroundHook);
        foregroundHook = 0;
    }

    static nint Module()
    {
        try { return GetModuleHandle(Process.GetCurrentProcess().MainModule?.ModuleName); }
        catch { return GetModuleHandle(null); }
    }

    static nint OnMouse(int code, nint wParam, nint lParam)
    {
        if (code >= 0)
        {
            try
            {
                var info = Marshal.PtrToStructure<MouseHookInfo>(lParam);
                int message = (int)wParam;
                if (message == MouseDown) ClickHistory.Shared.NoteClick(info.X, info.Y, true);
                else if (message == RightDown) ClickHistory.Shared.NoteClick(info.X, info.Y, false);
                else if (message == MouseUp) ClickHistory.Shared.NoteRelease(info.X, info.Y);
                else if (message == MouseWheel) ClickHistory.Shared.NoteWheel(info.X, info.Y, 0, Wheel(info.MouseData));
                else if (message == MouseHWheel) ClickHistory.Shared.NoteWheel(info.X, info.Y, Wheel(info.MouseData), 0);
            }
            catch { /* A failed step never blocks the click that caused it. */ }
        }
        return CallNextHookEx(mouseHook, code, wParam, lParam);
    }

    static nint OnKeyboard(int code, nint wParam, nint lParam)
    {
        if (code >= 0 && ((int)wParam == KeyDown || (int)wParam == SysKeyDown))
        {
            try
            {
                var info = Marshal.PtrToStructure<KeyHookInfo>(lParam);
                ClickHistory.Shared.NoteTyping((int)info.VirtualKey);
            }
            catch { /* Typing detection never stores the key and never eats it. */ }
        }
        return CallNextHookEx(keyboardHook, code, wParam, lParam);
    }

    static void OnForeground(nint hook, uint eventType, nint hwnd, int idObject, int idChild, uint thread, uint time)
    {
        try { ClickHistory.Shared.NoteForeground(hwnd); }
        catch { /* An app switch is optional context. */ }
    }

    static double Wheel(uint mouseData) => (short)((mouseData >> 16) & 0xFFFF) / 12.0;

    static bool Down(int virtualKey) => (GetAsyncKeyState(virtualKey) & 0x8000) != 0;

    [StructLayout(LayoutKind.Sequential)]
    struct MouseHookInfo
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public nint Extra;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KeyHookInfo
    {
        public uint VirtualKey;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public nint Extra;
    }

    delegate nint HookProc(int code, nint wParam, nint lParam);
    delegate void WinEventProc(nint hook, uint eventType, nint hwnd, int idObject, int idChild, uint thread, uint time);

    [DllImport("user32.dll", SetLastError = true)] static extern nint SetWindowsHookEx(int id, HookProc proc, nint module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] static extern nint CallNextHookEx(nint hook, int code, nint wParam, nint lParam);
    [DllImport("user32.dll")] static extern nint SetWinEventHook(uint min, uint max, nint module, WinEventProc proc, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32.dll")] static extern uint GetDoubleClickTime();
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern nint GetModuleHandle(string? name);
}
