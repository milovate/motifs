using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Linq;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace OpenCode.Appshots;

// What a destination receives besides the note: counts, preview text, and Markdown.
internal static class ContextReview
{
    internal const int PreviewLimit = 8_000;
    internal const int MarkdownLimit = 20_000;

    internal static string Label(string source) => source switch
    {
        "windowText" => "Window",
        "device" => "Device",
        "console" => "Console",
        "network" => "Network",
        "events" => "Steps",
        "customLogs" => "Logs",
        _ => source,
    };

    internal static string EmptyText(string source) => source switch
    {
        "console" => "No console errors. Native apps: errors and faults from the last 5 minutes. Browsers: install the Capture Studio extension from the menu bar.",
        "network" => "No failed network requests. Browser captures need the Capture Studio extension.",
        "events" => "No steps. Screen recordings capture clicks, scrolls, selections and which fields you typed into. For screenshots, turn on “Record recent clicks” in the tray menu.",
        "customLogs" => "No log files. Add up to 4 under “Custom log files” in the tray menu.",
        "windowText" => "No window text was read from the captured app.",
        "device" => "No device details.",
        _ => "Nothing to show.",
    };

    // Windows reports memory use as a percentage. These bands name that load the
    // same way the context pane names memory pressure.
    internal static string PressureName(int loadPercent) => loadPercent switch
    {
        < 0 => "unknown",
        <= 75 => "normal",
        <= 90 => "warning",
        _ => "critical",
    };

    internal static string Describe(JsonObject entry)
    {
        string? role = Role(entry);
        string? label = StringOf(entry, "name") ?? StringOf(entry, "title");
        string target = (role ?? "element") + (label == null ? "" : " \"" + label + "\"");
        string kind = StringOf(entry, "kind") ?? "";
        switch (kind)
        {
            case "click": return (Whole(entry, "count") > 1 ? "Double-clicked " : "Clicked ") + target;
            case "type": return "Typed into " + target;
            case "select": return "Selected \"" + (StringOf(entry, "text") ?? "") + "\"" + (role == null ? "" : " in " + target);
            case "scroll":
                if (StringOf(entry, "direction") is string direction) return "Scrolled " + direction + " " + Whole(entry, "distance") + " pt" + (role == null ? "" : " over " + target);
                return "Scrolled " + (role == null && entry["selector"] == null ? "the page" : target) + " to " + Whole(entry, "x") + ", " + Whole(entry, "y");
            case "drag": return "Dragged" + (role == null ? "" : " in " + target);
            case "choose": return "Chose \"" + (StringOf(entry, "option") ?? "") + "\" in " + target;
            case "check": return (Bool(entry, "checked") == true ? "Checked " : "Unchecked ") + target;
            case "upload": return "Chose a file for " + target;
            case "submit": return "Submitted " + target;
            case "navigate": return "Opened " + (StringOf(entry, "url") ?? "a page");
            case "tab": return "Switched to tab " + (StringOf(entry, "title") ?? StringOf(entry, "url") ?? "");
            case "app-switch": return "Switched to " + (StringOf(entry, "app") ?? "app");
            default: return kind;
        }
    }

    internal static int Count(string source, IReadOnlyList<JsonObject> shots, JsonObject context)
    {
        switch (source)
        {
            case "windowText": return shots.Count(shot => !string.IsNullOrEmpty(StringOf(shot, "text")));
            case "device": return Render(source, shots, context).Length == 0 ? 0 : 1;
            case "customLogs": return Logs(context).Count;
            default: return Entries(context, source).Count;
        }
    }

    internal static int ErrorCount(string source, JsonObject context)
    {
        if (source == "console") return Entries(context, "console").Count(entry => Field(entry, "level").ToLowerInvariant() is "error" or "fault");
        if (source == "network") return Entries(context, "network").Count;
        return 0;
    }

    internal static string Render(string source, IReadOnlyList<JsonObject> shots, JsonObject context)
    {
        switch (source)
        {
            case "windowText":
                string joined = string.Join("\n\n", shots.Select(shot => StringOf(shot, "text")).Where(text => !string.IsNullOrEmpty(text)));
                return joined.Length <= 120_000 ? joined : joined[..120_000];
            case "device":
                var lines = DeviceSummary(context["device"] as JsonObject ?? new JsonObject());
                if (context["app"] is JsonObject app && StringOf(app, "name") is string name)
                    lines.Add(("Captured app: " + name + " " + Field(app, "version")).Trim());
                if (context["browser"] is JsonObject browser) lines.Add("Browser page: " + Field(browser, "title") + " " + Field(browser, "url"));
                if (context["system"] is JsonObject system)
                {
                    if (system["memory"] is JsonObject memory && StringOf(memory, "pressure") is string pressure) lines.Add("Memory pressure: " + pressure);
                    if (system["battery"] is JsonObject battery && Number(battery, "level") is double level)
                        lines.Add("Battery: " + (int)Math.Round(level) + "%" + (Bool(battery, "charging") == true ? ", charging" : ""));
                    if (system["storage"] is JsonObject storage && Number(storage, "availableBytes") is double free)
                        lines.Add(string.Format(CultureInfo.InvariantCulture, "Storage: {0:0} GB free", free / 1_073_741_824));
                    if (StringOf(system, "thermal") is string thermal) lines.Add("Thermal state: " + thermal);
                }
                return string.Join("\n", lines);
            case "console":
                return string.Join("\n", Entries(context, "console").Select(entry => "[" + Field(entry, "time") + "] " + Field(entry, "level").ToUpperInvariant() + " " + (Field(entry, "source") == "browser" ? "page" : (StringOf(entry, "subsystem") ?? "app")) + ": " + Field(entry, "message")));
            case "network":
                return string.Join("\n", Entries(context, "network").Select(entry => "[" + Field(entry, "time") + "] " + Field(entry, "method") + " " + StatusOrError(entry) + " " + Field(entry, "url")));
            case "events":
                return string.Join("\n", Entries(context, "events").Select(entry => "[" + Field(entry, "time") + "] " + Describe(entry) + (Field(entry, "kind") == "app-switch" || Field(entry, "app").Length == 0 ? "" : " in " + Field(entry, "app"))));
            case "customLogs":
                return string.Join("\n\n", Logs(context).Select(entry => "== " + Field(entry, "name") + " ==\n" + Field(entry, "text")));
            default:
                return "";
        }
    }

    internal static int Characters(string source, IReadOnlyList<JsonObject> shots, JsonObject context)
    {
        int length = Render(source, shots, context).Length;
        return source == "windowText" ? length : Math.Min(length, 60_000);
    }

    internal static int IncludedCharacters(IReadOnlyList<JsonObject> shots, JsonObject context, JsonObject include) =>
        ComposerFiles.Sources.Where(source => ComposerFiles.Included(include, source)).Sum(source => Characters(source, shots, context));

    internal static string TokenEstimate(int characters)
    {
        int tokens = (int)Math.Ceiling(characters / 4.0);
        return tokens >= 1000
            ? string.Format(CultureInfo.InvariantCulture, "≈{0:0.0}k tokens", tokens / 1000.0)
            : "≈" + tokens.ToString(CultureInfo.InvariantCulture) + " tokens";
    }

    internal static string Markdown(string source, IReadOnlyList<JsonObject> shots, IReadOnlyList<JsonObject> videos, JsonObject context)
    {
        string When(JsonObject entry) => "`" + (ClipMoment(Field(entry, "time"), videos) ?? Field(entry, "time")) + "`";
        string Block(string text)
        {
            string fence = text.Contains("```") ? "````" : "```";
            return fence + "text\n" + text + "\n" + fence;
        }
        switch (source)
        {
            case "windowText":
                return string.Join("\n\n", shots.Select((shot, index) => string.IsNullOrEmpty(StringOf(shot, "text")) ? null : "### " + ScreenshotTitle(index, shot) + "\n\n" + Block(StringOf(shot, "text")!)).Where(line => line != null));
            case "device":
                return string.Join("\n", DevicePairs(context).Select(pair => "- **" + pair.Key + ":** " + pair.Value.Replace("\n", " · ")));
            case "console":
                return string.Join("\n", Entries(context, "console").Select(entry =>
                {
                    string origin = Field(entry, "source") == "browser" ? "page" : (StringOf(entry, "subsystem") ?? StringOf(entry, "process") ?? "app");
                    return "- " + When(entry) + " **" + Field(entry, "level").ToUpperInvariant() + "** " + origin + ": " + Field(entry, "message").Replace("\n", " ");
                }));
            case "network":
                return string.Join("\n", Entries(context, "network").Select(entry => "- " + When(entry) + " `" + Field(entry, "method") + " " + StatusOrError(entry) + "` " + Field(entry, "url")));
            case "events":
                return string.Join("\n", Entries(context, "events").Select((entry, index) =>
                    (index + 1) + ". " + When(entry) + " " + Describe(entry) + (Field(entry, "kind") == "app-switch" || Field(entry, "app").Length == 0 ? "" : " in " + Field(entry, "app")) + (StringOf(entry, "selector") is string selector ? " — `" + selector + "`" : "")));
            case "customLogs":
                return string.Join("\n\n", Logs(context).Select(entry => "### " + Field(entry, "name") + "\n\n" + Block(Field(entry, "text"))));
            default:
                return "";
        }
    }

    internal static string Preview(string source, IReadOnlyList<JsonObject> shots, JsonObject context)
    {
        if (source == "device")
        {
            var pairs = DevicePairs(context);
            return pairs.Count == 0 ? "" : string.Join("\n", pairs.Select(pair => pair.Key + ": " + pair.Value));
        }
        return Render(source, shots, context);
    }

    internal static List<KeyValuePair<string, string>> DevicePairs(JsonObject context)
    {
        var pairs = new List<KeyValuePair<string, string>>();
        var device = context["device"] as JsonObject ?? new JsonObject();
        if (StringOf(device, "os") is string os) pairs.Add(new("System", os + (StringOf(device, "arch") is string arch ? " (" + arch + ")" : "")));
        if (StringOf(device, "model") is string model) pairs.Add(new("Model", model));
        if (StringOf(device, "cpu") is string cpu) pairs.Add(new("Processor", cpu));
        if (Number(device, "memoryBytes") is double memory && memory > 0) pairs.Add(new("Memory", Gigabytes(memory) + " GB"));
        if (device["displays"] is JsonArray displays && displays.Count > 0)
            pairs.Add(new("Displays", string.Join(", ", displays.OfType<JsonObject>().Select(display => (Number(display, "width") ?? 0).ToString(CultureInfo.InvariantCulture) + "×" + (Number(display, "height") ?? 0).ToString(CultureInfo.InvariantCulture) + " @" + Scale(display["scale"]) + "x"))));
        if (StringOf(device, "locale") is string locale) pairs.Add(new("Locale", locale));
        if (context["app"] is JsonObject app && StringOf(app, "name") is string name) pairs.Add(new("Captured app", (name + " " + Field(app, "version")).Trim()));
        if (context["browser"] is JsonObject browser) pairs.Add(new("Browser page", string.Join("\n", new[] { StringOf(browser, "title"), StringOf(browser, "url") }.Where(part => !string.IsNullOrEmpty(part)))));
        if (context["system"] is JsonObject system)
        {
            if (system["memory"] is JsonObject systemMemory && StringOf(systemMemory, "pressure") is string pressure) pairs.Add(new("Memory pressure", pressure));
            if (system["battery"] is JsonObject battery && Number(battery, "level") is double level) pairs.Add(new("Battery", (int)Math.Round(level) + "%" + (Bool(battery, "charging") == true ? ", charging" : "")));
            if (system["storage"] is JsonObject storage && Number(storage, "availableBytes") is double free) pairs.Add(new("Storage", string.Format(CultureInfo.InvariantCulture, "{0:0} GB free", free / 1_073_741_824)));
            if (StringOf(system, "thermal") is string thermal) pairs.Add(new("Thermal state", thermal));
        }
        return pairs;
    }

    internal static string? ClipMoment(string time, IReadOnlyList<JsonObject> videos)
    {
        if (!DateTimeOffset.TryParse(time, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var moment)) return null;
        for (int index = 0; index < videos.Count; index++)
        {
            if (Offset(moment, videos[index]) is not double offset) continue;
            string name = Field(videos[index], "source") == "recording" ? "Screen recording" : "Instant replay";
            return (videos.Count > 1 ? name + " " + (index + 1) : name) + " · " + ClipTime(offset);
        }
        return null;
    }

    internal static string ClipTime(double seconds)
    {
        double whole = Math.Max(0, seconds);
        return string.Format(CultureInfo.InvariantCulture, "{0}:{1:00.0}", (int)whole / 60, whole % 60);
    }

    static List<string> DeviceSummary(JsonObject device)
    {
        var lines = new List<string>();
        if (StringOf(device, "os") is string os) lines.Add(os + (StringOf(device, "arch") is string arch ? " (" + arch + ")" : ""));
        if (StringOf(device, "model") is string model) lines.Add(model);
        if (StringOf(device, "cpu") is string cpu) lines.Add(cpu);
        if (Number(device, "memoryBytes") is double memory && memory > 0) lines.Add(Gigabytes(memory) + " GB memory");
        if (device["displays"] is JsonArray displays && displays.Count > 0)
        {
            string sizes = string.Join(", ", displays.OfType<JsonObject>().Select(display => (Number(display, "width") ?? 0).ToString(CultureInfo.InvariantCulture) + "×" + (Number(display, "height") ?? 0).ToString(CultureInfo.InvariantCulture) + "@" + Scale(display["scale"]) + "x"));
            lines.Add(displays.Count + " display" + (displays.Count == 1 ? "" : "s") + " (" + sizes + ")");
        }
        if (StringOf(device, "locale") is string locale) lines.Add("Locale " + locale);
        return lines;
    }

    static string ScreenshotTitle(int index, JsonObject shot)
    {
        string title = StringOf(shot, "title") ?? "";
        return "Screenshot " + (index + 1) + " · " + (StringOf(shot, "app") ?? "App") + (title.Length == 0 ? "" : " · \"" + title + "\"");
    }

    internal static double? Offset(DateTimeOffset moment, JsonObject video)
    {
        if (StringOf(video, "startedAt") is not string started || !DateTimeOffset.TryParse(started, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var start)) return null;
        double elapsed = (moment - start).TotalSeconds;
        if (elapsed < 0) return null;
        double duration = Number(video, "durationSeconds") ?? 0;
        if (video["pauses"] is JsonArray pauses)
        {
            foreach (var node in pauses.OfType<JsonObject>().OrderBy(pause => Number(pause, "atSeconds") ?? 0))
            {
                double at = Number(node, "atSeconds") ?? 0;
                double span = Number(node, "durationSeconds") ?? 0;
                if (elapsed < at) break;
                if (elapsed < at + span) return null;
                elapsed -= span;
            }
        }
        return elapsed <= duration + 1 ? elapsed : null;
    }

    static List<JsonObject> Entries(JsonObject context, string key) =>
        context[key] is JsonObject group && group["entries"] is JsonArray entries ? entries.OfType<JsonObject>().ToList() : new List<JsonObject>();

    static List<JsonObject> Logs(JsonObject context) =>
        context["customLogs"] as JsonArray is JsonArray logs ? logs.OfType<JsonObject>().ToList() : new List<JsonObject>();

    static string? Role(JsonObject entry)
    {
        if (StringOf(entry, "role") is string role) return role.StartsWith("AX", StringComparison.Ordinal) ? role[2..].ToLowerInvariant() : role;
        return StringOf(entry, "tag");
    }

    static string Field(JsonObject entry, string key) => StringOf(entry, key) ?? (Number(entry, key)?.ToString(CultureInfo.InvariantCulture) ?? "");

    static string StatusOrError(JsonObject entry) => entry["status"] != null ? Field(entry, "status") : Field(entry, "error");

    static string? StringOf(JsonObject entry, string key) =>
        entry[key] is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    static bool? Bool(JsonObject entry, string key) =>
        entry[key] is JsonValue value && value.TryGetValue(out bool flag) ? flag : null;

    static double? Number(JsonObject entry, string key) => Number(entry[key]);

    static double? Number(JsonNode? node)
    {
        if (node is not JsonValue value) return null;
        if (value.TryGetValue(out double real)) return real;
        if (value.TryGetValue(out int number)) return number;
        if (value.TryGetValue(out long wide)) return wide;
        if (value.TryGetValue(out ulong huge)) return huge;
        return null;
    }

    static int Whole(JsonObject entry, string key) => Number(entry, key) is double value ? (int)value : 0;

    static int Gigabytes(double bytes) => (int)Math.Round(bytes / 1_073_741_824);

    static string Scale(JsonNode? node)
    {
        if (Number(node) is not double scale) return "1";
        return scale == Math.Truncate(scale) ? ((int)scale).ToString(CultureInfo.InvariantCulture) : scale.ToString("0.##", CultureInfo.InvariantCulture);
    }
}

// Sidebar of context sources, with the text or Markdown the destination will receive.
internal sealed class ContextDialog : Form
{
    readonly IReadOnlyList<JsonObject> shots;
    readonly IReadOnlyList<JsonObject> videos;
    readonly JsonObject context;
    readonly JsonObject include;
    readonly ListView sources = new() { View = View.Details, CheckBoxes = true, FullRowSelect = true, HeaderStyle = ColumnHeaderStyle.None, MultiSelect = false, HideSelection = false };
    readonly TextBox detail = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, Font = new Font("Segoe UI", 10) };
    readonly Label banner = new() { Text = "Turned off · Not sent to any destination", AutoSize = true, ForeColor = Color.DarkOrange };
    readonly Label estimate = new() { AutoSize = true };
    readonly RadioButton preview = new() { Text = "Preview", AutoSize = true, Checked = true };
    readonly RadioButton markdown = new() { Text = "Markdown", AutoSize = true };
    readonly Button copy = new() { Text = "Copy", AutoSize = true, Visible = false };
    bool filling;
    string selected = ComposerFiles.Sources[0];

    internal ContextDialog(IReadOnlyList<JsonObject> shots, IReadOnlyList<JsonObject> videos, JsonObject context, JsonObject include)
    {
        this.shots = shots;
        this.videos = videos;
        this.context = context;
        this.include = include;
        Text = "Context";
        ClientSize = new Size(760, 540);
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = false;
        MaximizeBox = false;
        Font = new Font("Segoe UI", 10);
        BackColor = Color.FromArgb(32, 32, 34);
        ForeColor = Color.FromArgb(236, 236, 238);
        var title = new Label { Text = "Context", AutoSize = true, Font = new Font("Segoe UI", 14, FontStyle.Bold), ForeColor = ForeColor };
        var subtitle = new Label { Text = "What this capture sends along with your note", AutoSize = true, ForeColor = Color.FromArgb(170, 170, 176) };
        estimate.ForeColor = Color.FromArgb(170, 170, 176);
        preview.ForeColor = ForeColor;
        markdown.ForeColor = ForeColor;
        preview.CheckedChanged += (_, _) => ModeChanged();
        copy.Click += (_, _) => CopyMarkdown();
        var header = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 64, Padding = new Padding(16, 12, 16, 0), WrapContents = true };
        header.Controls.AddRange(new Control[] { title, subtitle, preview, markdown, copy, estimate });
        sources.Dock = DockStyle.Fill;
        sources.BackColor = Color.FromArgb(24, 24, 26);
        sources.ForeColor = ForeColor;
        sources.Columns.Add("Source", 150);
        sources.Columns.Add("Count", 70);
        sources.ItemSelectionChanged += (_, args) => { if (!filling && args.IsSelected && args.Item?.Tag is string source) { selected = source; RefreshDetail(); } };
        sources.ItemCheck += (_, args) =>
        {
            if (filling || sources.Items[args.Index].Tag is not string source) return;
            include[source] = args.NewValue == CheckState.Checked;
            RefreshEstimate();
            if (source == selected) RefreshDetail();
        };
        detail.Dock = DockStyle.Fill;
        detail.BackColor = Color.FromArgb(24, 24, 26);
        detail.ForeColor = ForeColor;
        var pane = new Panel { Dock = DockStyle.Fill, Padding = new Padding(8, 0, 0, 0) };
        banner.Dock = DockStyle.Top;
        pane.Controls.Add(detail);
        pane.Controls.Add(banner);
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(16, 0, 16, 0) };
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 230));
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        body.Controls.Add(sources, 0, 0);
        body.Controls.Add(pane, 1, 0);
        var privacy = new Label
        {
            Dock = DockStyle.Bottom,
            Height = 48,
            Padding = new Padding(16, 8, 16, 8),
            ForeColor = Color.FromArgb(170, 170, 176),
            Text = "Location and keystrokes are never collected. Values that look like secrets are replaced with [redacted] when sent; screenshots are not. Switched-off sources are not sent to any destination.",
        };
        Controls.Add(body);
        Controls.Add(privacy);
        Controls.Add(header);
        FillSources();
        RefreshEstimate();
        RefreshDetail();
    }

    void FillSources()
    {
        filling = true;
        sources.Items.Clear();
        foreach (string source in ComposerFiles.Sources)
        {
            int count = ContextReview.Count(source, shots, context);
            int errors = ContextReview.ErrorCount(source, context);
            var item = new ListViewItem(ContextReview.Label(source)) { Tag = source };
            item.UseItemStyleForSubItems = false;
            string countText = count > 0 ? count.ToString(CultureInfo.InvariantCulture) : "";
            if (errors > 0 && source == "console") countText = (countText.Length == 0 ? "0" : countText) + " · " + errors;
            item.SubItems.Add(countText).ForeColor = errors > 0 ? Color.IndianRed : Color.FromArgb(170, 170, 176);
            sources.Items.Add(item);
            item.Checked = ComposerFiles.Included(include, source);
        }
        if (sources.Items.Count > 0) sources.Items[0].Selected = true;
        filling = false;
    }

    void ModeChanged()
    {
        copy.Visible = markdown.Checked;
        detail.Font = new Font(markdown.Checked ? "Consolas" : "Segoe UI", 10);
        RefreshDetail();
    }

    void RefreshEstimate() => estimate.Text = ContextReview.TokenEstimate(ContextReview.IncludedCharacters(shots, context, include));

    void RefreshDetail()
    {
        bool included = ComposerFiles.Included(include, selected);
        banner.Visible = !included;
        detail.ForeColor = included ? Color.FromArgb(236, 236, 238) : Color.FromArgb(140, 140, 146);
        string text = markdown.Checked
            ? ContextReview.Markdown(selected, shots, videos, context)
            : ContextReview.Preview(selected, shots, context);
        if (text.Length == 0) text = ContextReview.EmptyText(selected);
        int limit = markdown.Checked ? ContextReview.MarkdownLimit : ContextReview.PreviewLimit;
        if (text.Length > limit) text = text[..limit] + "\n… " + (text.Length - limit) + " more characters" + (markdown.Checked ? " (Copy includes everything)" : "");
        detail.Text = text;
    }

    void CopyMarkdown()
    {
        string text = ContextReview.Markdown(selected, shots, videos, context);
        if (text.Length == 0) return;
        Clipboard.SetText(text);
        copy.Text = "Copied";
        var timer = new Timer { Interval = 1200 };
        timer.Tick += (_, _) => { copy.Text = "Copy"; timer.Stop(); timer.Dispose(); };
        timer.Start();
    }
}
