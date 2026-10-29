using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using Microsoft.Win32;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace OpenCode.Appshots;

internal sealed record ComposerEndpoint(string Directory, int Port, string Token);

internal sealed record ComposerTarget(string Id, string Label, string? Detail, string ActionLabel, string Hint, int Endpoint);

internal sealed record ComposerDestination(string Id, string Label, string Status, List<ComposerTarget> Targets);

internal sealed class LoadedBundle
{
    internal string Path = "";
    internal string? Id;
    internal DateTimeOffset? Created;
    internal List<JsonObject> Shots = new();
    internal List<JsonObject> Videos = new();
    internal string Note = "";
    internal JsonObject Context = new();
    internal JsonObject Include = new();
    internal int Missing;
}

internal sealed class RecentCapture
{
    internal string Path = "";
    internal string Title = "";
    internal DateTimeOffset Updated;
    internal int Screenshots;
}

internal static class ComposerFiles
{
    internal const string Schema = "capture-studio.bundle/1";
    internal static readonly string[] Sources = { "windowText", "device", "console", "network", "events", "customLogs" };

    internal static string Iso(DateTimeOffset time) => time.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    internal static JsonObject Clone(JsonObject value) => JsonNode.Parse(value.ToJsonString())!.AsObject();

    internal static JsonObject DefaultInclude()
    {
        var include = new JsonObject();
        foreach (string source in Sources) include[source] = true;
        return include;
    }

    internal static bool Included(JsonObject include, string source)
    {
        if (include[source] is JsonValue value && value.TryGetValue(out bool flag)) return flag;
        return true;
    }

    internal static Rectangle? Selection(Point start, Point end, Rectangle bounds)
    {
        var rect = Rectangle.FromLTRB(Math.Min(start.X, end.X), Math.Min(start.Y, end.Y), Math.Max(start.X, end.X), Math.Max(start.Y, end.Y));
        rect.Intersect(bounds);
        return rect.Width < 3 || rect.Height < 3 ? null : rect;
    }

    internal static bool Mentions(string text, string id) => Regex.IsMatch(text, MentionPattern(id));

    internal static string RemoveMention(string text, string id) => Regex.Replace(text, MentionPattern(id), "");

    static string MentionPattern(string id) => $@"(?<![\p{{L}}\p{{N}}_@/])@{Regex.Escape(id)}(?![\p{{L}}\p{{N}}_-])";

    internal static JsonObject Device()
    {
        var displays = new JsonArray();
        foreach (var screen in System.Windows.Forms.Screen.AllScreens)
        {
            float scale = MonitorScale(screen);
            displays.Add(new JsonObject
            {
                ["width"] = Math.Max(1, (int)Math.Round(screen.Bounds.Width * scale)),
                ["height"] = Math.Max(1, (int)Math.Round(screen.Bounds.Height * scale)),
                ["scale"] = Math.Round(scale, 2),
            });
        }
        var device = new JsonObject
        {
            ["os"] = RuntimeInformation.OSDescription.Trim(),
            ["arch"] = RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant(),
            ["memoryBytes"] = JsonValue.Create(PhysicalMemory()),
            ["displays"] = displays,
            ["locale"] = CultureInfo.CurrentCulture.Name,
        };
        string? cpu = CpuName();
        if (cpu != null) device["cpu"] = cpu;
        return device;
    }

    static string? CpuName()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0");
            string? name = key?.GetValue("ProcessorNameString") as string;
            name = name?.Trim();
            return string.IsNullOrEmpty(name) ? null : name;
        }
        catch { return null; }
    }

    // Hardware facts only. No machine name, user name, or network identity.
    internal static JsonObject SystemFacts()
    {
        var system = new JsonObject();
        var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        if (Native.GlobalMemoryStatusEx(ref memory))
            system["memory"] = new JsonObject { ["pressure"] = ContextReview.PressureName((int)memory.MemoryLoad), ["loadPercent"] = memory.MemoryLoad };
        if (Native.GetSystemPowerStatus(out var power) && (power.BatteryFlag & 128) == 0 && power.BatteryLifePercent <= 100)
            system["battery"] = new JsonObject { ["level"] = (int)power.BatteryLifePercent, ["charging"] = (power.BatteryFlag & 8) != 0 };
        string? root = Path.GetPathRoot(Environment.SystemDirectory);
        if (root != null && Native.GetDiskFreeSpaceEx(root, out ulong free, out _, out _))
            system["storage"] = new JsonObject { ["availableBytes"] = JsonValue.Create(free) };
        return system;
    }

    static float MonitorScale(System.Windows.Forms.Screen screen)
    {
        try
        {
            var point = new Native.NativePoint { X = screen.Bounds.Left + screen.Bounds.Width / 2, Y = screen.Bounds.Top + screen.Bounds.Height / 2 };
            nint monitor = Native.MonitorFromPoint(point, 2);
            if (monitor != 0 && Native.GetDpiForMonitor(monitor, 0, out uint dpi, out _) == 0 && dpi >= 96) return dpi / 96f;
        }
        catch { /* A display scale is optional device context. */ }
        return 1;
    }

    static ulong PhysicalMemory()
    {
        var status = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        return Native.GlobalMemoryStatusEx(ref status) ? status.TotalPhys : 0;
    }

    internal static JsonObject Settings(string output)
    {
        string file = Path.Combine(output, "settings.json");
        if (!File.Exists(file) || new FileInfo(file).Length > 64_000) return DefaultSettings();
        try { return JsonNode.Parse(File.ReadAllText(file)) as JsonObject ?? DefaultSettings(); }
        catch { return DefaultSettings(); }
    }

    internal static JsonObject DefaultSettings() => new()
    {
        ["defaultDestination"] = "opencode",
        ["knownDestinations"] = new JsonArray(DestinationEntry("opencode", "OpenCode"), DestinationEntry("clipboard", "Clipboard"), DestinationEntry("folder", "Save to folder")),
        ["include"] = DefaultInclude(),
        ["prefixes"] = new JsonArray(),
        ["showBubble"] = true,
        ["instantReplay"] = false,
        ["recordClicks"] = false,
        ["customLogFiles"] = new JsonArray(),
    };

    static JsonObject DestinationEntry(string id, string label) => new() { ["id"] = id, ["label"] = label };

    internal static bool InstantReplay(JsonObject settings) => settings["instantReplay"]?.GetValue<bool>() == true;

    internal static bool RecordClicks(JsonObject settings) => settings["recordClicks"]?.GetValue<bool>() == true;

    // The first four saved paths are kept, including a relative path that load then drops.
    internal static JsonArray NormalizeLogs(JsonArray? logs)
    {
        var kept = new JsonArray();
        if (logs == null) return kept;
        foreach (var item in logs)
        {
            if (item is not JsonValue value || !value.TryGetValue(out string? path) || string.IsNullOrEmpty(path) || path.Length > 1024) continue;
            kept.Add(path);
            if (kept.Count == 4) break;
        }
        return kept;
    }

    internal static List<string> CustomLogFiles(JsonObject settings)
    {
        var kept = new List<string>();
        if (settings["customLogFiles"] is not JsonArray logs) return kept;
        foreach (var item in logs)
        {
            if (item is not JsonValue value || !value.TryGetValue(out string? path) || string.IsNullOrEmpty(path)) continue;
            if (path.Length > 1024 || !Path.IsPathRooted(path)) continue;
            kept.Add(path);
            if (kept.Count == 4) break;
        }
        return kept;
    }

    // Composer saves can race a tray toggle. Keep tray-owned values on disk unless the caller is that toggle.
    internal static void SaveSettings(string output, JsonObject settings, bool preserveReplay = true)
    {
        if (preserveReplay)
        {
            var disk = Settings(output);
            settings["instantReplay"] = InstantReplay(disk);
            settings["recordClicks"] = RecordClicks(disk);
            settings["customLogFiles"] = NormalizeLogs(disk["customLogFiles"] as JsonArray);
        }
        else settings["customLogFiles"] = NormalizeLogs(settings["customLogFiles"] as JsonArray);
        Program.Save(output, "settings.json", settings);
    }

    internal static List<string> Prefixes(JsonObject settings) =>
        (settings["prefixes"] as JsonArray ?? new JsonArray())
        .Select(item => item?.GetValue<string>() ?? "")
        .Where(item => item.Length > 0 && item.Length <= 500)
        .Take(12)
        .ToList();

    // The longest saved opening the note starts with. A following space or newline is required
    // unless the note is exactly that prefix, so one saved opening can extend another.
    internal static string? ActivePrefix(IReadOnlyList<string> prefixes, string text) =>
        prefixes.Where(prefix => text == prefix || text.StartsWith(prefix + " ", StringComparison.Ordinal) || text.StartsWith(prefix + "\n", StringComparison.Ordinal))
        .OrderByDescending(prefix => prefix.Length)
        .FirstOrDefault();

    // Puts the chosen opening at the start, replacing whichever opening is already there.
    // Choosing the active opening removes it and leaves the rest of the note.
    internal static string ApplyPrefix(IReadOnlyList<string> prefixes, string text, string prefix)
    {
        string? active = ActivePrefix(prefixes, text);
        string body = active == null ? text : text[active.Length..];
        int trim = 0;
        while (trim < body.Length && (body[trim] == ' ' || body[trim] == '\n')) trim++;
        body = body[trim..];
        if (active == prefix) return body;
        return body.Length == 0 ? prefix : prefix + " " + body;
    }

    internal static string WriteBundle(string output, string id, DateTimeOffset created, string note, IReadOnlyList<JsonObject> shots, JsonObject context, JsonObject include, IReadOnlyList<JsonObject>? videos = null)
    {
        if (shots.Count > 8) throw new Exception("A draft can contain up to 8 screenshots.");
        if (videos != null && videos.Count > ReplayMath.MaxClips) throw new Exception("A draft can contain up to 3 screen recordings.");
        var media = new JsonArray();
        foreach (var shot in shots)
        {
            var copy = Clone(shot);
            copy["kind"] = "image";
            media.Add(copy);
        }
        if (videos != null) foreach (var video in videos)
        {
            var copy = Clone(video);
            copy["kind"] = "video";
            string? file = copy["video"]?.GetValue<string>();
            if (file == null) throw new Exception("Invalid screen recording.");
            ValidateVideo(file, output);
            media.Add(copy);
        }
        var bundle = new JsonObject
        {
            ["schema"] = Schema,
            ["id"] = id.ToLowerInvariant(),
            ["createdAt"] = Iso(created),
            ["updatedAt"] = Iso(DateTimeOffset.UtcNow),
            ["note"] = note,
            ["media"] = media,
            ["context"] = Clone(context),
            ["include"] = Clone(include),
        };
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(bundle, Program.Json);
        if (bytes.Length > 2_000_000) throw new Exception("Capture bundle exceeds 2 MB.");
        string name = "bundle-" + id.ToLowerInvariant() + ".json";
        Program.Save(output, name, bundle);
        return Path.Combine(output, name);
    }

    internal static LoadedBundle LoadBundle(string path, string output)
    {
        string full = Path.GetFullPath(path);
        string name = Path.GetFileName(full);
        if (!string.Equals(Path.GetDirectoryName(full), output, StringComparison.OrdinalIgnoreCase) || !name.StartsWith("bundle-", StringComparison.Ordinal) || !name.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
            throw new Exception("Bundles must be in the Capture Studio captures folder.");
        if (new FileInfo(full).Length > 2_000_000) throw new Exception("This capture bundle is invalid or from a newer version.");
        if (JsonNode.Parse(File.ReadAllText(full)) is not JsonObject raw || raw["schema"]?.GetValue<string>() != Schema || raw["media"] is not JsonArray media || media.Count > 11)
            throw new Exception("This capture bundle is invalid or from a newer version.");
        var loaded = new LoadedBundle { Path = full, Id = raw["id"]?.GetValue<string>(), Note = raw["note"]?.GetValue<string>() ?? "" };
        if (DateTimeOffset.TryParse(raw["createdAt"]?.GetValue<string>(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var created)) loaded.Created = created;
        loaded.Context = raw["context"] as JsonObject ?? new JsonObject();
        loaded.Include = raw["include"] as JsonObject ?? DefaultInclude();
        int images = 0;
        int clips = 0;
        foreach (var entry in media)
        {
            if (entry is not JsonObject shot) continue;
            if (shot["kind"]?.GetValue<string>() == "video")
            {
                if (++clips > ReplayMath.MaxClips) throw new Exception("This capture bundle is invalid or from a newer version.");
                try { loaded.Videos.Add(AcceptedVideo(shot, output)); }
                catch { loaded.Missing++; }
                continue;
            }
            if (++images > 8) throw new Exception("This capture bundle is invalid or from a newer version.");
            string? screenshot = shot["screenshot"]?.GetValue<string>();
            try
            {
                if (screenshot == null) throw new Exception("Missing screenshot.");
                Program.ValidateImage(screenshot, output);
                loaded.Shots.Add(shot);
            }
            catch { loaded.Missing++; }
        }
        return loaded;
    }

    internal static void ValidateVideo(string file, string output)
    {
        string full = Path.GetFullPath(file);
        if (!string.Equals(Path.GetDirectoryName(full), output, StringComparison.OrdinalIgnoreCase) || !full.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase)
            || (File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0)
            throw new Exception("Screen recordings must be MP4 files in the capture folder.");
        long length = new FileInfo(full).Length;
        if (length < 12 || length > 200_000_000) throw new Exception(length > 200_000_000 ? "Screen recording is larger than 200 MB." : "Invalid screen recording.");
        using var stream = File.OpenRead(full);
        Span<byte> header = stackalloc byte[8];
        if (stream.Read(header) != 8 || header[4] != (byte)'f' || header[5] != (byte)'t' || header[6] != (byte)'y' || header[7] != (byte)'p')
            throw new Exception("Invalid screen recording.");
    }

    static JsonObject AcceptedVideo(JsonObject shot, string output)
    {
        string? video = shot["video"]?.GetValue<string>();
        if (video == null) throw new Exception("Invalid screen recording.");
        ValidateVideo(video, output);
        var copy = Clone(shot);
        copy["kind"] = "video";
        var frames = new JsonArray();
        if (shot["frames"] is JsonArray rawFrames) foreach (var node in rawFrames)
        {
            if (frames.Count >= 6 || node is not JsonObject frame) continue;
            string? screenshot = frame["screenshot"]?.GetValue<string>();
            try
            {
                if (screenshot == null) continue;
                Program.ValidateImage(screenshot, output);
                frames.Add(Clone(frame));
            }
            catch { /* A missing key frame stays out of the reopened clip. */ }
        }
        copy["frames"] = frames;
        return copy;
    }

    internal static List<RecentCapture> Recents(string output, int limit = 8)
    {
        if (!Directory.Exists(output)) return new List<RecentCapture>();
        var found = new List<RecentCapture>();
        foreach (string file in Directory.GetFiles(output, "bundle-*.json"))
        {
            try
            {
                if (new FileInfo(file).Length > 2_000_000) continue;
                if (JsonNode.Parse(File.ReadAllText(file)) is not JsonObject raw || raw["schema"]?.GetValue<string>() != Schema) continue;
                var createdText = raw["createdAt"]?.GetValue<string>();
                var updatedText = raw["updatedAt"]?.GetValue<string>() ?? createdText;
                if (!DateTimeOffset.TryParse(updatedText, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var updated)) continue;
                var entries = raw["media"] as JsonArray ?? new JsonArray();
                var media = entries.Where(item => item?["kind"]?.GetValue<string>() != "video").ToList();
                bool recorded = entries.Any(item => item?["kind"]?.GetValue<string>() == "video");
                string note = (raw["note"]?.GetValue<string>() ?? "").Split('\n')[0].Trim();
                string fallback = media.Count > 0 ? media[0]?["app"]?.GetValue<string>() ?? "Capture" : recorded ? "Screen recording" : "Capture";
                string title = note.Length == 0 ? fallback : note.Length > 48 ? note[..45] + "…" : note;
                found.Add(new RecentCapture { Path = file, Title = title, Updated = updated, Screenshots = media.Count });
            }
            catch { /* A damaged bundle stays on disk and is omitted from Recents. */ }
        }
        return found.OrderByDescending(item => item.Updated).Take(limit).ToList();
    }

    internal static List<ComposerEndpoint> Endpoints(string output)
    {
        string folder = Path.Combine(output, "composers");
        if (!Directory.Exists(folder)) return new List<ComposerEndpoint>();
        var found = new List<ComposerEndpoint>();
        foreach (string file in Directory.GetFiles(folder, "*.json"))
        {
            try
            {
                if (new FileInfo(file).Length > 16_000) continue;
                if (JsonNode.Parse(File.ReadAllText(file)) is not JsonObject raw) continue;
                string? directory = raw["directory"]?.GetValue<string>();
                int port = raw["port"]?.GetValue<int>() ?? 0;
                string? token = raw["token"]?.GetValue<string>();
                if (string.IsNullOrWhiteSpace(directory) || port is < 1 or > 65535 || token == null || token.Length != 64 || token.Any(character => !Uri.IsHexDigit(character))) continue;
                found.Add(new ComposerEndpoint(directory, port, token));
            }
            catch { /* Ignore a descriptor the helper cannot read. */ }
        }
        return found.OrderBy(item => item.Directory, StringComparer.OrdinalIgnoreCase).ToList();
    }

    internal static JsonArray LegacyOpenCode(ComposerEndpoint endpoint)
    {
        string name = Path.GetFileName(endpoint.Directory.TrimEnd('\\', '/'));
        if (string.IsNullOrEmpty(name)) name = "Project";
        return new JsonArray(new JsonObject
        {
            ["id"] = "opencode",
            ["label"] = "OpenCode",
            ["status"] = "ready",
            ["targets"] = new JsonArray(new JsonObject
            {
                ["id"] = endpoint.Directory,
                ["label"] = name,
                ["detail"] = endpoint.Directory,
                ["actionLabel"] = "Review in OpenCode",
                ["hint"] = "Opens an unsent draft in a new session. You press Enter.",
            }),
        });
    }

    internal static List<ComposerDestination> Merge(IReadOnlyList<(int Endpoint, JsonArray Destinations)> responses)
    {
        var merged = new List<ComposerDestination>();
        foreach (var response in responses)
        {
            foreach (var node in response.Destinations)
            {
                if (node is not JsonObject raw) continue;
                string? id = raw["id"]?.GetValue<string>();
                string? label = raw["label"]?.GetValue<string>();
                if (id == null || !Regex.IsMatch(id, "^[a-z][a-z0-9-]{0,31}$") || string.IsNullOrWhiteSpace(label)) continue;
                string status = raw["status"]?.GetValue<string>() ?? "not-running";
                var targets = new List<ComposerTarget>();
                foreach (var targetNode in raw["targets"] as JsonArray ?? new JsonArray())
                {
                    if (targetNode is not JsonObject target) continue;
                    string? targetId = target["id"]?.GetValue<string>();
                    string? targetLabel = target["label"]?.GetValue<string>();
                    if (targetId == null || targetLabel == null) continue;
                    targets.Add(new ComposerTarget(targetId, targetLabel, target["detail"]?.GetValue<string>(), target["actionLabel"]?.GetValue<string>() ?? "Continue", target["hint"]?.GetValue<string>() ?? "", response.Endpoint));
                }
                int index = merged.FindIndex(item => item.Id == id);
                if (index < 0) { merged.Add(new ComposerDestination(id, label, status, targets)); continue; }
                foreach (var target in targets.Where(target => merged[index].Targets.All(existing => existing.Id != target.Id))) merged[index].Targets.Add(target);
                if (status == "ready" && merged[index].Status != "ready") merged[index] = new ComposerDestination(id, merged[index].Label, status, merged[index].Targets);
            }
        }
        return merged;
    }

    internal static JsonObject Media(Snapshot shot)
    {
        var media = JsonSerializer.SerializeToNode(shot, Program.Json)!.AsObject();
        media["kind"] = "image";
        return media;
    }

    internal static Snapshot Shot(JsonObject media)
    {
        var copy = Clone(media);
        copy.Remove("kind");
        return JsonSerializer.Deserialize<Snapshot>(copy.ToJsonString()) ?? throw new Exception("This screenshot could not be reopened.");
    }
}

[StructLayout(LayoutKind.Sequential)]
internal struct PowerStatus
{
    internal byte ACLineStatus;
    internal byte BatteryFlag;
    internal byte BatteryLifePercent;
    internal byte SystemStatusFlag;
    internal uint BatteryLifeTime;
    internal uint BatteryFullLifeTime;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MemoryStatus
{
    internal uint Length;
    internal uint MemoryLoad;
    internal ulong TotalPhys;
    internal ulong AvailPhys;
    internal ulong TotalPageFile;
    internal ulong AvailPageFile;
    internal ulong TotalVirtual;
    internal ulong AvailVirtual;
    internal ulong AvailExtendedVirtual;
}

internal sealed class SkillChoice
{
    internal string Id = "";
    internal string Name = "";
}

// The note is canonical. Completion offers known skills while an @ query is being typed.
internal sealed class MentionSession
{
    internal List<SkillChoice> Candidates = new();
    internal int Selected;
    internal MentionQuery? Query;

    internal bool Open => Candidates.Count > 0;

    internal void Update(string text, int caret, int selectionLength, IReadOnlyList<SkillChoice> skills)
    {
        var next = QueryAt(text, caret, selectionLength);
        if (next?.Prefix != Query?.Prefix || next?.Start != Query?.Start) Selected = 0;
        Query = next;
        if (next is not MentionQuery query) { Candidates.Clear(); return; }
        Candidates = Matching(skills, query.Prefix);
        if (Candidates.Count == 0) { Query = null; return; }
        Selected = Math.Min(Selected, Candidates.Count - 1);
    }

    internal void Move(int delta)
    {
        if (Candidates.Count == 0) return;
        Selected = (Selected + delta + Candidates.Count) % Candidates.Count;
    }

    internal void Dismiss()
    {
        Candidates.Clear();
        Query = null;
        Selected = 0;
    }

    internal static List<SkillChoice> Matching(IReadOnlyList<SkillChoice> skills, string prefix) =>
        skills.Where(skill => prefix.Length == 0 || skill.Id.Contains(prefix, StringComparison.OrdinalIgnoreCase) || skill.Name.Contains(prefix, StringComparison.OrdinalIgnoreCase))
        .OrderBy(skill => skill.Id == "report" ? 0 : 1)
        .ThenBy(skill => skill.Id, StringComparer.Ordinal)
        .ToList();

    internal static MentionQuery? QueryAt(string text, int caret, int selectionLength)
    {
        if (selectionLength != 0 || caret < 0 || caret > text.Length) return null;
        var match = Regex.Match(text[..caret], @"(?<![\p{L}\p{N}_@/])@([\p{L}\p{N}_.-]*)$");
        if (!match.Success) return null;
        if (caret < text.Length && ContinuesToken(text[caret])) return null;
        return new MentionQuery(match.Index, match.Length, match.Groups[1].Value);
    }

    internal static string Apply(string text, int start, int length, string id)
    {
        string mention = "@" + id + " ";
        if (start < 0 || length < 0 || start > text.Length || start + length > text.Length) return text + mention;
        return text[..start] + mention + text[(start + length)..];
    }

    static bool ContinuesToken(char value) => char.IsLetterOrDigit(value) || value is '_' or '-' or '.' or '@';
}

internal readonly struct MentionQuery
{
    internal int Start { get; }
    internal int Length { get; }
    internal string Prefix { get; }
    internal MentionQuery(int start, int length, string prefix)
    {
        Start = start;
        Length = length;
        Prefix = prefix;
    }
}

internal static class ComposerTests
{
    static void Check(bool condition, string message) { if (!condition) throw new Exception("Composer regression: " + message); }

    internal static void Run(string output)
    {
        Check(ComposerFiles.Selection(new Point(0, 0), new Point(2, 2), new Rectangle(0, 0, 100, 100)) == null, "tiny region is not a capture");
        var selected = ComposerFiles.Selection(new Point(40, 50), new Point(10, 10), new Rectangle(0, 0, 100, 100));
        Check(selected == new Rectangle(10, 10, 30, 40), "region uses the drag bounds");
        Check(ComposerFiles.Selection(new Point(-10, -10), new Point(20, 25), new Rectangle(0, 0, 100, 100)) == new Rectangle(0, 0, 20, 25), "region stays on the display");
        Check(ComposerFiles.Mentions("see @report next", "report") && !ComposerFiles.Mentions("mail@report.com", "report"), "skill mentions ignore email addresses");

        var merged = ComposerFiles.Merge(new (int, JsonArray)[]
        {
            (0, new JsonArray(new JsonObject { ["id"] = "opencode", ["label"] = "OpenCode", ["status"] = "not-running", ["targets"] = new JsonArray(Target("p1", "One")) })),
            (1, new JsonArray(
                new JsonObject { ["id"] = "opencode", ["label"] = "OpenCode", ["status"] = "ready", ["targets"] = new JsonArray(Target("p2", "Two")) },
                new JsonObject { ["id"] = "clipboard", ["label"] = "Clipboard", ["status"] = "ready", ["targets"] = new JsonArray(Target("markdown", "Markdown")) })),
        });
        Check(merged.Count == 2 && merged[0].Status == "ready" && merged[0].Targets.Select(item => item.Id).SequenceEqual(new[] { "p1", "p2" }), "destinations merge targets and prefer a ready project");
        Check(merged[0].Targets[0].Endpoint == 0 && merged[1].Targets[0].Endpoint == 1, "targets remember the endpoint that offered them");

        string token = new string('a', 64);
        Directory.CreateDirectory(Path.Combine(output, "composers"));
        File.WriteAllText(Path.Combine(output, "composers", "ok.json"), JsonSerializer.Serialize(new { directory = "C:/work/demo", port = 9, token }));
        File.WriteAllText(Path.Combine(output, "composers", "bad.json"), "{\"directory\":\"C:/nope\",\"port\":9,\"token\":\"short\"}");
        var endpoints = ComposerFiles.Endpoints(output);
        Check(endpoints.Count == 1 && endpoints[0].Directory == "C:/work/demo" && endpoints[0].Port == 9, "only complete loopback descriptors are used");

        string image = Path.Combine(output, "shot.png");
        using (var bitmap = new Bitmap(2, 2)) { bitmap.SetPixel(0, 0, Color.Red); bitmap.Save(image, ImageFormat.Png); }
        var shot = ComposerFiles.Media(new Snapshot("Notepad", "Notes", "2026-10-29T00:00:00Z", image, "Edit Notes", new[] { "Review the screenshot." }));
        var include = ComposerFiles.DefaultInclude();
        include["windowText"] = false;
        var context = new JsonObject { ["device"] = new JsonObject { ["os"] = "Windows", ["arch"] = "x64" } };
        string bundle = ComposerFiles.WriteBundle(output, "11111111-1111-1111-1111-111111111111", DateTimeOffset.Parse("2026-10-29T00:00:00Z"), "Blank PDF\nmore", new[] { shot }, context, include);
        var loaded = ComposerFiles.LoadBundle(bundle, output);
        Check(loaded.Shots.Count == 1 && loaded.Note.StartsWith("Blank PDF") && !ComposerFiles.Included(loaded.Include, "windowText") && loaded.Context["device"]?["os"]?.GetValue<string>() == "Windows", "bundle keeps the note, screenshot, and context switches");
        var outside = ComposerFiles.Clone(loaded.Shots[0]);
        outside["screenshot"] = Path.Combine(Path.GetTempPath(), "outside.png");
        string foreign = Path.Combine(output, "bundle-22222222-2222-2222-2222-222222222222.json");
        File.WriteAllText(foreign, new JsonObject { ["schema"] = ComposerFiles.Schema, ["id"] = "22222222-2222-2222-2222-222222222222", ["createdAt"] = "2026-10-29T00:00:00Z", ["note"] = "", ["media"] = new JsonArray(outside), ["context"] = new JsonObject(), ["include"] = ComposerFiles.DefaultInclude() }.ToJsonString());
        Check(ComposerFiles.LoadBundle(foreign, output).Missing == 1 && ComposerFiles.LoadBundle(foreign, output).Shots.Count == 0, "screenshots outside the captures folder are not reopened");
        Check(ComposerFiles.Recents(output)[0].Title == "Blank PDF", "recents use the first note line");

        var settings = ComposerFiles.DefaultSettings();
        settings["defaultDestination"] = "clipboard";
        settings["prefixes"] = new JsonArray(JsonValue.Create("Look at this:"), JsonValue.Create(new string('x', 501)));
        ComposerFiles.SaveSettings(output, settings);
        var restored = ComposerFiles.Settings(output);
        Check(restored["defaultDestination"]?.GetValue<string>() == "clipboard" && ComposerFiles.Prefixes(restored).SequenceEqual(new[] { "Look at this:" }), "settings keep the destination and reject an oversized prefix");
        Check(ComposerFiles.InstantReplay(ComposerFiles.DefaultSettings()) == false, "instant replay is off by default");
        settings["instantReplay"] = true;
        ComposerFiles.SaveSettings(output, settings, false);
        Check(ComposerFiles.InstantReplay(ComposerFiles.Settings(output)), "instant replay persists");
        var kept = ComposerFiles.Settings(output);
        kept["defaultDestination"] = "opencode";
        ComposerFiles.SaveSettings(output, kept);
        Check(ComposerFiles.InstantReplay(ComposerFiles.Settings(output)), "saving the composer keeps instant replay");
        Check(!ComposerFiles.RecordClicks(ComposerFiles.DefaultSettings()) && ComposerFiles.CustomLogFiles(ComposerFiles.DefaultSettings()).Count == 0, "click recording and custom logs are off by default");
        var clickSettings = ComposerFiles.Settings(output);
        clickSettings["recordClicks"] = true;
        clickSettings["customLogFiles"] = new JsonArray(JsonValue.Create("/tmp/a.log"), JsonValue.Create("relative.log"), JsonValue.Create("/tmp/b.log"), JsonValue.Create("/tmp/c.log"), JsonValue.Create("/tmp/d.log"), JsonValue.Create("/tmp/e.log"));
        ComposerFiles.SaveSettings(output, clickSettings, false);
        var loadedLogs = ComposerFiles.CustomLogFiles(ComposerFiles.Settings(output));
        Check(ComposerFiles.RecordClicks(ComposerFiles.Settings(output)) && loadedLogs.SequenceEqual(new[] { "/tmp/a.log", "/tmp/b.log", "/tmp/c.log" }), "at most 4 saved log paths persist and relative paths are dropped");
        var preservedClicks = ComposerFiles.Settings(output);
        preservedClicks["defaultDestination"] = "folder";
        ComposerFiles.SaveSettings(output, preservedClicks);
        Check(ComposerFiles.RecordClicks(ComposerFiles.Settings(output)) && ComposerFiles.CustomLogFiles(ComposerFiles.Settings(output)).SequenceEqual(loadedLogs), "saving the composer keeps click recording and log files");

        string logDirectory = Path.Combine(output, "logs");
        Directory.CreateDirectory(logDirectory);
        string bigLog = Path.Combine(logDirectory, "big.log");
        string smallLog = Path.Combine(logDirectory, "small.log");
        File.WriteAllText(bigLog, string.Join("\n", Enumerable.Range(0, 3000).Select(index => "line " + index.ToString(CultureInfo.InvariantCulture) + " " + new string('y', 40))));
        File.WriteAllText(smallLog, "one\ntwo");
        var tails = CustomLogs.Tail(new[] { bigLog, logDirectory, Path.Combine(logDirectory, "missing.log"), smallLog }, 64_000);
        Check(tails.Count == 2, "directories and missing files are skipped");
        string bigText = tails[0]?["text"]?.GetValue<string>() ?? "";
        string lastLine = "line 2999 " + new string('y', 40);
        Check(tails[0]?["truncated"]?.GetValue<bool>() == true && Encoding.UTF8.GetByteCount(bigText) <= 64_000 && bigText.StartsWith("line ", StringComparison.Ordinal) && bigText.EndsWith(lastLine, StringComparison.Ordinal), "large logs keep whole last lines");
        Check(tails[1]?["text"]?.GetValue<string>() == "one\ntwo" && tails[1]?["truncated"]?.GetValue<bool>() == false && tails[1]?["name"]?.GetValue<string>() == "small.log", "small logs are read whole");
        Check(CustomLogs.Tail(Enumerable.Repeat(smallLog, 6).ToList()).Count == 4, "at most 4 log files");
        var joined = new JsonObject();
        CaptureContext.Apply(joined, new JsonObject { ["customLogFiles"] = new JsonArray(JsonValue.Create(smallLog)) }, new[] { new JsonObject { ["kind"] = "app-switch", ["app"] = "Finder", ["time"] = "t" } });
        Check(ContextReview.Count("events", Array.Empty<JsonObject>(), joined) == 1 && ContextReview.Count("customLogs", Array.Empty<JsonObject>(), joined) == 1, "events and custom logs join the context");
        CaptureContext.Apply(joined, ComposerFiles.DefaultSettings(), Array.Empty<JsonObject>());
        Check(joined["events"] == null && joined["customLogs"] == null, "no events key when the history is empty");

        var history = new ClickHistory();
        history.RecordAppSwitch("Notes");
        Check(history.Snapshot().Count == 0, "app switches are ignored while recording is off");
        var clickNow = DateTimeOffset.UtcNow;
        history.Append(new JsonObject { ["kind"] = "click", ["app"] = "Old" }, clickNow.AddSeconds(-700));
        for (int index = 0; index < ClickHistory.Limit + 20; index++) history.Append(new JsonObject { ["kind"] = "click", ["app"] = "App " + index.ToString(CultureInfo.InvariantCulture) }, clickNow);
        var buffered = history.Snapshot(clickNow);
        Check(buffered.Count == ClickHistory.Limit && buffered[^1]["app"]?.GetValue<string>() == "App " + (ClickHistory.Limit + 19).ToString(CultureInfo.InvariantCulture) && buffered.All(entry => entry["app"]?.GetValue<string>() != "Old"), "the event buffer is capped and expires old entries");
        Check(history.Snapshot(clickNow.AddSeconds(601)).Count == 0, "events expire after 10 minutes");
        history.Stop();
        Check(history.Snapshot().Count == 0, "stopping clears the buffer");
        var secure = ClickHistory.Describe("AXSecureTextField", null, "Password");
        Check(secure["role"]?.GetValue<string>() == "AXSecureTextField" && secure["title"] == null, "secure fields never keep labels");
        Check(ClickHistory.Describe("AXTextField", "AXSecureTextField", "PIN")["title"] == null, "secure subroles never keep labels");
        Check(ClickHistory.Describe("AXButton", null, "  " + new string('p', 200))["title"]?.GetValue<string>().Length == 120, "labels are trimmed and capped");
        Check(ClickHistory.SelectionEntry("  Seattle weather  ", "AXStaticText", null, null)?["text"]?.GetValue<string>() == "Seattle weather", "selected text is kept, trimmed");
        Check(ClickHistory.SelectionEntry("hunter2", "AXTextField", "AXSecureTextField", "Password") == null, "selections in secure fields are never kept");
        Check(ClickHistory.SelectionEntry(new string('s', 500), null, null, null)?["text"]?.GetValue<string>().Length == 200, "selected text is capped");
        var gesture = new ScrollGesture();
        var scrollStart = DateTimeOffset.UtcNow;
        Check(gesture.Add("Chrome", 0, 0, 0, -40, scrollStart) && gesture.Add("Chrome", 0, 0, 0, -60, scrollStart.AddSeconds(0.3)), "a continuing scroll joins the gesture");
        Check(!gesture.Add("Chrome", 0, 0, 0, -10, scrollStart.AddSeconds(2)) && !gesture.Add("Finder", 0, 0, 0, -10, scrollStart.AddSeconds(0.5)), "a pause or another app starts a new gesture");
        Check(gesture.Entry()?["direction"]?.GetValue<string>() == "down" && gesture.Entry()?["distance"]?.GetValue<int>() == 100, "a gesture becomes one scroll step");
        var recordingSteps = new ClickHistory();
        recordingSteps.BeginRecording();
        Check(recordingSteps.IsRunning && recordingSteps.IsRecording, "recordings capture clicks even when Record recent clicks is off");
        recordingSteps.Append(new JsonObject { ["kind"] = "click", ["app"] = "Notes" });
        recordingSteps.Append(new JsonObject { ["kind"] = "type", ["app"] = "Notes", ["role"] = "AXTextArea" });
        Check(recordingSteps.EndRecording(false).Count == 2 && !recordingSteps.IsRunning && recordingSteps.Snapshot().Count == 0, "ending a recording returns its steps and stops when clicks are off");
        recordingSteps.Start();
        recordingSteps.BeginRecording();
        recordingSteps.Append(new JsonObject { ["kind"] = "click", ["app"] = "Notes" });
        recordingSteps.Append(new JsonObject { ["kind"] = "scroll", ["app"] = "Notes", ["direction"] = "down", ["distance"] = 10 });
        _ = recordingSteps.EndRecording(true);
        var remaining = recordingSteps.Snapshot();
        Check(recordingSteps.IsRunning && remaining.Count == 1 && remaining[0]["kind"]?.GetValue<string>() == "click", "recording-only steps leave the click history when the recording ends");
        recordingSteps.Stop();
        var stepVideo = new JsonObject
        {
            ["startedAt"] = "2026-10-29T00:00:00.000Z",
            ["durationSeconds"] = 5,
            ["pauses"] = new JsonArray(new JsonObject { ["atSeconds"] = 1, ["durationSeconds"] = 0.5 }),
        };
        var clipSteps = ClickHistory.ForClip(new[]
        {
            new JsonObject { ["kind"] = "click", ["app"] = "Notes", ["time"] = "2026-10-29T00:00:02.000Z" },
            new JsonObject { ["kind"] = "click", ["app"] = "Notes", ["time"] = "2026-10-29T00:00:01.200Z" },
            new JsonObject { ["kind"] = "click", ["app"] = "Notes", ["time"] = "2026-10-29T00:00:10.000Z" },
        }, stepVideo);
        Check(clipSteps.Count == 1 && clipSteps[0]["source"]?.GetValue<string>() == "app", "steps outside the clip and inside a pause are left out");
        var replay = new ReplayBuffer();
        for (int second = 0; second <= 40; second++) replay.Add(second, new byte[] { 1 }, 8, 8);
        Check(replay.Count == 31 && Math.Abs(replay.Duration - 30) < 0.001, "instant replay keeps the last 30 seconds");
        replay.Add(41, new byte[] { 1 }, 16, 16);
        Check(replay.Count == 1 && replay.Width == 16 && replay.Height == 16, "a display change starts a new replay buffer");
        replay.Add(42, Array.Empty<byte>(), 16, 16);
        Check(replay.Count == 1, "an empty replay frame is ignored");
        replay.Add(43, new byte[] { 1 }, 16, 16, true);
        Check(replay.Count == 1 && Math.Abs(replay.Duration) < 0.001, "moving to another display starts a new replay buffer");
        var capped = new ReplayBuffer(2500);
        var payload = new byte[1000];
        capped.Add(0, payload, 8, 8);
        capped.Add(1, payload, 8, 8);
        capped.Add(2, payload, 8, 8);
        Check(capped.Count == 2, "instant replay drops frames past the memory cap");
        var prefixes = new[] { "@other", "@report Checkout:" };
        Check(ComposerFiles.ApplyPrefix(prefixes, "button is broken", "@report Checkout:") == "@report Checkout: button is broken", "choosing a prefix puts it at the start");
        Check(ComposerFiles.ActivePrefix(prefixes, "@report Checkout: button is broken") == "@report Checkout:", "the longest matching prefix is active");
        Check(ComposerFiles.ApplyPrefix(prefixes, "@report Checkout: button is broken", "@other") == "@other button is broken", "choosing another prefix swaps it");
        Check(ComposerFiles.ApplyPrefix(prefixes, "@other button is broken", "@other") == "button is broken", "choosing the active prefix removes it");
        Check(ComposerFiles.Mentions("see @report next", "report") && !ComposerFiles.Mentions("mail@report.com", "report") && !ComposerFiles.Mentions("/@report", "report"), "skill mentions ignore email addresses and path prefixes");
        Check(MentionSession.QueryAt("@report", 3, 0) == null, "completion never replaces half a token");
        var skills = new[] { new SkillChoice { Id = "other", Name = "Other" }, new SkillChoice { Id = "report", Name = "Report" } };
        var session = new MentionSession();
        session.Update("@re", 3, 0, skills);
        Check(session.Open && session.Candidates[0].Id == "report", "@ prefix opens matching completion with report first");
        var chosen = session.Query!.Value;
        Check(MentionSession.Apply("@re", chosen.Start, chosen.Length, "report") == "@report ", "completion replaces the query");
        var caret = MentionSession.QueryAt("🙂 @ot", 6, 0)!.Value;
        Check(MentionSession.Apply("🙂 @ot", caret.Start, 3, "other") == "🙂 @other ", "completion uses UTF-16 caret offsets");

        var reviewShot = new JsonObject { ["text"] = "AXStaticText: fixture", ["app"] = "Notes", ["title"] = "Scratch" };
        var reviewContext = new JsonObject
        {
            ["device"] = new JsonObject { ["os"] = "Windows 11", ["arch"] = "x64", ["memoryBytes"] = 8L * 1_073_741_824, ["displays"] = new JsonArray(new JsonObject { ["width"] = 1920, ["height"] = 1080, ["scale"] = 1.5 }), ["locale"] = "en-US" },
            ["app"] = new JsonObject { ["name"] = "Notes" },
            ["console"] = new JsonObject { ["entries"] = new JsonArray(new JsonObject { ["time"] = "2026-10-29T10:00:00Z", ["level"] = "fault", ["message"] = "boom", ["source"] = "app" }) },
            ["network"] = new JsonObject { ["entries"] = new JsonArray(new JsonObject { ["time"] = "2026-10-29T10:00:01Z", ["method"] = "POST", ["url"] = "https://shop.test/api", ["status"] = 502 }) },
            ["events"] = new JsonObject { ["entries"] = new JsonArray(new JsonObject { ["kind"] = "type", ["role"] = "AXTextField", ["title"] = "Search", ["time"] = "2026-10-29T10:00:05Z", ["app"] = "Notes" }, new JsonObject { ["kind"] = "click", ["role"] = "button", ["name"] = "Run", ["count"] = 2 }, new JsonObject { ["kind"] = "scroll", ["x"] = 0, ["y"] = 400 }) },
            ["system"] = new JsonObject { ["memory"] = new JsonObject { ["pressure"] = "normal" }, ["battery"] = new JsonObject { ["level"] = 50, ["charging"] = true }, ["storage"] = new JsonObject { ["availableBytes"] = 10L * 1_073_741_824 } },
        };
        var reviewShots = new List<JsonObject> { reviewShot };
        Check(ContextReview.Describe(reviewContext["events"]!["entries"]![0]!.AsObject()) == "Typed into textfield \"Search\"", "typing names the field only");
        Check(ContextReview.Describe(reviewContext["events"]!["entries"]![1]!.AsObject()) == "Double-clicked button \"Run\"", "browser steps use the role and accessible name");
        Check(ContextReview.Describe(reviewContext["events"]!["entries"]![2]!.AsObject()) == "Scrolled the page to 0, 400", "page scrolls keep their position");
        Check(ContextReview.Count("windowText", reviewShots, reviewContext) == 1 && ContextReview.Count("console", reviewShots, reviewContext) == 1 && ContextReview.ErrorCount("console", reviewContext) == 1, "context counts window text and console faults");
        Check(ContextReview.Render("device", reviewShots, reviewContext).Contains("Windows 11 (x64)") && ContextReview.Render("device", reviewShots, reviewContext).Contains("8 GB memory") && ContextReview.Render("device", reviewShots, reviewContext).Contains("Battery: 50%, charging"), "device preview includes hardware and power");
        Check(ContextReview.Markdown("device", reviewShots, Array.Empty<JsonObject>(), reviewContext).Contains("- **Memory:** 8 GB"), "device markdown uses labeled pairs");
        Check(ContextReview.TokenEstimate(0) == "≈0 tokens" && ContextReview.TokenEstimate(4000) == "≈1.0k tokens", "token estimate uses about four characters");
        var video = new JsonObject { ["source"] = "replay", ["startedAt"] = "2026-10-29T10:00:00Z", ["durationSeconds"] = 20 };
        Check(ContextReview.ClipMoment("2026-10-29T10:00:05Z", new[] { video }) == "Instant replay · 0:05.0", "events inside a clip show the clip time");
        var pausedClip = new JsonObject
        {
            ["startedAt"] = "2026-10-29T10:00:00.000Z",
            ["durationSeconds"] = 30,
            ["source"] = "recording",
            ["pauses"] = new JsonArray(new JsonObject { ["atSeconds"] = 2, ["durationSeconds"] = 50 }, new JsonObject { ["atSeconds"] = 20, ["durationSeconds"] = 5 }),
        };
        var pauseOnly = new JsonObject { ["startedAt"] = "2026-10-29T10:00:00.000Z", ["durationSeconds"] = 30, ["pauses"] = new JsonArray(new JsonObject { ["atSeconds"] = 10, ["durationSeconds"] = 60 }) };
        Check(ContextReview.Offset(DateTimeOffset.Parse("2026-10-29T10:00:04Z", CultureInfo.InvariantCulture), pauseOnly) == 4, "events before a pause keep their time");
        Check(ContextReview.Offset(DateTimeOffset.Parse("2026-10-29T10:00:30Z", CultureInfo.InvariantCulture), pauseOnly) == null, "events during a pause are not in the clip");
        Check(ContextReview.Offset(DateTimeOffset.Parse("2026-10-29T10:01:15Z", CultureInfo.InvariantCulture), pauseOnly) == 15, "events after a pause skip the paused time");
        var described = ClipReviewMath.Describe(pausedClip, 10, 22);
        var moved = DateTimeOffset.Parse(described["startedAt"]!.GetValue<string>(), CultureInfo.InvariantCulture);
        Check(Math.Abs(described["durationSeconds"]!.GetValue<double>() - 12) < 0.001 && Math.Abs((moved - DateTimeOffset.Parse("2026-10-29T10:00:00Z", CultureInfo.InvariantCulture)).TotalSeconds - 60) < 0.01, "the start moves by the trimmed time plus earlier pauses");
        Check(described["pauses"] is JsonArray keptPauses && keptPauses.Count == 1 && keptPauses[0]!["atSeconds"]!.GetValue<double>() == 10 && keptPauses[0]!["durationSeconds"]!.GetValue<double>() == 5, "pauses inside the selection are kept in clip time");
        try { ClipReviewMath.Describe(pausedClip, 3, 3.2); Check(false, "tiny selections are refused"); }
        catch (Exception error) { Check(error.Message.Contains("half a second"), "tiny selections are refused"); }
        var markerContext = new JsonObject
        {
            ["events"] = new JsonObject { ["entries"] = new JsonArray(new JsonObject { ["time"] = "2026-10-29T10:00:04Z", ["kind"] = "click", ["app"] = "Safari", ["role"] = "AXButton", ["title"] = "Buy" }, new JsonObject { ["time"] = "2026-10-29T09:00:00Z", ["kind"] = "click", ["app"] = "Old" }) },
            ["console"] = new JsonObject { ["entries"] = new JsonArray(new JsonObject { ["time"] = "2026-10-29T10:00:06.500Z", ["level"] = "error", ["message"] = "boom" }, new JsonObject { ["time"] = "2026-10-29T10:00:07Z", ["level"] = "warning", ["message"] = "slow" }, new JsonObject { ["time"] = "2026-10-29T10:00:08Z", ["level"] = "log", ["message"] = "noise" }) },
            ["network"] = new JsonObject { ["entries"] = new JsonArray(new JsonObject { ["time"] = "2026-10-29T10:00:09Z", ["method"] = "POST", ["status"] = 500, ["url"] = "https://x.test/pay" }) },
        };
        var markerVideo = new JsonObject { ["startedAt"] = "2026-10-29T10:00:00Z", ["durationSeconds"] = 20, ["source"] = "recording" };
        var markers = ClipReviewMath.Markers(markerVideo, markerContext);
        Check(markers.Count == 4 && markers[0].Title == "Click · 0:04.0" && markers[0].Kind == ClipMarkerKind.Click && markers[1].Kind == ClipMarkerKind.Error && markers[2].Kind == ClipMarkerKind.Warning && markers[3].Kind == ClipMarkerKind.Error && markers[3].Label == "POST 500 /pay", "clicks, errors, warnings and failed requests become timeline markers");
        Check(Math.Abs(markers[1].Time - 6.5) < 0.001 && Math.Abs(markers[2].Time - 7) < 0.001 && Math.Abs(markers[3].Time - 9) < 0.001, "marker times skip events outside the clip");
        Check(!ClipReviewMath.IsTrimmed(0, 20, 20) && ClipReviewMath.IsTrimmed(5, 12, 20), "the review opens untrimmed");
        Check(ClipReviewMath.SelectionLabel(5, 12, 20) == "0:05.0 in · 0:07.0 selected of 0:20.0 · 0:12.0 out", "trim handles describe the selection");
        Check(Math.Abs(ClipReviewMath.TimeAt(ClipReviewMath.X(7, 20, 220), 20, 220) - 7) < 0.01, "timeline positions map to clip time");
        Check(ClipReviewMath.MarkerNear(markers, ClipReviewMath.X(9, 20, 220) + 3, 20, 220)?.Label == "POST 500 /pay" && ClipReviewMath.MarkerNear(markers, ClipReviewMath.X(2, 20, 220), 20, 220) == null, "hovering near a marker finds it");
        Check(ContextReview.PressureName(10) == "normal" && ContextReview.PressureName(80) == "warning" && ContextReview.PressureName(95) == "critical" && ContextReview.PressureName(-1) == "unknown", "memory load maps to a pressure name");
        var facts = ComposerFiles.SystemFacts();
        Check(facts["memory"]?["pressure"] != null && facts["storage"]?["availableBytes"] != null, "Windows reports memory pressure and free storage");

        var offsets = ReplayMath.Offsets(30, 6).Select(value => Math.Round(value, 2, MidpointRounding.AwayFromZero)).Select(value => value.ToString("0.00", CultureInfo.InvariantCulture));
        Check(string.Join(",", offsets) == "0.00,5.98,11.96,17.94,23.92,29.90", "six evenly spaced key frames");
        Check(ReplayMath.Offsets(0, 6).SequenceEqual(new[] { 0d }), "a single frame for an instant recording");
        Check(new[] { 1, 2, 3, 4 }.Select(ReplayMath.FramesPerClip).SequenceEqual(new[] { 6, 3, 2, 2 }), "six frames are split across up to three clips");
        Check(ReplayMath.OutputSize(100, 51) == (100, 50) && ReplayMath.OutputSize(3000, 1000).Width == 1280 && ReplayMath.OutputSize(3000, 1000).Height % 2 == 0, "recording dimensions stay even");
        Check(ReplayMath.ClockLabel(10, 300) == "00:10" && ReplayMath.ClockLabel(280, 300) == "04:40 · 20s left", "the last 30 seconds show the time left");
        var timeline = new RecordingTimeline();
        timeline.Start(0);
        timeline.Pause(10);
        Check(timeline.Seconds(14) == 10, "a pause freezes the recorded time");
        timeline.Resume(15);
        Check(timeline.Seconds(20) == 15 && timeline.Pauses.Count == 1 && timeline.Pauses[0].At == 10 && timeline.Pauses[0].Duration == 5, "paused time stays out of the recording");

        string movie = Path.Combine(output, "recording-test.mp4");
        File.WriteAllBytes(movie, new byte[] { 0, 0, 0, 24, (byte)'f', (byte)'t', (byte)'y', (byte)'p', (byte)'i', (byte)'s', (byte)'o', (byte)'m', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        string frame = Path.Combine(output, "recording-test-frame-1.png");
        File.Copy(image, frame, true);
        var clip = new JsonObject
        {
            ["kind"] = "video",
            ["video"] = movie,
            ["source"] = "recording",
            ["area"] = "display",
            ["startedAt"] = "2026-10-29T00:00:00Z",
            ["durationSeconds"] = 5,
            ["frames"] = new JsonArray(new JsonObject { ["screenshot"] = frame, ["offsetSeconds"] = 0 }),
            ["pauses"] = new JsonArray(new JsonObject { ["atSeconds"] = 1, ["durationSeconds"] = 0.5 }),
        };
        string withVideo = ComposerFiles.WriteBundle(output, "33333333-3333-3333-3333-333333333333", DateTimeOffset.Parse("2026-10-29T00:00:00Z"), "Clip note", new[] { shot }, context, include, new[] { clip });
        var reopened = ComposerFiles.LoadBundle(withVideo, output);
        Check(reopened.Shots.Count == 1 && reopened.Videos.Count == 1 && reopened.Videos[0]["source"]?.GetValue<string>() == "recording" && reopened.Videos[0]["frames"] is JsonArray keptFrames && keptFrames.Count == 1, "a recording reopens beside its screenshots");
        string onlyVideo = ComposerFiles.WriteBundle(output, "55555555-5555-5555-5555-555555555555", DateTimeOffset.Parse("2026-10-29T00:00:01Z"), "", Array.Empty<JsonObject>(), context, include, new[] { clip });
        Check(ComposerFiles.LoadBundle(onlyVideo, output).Videos.Count == 1 && ComposerFiles.Recents(output).Any(item => item.Title == "Screen recording"), "a clip without a screenshot still appears in Recents");
        var outsideClip = ComposerFiles.Clone(clip);
        outsideClip["video"] = Path.Combine(Path.GetTempPath(), "outside-recording.mp4");
        string outsideBundle = Path.Combine(output, "bundle-44444444-4444-4444-4444-444444444444.json");
        File.WriteAllText(outsideBundle, new JsonObject { ["schema"] = ComposerFiles.Schema, ["id"] = "44444444-4444-4444-4444-444444444444", ["createdAt"] = "2026-10-29T00:00:00Z", ["note"] = "", ["media"] = new JsonArray(outsideClip), ["context"] = new JsonObject(), ["include"] = ComposerFiles.DefaultInclude() }.ToJsonString());
        var rejected = ComposerFiles.LoadBundle(outsideBundle, output);
        Check(rejected.Videos.Count == 0 && rejected.Missing == 1, "recordings outside the captures folder are not reopened");
        Check(ComposerFiles.Recents(output).Any(item => item.Title == "Screen recording"), "a clip without a screenshot still appears in Recents");
        Console.WriteLine("Windows composer regressions passed");
    }

    static JsonObject Target(string id, string label) => new() { ["id"] = id, ["label"] = label, ["actionLabel"] = "Continue", ["hint"] = "" };
}
