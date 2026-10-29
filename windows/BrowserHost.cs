using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace OpenCode.Appshots;

// Chrome launches this executable as a native messaging host. The tray helper asks
// that host for the extension's buffer only when a browser window is captured, and
// turns page-step recording on and off around a screen recording. The two processes
// talk over a named pipe and each refuses a peer that is not this same executable.
internal static class BrowserHost
{
    internal const string ExtensionId = "ffjgcjgbehaoabcniapiljdcpeehoocd";
    internal const string HostName = "local.opencode.capturestudio";

    internal readonly record struct BrowserTarget(string Name, string ProcessName, string PathMarker, string RegistryKey);

    internal static readonly BrowserTarget[] Browsers =
    {
        new("Google Chrome", "chrome", @"\Google\Chrome\Application\", @"Software\Google\Chrome"),
        new("Chrome Canary", "chrome", @"\Chrome SxS\", @"Software\Google\Chrome SxS"),
        new("Brave", "brave", @"\Brave", @"Software\BraveSoftware\Brave-Browser"),
        new("Microsoft Edge", "msedge", @"\Edge\", @"Software\Microsoft\Edge"),
        new("Chromium", "chromium", @"\Chromium\", @"Software\Chromium"),
        new("Arc", "arc", @"\Arc\", @"Software\Arc"),
    };

    internal readonly record struct HostPipe(string Name, int Browser, string BrowserName);

    internal static bool IsNativeHostLaunch(IReadOnlyList<string> args) =>
        args.Any(arg => arg == "chrome-extension://" + ExtensionId + "/");

    internal static int IndexForImage(string? image)
    {
        if (string.IsNullOrEmpty(image)) return -1;
        string file = Path.GetFileNameWithoutExtension(image);
        for (int index = 0; index < Browsers.Length; index++)
        {
            var browser = Browsers[index];
            if (!file.Equals(browser.ProcessName, StringComparison.OrdinalIgnoreCase)) continue;
            if (image.Contains(browser.PathMarker, StringComparison.OrdinalIgnoreCase)) return index;
        }
        int found = -1;
        for (int index = 0; index < Browsers.Length; index++)
        {
            if (!file.Equals(Browsers[index].ProcessName, StringComparison.OrdinalIgnoreCase)) continue;
            if (found >= 0) return -1;
            found = index;
        }
        return found;
    }

    internal static string PipeName(int browser, int pid) => "OpenCode.CaptureStudio." + browser + "." + pid;

    internal static JsonObject Manifest(string executable) => new()
    {
        ["name"] = HostName,
        ["description"] = "Capture Studio browser context",
        ["path"] = executable,
        ["type"] = "stdio",
        ["allowed_origins"] = new JsonArray("chrome-extension://" + ExtensionId + "/"),
    };

    internal static List<string> InstalledBrowsers(Func<string, bool> keyExists)
    {
        var installed = new List<string>();
        foreach (var browser in Browsers)
            if (keyExists(browser.RegistryKey)) installed.Add(browser.Name);
        return installed;
    }

    internal static byte[] EncodeMessage(JsonObject message)
    {
        byte[] payload = Encoding.UTF8.GetBytes(message.ToJsonString());
        var framed = new byte[4 + payload.Length];
        framed[0] = (byte)payload.Length;
        framed[1] = (byte)(payload.Length >> 8);
        framed[2] = (byte)(payload.Length >> 16);
        framed[3] = (byte)(payload.Length >> 24);
        payload.CopyTo(framed, 4);
        return framed;
    }

    internal static int? DecodeLength(ReadOnlySpan<byte> header)
    {
        if (header.Length != 4) return null;
        return header[0] | (header[1] << 8) | (header[2] << 16) | (header[3] << 24);
    }

    internal static bool SameExecutable(string? peer, string? own)
    {
        if (string.IsNullOrWhiteSpace(peer) || string.IsNullOrWhiteSpace(own)) return false;
        try { return string.Equals(Path.GetFullPath(peer), Path.GetFullPath(own), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    internal static JsonObject? Pick(JsonArray? windows, string windowTitle)
    {
        JsonObject? focused = null;
        JsonObject? first = null;
        if (windows == null) return null;
        foreach (var node in windows)
        {
            if (node is not JsonObject window || window["snapshot"] is not JsonObject snapshot) continue;
            first ??= snapshot;
            if (window["focused"]?.GetValue<bool>() == true) focused ??= snapshot;
            if (Text(snapshot, "title") is string title && title.Length > 0 && windowTitle.StartsWith(title, StringComparison.Ordinal)) return snapshot;
        }
        return focused ?? first;
    }

    internal static JsonObject ContextFrom(JsonObject? snapshot)
    {
        var context = new JsonObject();
        if (snapshot == null) return context;
        var browser = new JsonObject();
        foreach (var (key, limit) in new[] { ("url", 2000), ("title", 300), ("userAgent", 400) })
        {
            if (Text(snapshot, key) is string value && value.Length > 0)
                browser[key] = value.Length <= limit ? value : value[..limit];
        }
        if (browser.Count > 0) context["browser"] = browser;
        var console = new JsonArray();
        foreach (var entry in Tail(snapshot["console"] as JsonArray, 300))
        {
            if (Text(entry, "message") is not string message || message.Length == 0) continue;
            console.Add(new JsonObject
            {
                ["time"] = Text(entry, "time") ?? "",
                ["level"] = Text(entry, "level") ?? "log",
                ["message"] = message.Length <= 2000 ? message : message[..2000],
                ["source"] = "browser",
            });
        }
        if (console.Count > 0) context["console"] = new JsonObject { ["entries"] = console };
        var network = new JsonArray();
        foreach (var entry in Tail(snapshot["network"] as JsonArray, 200))
        {
            if (Text(entry, "url") is not string url || url.Length == 0) continue;
            var result = new JsonObject
            {
                ["time"] = Text(entry, "time") ?? "",
                ["method"] = Text(entry, "method") ?? "GET",
                ["url"] = url.Length <= 2000 ? url : url[..2000],
            };
            foreach (string key in new[] { "status", "error", "type" })
                if (entry[key] != null) result[key] = entry[key]!.DeepClone();
            network.Add(result);
        }
        if (network.Count > 0) context["network"] = new JsonObject { ["entries"] = network };
        return context;
    }

    static string? Text(JsonObject obj, string key) => obj[key] is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    static IEnumerable<JsonObject> Tail(JsonArray? items, int count)
    {
        if (items == null) yield break;
        var list = items.OfType<JsonObject>().ToList();
        foreach (var entry in list.Skip(Math.Max(0, list.Count - count))) yield return entry;
    }

    internal static List<string> Install(string executable)
    {
        string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Capture Studio", "NativeMessagingHosts");
        Directory.CreateDirectory(folder);
        Program.PrivateDirectory(folder);
        string manifestPath = Path.Combine(folder, HostName + ".json");
        File.WriteAllText(manifestPath, Manifest(executable).ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        var installed = new List<string>();
        foreach (var browser in Browsers)
        {
            using var existing = Registry.CurrentUser.OpenSubKey(browser.RegistryKey);
            if (existing == null) continue;
            using var hosts = Registry.CurrentUser.CreateSubKey(browser.RegistryKey + @"\NativeMessagingHosts\" + HostName);
            hosts?.SetValue("", manifestPath);
            installed.Add(browser.Name);
        }
        return installed;
    }

    internal static string ExtensionFolder(string baseDirectory)
    {
        string packaged = Path.GetFullPath(Path.Combine(baseDirectory, "..", "..", "browser-extension"));
        if (Directory.Exists(packaged)) return packaged;
        return Path.GetFullPath(Path.Combine(baseDirectory, "..", "..", "..", "..", "browser-extension"));
    }

    internal static int RunNativeHost()
    {
        int index = IndexForImage(ParentImage());
        if (index < 0) return 0;
        string name = PipeName(index, Environment.ProcessId);
        var session = new HostSession();
        using var stdinDone = new CancellationTokenSource();
        var stdout = Console.OpenStandardOutput();
        session.Send = bytes => { lock (stdout) stdout.Write(bytes, 0, bytes.Length); stdout.Flush(); };
        var reader = new Thread(() => ReadExtension(Console.OpenStandardInput(), session, stdinDone)) { IsBackground = true };
        reader.Start();
        while (!stdinDone.IsCancellationRequested)
        {
            NamedPipeServerStream? server = null;
            try
            {
                server = OpenPipe(name);
                server.WaitForConnectionAsync(stdinDone.Token).GetAwaiter().GetResult();
                if (!ClientIsThisExecutable(server)) { server.Dispose(); server = null; continue; }
                string? type = ReadRequest(server, 4096);
                if (type == null) { server.Dispose(); server = null; continue; }
                session.Begin(server, type);
                server = null;
            }
            catch (OperationCanceledException) { server?.Dispose(); break; }
            catch { server?.Dispose(); }
        }
        return 0;
    }

    internal static JsonObject? RequestSnapshot(string? image, string windowTitle)
    {
        int index = IndexForImage(image);
        if (index < 0) return null;
        var pipes = HostPipes().Where(pipe => pipe.Browser == index).Take(8).ToList();
        var replies = Task.WhenAll(pipes.Select(pipe => Task.Run(() => Request(pipe.Name, "snapshot", 2000)))).GetAwaiter().GetResult();
        var windows = new JsonArray();
        foreach (var reply in replies)
        {
            if (reply?["windows"] is not JsonArray list) continue;
            foreach (var item in list) if (item != null) windows.Add(item.DeepClone());
        }
        return Pick(windows, windowTitle);
    }

    internal static List<JsonObject> CollectSteps(bool recording)
    {
        var all = new List<JsonObject>();
        string type = recording ? "steps-start" : "steps-stop";
        var pipes = HostPipes().Take(8).ToList();
        var replies = Task.WhenAll(pipes.Select(pipe => Task.Run(() => (pipe, reply: Request(pipe.Name, type, 1500))))).GetAwaiter().GetResult();
        foreach (var (pipe, reply) in replies) all.AddRange(TagSteps(reply?["steps"] as JsonArray, pipe.BrowserName));
        return all;
    }

    // The extension can record more than the draft keeps. The newest steps are the ones still on screen.
    internal static List<JsonObject> TagSteps(JsonArray? steps, string browserName)
    {
        var tagged = new List<JsonObject>();
        if (steps == null) return tagged;
        foreach (var entry in steps.OfType<JsonObject>().TakeLast(500))
        {
            var copy = ComposerFiles.Clone(entry);
            copy["app"] = browserName;
            copy["source"] = "browser";
            tagged.Add(copy);
        }
        return tagged;
    }

    internal static string? WindowImage(nint window)
    {
        Native.GetWindowThreadProcessId(window, out uint pid);
        return ImageOf(pid);
    }

    internal static void SelfCheck()
    {
        void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
        Check(IsNativeHostLaunch(new[] { "chrome-extension://" + ExtensionId + "/" }) && !IsNativeHostLaunch(new[] { "chrome-extension://abcdefghijklmnopabcdefghijklmnop/" }) && !IsNativeHostLaunch(Array.Empty<string>()), "only the pinned extension starts host mode");
        Check(IndexForImage(@"C:\Program Files\Google\Chrome\Application\chrome.exe") == 0 && IndexForImage(@"C:\Google\Chrome SxS\Application\chrome.exe") == 1 && IndexForImage(@"C:\BraveSoftware\Brave-Browser\Application\brave.exe") == 2 && IndexForImage(@"C:\Windows\notepad.exe") < 0, "Chromium browsers are recognised from the executable");
        var framed = EncodeMessage(new JsonObject { ["type"] = "snapshot", ["requestID"] = "r" });
        Check(DecodeLength(framed.AsSpan(0, 4)) == framed.Length - 4 && DecodeLength(new byte[] { 1, 2 }) == null, "native messages are length-prefixed");
        Check(PipeName(2, 4321) == "OpenCode.CaptureStudio.2.4321", "one pipe per host");
        string own = ImageOf((uint)Environment.ProcessId) ?? "";
        Check(SameExecutable(own, own) && !SameExecutable(@"C:\Windows\System32\cmd.exe", own), "only this executable is accepted");
        var windows = new JsonArray
        {
            new JsonObject { ["focused"] = true, ["snapshot"] = new JsonObject { ["title"] = "Inbox", ["url"] = "https://mail.test" } },
            new JsonObject { ["focused"] = false, ["snapshot"] = new JsonObject { ["title"] = "Checkout - Shop", ["url"] = "https://shop.test" } },
            new JsonObject { ["focused"] = false },
        };
        Check(Pick(windows, "Checkout - Shop - Google Chrome - Work")?["url"]?.GetValue<string>() == "https://shop.test", "the captured window's tab is chosen by title");
        Check(Pick(windows, "Something else")?["url"]?.GetValue<string>() == "https://mail.test", "falls back to the focused window");
        Check(Pick(new JsonArray(), "x") == null, "no windows, no snapshot");
        var console = new JsonArray();
        for (int i = 0; i < 320; i++) console.Add(new JsonObject { ["time"] = "t", ["level"] = "error", ["message"] = new string('m', 3000) });
        console.Add(new JsonObject { ["level"] = "log" });
        var snapshot = new JsonObject
        {
            ["url"] = "https://shop.test/pay",
            ["title"] = "Pay",
            ["userAgent"] = "Mozilla/5.0",
            ["console"] = console,
            ["network"] = new JsonArray
            {
                new JsonObject { ["time"] = "t", ["method"] = "POST", ["url"] = "https://shop.test/api", ["status"] = 502, ["type"] = "xmlhttprequest" },
                new JsonObject { ["method"] = "GET" },
            },
        };
        var context = ContextFrom(snapshot);
        Check(context["browser"]?["userAgent"]?.GetValue<string>() == "Mozilla/5.0", "browser page and user agent");
        var entries = context["console"]?["entries"] as JsonArray;
        Check(entries?.Count == 299 && entries.All(entry => entry?["source"]?.GetValue<string>() == "browser" && entry?["message"]?.GetValue<string>()?.Length == 2000) == true, "browser console is capped, labeled and trimmed");
        var failed = context["network"]?["entries"] as JsonArray;
        Check(failed?.Count == 1 && failed[0]?["status"]?.GetValue<int>() == 502, "failed requests keep status, entries without URLs are dropped");
        Check(ContextFrom(new JsonObject()).Count == 0, "empty snapshots add nothing");
        var many = new JsonArray();
        for (int i = 0; i < 520; i++) many.Add(new JsonObject { ["kind"] = "click", ["n"] = i });
        var tagged = TagSteps(many, "Brave");
        Check(tagged.Count == 500 && tagged[0]["n"]?.GetValue<int>() == 20 && tagged[499]["app"]?.GetValue<string>() == "Brave" && tagged[499]["source"]?.GetValue<string>() == "browser", "page steps keep the latest 500 and name their browser");
        Check(InstalledBrowsers(key => key == @"Software\Google\Chrome").SequenceEqual(new[] { "Google Chrome" }) && InstalledBrowsers(_ => false).Count == 0, "manifests are written only for installed browsers");
        var manifest = Manifest(@"C:\Capture Studio\Appshots.exe");
        Check(manifest["allowed_origins"]?[0]?.GetValue<string>() == "chrome-extension://" + ExtensionId + "/" && manifest["type"]?.GetValue<string>() == "stdio" && manifest["name"]?.GetValue<string>() == HostName, "the host allows only the pinned extension");
        ExercisePipe();
    }

    static void ExercisePipe()
    {
        void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
        string name = PipeName(0, Environment.ProcessId);
        var session = new HostSession();
        using var ready = new ManualResetEventSlim();
        var gate = new object();
        Exception? serverError = null;
        var server = new Thread(() =>
        {
            try
            {
                var pipe = OpenPipe(name);
                ready.Set();
                pipe.WaitForConnection();
                Check(ClientIsThisExecutable(pipe), "the helper is accepted by its own host");
                string? type = ReadRequest(pipe, 4096);
                Check(type == "snapshot", "the host reads which request the helper sent");
                session.Begin(pipe, type!);
            }
            catch (Exception error) { lock (gate) serverError = error; ready.Set(); }
        });
        server.IsBackground = true;
        server.Start();
        ready.Wait(5000);
        if (serverError != null) throw serverError;
        JsonObject? reply = null;
        var client = Task.Run(() => reply = Request(name, "snapshot", 4000));
        var until = DateTime.UtcNow.AddSeconds(4);
        while (session.Sent.Count == 0 && DateTime.UtcNow < until)
        {
            lock (gate) if (serverError != null) throw serverError;
            Thread.Sleep(10);
        }
        lock (gate) if (serverError != null) throw serverError;
        Check(session.Sent.Count == 1 && session.Sent[0]["type"]?.GetValue<string>() == "snapshot" && Guid.TryParse(session.Sent[0]["requestID"]?.GetValue<string>(), out _), "each connection asks the extension once");
        string requestId = session.Sent[0]["requestID"]!.GetValue<string>();
        session.Receive(new JsonObject { ["type"] = "snapshot", ["requestID"] = Guid.NewGuid().ToString(), ["windows"] = new JsonArray { new JsonObject { ["focused"] = true } } });
        Check(session.Pending == 1, "unrequested replies are ignored");
        var windows = new JsonArray
        {
            new JsonObject { ["focused"] = true, ["snapshot"] = new JsonObject { ["title"] = "Inbox", ["url"] = "https://mail.test" } },
            new JsonObject { ["focused"] = false, ["snapshot"] = new JsonObject { ["title"] = "Checkout - Shop", ["url"] = "https://shop.test" } },
            new JsonObject { ["focused"] = false },
        };
        session.Receive(new JsonObject { ["type"] = "snapshot", ["requestID"] = requestId, ["windows"] = windows });
        client.Wait(5000);
        JsonArray? received = reply?["windows"] as JsonArray;
        Check(received != null && received.Count == 3 && session.Pending == 0, "the reply goes back on the requesting connection only");
        Check(Pick(received, "Checkout - Shop - Brave")?["url"]?.GetValue<string>() == "https://shop.test", "the helper picks the captured tab from the reply");
        ExerciseSteps();
        RefuseOtherProcess();
    }

    static void ExerciseSteps()
    {
        void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
        string name = PipeName(0, Environment.ProcessId);
        var session = new HostSession();
        using var ready = new ManualResetEventSlim();
        var gate = new object();
        Exception? serverError = null;
        var server = new Thread(() =>
        {
            try
            {
                var pipe = OpenPipe(name);
                ready.Set();
                pipe.WaitForConnection();
                string? type = ReadRequest(pipe, 4096);
                Check(type == "steps-stop", "stopping page steps is its own request");
                session.Begin(pipe, type!);
            }
            catch (Exception error) { lock (gate) serverError = error; ready.Set(); }
        }) { IsBackground = true };
        server.Start();
        ready.Wait(5000);
        lock (gate) if (serverError != null) throw serverError;
        JsonObject? reply = null;
        var client = Task.Run(() => reply = Request(name, "steps-stop", 4000));
        var until = DateTime.UtcNow.AddSeconds(4);
        while (session.Sent.Count == 0 && DateTime.UtcNow < until) Thread.Sleep(10);
        lock (gate) if (serverError != null) throw serverError;
        Check(session.Sent.Count == 1 && session.Sent[0]["type"]?.GetValue<string>() == "steps-stop", "the extension is told to stop recording steps");
        session.Receive(new JsonObject
        {
            ["type"] = "steps",
            ["requestID"] = session.Sent[0]["requestID"]!.GetValue<string>(),
            ["steps"] = new JsonArray { new JsonObject { ["kind"] = "click", ["time"] = "t" } },
        });
        client.Wait(5000);
        JsonArray? steps = reply?["steps"] as JsonArray;
        Check(steps != null && steps.Count == 1 && steps[0]?["kind"]?.GetValue<string>() == "click", "recorded steps come back to the helper");
    }

    static void RefuseOtherProcess()
    {
        string name = PipeName(1, Environment.ProcessId);
        string script = Path.Combine(Path.GetTempPath(), "capture-studio-impostor-" + Environment.ProcessId + ".ps1");
        File.WriteAllText(script, "$c = New-Object System.IO.Pipes.NamedPipeClientStream('.', '" + name + "', 'InOut')\n$c.Connect(5000)\n$b = [Text.Encoding]::UTF8.GetBytes('{\"type\":\"snapshot\"}')\n$c.Write($b, 0, $b.Length)\nStart-Sleep -Seconds 2\n");
        using var ready = new ManualResetEventSlim();
        bool refused = false;
        var server = new Thread(() =>
        {
            try
            {
                using var pipe = OpenPipe(name);
                ready.Set();
                if (!pipe.WaitForConnectionAsync().Wait(8000)) return;
                refused = !ClientIsThisExecutable(pipe);
            }
            catch { ready.Set(); }
        });
        server.IsBackground = true;
        server.Start();
        ready.Wait(5000);
        using var impostor = Process.Start(new ProcessStartInfo("powershell", "-NoProfile -File \"" + script + "\"") { CreateNoWindow = true, UseShellExecute = false });
        server.Join(8000);
        try { if (impostor is { HasExited: false }) impostor.Kill(entireProcessTree: true); } catch { /* The refused client can exit on its own. */ }
        try { File.Delete(script); } catch { /* The script is outside the captures folder. */ }
        if (!refused) throw new Exception("other processes are refused");
    }

    static List<HostPipe> HostPipes()
    {
        var found = new List<HostPipe>();
        string[] names;
        try { names = Directory.GetFiles(@"\\.\pipe\"); }
        catch { return found; }
        foreach (string full in names)
        {
            string name = Path.GetFileName(full);
            const string prefix = "OpenCode.CaptureStudio.";
            if (!name.StartsWith(prefix, StringComparison.Ordinal)) continue;
            string[] parts = name.Split('.');
            if (parts.Length != 4 || !int.TryParse(parts[2], out int index) || index < 0 || index >= Browsers.Length) continue;
            found.Add(new HostPipe(name, index, Browsers[index].Name));
        }
        return found;
    }

    static JsonObject? Request(string name, string type, int timeoutMs)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut);
            client.Connect(timeoutMs);
            if (!ServerIsThisExecutable(client)) return null;
            byte[] body = Encoding.UTF8.GetBytes(new JsonObject { ["type"] = type }.ToJsonString());
            client.Write(body, 0, body.Length);
            client.Flush();
            var message = ReadMessage(client, 32_000_000);
            return message == null ? null : JsonNode.Parse(message) as JsonObject;
        }
        catch { return null; }
    }

    static string? ReadRequest(PipeStream stream, int limit)
    {
        var message = ReadMessage(stream, limit);
        if (message == null) return null;
        if (JsonNode.Parse(message) is not JsonObject request) return null;
        string? type = request["type"]?.GetValue<string>();
        return type is "snapshot" or "steps-start" or "steps-stop" ? type : null;
    }

    static byte[]? ReadMessage(PipeStream stream, int limit)
    {
        var buffer = new MemoryStream();
        var chunk = new byte[65536];
        do
        {
            int count = stream.Read(chunk, 0, chunk.Length);
            if (count <= 0) break;
            if (buffer.Length + count > limit) return null;
            buffer.Write(chunk, 0, count);
        }
        while (!stream.IsMessageComplete);
        return buffer.Length == 0 ? null : buffer.ToArray();
    }

    static void ReadExtension(Stream stdin, HostSession session, CancellationTokenSource done)
    {
        try
        {
            while (true)
            {
                var header = ReadExact(stdin, 4);
                if (header == null) break;
                int? length = DecodeLength(header);
                if (length is null or < 1 or > 16_000_000) break;
                var payload = ReadExact(stdin, length.Value);
                if (payload == null) break;
                if (JsonNode.Parse(payload) is JsonObject message) session.Receive(message);
            }
        }
        catch { /* Chrome closed the host. */ }
        finally { try { done.Cancel(); } catch { /* Already stopped. */ } }
    }

    static byte[]? ReadExact(Stream stream, int count)
    {
        var buffer = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int read = stream.Read(buffer, offset, count - offset);
            if (read <= 0) return null;
            offset += read;
        }
        return buffer;
    }

    static NamedPipeServerStream OpenPipe(string name)
    {
        var security = new PipeSecurity();
        var user = WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("Current Windows user is unavailable.");
        security.AddAccessRule(new PipeAccessRule(user, PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        return NamedPipeServerStreamAcl.Create(name, PipeDirection.InOut, 1, PipeTransmissionMode.Message, PipeOptions.None, 64 * 1024, 64 * 1024, security);
    }

    static bool ClientIsThisExecutable(PipeStream pipe) => PeerIsThisExecutable(pipe, client: true);
    static bool ServerIsThisExecutable(PipeStream pipe) => PeerIsThisExecutable(pipe, client: false);

    static bool PeerIsThisExecutable(PipeStream pipe, bool client)
    {
        if (!pipe.IsConnected) return false;
        uint pid;
        bool known = client ? GetNamedPipeClientProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out pid) : GetNamedPipeServerProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out pid);
        if (!known || pid == 0) return false;
        return SameExecutable(ImageOf(pid), ImageOf((uint)Environment.ProcessId));
    }

    static string? ParentImage()
    {
        var info = new ProcessBasicInformation();
        if (NtQueryInformationProcess(Process.GetCurrentProcess().Handle, 0, ref info, Marshal.SizeOf<ProcessBasicInformation>(), out _) != 0) return null;
        return ImageOf((uint)info.InheritedFromUniqueProcessId);
    }

    static string? ImageOf(uint pid)
    {
        nint process = OpenProcess(0x1000, false, pid);
        if (process == 0) return null;
        try
        {
            var name = new StringBuilder(1024);
            int size = name.Capacity;
            return QueryFullProcessImageName(process, 0, name, ref size) ? name.ToString() : null;
        }
        finally { CloseHandle(process); }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessBasicInformation
    {
        public nint Reserved1;
        public nint PebBaseAddress;
        public nint Reserved2_0;
        public nint Reserved2_1;
        public nint UniqueProcessId;
        public nint InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(nint process, int processInformationClass, ref ProcessBasicInformation info, int size, out int returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern nint OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(nint handle);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(nint process, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNamedPipeClientProcessId(nint pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNamedPipeServerProcessId(nint pipe, out uint pid);
}

internal sealed class HostSession
{
    readonly Dictionary<string, Stream> pending = new();
    readonly object gate = new();
    internal readonly List<JsonObject> Sent = new();
    internal Action<byte[]> Send = static _ => { };
    internal int Pending { get { lock (gate) return pending.Count; } }

    internal void Begin(Stream client, string type)
    {
        string requestID = Guid.NewGuid().ToString();
        var message = new JsonObject { ["type"] = type, ["requestID"] = requestID };
        lock (gate)
        {
            pending[requestID] = client;
            Sent.Add(ComposerFiles.Clone(message));
        }
        try { Send(BrowserHost.EncodeMessage(message)); }
        catch { Close(requestID); return; }
        _ = Task.Run(async () =>
        {
            await Task.Delay(3000);
            Close(requestID);
        });
    }

    internal void Receive(JsonObject message)
    {
        string? type = message["type"]?.GetValue<string>();
        string? requestID = message["requestID"]?.GetValue<string>();
        if (requestID == null || type is not ("snapshot" or "steps")) return;
        Stream? client;
        lock (gate)
        {
            if (!pending.Remove(requestID, out client)) return;
        }
        try
        {
            var reply = new JsonObject();
            reply[type == "snapshot" ? "windows" : "steps"] = message[type == "snapshot" ? "windows" : "steps"]?.DeepClone() ?? new JsonArray();
            byte[] data = Encoding.UTF8.GetBytes(reply.ToJsonString());
            client.Write(data, 0, data.Length);
            client.Flush();
        }
        catch { /* The helper stopped waiting. */ }
        finally { try { client.Dispose(); } catch { /* Already closed. */ } }
    }

    void Close(string requestID)
    {
        Stream? client;
        lock (gate)
        {
            if (!pending.Remove(requestID, out client)) return;
        }
        try { client.Dispose(); } catch { /* Already closed. */ }
    }
}
