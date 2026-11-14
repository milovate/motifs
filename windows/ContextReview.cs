using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Drawing;
using System.Globalization;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Motifs;

// What a destination receives besides the note: counts, preview text, and Markdown.
internal static class ContextReview
{
    internal const int MarkdownLimit = 20_000;
    internal const int RowLimit = 200;
    internal const int TextLimit = 8_000;

    internal enum ContextTone { Neutral, Warning, Danger }

    internal readonly record struct ContextMark(string Text, ContextTone Tone);

    internal sealed class ContextCard
    {
        internal List<ContextMark> Marks { get; } = new();
        internal string Aside = "";
        internal string When = "";
        internal bool Clip;
        internal bool InlineBody;
        internal string Heading = "";
        internal string Body = "";
        internal bool Mono;
        internal string Foot = "";
        internal List<KeyValuePair<string, string>> Pairs { get; } = new();
        internal List<string> Lines { get; } = new();
    }

    internal readonly record struct ContextSheet(List<ContextCard> Cards, string More);

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
        "console" => "No console errors. Native apps: errors and faults from the Application log in the last 5 minutes. Browsers: install the Motifs extension from the tray menu.",
        "network" => "No failed network requests. Browser captures need the Motifs extension.",
        "events" => "No steps. Screen recordings capture clicks, scrolls, selections and which fields you typed into. For screenshots, turn on “Record recent clicks” in the tray menu.",
        "customLogs" => "No log files. Add up to 4 under “Custom log files” in the tray menu.",
        "windowText" => "No window text was read from the captured app.",
        "device" => "No device details.",
        _ => "Nothing to show.",
    };

    internal static string EmptyText(string source, bool collecting, bool collectingNetwork = false) => source switch
    {
        "console" when collecting => "Collecting console messages…",
        "network" when collectingNetwork => "Collecting failed requests…",
        _ => EmptyText(source),
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

    internal static string IncludeTip(string source) => "Send " + Label(source).ToLowerInvariant() + " with this capture";

    internal static string Preview(string source, IReadOnlyList<JsonObject> shots, JsonObject context, IReadOnlyList<JsonObject>? videos = null)
    {
        var sheet = Sheet(source, shots, context, videos);
        var lines = sheet.Cards.SelectMany(card => card.Lines).ToList();
        if (sheet.More.Length > 0) lines.Add(sheet.More);
        return string.Join("\n", lines);
    }

    // One card per console message, failed request, step, screenshot, or log.
    // Device details share a single labeled card. Lines follow the macOS preview's reading order.
    internal static ContextSheet Sheet(string source, IReadOnlyList<JsonObject> shots, JsonObject context, IReadOnlyList<JsonObject>? videos = null)
    {
        var clips = videos ?? Array.Empty<JsonObject>();
        var cards = new List<ContextCard>();
        string more = "";
        switch (source)
        {
            case "windowText":
                for (int index = 0; index < shots.Count; index++)
                {
                    string? text = StringOf(shots[index], "text");
                    if (string.IsNullOrEmpty(text)) continue;
                    cards.Add(Titled(ScreenshotTitle(index, shots[index]), Bound(text), false));
                }
                break;
            case "device":
                var pairs = DevicePairs(context);
                if (pairs.Count > 0)
                {
                    var card = new ContextCard();
                    foreach (var pair in pairs)
                    {
                        card.Pairs.Add(pair);
                        card.Lines.Add(pair.Key);
                        card.Lines.Add(pair.Value);
                    }
                    cards.Add(card);
                }
                break;
            case "console":
                var console = Entries(context, "console");
                foreach (var entry in console.Take(RowLimit)) cards.Add(ConsoleCard(entry, clips));
                if (console.Count > RowLimit) more = LeftOut(console.Count);
                break;
            case "network":
                var network = Entries(context, "network");
                foreach (var entry in network.Take(RowLimit)) cards.Add(NetworkCard(entry, clips));
                if (network.Count > RowLimit) more = LeftOut(network.Count);
                break;
            case "events":
                foreach (var entry in Entries(context, "events").TakeLast(RowLimit).Reverse()) cards.Add(EventCard(entry, clips));
                break;
            case "customLogs":
                foreach (var entry in Logs(context)) cards.Add(Titled(Field(entry, "name"), Bound(Field(entry, "text")), true));
                break;
            default:
                break;
        }
        return new ContextSheet(cards, more);
    }

    static string LeftOut(int count) => (count - RowLimit).ToString(CultureInfo.InvariantCulture) + " more not shown";

    static string Bound(string text)
    {
        if (text.Length <= TextLimit) return text;
        return text[..TextLimit] + "\n… " + (text.Length - TextLimit).ToString(CultureInfo.InvariantCulture) + " more characters";
    }

    static ContextCard Titled(string title, string body, bool mono)
    {
        var card = new ContextCard { Heading = title, Body = body, Mono = mono };
        card.Lines.Add(title);
        if (body.Length > 0) card.Lines.Add(body);
        return card;
    }

    static ContextCard ConsoleCard(JsonObject entry, IReadOnlyList<JsonObject> videos)
    {
        string level = Field(entry, "level").ToLowerInvariant();
        string shown = level.Length == 0 ? "LOG" : level.ToUpperInvariant();
        string origin = Field(entry, "source") == "browser" ? "Page" : (StringOf(entry, "subsystem") ?? StringOf(entry, "process") ?? "App");
        string when = Moment(Field(entry, "time"), videos);
        var card = new ContextCard { Aside = origin, When = when, Clip = ClipMoment(Field(entry, "time"), videos) != null, Body = Field(entry, "message"), Mono = true };
        card.Marks.Add(new ContextMark(shown, LevelTone(level)));
        card.Lines.Add(shown);
        card.Lines.Add(origin);
        if (when.Length > 0) card.Lines.Add(when);
        if (card.Body.Length > 0) card.Lines.Add(card.Body);
        return card;
    }

    static ContextTone LevelTone(string level)
    {
        if (level is "error" or "fault") return ContextTone.Danger;
        if (level.StartsWith("warn", StringComparison.Ordinal)) return ContextTone.Warning;
        return ContextTone.Neutral;
    }

    static ContextCard NetworkCard(JsonObject entry, IReadOnlyList<JsonObject> videos)
    {
        var request = Request(entry);
        string when = Moment(Field(entry, "time"), videos);
        var card = new ContextCard
        {
            InlineBody = true,
            Body = request.Path,
            Mono = true,
            When = when,
            Clip = ClipMoment(Field(entry, "time"), videos) != null,
            Foot = request.HostLine,
        };
        card.Marks.Add(new ContextMark(request.Method, ContextTone.Neutral));
        card.Marks.Add(new ContextMark(request.Status, request.Tone));
        card.Lines.Add(request.Method);
        card.Lines.Add(request.Status);
        card.Lines.Add(request.Path);
        if (when.Length > 0) card.Lines.Add(when);
        if (request.HostLine.Length > 0) card.Lines.Add(request.HostLine);
        return card;
    }

    static ContextCard EventCard(JsonObject entry, IReadOnlyList<JsonObject> videos)
    {
        string kind = Field(entry, "kind");
        string app = Field(entry, "app");
        string aside = kind == "app-switch" || app.Length == 0 ? "" : app;
        string when = Moment(Field(entry, "time"), videos);
        var card = new ContextCard
        {
            InlineBody = true,
            Body = Describe(entry),
            Aside = aside,
            When = when,
            Clip = ClipMoment(Field(entry, "time"), videos) != null,
        };
        if (card.Body.Length > 0) card.Lines.Add(card.Body);
        if (aside.Length > 0) card.Lines.Add(aside);
        if (when.Length > 0) card.Lines.Add(when);
        return card;
    }

    internal static string Moment(string time, IReadOnlyList<JsonObject> videos)
    {
        if (ClipMoment(time, videos) is string clip) return clip;
        if (DateTimeOffset.TryParse(time, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var moment))
            return moment.ToLocalTime().ToString("HH:mm:ss", CultureInfo.InvariantCulture);
        return time;
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

    internal static string NetworkPreview(JsonObject entry, string when)
    {
        var request = Request(entry);
        string line = request.Method + " " + request.Status + " " + request.Path + " · " + when;
        if (request.HostLine.Length > 0) line += "\n" + request.HostLine;
        return line;
    }

    readonly record struct RequestView(string Method, string Status, string Path, string HostLine, ContextTone Tone);

    static RequestView Request(JsonObject entry)
    {
        string method = Field(entry, "method");
        if (method.Length == 0) method = "GET";
        string status;
        ContextTone tone;
        if (entry["status"] == null)
        {
            status = "Failed";
            tone = ContextTone.Danger;
        }
        else if (Number(entry, "status") is double value)
        {
            int code = (int)value;
            status = code.ToString(CultureInfo.InvariantCulture);
            tone = code >= 500 ? ContextTone.Danger : ContextTone.Warning;
        }
        else
        {
            status = Field(entry, "status");
            tone = ContextTone.Warning;
        }
        string url = Field(entry, "url");
        string path = url;
        string host = "";
        if (Uri.TryCreate(url, UriKind.Absolute, out var parsed))
        {
            path = parsed.AbsolutePath.Length == 0 ? "/" : parsed.AbsolutePath;
            if (parsed.Query.Length > 0) path += parsed.Query;
            host = parsed.IdnHost;
        }
        var extra = new List<string>();
        if (host.Length > 0) extra.Add(host);
        if (Field(entry, "error") is string error && error.Length > 0) extra.Add(error);
        return new RequestView(method, status, path, string.Join(" · ", extra), tone);
    }

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

// The Context chip: its label while a slow source is still loading, and the hover
// text that names every source that has something to send.
internal static class ContextSummary
{
    internal readonly record struct SourceChip(string Label, bool Included, int Count);

    internal static string ButtonText(bool collecting, int included) =>
        collecting ? "Context · collecting…" : included > 0 ? "Context " + included.ToString(CultureInfo.InvariantCulture) : "No context";

    internal static string Accessible(bool collecting, int included, int available, string tokens) =>
        collecting ? "collecting" : included.ToString(CultureInfo.InvariantCulture) + " of " + available.ToString(CultureInfo.InvariantCulture) + " sources included, " + tokens;

    internal static string Tooltip(IReadOnlyList<SourceChip> available, string tokens) =>
        (available.Count == 0 ? "No context" : string.Join(" · ", available.Select(part => part.Label + " " + (part.Included ? part.Count.ToString(CultureInfo.InvariantCulture) : "off"))) + " · " + tokens) + ". Click to review.";
}

// Errors and critical events the captured app wrote to the Application log.
// A browser capture keeps the extension's console and does not read this log.
internal static class AppConsole
{
    internal const int Limit = 200;

    internal static string Query(int pid, int minutes = 5)
    {
        int window = Math.Max(1, minutes) * 60 * 1000;
        return "*[System[(Level=1 or Level=2) and TimeCreated[timediff(@SystemTime) <= " + window.ToString(CultureInfo.InvariantCulture) + "] and Execution[@ProcessID=" + pid.ToString(CultureInfo.InvariantCulture) + "]]]";
    }

    internal static int TargetPid(nint window)
    {
        if (window == 0) return 0;
        try
        {
            if (!Native.IsWindow(window)) return 0;
            if (BrowserHost.IndexForImage(BrowserHost.WindowImage(window)) >= 0) return 0;
            Native.GetWindowThreadProcessId(window, out uint pid);
            if (pid == 0 || pid > int.MaxValue || pid == (uint)Environment.ProcessId) return 0;
            return (int)pid;
        }
        catch { return 0; }
    }

    internal static string? Message(string? description, string? provider, int? eventId)
    {
        if (!string.IsNullOrEmpty(description)) return description.Length <= 2000 ? description : description[..2000];
        if (string.IsNullOrWhiteSpace(provider) || eventId is not int id) return null;
        string text = provider.Trim() + " event " + id.ToString(CultureInfo.InvariantCulture);
        return text.Length <= 2000 ? text : text[..2000];
    }

    internal static JsonObject? Entry(int? processId, byte? level, DateTime? created, string? message, string? provider, int pid, DateTime utcNow)
    {
        if (processId != pid || pid <= 0 || level is not (1 or 2) || created == null || string.IsNullOrEmpty(message)) return null;
        DateTime when = created.Value.Kind == DateTimeKind.Local ? created.Value.ToUniversalTime() : DateTime.SpecifyKind(created.Value, DateTimeKind.Utc);
        if (when < utcNow - TimeSpan.FromMinutes(5) || when > utcNow + TimeSpan.FromMinutes(1)) return null;
        var entry = new JsonObject
        {
            ["time"] = new DateTimeOffset(when).ToString("O"),
            ["level"] = level == 1 ? "fault" : "error",
            ["message"] = message.Length <= 2000 ? message : message[..2000],
            ["source"] = "app",
        };
        if (!string.IsNullOrWhiteSpace(provider)) entry["subsystem"] = provider.Trim();
        return entry;
    }

    internal static List<JsonObject> Latest(IReadOnlyList<JsonObject?> entries, int limit)
    {
        var kept = new List<JsonObject>();
        foreach (var entry in entries)
            if (entry != null) kept.Add(entry);
        if (limit <= 0 || kept.Count <= limit) return kept;
        return kept.GetRange(kept.Count - limit, limit);
    }

    internal static bool IsBrowser(nint window)
    {
        if (window == 0) return false;
        try { return BrowserHost.IndexForImage(BrowserHost.WindowImage(window)) >= 0; }
        catch { return false; }
    }

    internal static bool Merge(JsonObject context, IReadOnlyList<JsonObject> entries)
    {
        if (context["console"] != null || entries.Count == 0) return false;
        var list = new JsonArray();
        foreach (var entry in entries) list.Add(ComposerFiles.Clone(entry));
        context["console"] = new JsonObject { ["entries"] = list };
        return true;
    }

    internal static bool MergeBrowser(JsonObject context, JsonObject? page)
    {
        if (page == null) return false;
        bool added = false;
        foreach (string key in new[] { "browser", "console", "network" })
        {
            if (context[key] != null || page[key] == null) continue;
            context[key] = page[key]!.DeepClone();
            added = true;
        }
        return added;
    }

    internal static async Task<JsonObject?> CollectBrowser(nint window, string? title)
    {
        if (window == 0) return null;
        var read = Task.Run(() =>
        {
            try { return BrowserContext(window, title); }
            catch { return null; }
        });
        Task finished = await Task.WhenAny(read, Task.Delay(TimeSpan.FromSeconds(8))).ConfigureAwait(false);
        if (finished != read) return null;
        return await read.ConfigureAwait(false);
    }

    static JsonObject? BrowserContext(nint window, string? title)
    {
        if (!IsBrowser(window)) return null;
        string? image = BrowserHost.WindowImage(window);
        if (string.IsNullOrEmpty(title))
        {
            var buffer = new System.Text.StringBuilder(4096);
            Native.GetWindowText(window, buffer, buffer.Capacity);
            title = buffer.ToString();
        }
        return BrowserHost.ContextFrom(BrowserHost.RequestSnapshot(image, title ?? ""));
    }

    internal static async Task<List<JsonObject>> Collect(int pid)
    {
        if (pid <= 0) return new List<JsonObject>();
        var read = Task.Run(() =>
        {
            try { return Read(pid, DateTime.UtcNow); }
            catch { return new List<JsonObject>(); }
        });
        Task finished = await Task.WhenAny(read, Task.Delay(TimeSpan.FromSeconds(8))).ConfigureAwait(false);
        if (finished != read) return new List<JsonObject>();
        return await read.ConfigureAwait(false);
    }

    static List<JsonObject> Read(int pid, DateTime utcNow)
    {
        var newest = new List<JsonObject>();
        try
        {
            var query = new EventLogQuery("Application", PathType.LogName, Query(pid)) { ReverseDirection = true };
            using var reader = new EventLogReader(query);
            while (newest.Count < Limit)
            {
                EventRecord? record;
                try { record = reader.ReadEvent(); }
                catch { break; }
                if (record == null) break;
                using (record)
                {
                    string? description = null;
                    try { description = record.FormatDescription(); }
                    catch { description = null; }
                    var entry = Entry(record.ProcessId, record.Level, record.TimeCreated, Message(description, record.ProviderName, record.Id), record.ProviderName, pid, utcNow);
                    if (entry != null) newest.Add(entry);
                }
            }
        }
        catch { /* An unreadable Application log adds no console entries. */ }
        newest.Reverse();
        return newest;
    }
}

// Sidebar of context sources, with the text or Markdown the destination will receive.
internal sealed class ContextDialog : Form
{
    readonly IReadOnlyList<JsonObject> shots;
    readonly IReadOnlyList<JsonObject> videos;
    readonly JsonObject context;
    readonly JsonObject include;
    readonly ListView sources = new() { View = View.Details, CheckBoxes = true, FullRowSelect = true, HeaderStyle = ColumnHeaderStyle.None, MultiSelect = false, HideSelection = false, ShowItemToolTips = true };
    readonly Font proseFont = new("Segoe UI", 10);
    readonly Font markdownFont = new("Consolas", 10);
    readonly TextBox detail = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, Visible = false };
    readonly ContextCardPane cards = new() { Dock = DockStyle.Fill };
    readonly Label banner = new() { Text = "Turned off · Not sent to any destination", AutoSize = true, ForeColor = Color.DarkOrange };
    readonly Label estimate = new() { AutoSize = true };
    readonly RadioButton preview = new() { Text = "Preview", AutoSize = true, Checked = true };
    readonly RadioButton markdown = new() { Text = "Markdown", AutoSize = true };
    readonly Button copy = new() { Text = "Copy", AutoSize = true, Visible = false };
    bool filling;
    string selected = ComposerFiles.Sources[0];
    internal bool Collecting { get; set; }
    internal bool CollectingNetwork { get; set; }
    internal event EventHandler? IncludeChanged;

    internal ContextDialog(IReadOnlyList<JsonObject> shots, IReadOnlyList<JsonObject> videos, JsonObject context, JsonObject include, bool collecting = false, bool collectingNetwork = false)
    {
        this.shots = shots;
        this.videos = videos;
        this.context = context;
        this.include = include;
        Collecting = collecting;
        CollectingNetwork = collectingNetwork;
        Text = "Context";
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ClientSize = new Size(680, 500);
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        MinimizeBox = false;
        MaximizeBox = false;
        KeyPreview = true;
        Font = new Font("Segoe UI", 10);
        BackColor = Color.FromArgb(32, 32, 34);
        ForeColor = Color.FromArgb(236, 236, 238);
        var title = new Label { Text = "Context", AutoSize = true, Font = new Font("Segoe UI", 14, FontStyle.Bold), ForeColor = ForeColor };
        var subtitle = new Label { Text = "What this capture sends along with your note", AutoSize = true, ForeColor = Color.FromArgb(170, 170, 176) };
        estimate.ForeColor = Color.FromArgb(170, 170, 176);
        var tips = new ToolTip { ShowAlways = true };
        tips.SetToolTip(estimate, "Rough size of the included context (about 4 characters per token)");
        tips.SetToolTip(copy, "Copy this source as Markdown");
        detail.Font = proseFont;
        Disposed += (_, _) =>
        {
            tips.Dispose();
            proseFont.Dispose();
            markdownFont.Dispose();
        };
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
            IncludeChanged?.Invoke(this, EventArgs.Empty);
        };
        detail.Dock = DockStyle.None;
        detail.BackColor = Color.FromArgb(24, 24, 26);
        detail.ForeColor = ForeColor;
        cards.BackColor = Color.FromArgb(24, 24, 26);
        var pane = new Panel { Dock = DockStyle.Fill, Padding = new Padding(8, 0, 0, 0) };
        banner.Dock = DockStyle.Top;
        pane.Controls.Add(detail);
        pane.Controls.Add(cards);
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

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.ExcludeFromCapture(Handle);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { Close(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
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
            item.ToolTipText = ContextReview.IncludeTip(source);
            sources.Items.Add(item);
            item.Checked = ComposerFiles.Included(include, source);
        }
        ListViewItem? match = null;
        foreach (ListViewItem item in sources.Items)
            if (item.Tag is string source && source == selected) match = item;
        if (match != null) match.Selected = true;
        else if (sources.Items.Count > 0) sources.Items[0].Selected = true;
        filling = false;
    }

    internal void Reload()
    {
        if (IsDisposed) return;
        FillSources();
        RefreshEstimate();
        RefreshDetail();
    }

    void ModeChanged()
    {
        copy.Visible = markdown.Checked;
        detail.Visible = markdown.Checked;
        detail.Dock = markdown.Checked ? DockStyle.Fill : DockStyle.None;
        cards.Visible = !markdown.Checked;
        cards.Dock = markdown.Checked ? DockStyle.None : DockStyle.Fill;
        detail.Font = markdown.Checked ? markdownFont : proseFont;
        RefreshDetail();
    }

    void RefreshEstimate() => estimate.Text = ContextReview.TokenEstimate(ContextReview.IncludedCharacters(shots, context, include));

    void RefreshDetail()
    {
        bool included = ComposerFiles.Included(include, selected);
        banner.Visible = !included;
        detail.ForeColor = included ? Color.FromArgb(236, 236, 238) : Color.FromArgb(140, 140, 146);
        if (!markdown.Checked)
        {
            cards.Show(ContextReview.Sheet(selected, shots, context, videos), ContextReview.EmptyText(selected, Collecting, CollectingNetwork), included);
            return;
        }
        string text = ContextReview.Markdown(selected, shots, videos, context);
        if (text.Length == 0) text = ContextReview.EmptyText(selected, Collecting, CollectingNetwork);
        if (text.Length > ContextReview.MarkdownLimit)
            text = text[..ContextReview.MarkdownLimit] + "\n… " + (text.Length - ContextReview.MarkdownLimit) + " more characters (Copy includes everything)";
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
