using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Automation;
using Forms = System.Windows.Forms;

namespace Motifs;

internal sealed class DraftUnconfirmedException : Exception
{
    internal DraftUnconfirmedException() : base("The draft was pasted into OpenCode but could not be confirmed. Check the prompt before sending it.") { }
}

// Opens the session created by the composer bridge, then pastes into its empty Prompt.
// This never presses Enter and never clicks Send.
internal static class SessionDraft
{
    internal static async Task Open(string sessionId, string title, IReadOnlyList<string> images, string text, string output)
    {
        if (!Regex.IsMatch(sessionId, "^ses_[A-Za-z0-9]+$")) throw new Exception("OpenCode returned an invalid session.");
        if (string.IsNullOrWhiteSpace(title)) throw new Exception("OpenCode returned an invalid draft handoff.");
        var windows = OpenCodeWindows();
        if (windows.Count != 1) throw new Exception("Open exactly one OpenCode desktop window, then retry. The session was created and has not been sent.");
        nint window = windows[0];
        Activate(window);
        await Task.Delay(300);
        var root = AutomationElement.FromHandle(window);
        var prompt = FindPrompt(root);
        if (prompt != null && ShowsTitle(root, title) && IsEmpty(prompt))
        {
            await Inserter.InsertContent(images, text, output, title);
            return;
        }
        Focus(window);
        Forms.SendKeys.SendWait("^b");
        var search = await Wait(root, node => FindSearch(node), TimeSpan.FromSeconds(8));
        if (search == null) throw new Exception("Created the session, but could not find OpenCode's session search. Your draft has not been sent.");
        await PasteLookup(window, search, sessionId);
        var result = await Wait(root, node => FindText(node, title), TimeSpan.FromSeconds(10));
        if (result == null) throw new Exception("The new session did not appear in OpenCode's exact-ID lookup. No prompt was submitted.");
        if (Native.GetForegroundWindow() != window) throw new Exception("OpenCode lost focus during handoff. No prompt was submitted.");
        Invoke(result);
        var opened = await Wait(root, node =>
        {
            try
            {
                var candidate = FindPrompt(node);
                return candidate != null && ShowsTitle(node, title) && IsEmpty(candidate) ? candidate : null;
            }
            catch { return null; }
        }, TimeSpan.FromSeconds(8));
        if (opened == null) throw new Exception("OpenCode did not open the expected empty session. Your saved capture and description have not been sent.");
        await Inserter.InsertContent(images, text, output, title);
    }

    internal static List<nint> OpenCodeWindows() => Program.Windows().Where(window =>
    {
        try { return Program.ProcessName(window).Equals("OpenCode", StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }).ToList();

    internal static bool ShowsTitle(AutomationElement root, string title) => Walk(root).Any(node =>
    {
        string name = Safe(() => node.Current.Name) ?? "";
        if (!name.Contains(title, StringComparison.Ordinal)) return false;
        if (node.TryGetCurrentPattern(SelectionItemPattern.Pattern, out object selected) && ((SelectionItemPattern)selected).Current.IsSelected) return true;
        var type = Safe(() => node.Current.ControlType);
        string localized = Safe(() => node.Current.LocalizedControlType) ?? "";
        return type == ControlType.Header || type == ControlType.HeaderItem || localized.Contains("heading", StringComparison.OrdinalIgnoreCase);
    });

    static void Activate(nint window)
    {
        Native.ShowWindow(window, 9);
        if (!Native.SetForegroundWindow(window)) throw new Exception("Windows could not activate OpenCode. The session was created and has not been sent.");
    }

    static void Focus(nint window)
    {
        if (Native.GetForegroundWindow() != window && !Native.SetForegroundWindow(window)) throw new Exception("OpenCode lost focus during handoff. No prompt was submitted.");
    }

    static async Task PasteLookup(nint window, AutomationElement field, string sessionId)
    {
        field.SetFocus();
        if (!await Focused(window, field)) throw new Exception("Could not confirm focus in OpenCode's session search. The session exists, but its ID was not pasted. Nothing was run.");
        var saved = CopyClipboard();
        uint owned = Native.GetClipboardSequenceNumber();
        try
        {
            Forms.Clipboard.SetText(sessionId);
            owned = Native.GetClipboardSequenceNumber();
            if (!FocusBelongs(FocusedElement(), field)) throw new Exception("OpenCode's session search lost focus before lookup. Nothing was pasted.");
            Forms.SendKeys.SendWait("^a");
            await Task.Delay(80);
            if (Native.GetClipboardSequenceNumber() != owned || !FocusBelongs(FocusedElement(), field)) throw new Exception("Focus or clipboard changed during session lookup. No draft was inserted.");
            Forms.SendKeys.SendWait("^v");
            var matched = await Wait(AutomationElement.FromHandle(window), node =>
            {
                if (Safe(() => node.Current.ControlType) != ControlType.Edit) return null;
                string label = Safe(() => node.Current.Name) ?? "";
                string value = ValueOf(node) ?? "";
                return SearchLabel(label) && value == sessionId ? node : null;
            }, TimeSpan.FromSeconds(3));
            if (matched == null) throw new Exception("Could not confirm the new session ID in OpenCode's search. Draft insertion stopped; nothing was run.");
        }
        finally { RestoreClipboard(saved, owned); }
    }

    static async Task<bool> Focused(nint window, AutomationElement field)
    {
        var deadline = DateTime.UtcNow.AddSeconds(2);
        while (DateTime.UtcNow < deadline)
        {
            try { if (Native.GetForegroundWindow() == window && FocusBelongs(AutomationElement.FocusedElement, field)) return true; }
            catch { /* Focus can disappear while OpenCode rebuilds the search field. */ }
            await Task.Delay(50);
        }
        return false;
    }

    static AutomationElement? FocusedElement()
    {
        try { return AutomationElement.FocusedElement; }
        catch { return null; }
    }

    internal static bool FocusBelongs(AutomationElement? focused, AutomationElement owner)
    {
        var current = focused;
        for (int depth = 0; current != null && depth < 6; depth++)
        {
            if (Automation.Compare(current, owner)) return true;
            try { current = TreeWalker.ControlViewWalker.GetParent(current); }
            catch { return false; }
        }
        return false;
    }

    static void Invoke(AutomationElement result)
    {
        var current = result;
        for (int depth = 0; current != null && depth < 6; depth++)
        {
            if (current.TryGetCurrentPattern(InvokePattern.Pattern, out object raw)) { ((InvokePattern)raw).Invoke(); return; }
            try { current = TreeWalker.ControlViewWalker.GetParent(current); }
            catch { break; }
        }
        var bounds = result.Current.BoundingRectangle;
        if (bounds.IsEmpty || bounds.Width <= 0 || bounds.Height <= 0) throw new Exception("OpenCode's session result is not actionable.");
        Forms.Cursor.Position = new System.Drawing.Point((int)(bounds.Left + Math.Min(bounds.Width / 2, 100)), (int)(bounds.Top + bounds.Height / 2));
        Native.mouse_event(0x0002, 0, 0, 0, 0);
        Native.mouse_event(0x0004, 0, 0, 0, 0);
    }

    internal static AutomationElement? FindPrompt(AutomationElement root) => Walk(root).FirstOrDefault(node =>
    {
        try
        {
            var type = node.Current.ControlType;
            return (type == ControlType.Edit || type == ControlType.Document) && node.Current.Name == "Prompt" && node.Current.IsEnabled && !node.Current.IsPassword;
        }
        catch { return false; }
    });

    static AutomationElement? FindSearch(AutomationElement root) => Walk(root).FirstOrDefault(node =>
        Safe(() => node.Current.ControlType) == ControlType.Edit && SearchLabel(Safe(() => node.Current.Name) ?? ""));

    static bool SearchLabel(string label)
    {
        string lower = label.ToLowerInvariant();
        return (lower.Contains("search") || lower.Contains("find")) && !lower.Contains("settings") && !lower.Contains("file");
    }

    static AutomationElement? FindText(AutomationElement root, string text) => Walk(root).FirstOrDefault(node => (Safe(() => node.Current.Name) ?? "").Contains(text, StringComparison.Ordinal));

    static bool IsEmpty(AutomationElement prompt)
    {
        string? value = ValueOf(prompt);
        if (value == null) throw new Exception("Could not confirm whether the new session's draft is empty. It was left untouched.");
        return value.Replace("\u200B", "").Trim().Length == 0;
    }

    static string? ValueOf(AutomationElement node)
    {
        try
        {
            if (!node.TryGetCurrentPattern(ValuePattern.Pattern, out object raw)) return null;
            return ((ValuePattern)raw).Current.Value ?? "";
        }
        catch { return null; }
    }

    static async Task<T?> Wait<T>(AutomationElement root, Func<AutomationElement, T?> find, TimeSpan limit) where T : class
    {
        var deadline = DateTime.UtcNow.Add(limit);
        while (DateTime.UtcNow < deadline)
        {
            var found = find(root);
            if (found != null) return found;
            await Task.Delay(150);
        }
        return null;
    }

    static IEnumerable<AutomationElement> Walk(AutomationElement root)
    {
        var queue = new Queue<AutomationElement>();
        queue.Enqueue(root);
        int seen = 0;
        var clock = Stopwatch.StartNew();
        while (queue.Count > 0 && seen < 4000 && clock.Elapsed.TotalSeconds < 2)
        {
            var node = queue.Dequeue();
            seen++;
            yield return node;
            AutomationElement? child = null;
            try { child = TreeWalker.ControlViewWalker.GetFirstChild(node); } catch { continue; }
            while (child != null && queue.Count < 4000)
            {
                queue.Enqueue(child);
                try { child = TreeWalker.ControlViewWalker.GetNextSibling(child); } catch { break; }
            }
        }
    }

    static T? Safe<T>(Func<T> read)
    {
        try { return read(); }
        catch { return default; }
    }

    static Forms.DataObject CopyClipboard()
    {
        var saved = new Forms.DataObject();
        var original = Forms.Clipboard.GetDataObject();
        if (original != null) foreach (string format in original.GetFormats(false))
        {
            object? data = original.GetData(format, false);
            if (data != null) saved.SetData(format, false, data);
        }
        return saved;
    }

    static void RestoreClipboard(Forms.DataObject saved, uint owned)
    {
        if (Native.GetClipboardSequenceNumber() == owned) Forms.Clipboard.SetDataObject(saved, true);
    }
}
