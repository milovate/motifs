using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using System.Speech.Recognition;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace OpenCode.Appshots;

internal sealed class BridgeException : Exception
{
    internal bool NotFound { get; }
    internal BridgeException(string message, bool notFound = false) : base(message) { NotFound = notFound; }
}

internal sealed class BridgeClient : IDisposable
{
    readonly HttpClient http = new(new HttpClientHandler { AllowAutoRedirect = false });
    readonly ComposerEndpoint endpoint;
    internal BridgeClient(ComposerEndpoint endpoint)
    {
        this.endpoint = endpoint;
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", endpoint.Token);
    }

    internal Task<JsonObject> Get(string route) => Send(new HttpRequestMessage(HttpMethod.Get, Url(route)), 3);
    internal Task<JsonObject> Post(string route, JsonObject body)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, Url(route)) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
        return Send(request, 30);
    }

    async Task<JsonObject> Send(HttpRequestMessage request, int seconds)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        using var response = await http.SendAsync(request, timeout.Token);
        byte[] bytes = await response.Content.ReadAsByteArrayAsync(timeout.Token);
        if (bytes.Length > 2_000_000) throw new BridgeException("Composer response is too large.");
        var root = JsonNode.Parse(Encoding.UTF8.GetString(bytes)) as JsonObject ?? new JsonObject();
        if ((int)response.StatusCode != 200) throw new BridgeException(root["error"]?.GetValue<string>() ?? "OpenCode could not accept the request.", (int)response.StatusCode == 404);
        return root;
    }

    Uri Url(string route)
    {
        if (!route.StartsWith("/", StringComparison.Ordinal) || endpoint.Port is < 1 or > 65535 || endpoint.Token.Length != 64) throw new BridgeException("Invalid local composer endpoint.");
        return new Uri($"http://127.0.0.1:{endpoint.Port}{route}");
    }

    public void Dispose() => http.Dispose();
}

// The note stays plain text. Known @mentions are drawn again in the accent color
// on a rounded tint, after the edit control has painted, so undo and paste stay plain.
internal sealed class MentionNote : TextBox
{
    List<ComposerFiles.MentionSpan> spans = new();
    IReadOnlyList<string> skills = Array.Empty<string>();

    internal void SetSkills(IReadOnlyList<string> ids)
    {
        skills = ids;
        RefreshSpans();
        Invalidate();
    }

    protected override void OnTextChanged(EventArgs e)
    {
        RefreshSpans();
        base.OnTextChanged(e);
    }

    void RefreshSpans() => spans = ComposerFiles.MentionSpans(Text, skills);

    protected override void WndProc(ref Message m)
    {
        base.WndProc(ref m);
        if (m.Msg == 0x000F) PaintMentions();
    }

    void PaintMentions()
    {
        if (!IsHandleCreated || spans.Count == 0 || TextLength == 0) return;
        using var graphics = Graphics.FromHwnd(Handle);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Color accent = SystemColors.Highlight;
        using var fill = new SolidBrush(ComposerFiles.MentionTint(BackColor, accent));
        var flags = TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.NoClipping;
        int selectedStart = SelectionStart;
        int selectedEnd = selectedStart + SelectionLength;
        foreach (var span in spans)
        {
            if (span.Start < 0 || span.Length <= 0 || span.Start + span.Length > TextLength) continue;
            if (SelectionLength > 0 && span.Start < selectedEnd && selectedStart < span.Start + span.Length) continue;
            int index = span.Start;
            int end = span.Start + span.Length;
            while (index < end)
            {
                int line = GetLineFromCharIndex(index);
                int nextLine = GetFirstCharIndexFromLine(line + 1);
                int segmentEnd = nextLine < 0 ? end : Math.Min(end, nextLine);
                if (segmentEnd <= index) break;
                string slice = Text.Substring(index, segmentEnd - index).Replace("\r", "").Replace("\n", "");
                if (slice.Length == 0) { index = segmentEnd; continue; }
                Point origin = GetPositionFromCharIndex(index);
                int width = segmentEnd < TextLength ? GetPositionFromCharIndex(segmentEnd).X - origin.X : 0;
                if (width < 4) width = TextRenderer.MeasureText(graphics, slice, Font, Size.Empty, flags).Width;
                int nextTop = nextLine >= 0 ? GetPositionFromCharIndex(nextLine).Y : origin.Y + Font.Height;
                int height = nextTop - origin.Y;
                if (height < Font.Height / 2) height = Font.Height;
                Rectangle pill = ComposerFiles.MentionPill(origin, width, height);
                using (var path = Round(pill, 5)) graphics.FillPath(fill, path);
                TextRenderer.DrawText(graphics, slice, Font, origin, accent, flags);
                index = segmentEnd;
            }
        }
    }

    static GraphicsPath Round(Rectangle rect, int radius)
    {
        int diameter = radius * 2;
        var path = new GraphicsPath();
        if (rect.Width < diameter || rect.Height < diameter) { path.AddRectangle(rect); return path; }
        path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

// Floating review surface: screenshots, a note, destination, context, and a handoff
// that stops in an unsent draft, on the clipboard, or in a folder.
internal sealed class ComposerForm : Form
{
    readonly string output;
    readonly List<JsonObject> shots = new();
    int selectedShotIndex;
    readonly List<JsonObject> videos = new();
    readonly List<ComposerEndpoint> endpoints = new();
    readonly List<SkillChoice> skills = new();
    readonly FlowLayoutPanel thumbs = new() { AutoSize = true, WrapContents = false, Height = 64, Dock = DockStyle.Fill };
    readonly MentionNote note = new() { Multiline = true, BorderStyle = BorderStyle.None, Font = new Font("Segoe UI", 14), PlaceholderText = "What feels wrong?", ScrollBars = ScrollBars.Vertical };
    bool fittingNote;
    readonly ComboBox destinationBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 150 };
    readonly ComboBox targetBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 180 };
    readonly Button contextButton = new() { Text = "Context", AutoSize = true };
    readonly ToolTip tips = new() { ShowAlways = true };
    readonly Button addButton = MakeButton("Add");
    readonly Button recordButton = MakeButton("Record");
    readonly Button recentsButton = MakeButton("Recents");
    readonly Button skillsButton = MakeButton("@");
    readonly Button prefixButton = MakeButton("Prefix");
    readonly Button dictateButton = MakeButton("Dictate");
    readonly Button closeButton = MakeButton("Close");
    readonly Button send = new() { Text = "Review in OpenCode", AutoSize = true, Enabled = false };
    readonly Label status = new() { AutoSize = true, MaximumSize = new Size(600, 0) };
    readonly Label shortcut = new() { Text = "Ctrl+Enter", AutoSize = true, ForeColor = Color.FromArgb(170, 170, 176), Padding = new Padding(0, 8, 0, 0) };
    readonly System.Windows.Forms.Timer autosave = new() { Interval = 600 };
    JsonObject settings;
    JsonObject context;
    JsonObject include;
    List<ComposerDestination> destinations = new();
    string bundleId = Guid.NewGuid().ToString();
    DateTimeOffset created = DateTimeOffset.UtcNow;
    string? manifest;
    string requestId = Guid.NewGuid().ToString();
    string? postedFingerprint;
    JsonObject? prepared;
    bool sending;
    bool submitted;
    string? handoffAction;
    nint returnWindow;
    internal nint ReturnTo { get => returnWindow; set => returnWindow = value; }
    bool filling;
    bool skillsReady;
    readonly MentionSession mentions = new();
    readonly MentionPopup mentionPopup = new();
    Form? skillPopup;
    bool updatingMentions;
    internal static ComposerForm? Open { get; private set; }
    bool addingShot;
    bool recordingClip;
    bool reviewingClip;
    internal bool CanRecord => CanEditAttachments && videos.Count < ReplayMath.MaxClips && !RecordingSession.Busy;
    bool CanEditAttachments => !sending && !submitted && !dictating && !addingShot && !recordingClip && !reviewingClip;
    bool CloseAllowed() => ComposerFiles.AllowClose(sending && !submitted, addingShot, recordingClip || (RecordingSession.Active && Open == this), reviewingClip);
    bool dictating;
    readonly int consolePid;
    readonly nint browserWindow;
    readonly string browserTitle;
    bool collectingConsole;
    bool collectingNetwork;
    int consoleGeneration;
    ContextDialog? contextReview;
    string dictationBase = "";
    string dictationCommitted = "";
    DictationSession? speech;

    internal ComposerForm(string output, IEnumerable<Snapshot> initial, IEnumerable<JsonObject>? clips = null, IReadOnlyList<JsonObject>? events = null, JsonObject? browser = null, int consolePid = 0, nint browserWindow = 0, string? browserTitle = null)
    {
        this.output = output;
        this.consolePid = consolePid;
        this.browserWindow = browserWindow;
        this.browserTitle = browserTitle ?? "";
        settings = ComposerFiles.Settings(output);
        include = settings["include"] is JsonObject saved ? ComposerFiles.Clone(saved) : ComposerFiles.DefaultInclude();
        context = new JsonObject { ["device"] = ComposerFiles.Device(), ["system"] = ComposerFiles.SystemFacts() };
        CaptureContext.Apply(context, settings, events);
        if (browser != null)
        {
            foreach (string key in new[] { "browser", "console", "network" })
                if (browser[key] != null) context[key] = browser[key]!.DeepClone();
        }
        foreach (var shot in initial) shots.Add(ComposerFiles.Media(shot));
        if (clips != null) videos.AddRange(clips.Take(ReplayMath.MaxClips));
        Text = "Capture Studio";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = true;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(680, 250);
        BackColor = Color.FromArgb(32, 32, 34);
        ForeColor = Color.FromArgb(236, 236, 238);
        Font = new Font("Segoe UI", 10);
        var top = new TableLayoutPanel { Dock = DockStyle.Top, Height = 72, ColumnCount = 2, Padding = new Padding(12, 10, 12, 0) };
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        top.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var actions = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Dock = DockStyle.Fill };
        contextButton.Click += (_, _) => EditContext();
        contextButton.AccessibleName = "Review context sent with this capture";
        addButton.Click += async (_, _) => await AddShot();
        addButton.AccessibleName = "Add a screenshot of a region";
        recordButton.Click += async (_, _) => await RecordClip();
        recordButton.AccessibleName = "Add a screen recording";
        recentsButton.Click += (_, _) => ShowRecents();
        recentsButton.AccessibleName = "Show recent captures";
        tips.SetToolTip(recentsButton, "Recent captures");
        skillsButton.AccessibleName = "Choose skills";
        skillsButton.Click += (_, _) => ChooseSkills();
        prefixButton.Click += (_, _) => ShowPrefixes(prefixButton);
        dictateButton.AccessibleName = "Start dictation";
        tips.SetToolTip(dictateButton, "On-device voice-to-text. Review the transcript before sending.");
        dictateButton.Click += (_, _) => ToggleDictation();
        closeButton.Click += (_, _) => Close();
        closeButton.AccessibleName = "Close without sending";
        tips.SetToolTip(closeButton, "Close without sending (Escape)");
        tips.SetToolTip(destinationBox, "Where to send this capture");
        actions.Controls.AddRange(new Control[] { contextButton, addButton, recordButton, recentsButton, skillsButton, prefixButton, dictateButton, closeButton });
        top.Controls.Add(thumbs, 0, 0);
        top.Controls.Add(actions, 1, 0);
        note.Dock = DockStyle.Fill;
        note.BackColor = Color.FromArgb(24, 24, 26);
        note.ForeColor = ForeColor;
        note.AccessibleDescription = "Describe what felt wrong. Type here, or use Dictate. Nothing is sent until you click Send.";
        note.TextChanged += (_, _) => { autosave.Stop(); autosave.Start(); RefreshSend(); RefreshPrefix(); UpdateMentions(); FitNote(); };
        note.MouseUp += (_, _) => UpdateMentions();
        note.KeyUp += (_, _) => UpdateMentions();
        note.Leave += (_, _) =>
        {
            if (!IsHandleCreated || IsDisposed) return;
            BeginInvoke(() =>
            {
                if (IsDisposed || !mentionPopup.Visible || mentionPopup.Bounds.Contains(Cursor.Position)) return;
                mentions.Dismiss();
                mentionPopup.Hide();
            });
        };
        var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(12, 4, 12, 10), WrapContents = true };
        destinationBox.FormattingEnabled = true;
        destinationBox.Format += (_, args) => { if (args.ListItem is ComposerDestination item) args.Value = item.Status == "ready" ? item.Label : item.Label + " (unavailable)"; };
        destinationBox.SelectedIndexChanged += (_, _) => { if (!filling) DestinationChanged(); };
        targetBox.SelectedIndexChanged += (_, _) => { if (!filling) RefreshSend(); };
        send.FlatStyle = FlatStyle.Flat;
        send.BackColor = Color.FromArgb(232, 232, 234);
        send.ForeColor = Color.FromArgb(20, 20, 20);
        send.Click += async (_, _) => await Send();
        bottom.Controls.AddRange(new Control[] { destinationBox, targetBox, send, shortcut, status });
        Controls.Add(note);
        Controls.Add(bottom);
        Controls.Add(top);
        autosave.Tick += (_, _) => { autosave.Stop(); Persist(); };
        foreach (var button in actions.Controls) StyleQuiet((Button)button);
        StyleQuiet(contextButton);
        RedistributeFrames();
        RefreshThumbs();
        RefreshContext();
        RefreshPrefix();
        mentionPopup.Choose = InsertMention;
        Shown += async (_, _) => await Discover();
        Open = this;
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.ExcludeFromCapture(Handle);
    }

    void FitNote()
    {
        if (fittingNote || IsDisposed || !IsHandleCreated || note.Width < 40) return;
        int lines = 1;
        if (note.TextLength > 0)
        {
            lines = note.GetLineFromCharIndex(note.TextLength - 1) + 1;
            if (note.Text.EndsWith('\n') || note.Text.EndsWith("\r\n", StringComparison.Ordinal)) lines++;
        }
        int wanted = Math.Clamp(lines * note.Font.Height + 14, 52, 180);
        int chrome = ClientSize.Height - note.Height;
        if (chrome < 80) return;
        int height = Math.Clamp(chrome + wanted, 214, 440);
        if (Math.Abs(ClientSize.Height - height) < 2) return;
        fittingNote = true;
        try
        {
            int bottomEdge = Bottom;
            ClientSize = new Size(ClientSize.Width, height);
            var screen = Screen.FromControl(this).WorkingArea;
            Location = new Point(Left, Math.Max(screen.Top + 16, Math.Min(bottomEdge - Height, screen.Bottom - Height - 16)));
        }
        finally { fittingNote = false; }
    }

    static Button MakeButton(string text) => new() { Text = text, AutoSize = true, Margin = new Padding(4, 16, 0, 0) };
    static void StyleQuiet(Button button)
    {
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderColor = Color.FromArgb(80, 80, 84);
        button.BackColor = Color.FromArgb(48, 48, 52);
        button.ForeColor = Color.FromArgb(236, 236, 238);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        ActiveSurface.Push(this);
        var screen = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(screen.Left + Math.Max(16, (screen.Width - Width) / 2), screen.Bottom - Height - 48);
        FitNote();
        note.Focus();
        try { Persist(); } catch { /* Recents still lists a draft that was already saved. */ }
        BeginSlowContext();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        if (Open == this) Open = null;
        tips.Dispose();
        ActiveSurface.Pop(this);
        if (FocusReturn.AfterComposer(submitted, handoffAction)) FocusReturn.TryActivate(returnWindow);
        base.OnFormClosed(e);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!CloseAllowed()) { e.Cancel = true; return; }
        if (skillPopup is { IsDisposed: false }) skillPopup.Close();
        dictating = false;
        speech?.Dispose();
        speech = null;
        mentions.Dismiss();
        mentionPopup.Hide();
        autosave.Stop();
        try { Persist(); } catch { /* The draft remains in the form until the next open. */ }
        base.OnFormClosing(e);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (mentions.Open && keyData is Keys.Down or Keys.Up or Keys.Enter or Keys.Tab or Keys.Escape)
        {
            if (keyData == Keys.Down) mentions.Move(1);
            else if (keyData == Keys.Up) mentions.Move(-1);
            else if (keyData is Keys.Enter or Keys.Tab) InsertMention();
            else { mentions.Dismiss(); mentionPopup.Hide(); }
            if (mentions.Open) mentionPopup.Present(this, note, mentions);
            return true;
        }
        if (keyData == Keys.Escape && CloseAllowed()) { Close(); return true; }
        if (keyData == (Keys.Control | Keys.Enter) && send.Enabled) { _ = Send(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    async Task Discover()
    {
        status.Text = "Finding connected OpenCode projects…";
        var found = ComposerFiles.Endpoints(output);
        var live = new List<(ComposerEndpoint Endpoint, JsonArray Destinations)>();
        foreach (var endpoint in found)
        {
            try
            {
                using var client = new BridgeClient(endpoint);
                await client.Get("/skills");
                JsonArray listed;
                try
                {
                    var response = await client.Get("/destinations");
                    listed = response["destinations"] as JsonArray ?? ComposerFiles.LegacyOpenCode(endpoint);
                }
                catch (BridgeException error) when (error.NotFound) { listed = ComposerFiles.LegacyOpenCode(endpoint); }
                live.Add((endpoint, listed));
            }
            catch { /* A closed OpenCode project is omitted until the composer is reopened. */ }
        }
        endpoints.Clear();
        endpoints.AddRange(live.Select(item => item.Endpoint));
        destinations = ComposerFiles.Merge(live.Select((item, index) => (index, item.Destinations)).ToList());
        FillDestinations();
    }

    void FillDestinations()
    {
        filling = true;
        destinationBox.Items.Clear();
        foreach (var destination in destinations) destinationBox.Items.Add(destination);
        destinationBox.DisplayMember = "Label";
        string preferred = settings["defaultDestination"]?.GetValue<string>() ?? "opencode";
        int index = destinations.FindIndex(item => item.Id == preferred && item.Status == "ready");
        if (index < 0) index = destinations.FindIndex(item => item.Status == "ready");
        if (index < 0) index = destinations.FindIndex(item => item.Id == preferred);
        destinationBox.Visible = destinations.Count >= 2;
        if (destinationBox.Items.Count > 0) destinationBox.SelectedIndex = index >= 0 ? index : 0;
        filling = false;
        DestinationChanged();
    }

    void DestinationChanged()
    {
        if (Current is ComposerDestination blocked && blocked.Status != "ready")
        {
            int ready = destinations.FindIndex(item => item.Status == "ready");
            if (ready >= 0 && destinationBox.SelectedIndex != ready)
            {
                filling = true;
                destinationBox.SelectedIndex = ready;
                filling = false;
            }
            else if (ready < 0)
            {
                status.Text = blocked.Label + ": " + blocked.Status;
                RefreshSend();
                return;
            }
        }
        filling = true;
        targetBox.Items.Clear();
        foreach (var target in Current?.Targets ?? new List<ComposerTarget>()) targetBox.Items.Add(target);
        targetBox.DisplayMember = "Label";
        if (targetBox.Items.Count > 0) targetBox.SelectedIndex = 0;
        filling = false;
        bool changed = RememberDestinations();
        if (Current is ComposerDestination selected && selected.Status == "ready")
        {
            settings["defaultDestination"] = selected.Id;
            changed = true;
        }
        if (changed)
        {
            try { ComposerFiles.SaveSettings(output, settings); } catch (Exception error) { status.Text = error.Message; }
        }
        RefreshSend();
        _ = LoadSkills();
    }

    ComposerDestination? Current => destinationBox.SelectedItem as ComposerDestination;

    bool RememberDestinations()
    {
        if (destinations.Count == 0) return false;
        var known = new JsonArray();
        foreach (var destination in destinations.Take(16))
        {
            if (destination.Id.Length == 0 || destination.Label.Length == 0) continue;
            known.Add(new JsonObject { ["id"] = destination.Id, ["label"] = destination.Label.Length <= 60 ? destination.Label : destination.Label[..60] });
        }
        if (known.Count == 0) return false;
        var previous = ComposerFiles.KnownDestinations(settings);
        var next = known.Select(item => new ComposerFiles.KnownDestination(item?["id"]?.GetValue<string>() ?? "", item?["label"]?.GetValue<string>() ?? "")).ToList();
        if (previous.Count == next.Count && previous.Zip(next).All(pair => pair.First == pair.Second)) return false;
        settings["knownDestinations"] = known;
        return true;
    }
    ComposerTarget? CurrentTarget => targetBox.SelectedItem as ComposerTarget;

    int skillGeneration;
    async Task LoadSkills()
    {
        int generation = ++skillGeneration;
        skillsReady = false;
        skills.Clear();
        note.SetSkills(Array.Empty<string>());
        RefreshSend();
        var target = CurrentTarget;
        if (target == null || target.Endpoint < 0 || target.Endpoint >= endpoints.Count)
        {
            status.Text = endpoints.Count == 0 ? "Open a project in OpenCode with the Capture Studio plugin loaded." : "This destination is not available right now.";
            return;
        }
        try
        {
            using var client = new BridgeClient(endpoints[target.Endpoint]);
            var response = await client.Get("/skills");
            foreach (var node in response["skills"] as JsonArray ?? new JsonArray())
            {
                if (node is not JsonObject skill) continue;
                string? id = skill["id"]?.GetValue<string>();
                if (id == null || !System.Text.RegularExpressions.Regex.IsMatch(id, "^[A-Za-z0-9][A-Za-z0-9_-]{0,64}$")) continue;
                skills.Add(new SkillChoice { Id = id, Name = skill["name"]?.GetValue<string>() ?? id });
            }
            if (generation != skillGeneration) return;
            skillsReady = true;
            note.SetSkills(skills.Select(skill => skill.Id).ToList());
            status.Text = Current?.Id == "opencode" ? "" : CurrentTarget?.Hint ?? "";
        }
        catch (Exception error)
        {
            if (generation != skillGeneration) return;
            status.Text = "Could not connect. Open this project in OpenCode and reopen the composer. " + error.Message;
        }
        RefreshSend();
    }

    void RefreshSend()
    {
        var target = CurrentTarget;
        send.Text = target?.ActionLabel ?? "Continue";
        var skillIds = skills.Select(skill => skill.Id).ToList();
        bool hasNote = ComposerFiles.HasNote(note.Text, skillIds);
        bool locked = sending || submitted;
        if (locked && skillPopup is { IsDisposed: false }) skillPopup.Close();
        bool attachments = !CanEditAttachments;
        note.ReadOnly = locked || dictating;
        destinationBox.Visible = destinations.Count >= 2;
        destinationBox.Enabled = !locked && destinationBox.Visible;
        shortcut.Text = (target?.ActionLabel ?? "Continue") + "  ·  Ctrl+Enter";
        targetBox.Enabled = !locked;
        contextButton.Enabled = !locked;
        addButton.Enabled = !attachments && shots.Count < 8;
        recentsButton.Enabled = !attachments;
        skillsButton.Enabled = !locked && skillsReady;
        prefixButton.Enabled = !locked;
        dictateButton.Enabled = !locked || dictating;
        closeButton.Enabled = CloseAllowed();
        tips.SetToolTip(addButton, shots.Count < 8 ? "Add a screenshot of a region" : "Up to 8 screenshots per capture");
        tips.SetToolTip(recordButton, videos.Count >= ReplayMath.MaxClips
            ? "Up to " + ReplayMath.MaxClips.ToString(CultureInfo.InvariantCulture) + " recordings per capture"
            : "Record the display, a window or an area; the clip is added here (Ctrl+Alt+Shift+R)" + (videos.Count == 0 ? "" : " · " + videos.Count.ToString(CultureInfo.InvariantCulture) + " of " + ReplayMath.MaxClips.ToString(CultureInfo.InvariantCulture) + " used"));
        tips.SetToolTip(skillsButton, ComposerFiles.SkillsTip(skillIds.Where(id => ComposerFiles.Mentions(note.Text, id))));
        tips.SetToolTip(targetBox, target?.Detail ?? target?.Label ?? "Project for the new session");
        tips.SetToolTip(send, (target?.ActionLabel ?? "Continue") + " (Ctrl+Enter). " + (target?.Hint ?? ""));
        send.Enabled = !attachments && skillsReady && Current?.Status == "ready" && target != null && (hasNote || shots.Count > 0 || videos.Count > 0) && note.Text.Length <= 16_000;
        recordButton.Text = videos.Count == 0 ? "Record" : videos.Count + "/" + ReplayMath.MaxClips.ToString(CultureInfo.InvariantCulture);
        recordButton.Enabled = CanRecord;
        int available = ComposerFiles.Sources.Count(source => ContextReview.Count(source, shots, context) > 0);
        int included = ComposerFiles.Sources.Count(source => ComposerFiles.Included(include, source) && ContextReview.Count(source, shots, context) > 0);
        string tokens = ContextReview.TokenEstimate(ContextReview.IncludedCharacters(shots, context, include));
        var chips = new List<ContextSummary.SourceChip>();
        foreach (string source in ComposerFiles.Sources)
        {
            int count = ContextReview.Count(source, shots, context);
            if (count > 0) chips.Add(new ContextSummary.SourceChip(ContextReview.Label(source), ComposerFiles.Included(include, source), count));
        }
        bool collecting = collectingConsole || collectingNetwork;
        contextButton.Text = ContextSummary.ButtonText(collecting, included);
        contextButton.AccessibleDescription = ContextSummary.Accessible(collecting, included, available, tokens);
        tips.SetToolTip(contextButton, ContextSummary.Tooltip(chips, tokens));
        if (!skillsReady) { mentions.Dismiss(); mentionPopup.Hide(); }
    }

    void RefreshContext()
    {
        if (shots.Count == 0) context.Remove("app");
        else context["app"] = new JsonObject { ["name"] = shots[0]["app"]?.GetValue<string>() ?? "App", ["title"] = shots[0]["title"]?.GetValue<string>() ?? "" };
        RefreshSend();
    }

    void RefreshThumbs()
    {
        foreach (Control child in thumbs.Controls)
        {
            if (child.Tag is Image image) image.Dispose();
            child.Dispose();
        }
        thumbs.Controls.Clear();
        if (shots.Count == 0 && videos.Count == 0)
            thumbs.Controls.Add(new Label { Text = "No attachments · Add a screenshot or recording ↗", AutoSize = true, ForeColor = Color.FromArgb(170, 170, 176), Margin = new Padding(0, 18, 8, 0) });
        for (int index = 0; index < shots.Count; index++)
        {
            int current = index;
            bool marked = ShotSelection.Highlight(shots.Count, index, selectedShotIndex);
            var panel = new Panel { Size = new Size(84, 60), Margin = new Padding(0, 4, 6, 0) };
            var frame = new Panel
            {
                Size = new Size(76, 56),
                Location = new Point(0, 4),
                BackColor = marked ? SystemColors.Highlight : Color.FromArgb(90, 90, 94),
                Padding = new Padding(marked ? 2 : 1),
            };
            var picture = new PictureBox { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, Cursor = Cursors.Hand, BackColor = Color.FromArgb(20, 20, 22) };
            try
            {
                var image = Image.FromFile(shots[index]["screenshot"]!.GetValue<string>());
                picture.Image = image;
                panel.Tag = image;
            }
            catch { picture.BackColor = Color.DimGray; }
            string app = shots[index]["app"]?.GetValue<string>() ?? "Image";
            picture.AccessibleName = "Annotate screenshot " + (index + 1) + " — " + app + (marked ? ", selected" : "");
            picture.AccessibleDescription = "Right-click to copy, share, or show this screenshot without sending the draft.";
            picture.Click += (_, _) => Annotate(current);
            frame.Controls.Add(picture);
            string? shotPath = shots[index]["screenshot"]?.GetValue<string>();
            var menu = AttachmentMenu(shotPath, true);
            var remove = new Button { Text = "×", Size = new Size(18, 18), Location = new Point(64, 0), FlatStyle = FlatStyle.Flat, Visible = false };
            remove.AccessibleName = "Remove screenshot " + (index + 1);
            remove.Click += (_, _) =>
            {
                if (!CanEditAttachments || current < 0 || current >= shots.Count) return;
                shots.RemoveAt(current);
                selectedShotIndex = ShotSelection.AfterRemove(selectedShotIndex, current, shots.Count);
                RefreshThumbs();
                RefreshContext();
                Touch();
            };
            panel.Controls.Add(frame);
            panel.Controls.Add(remove);
            AssignMenu(panel, menu);
            RevealRemove(panel, remove);
            thumbs.Controls.Add(panel);
        }
        for (int index = 0; index < videos.Count; index++)
        {
            int current = index;
            var panel = new Panel { Size = new Size(84, 60), Margin = new Padding(0, 4, 6, 0) };
            var picture = new PictureBox { Size = new Size(72, 52), SizeMode = PictureBoxSizeMode.Zoom, Location = new Point(0, 6), BackColor = Color.FromArgb(20, 20, 22) };
            string? framePath = (videos[index]["frames"] as JsonArray)?.FirstOrDefault()?["screenshot"]?.GetValue<string>();
            if (framePath != null)
            {
                try
                {
                    var image = Image.FromFile(framePath);
                    picture.Image = image;
                    panel.Tag = image;
                }
                catch { /* The duration label still identifies the clip. */ }
            }
            double duration = 0;
            try { if (videos[index]["durationSeconds"] is JsonNode seconds) duration = seconds.GetValue<double>(); } catch { duration = 0; }
            string clipKind = videos[index]["source"]?.GetValue<string>() == "recording" ? "Screen recording" : "Instant replay";
            picture.AccessibleName = clipKind + " " + (index + 1) + ", " + ContextReview.ClipTime(duration) + ". Click to review or trim.";
            var caption = new Label { Text = ContextReview.ClipTime(duration), AutoSize = false, Size = new Size(72, 16), Location = new Point(0, 40), ForeColor = Color.White, BackColor = Color.FromArgb(160, 0, 0, 0), TextAlign = ContentAlignment.MiddleCenter };
            picture.Cursor = Cursors.Hand;
            caption.Cursor = Cursors.Hand;
            picture.AccessibleDescription = "Right-click to copy, share, or show this recording without sending the draft.";
            picture.Click += (_, _) => Review(current);
            caption.Click += (_, _) => Review(current);
            string? videoPath = videos[index]["video"]?.GetValue<string>();
            var menu = AttachmentMenu(videoPath, false);
            var remove = new Button { Text = "×", Size = new Size(18, 18), Location = new Point(64, 0), FlatStyle = FlatStyle.Flat, Visible = false };
            remove.AccessibleName = "Remove recording " + (index + 1);
            remove.Click += (_, _) => RemoveVideo(current);
            panel.Controls.Add(picture);
            panel.Controls.Add(caption);
            panel.Controls.Add(remove);
            AssignMenu(panel, menu);
            RevealRemove(panel, remove);
            thumbs.Controls.Add(panel);
        }
    }

    ContextMenuStrip AttachmentMenu(string? path, bool image)
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add(AttachmentShare.CopyTitle(image), null, (_, _) => CopyAttachment(path, image));
        menu.Items.Add("Share…", null, (_, _) => ShareAttachment(path, image));
        menu.Items.Add("Show in File Explorer", null, (_, _) => RevealAttachment(path, image));
        menu.Items.Add("Copy Path", null, (_, _) => CopyAttachmentPath(path, image));
        foreach (ToolStripItem item in menu.Items) item.Enabled = AttachmentShare.Accepted(path, output, image);
        return menu;
    }

    static void AssignMenu(Control root, ContextMenuStrip menu)
    {
        void Apply(Control control)
        {
            control.ContextMenuStrip = menu;
            foreach (Control child in control.Controls) Apply(child);
        }
        Apply(root);
        root.Disposed += (_, _) => { if (!menu.IsDisposed) menu.Dispose(); };
    }

    static void RevealRemove(Control tile, Button remove)
    {
        void Sync()
        {
            if (remove.IsDisposed || tile.IsDisposed) return;
            bool inside = tile.RectangleToScreen(tile.ClientRectangle).Contains(Cursor.Position);
            remove.Visible = inside || tile.ContainsFocus;
        }
        void Watch(Control control)
        {
            control.MouseEnter += (_, _) => Sync();
            control.MouseLeave += (_, _) => Sync();
            control.GotFocus += (_, _) => Sync();
            control.LostFocus += (_, _) => Sync();
            foreach (Control child in control.Controls) Watch(child);
        }
        Watch(tile);
    }

    bool AttachmentReady(string? path, bool image)
    {
        if (sending || submitted || dictating) return false;
        if (AttachmentShare.Accepted(path, output, image)) return true;
        status.Text = image ? "This screenshot cannot be copied." : "This recording cannot be copied.";
        return false;
    }

    void CopyAttachment(string? path, bool image)
    {
        if (path == null || !AttachmentReady(path, image)) return;
        try
        {
            if (image)
            {
                using var source = Image.FromFile(path);
                using var copy = new Bitmap(source);
                var data = new DataObject();
                using var bytes = new MemoryStream(File.ReadAllBytes(path));
                data.SetData("PNG", false, bytes);
                data.SetImage(copy);
                Clipboard.SetDataObject(data, true);
                status.Text = "Image copied. It was not sent.";
            }
            else
            {
                var files = new System.Collections.Specialized.StringCollection { path };
                var data = new DataObject();
                data.SetFileDropList(files);
                Clipboard.SetDataObject(data, true);
                status.Text = "Video copied. It was not sent.";
            }
        }
        catch (Exception error) { status.Text = error.Message; }
    }

    void ShareAttachment(string? path, bool image)
    {
        if (path == null || !AttachmentReady(path, image)) return;
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true, Verb = "Share" });
            status.Text = "Share this file without sending the draft.";
        }
        catch { status.Text = "Sharing is not available from this PC. Copy the file or show it in File Explorer."; }
    }

    void RevealAttachment(string? path, bool image)
    {
        if (path == null || !AttachmentReady(path, image)) return;
        string? argument = AttachmentShare.RevealArgument(path);
        if (argument == null) { status.Text = "This attachment path cannot be shown."; return; }
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", argument) { UseShellExecute = true }); }
        catch (Exception error) { status.Text = error.Message; }
    }

    void CopyAttachmentPath(string? path, bool image)
    {
        if (path == null || !AttachmentReady(path, image)) return;
        try
        {
            Clipboard.SetText(path);
            status.Text = "Path copied. It was not sent.";
        }
        catch (Exception error) { status.Text = error.Message; }
    }

    void Annotate(int index)
    {
        if (sending || submitted || index < 0 || index >= shots.Count) return;
        selectedShotIndex = index;
        Hide();
        try
        {
            using var editor = new Preview(ComposerFiles.Shot(shots[index]), output, true);
            if (editor.ShowDialog() == DialogResult.OK && editor.Result is Snapshot edited) shots[index] = ComposerFiles.Media(edited);
        }
        catch (Exception error) { status.Text = error.Message; }
        finally { if (!IsDisposed) { Show(); RefreshThumbs(); Touch(); } }
    }

    async Task AddShot()
    {
        if (!CanEditAttachments || RecordingSession.Busy || shots.Count >= 8) { if (shots.Count >= 8) status.Text = "A draft can contain up to 8 screenshots."; return; }
        addingShot = true;
        RefreshSend();
        Hide();
        try
        {
            using var overlay = new RegionOverlay();
            if (overlay.ShowDialog() != DialogResult.OK || overlay.Choice is not CaptureChoice choice) return;
            shots.Add(ComposerFiles.Media(await CaptureSelector.Take(choice, output)));
            selectedShotIndex = shots.Count - 1;
            status.Text = "Screenshot added · Click a thumbnail to annotate.";
            RefreshThumbs();
            RefreshContext();
            Touch();
        }
        catch (Exception error) { status.Text = error.Message; }
        finally
        {
            addingShot = false;
            if (!IsDisposed) { Show(); RefreshSend(); }
        }
    }

    void EditContext()
    {
        mentions.Dismiss();
        mentionPopup.Hide();
        using var dialog = new ContextDialog(shots, videos, context, include, collectingConsole, collectingNetwork);
        contextReview = dialog;
        dialog.ShowDialog(this);
        contextReview = null;
        settings["include"] = ComposerFiles.Clone(include);
        try { ComposerFiles.SaveSettings(output, settings); } catch (Exception error) { status.Text = error.Message; }
        RefreshSend();
        Touch();
    }

    void ShowRecents()
    {
        if (!CanEditAttachments) return;
        try { Persist(); } catch (Exception error) { status.Text = error.Message; return; }
        var recent = ComposerFiles.Recents(output, ComposerFiles.ComposerRecentLimit);
        using var headingFont = new Font(Font, FontStyle.Bold);
        using var dialog = new Form
        {
            Text = "Recents",
            ClientSize = new Size(300, 460),
            StartPosition = FormStartPosition.CenterParent,
            MinimizeBox = false,
            MaximizeBox = false,
            BackColor = BackColor,
            ForeColor = ForeColor,
            Font = Font,
        };
        dialog.Controls.Add(new Label { Text = "Recents", Font = headingFont, AutoSize = true, Location = new Point(12, 16), ForeColor = ForeColor });
        dialog.Controls.Add(new Label { Text = "Captures and edits are saved as you go", AutoSize = true, Location = new Point(12, 40), ForeColor = Color.FromArgb(170, 170, 176) });
        var scroll = new Panel { Location = new Point(12, 68), Size = new Size(276, 380), AutoScroll = true };
        string? chosen = null;
        if (recent.Count == 0)
            scroll.Controls.Add(new Label { Text = "No captures yet. Press Ctrl+Alt+Shift+A to capture.", AutoSize = true, MaximumSize = new Size(260, 0), ForeColor = Color.FromArgb(170, 170, 176) });
        int top = 0;
        using var rowTips = new ToolTip { ShowAlways = true };
        foreach (var item in recent)
        {
            bool open = ComposerFiles.SameCapture(item.Path, manifest);
            string detail = ComposerFiles.RecentDetail(item.Screenshots, item.Videos, ComposerFiles.RelativeTime(item.Updated, DateTimeOffset.Now), open);
            var row = RecentRow(item, detail, open, headingFont);
            row.Location = new Point(0, top);
            row.Width = 260;
            string tip = open ? "This capture is open" : "Reopen this capture in the composer";
            void Choose(object? sender, EventArgs args)
            {
                if (open) return;
                chosen = item.Path;
                dialog.DialogResult = DialogResult.OK;
            }
            void Watch(Control control)
            {
                rowTips.SetToolTip(control, tip);
                control.MouseEnter += (_, _) => PaintRecent(row, open, true);
                control.MouseLeave += (_, _) => PaintRecent(row, open, row.RectangleToScreen(row.ClientRectangle).Contains(Cursor.Position));
                if (!open)
                {
                    control.Click += Choose;
                    control.KeyDown += (_, key) =>
                    {
                        if (key.KeyCode == Keys.Enter) Choose(control, EventArgs.Empty);
                    };
                }
                foreach (Control child in control.Controls) Watch(child);
            }
            Watch(row);
            scroll.Controls.Add(row);
            top += row.Height + 2;
        }
        dialog.Controls.Add(scroll);
        if (dialog.ShowDialog(this) != DialogResult.OK || chosen == null) return;
        LoadSaved(chosen);
    }

    Panel RecentRow(RecentCapture item, string detail, bool open, Font headingFont)
    {
        var idle = BackColor;
        var row = new Panel { Size = new Size(260, 52), BackColor = open ? Color.FromArgb(27, 46, 63) : idle, Cursor = open ? Cursors.Default : Cursors.Hand, AccessibleRole = AccessibleRole.PushButton, AccessibleName = item.Title + ", " + detail, TabStop = !open };
        var preview = new PictureBox { Location = new Point(6, 6), Size = new Size(64, 40), SizeMode = PictureBoxSizeMode.Zoom, BackColor = Color.FromArgb(48, 48, 52) };
        string? thumb = ComposerFiles.RecentThumbnail(item.Thumbnail, output);
        if (thumb != null)
        {
            try
            {
                using var source = Image.FromFile(thumb);
                int edge = Math.Max(source.Width, source.Height);
                int width = edge <= 160 ? source.Width : Math.Max(1, source.Width * 160 / edge);
                int height = edge <= 160 ? source.Height : Math.Max(1, source.Height * 160 / edge);
                preview.Image = source.GetThumbnailImage(width, height, () => false, IntPtr.Zero);
            }
            catch { preview.Image = null; }
        }
        if (preview.Image == null)
            preview.Controls.Add(new Label { Text = item.Videos > 0 ? "Clip" : "Image", AutoSize = false, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, BackColor = Color.FromArgb(48, 48, 52), ForeColor = Color.FromArgb(170, 170, 176) });
        var name = new Label { Text = item.Title, AutoEllipsis = true, Font = headingFont, Location = new Point(80, 8), Size = new Size(172, 18), BackColor = Color.Transparent, ForeColor = ForeColor };
        var meta = new Label { Text = detail, AutoEllipsis = true, Location = new Point(80, 28), Size = new Size(172, 16), BackColor = Color.Transparent, ForeColor = Color.FromArgb(170, 170, 176) };
        row.Controls.Add(preview);
        row.Controls.Add(name);
        row.Controls.Add(meta);
        return row;
    }

    static void PaintRecent(Panel row, bool open, bool hovering)
    {
        if (open) return;
        row.BackColor = hovering ? Color.FromArgb(48, 48, 52) : Color.FromArgb(32, 32, 34);
    }

    internal void LoadSaved(string path)
    {
        if (!CanEditAttachments || ComposerFiles.SameCapture(path, manifest)) return;
        consoleGeneration++;
        collectingConsole = false;
        collectingNetwork = false;
        try
        {
            var bundle = ComposerFiles.LoadBundle(path, output);
            shots.Clear();
            shots.AddRange(bundle.Shots);
            selectedShotIndex = 0;
            videos.Clear();
            videos.AddRange(bundle.Videos);
            RedistributeFrames();
            note.Text = bundle.Note;
            context = bundle.Context.Count == 0 ? context : bundle.Context;
            include = ComposerFiles.Clone(bundle.Include);
            bundleId = bundle.Id ?? bundleId;
            created = bundle.Created ?? created;
            manifest = bundle.Path;
            if (bundle.Missing > 0) status.Text = bundle.Missing + (bundle.Missing == 1 ? " file was" : " files were") + " deleted since this capture was saved.";
            RefreshThumbs();
            RefreshContext();
        }
        catch (Exception error) { status.Text = error.Message; }
    }

    void ChooseSkills()
    {
        if (!skillsReady || sending || submitted) return;
        if (skillPopup is { IsDisposed: false }) { skillPopup.Close(); return; }
        var popup = new Form
        {
            Text = "Skills",
            FormBorderStyle = FormBorderStyle.FixedToolWindow,
            ClientSize = new Size(300, 310),
            StartPosition = FormStartPosition.Manual,
            MinimizeBox = false,
            MaximizeBox = false,
            ShowInTaskbar = false,
            BackColor = BackColor,
            ForeColor = ForeColor,
            Font = Font,
            KeyPreview = true,
        };
        skillPopup = popup;
        popup.FormClosed += (_, _) => { if (skillPopup == popup) skillPopup = null; };
        popup.KeyDown += (_, key) =>
        {
            if (key.KeyCode != Keys.Escape) return;
            key.Handled = true;
            popup.Close();
        };
        var search = new TextBox { Dock = DockStyle.Top, PlaceholderText = "Find a skill…", AccessibleName = "Find a skill" };
        var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
        var skillTips = new ToolTip { ShowAlways = true };
        popup.Disposed += (_, _) => skillTips.Dispose();
        bool fillingSkills = false;
        void Fill()
        {
            fillingSkills = true;
            while (scroll.Controls.Count > 0)
            {
                var child = scroll.Controls[0];
                scroll.Controls.Remove(child);
                child.Dispose();
            }
            var matches = SkillChoice.ForPicker(skills, search.Text);
            if (matches.Count == 0)
            {
                scroll.Controls.Add(new Label { Text = "No matching skills", AutoSize = true, ForeColor = Color.FromArgb(170, 170, 176), Location = new Point(8, 8) });
                fillingSkills = false;
                return;
            }
            int top = 4;
            foreach (var skill in matches)
            {
                string id = skill.Id;
                var box = new CheckBox
                {
                    Text = "@" + id,
                    Checked = ComposerFiles.Mentions(note.Text, id),
                    AutoSize = true,
                    Location = new Point(8, top),
                    ForeColor = ForeColor,
                };
                skillTips.SetToolTip(box, skill.Name);
                box.CheckedChanged += (_, _) =>
                {
                    if (fillingSkills) return;
                    if (box.Checked) InsertSkillMention(id);
                    else note.Text = ComposerFiles.RemoveMention(note.Text, id);
                };
                scroll.Controls.Add(box);
                top += 28;
            }
            fillingSkills = false;
        }
        search.TextChanged += (_, _) => Fill();
        popup.Controls.Add(scroll);
        popup.Controls.Add(search);
        Fill();
        popup.Shown += (_, _) => search.Focus();
        var origin = skillsButton.PointToScreen(new Point(0, skillsButton.Height + 4));
        popup.Location = origin;
        popup.Show(this);
        var area = Screen.FromControl(popup).WorkingArea;
        int x = Math.Max(area.Left, Math.Min(popup.Left, area.Right - popup.Width));
        int y = popup.Bottom > area.Bottom ? skillsButton.PointToScreen(Point.Empty).Y - popup.Height - 4 : popup.Top;
        popup.Location = new Point(x, Math.Max(area.Top, y));
    }

    void InsertSkillMention(string id)
    {
        if (!skills.Any(skill => skill.Id == id) || ComposerFiles.Mentions(note.Text, id)) return;
        int start = note.SelectionStart;
        int length = note.SelectionLength;
        if (MentionSession.QueryAt(note.Text, start, length) is MentionQuery query)
        {
            start = query.Start;
            length = query.Length;
        }
        note.Text = MentionSession.Apply(note.Text, start, length, id);
        note.SelectionStart = Math.Min(note.Text.Length, start + id.Length + 2);
        note.Focus();
    }

    void ShowPrefixes(Control anchor)
    {
        var menu = new ContextMenuStrip();
        var prefixes = ComposerFiles.Prefixes(settings);
        string? active = ComposerFiles.ActivePrefix(prefixes, note.Text);
        if (prefixes.Count == 0)
        {
            var empty = menu.Items.Add("No prefixes yet. Type one, then save it.");
            empty.Enabled = false;
        }
        foreach (string prefix in prefixes)
        {
            string saved = prefix;
            var item = new ToolStripMenuItem(MenuTitle(saved)) { Checked = saved == active, ToolTipText = saved };
            item.Click += (_, _) => ApplyPrefix(saved);
            menu.Items.Add(item);
        }
        menu.Items.Add(new ToolStripSeparator());
        string candidate = PrefixCandidate();
        var save = new ToolStripMenuItem(note.SelectionLength > 0 ? "Save Selection as Prefix" : "Save Note as Prefix");
        save.Enabled = candidate.Length > 0 && candidate.Length <= 500 && !prefixes.Contains(candidate);
        save.Click += (_, _) => RememberPrefix(candidate);
        menu.Items.Add(save);
        if (prefixes.Count > 0)
        {
            var remove = new ToolStripMenuItem("Remove");
            for (int index = 0; index < prefixes.Count; index++)
            {
                int chosen = index;
                remove.DropDownItems.Add(MenuTitle(prefixes[index]), null, (_, _) =>
                {
                    var current = ComposerFiles.Prefixes(settings);
                    if (chosen >= current.Count) return;
                    current.RemoveAt(chosen);
                    StorePrefixes(current);
                });
            }
            menu.Items.Add(remove);
        }
        menu.Show(anchor, new Point(0, anchor.Height));
    }

    static string MenuTitle(string prefix)
    {
        string line = prefix.Replace('\n', ' ').Replace('\r', ' ');
        return line.Length > 48 ? line[..47] + "…" : line;
    }

    string PrefixCandidate()
    {
        string text = note.SelectionLength > 0 ? note.SelectedText : note.Text;
        return text.Trim();
    }

    void ApplyPrefix(string prefix)
    {
        note.Text = ComposerFiles.ApplyPrefix(ComposerFiles.Prefixes(settings), note.Text, prefix);
        note.SelectionStart = note.Text.Length;
        RefreshPrefix();
    }

    void RefreshPrefix()
    {
        string? active = ComposerFiles.ActivePrefix(ComposerFiles.Prefixes(settings), note.Text);
        prefixButton.Text = active == null ? "Prefix" : "Prefix on";
        prefixButton.AccessibleName = active == null ? "Choose a saved prefix" : "Prefix: " + MenuTitle(active);
        tips.SetToolTip(prefixButton, active == null ? "Prefixes" : "Prefix: " + (active.Length <= 80 ? active : active[..80]) + " — click to switch");
    }

    void RememberPrefix(string prefix)
    {
        if (prefix.Length == 0 || prefix.Length > 500) return;
        var prefixes = ComposerFiles.Prefixes(settings);
        if (prefixes.Contains(prefix)) return;
        prefixes.Insert(0, prefix);
        StorePrefixes(prefixes.Take(12).ToList());
        status.Text = "Saved prefix · choose it from the prefix button next time.";
    }

    void StorePrefixes(List<string> prefixes)
    {
        settings["prefixes"] = new JsonArray(prefixes.Select(item => (JsonNode)JsonValue.Create(item)!).ToArray());
        try { ComposerFiles.SaveSettings(output, settings); } catch (Exception error) { status.Text = error.Message; }
        RefreshPrefix();
    }

    void Touch() { autosave.Stop(); autosave.Start(); RefreshSend(); }

    void Persist()
    {
        if (!ComposerFiles.HasNote(note.Text, skills.Select(skill => skill.Id).ToList()) && shots.Count == 0 && videos.Count == 0) return;
        manifest = ComposerFiles.WriteBundle(output, bundleId, created, note.Text, shots, context, include, videos);
    }

    string Fingerprint() => string.Join("\u001f", new[] { Current?.Id ?? "", CurrentTarget?.Id ?? "", note.Text, string.Join("|", shots.Select(shot => shot["screenshot"]?.GetValue<string>() ?? "")), string.Join("|", videos.Select(video => video["video"]?.GetValue<string>() ?? "")) });

    async Task Send()
    {
        if (!send.Enabled || sending || submitted) return;
        if (note.Text.Length > 16_000) { status.Text = "Keep the description under 16000 characters."; return; }
        var target = CurrentTarget;
        var destination = Current;
        if (target == null || destination == null) return;
        string fingerprint = Fingerprint();
        if (postedFingerprint != null && postedFingerprint != fingerprint)
        {
            status.Text = "This draft changed after the first attempt. Close the composer and open it again to send the edited note. Nothing new was run.";
            return;
        }
        sending = true;
        send.Enabled = false;
        status.Text = "Preparing " + target.ActionLabel.ToLowerInvariant() + "…";
        try
        {
            autosave.Stop();
            Persist();
            if (manifest == null) throw new Exception("Could not save the capture bundle.");
            if (prepared == null)
            {
                postedFingerprint = fingerprint;
                var body = new JsonObject
                {
                    ["requestID"] = requestId,
                    ["text"] = note.Text,
                    ["skills"] = new JsonArray(skills.Where(skill => ComposerFiles.Mentions(note.Text, skill.Id)).Select(skill => (JsonNode)JsonValue.Create(skill.Id)!).ToArray()),
                    ["destination"] = destination.Id,
                    ["target"] = target.Id,
                    ["manifest"] = manifest,
                };
                using var client = new BridgeClient(endpoints[target.Endpoint]);
                prepared = await client.Post("/prepare", body);
            }
            await Complete(prepared);
        }
        catch (DraftUnconfirmedException error)
        {
            submitted = true;
            Program.Save(output, "status.json", new { phase = "composer_draft_unconfirmed" });
            MessageBox.Show(this, error.Message, "Capture Studio");
            Close();
        }
        catch (Exception error)
        {
            status.Text = error.Message + " Nothing was run. Your draft is still here.";
            sending = false;
            RefreshSend();
        }
    }

    async Task Complete(JsonObject result)
    {
        string action = result["action"]?.GetValue<string>() ?? (result["sessionID"] == null ? "" : "opencode-draft");
        switch (action)
        {
            case "opencode-draft":
                string? id = result["sessionID"]?.GetValue<string>();
                string? title = result["title"]?.GetValue<string>();
                string? draft = result["draftText"]?.GetValue<string>();
                if (id == null || title == null || draft == null) throw new Exception("OpenCode returned an invalid draft handoff.");
                status.Text = "Opening the new session in OpenCode…";
                Hide();
                await SessionDraft.Open(id, title, AttachmentImages(), draft, output);
                Program.Save(output, "status.json", new { phase = "composer_draft_inserted", sessionID = id });
                break;
            case "copy-text":
                string? copied = result["text"]?.GetValue<string>();
                if (copied == null) throw new Exception("The clipboard destination returned no text.");
                Clipboard.SetText(copied);
                Program.Save(output, "status.json", new { phase = "composer_copied" });
                break;
            case "reveal-folder":
                string? folder = result["path"]?.GetValue<string>();
                if (folder == null || !System.IO.Path.IsPathRooted(folder) || folder.Contains('"')) throw new Exception("The folder destination returned an invalid path.");
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", "/select,\"" + folder + "\"") { UseShellExecute = true });
                Program.Save(output, "status.json", new { phase = "composer_saved" });
                break;
            default:
                throw new Exception("This destination returned an unsupported handoff.");
        }
        handoffAction = action;
        submitted = true;
        sending = false;
        Close();
    }

    List<string> AttachmentImages()
    {
        var images = new List<string>();
        foreach (var shot in shots)
        {
            string? path = shot["screenshot"]?.GetValue<string>();
            if (path != null) images.Add(path);
        }
        foreach (var video in videos)
        {
            if (video["frames"] is not JsonArray frames) continue;
            foreach (var node in frames)
            {
                string? path = node?["screenshot"]?.GetValue<string>();
                if (path != null) images.Add(path);
            }
        }
        return images;
    }

    internal void ShowRecordingLimit() => status.Text = videos.Count >= ReplayMath.MaxClips ? "A draft can contain up to 3 recordings." : "Finish the current draft before recording.";

    internal async Task RecordClip()
    {
        if (!CanRecord) { ShowRecordingLimit(); return; }
        mentions.Dismiss();
        mentionPopup.Hide();
        recordingClip = true;
        RefreshSend();
        var parked = Location;
        Location = new Point(-32000, -32000);
        try
        {
            var clip = await RecordingSession.Capture(output, videos.Count);
            var recorded = ClickHistory.Shared.TakePublished();
            if (clip != null && !IsDisposed)
            {
                Attach(clip);
                if (recorded.Count > 0)
                {
                    var list = new JsonArray();
                    foreach (var entry in recorded) list.Add(entry);
                    context["events"] = new JsonObject { ["entries"] = list };
                    RefreshSend();
                }
            }
        }
        catch (Exception error)
        {
            ClickHistory.Shared.TakePublished();
            if (!IsDisposed) status.Text = error.Message;
        }
        finally
        {
            recordingClip = false;
            if (!IsDisposed) { Location = parked; Activate(); RefreshSend(); }
        }
    }

    void Review(int index)
    {
        if (!CanEditAttachments || index < 0 || index >= videos.Count) return;
        mentions.Dismiss();
        mentionPopup.Hide();
        reviewingClip = true;
        RefreshSend();
        try
        {
            using var review = new ClipReviewForm(output, videos[index], context, ReplayMath.FramesPerClip(videos.Count));
            review.ShowDialog(this);
            if (review.Outcome == ClipReviewOutcome.Remove)
            {
                videos.RemoveAt(index);
                status.Text = "Clip removed. The MP4 stays in the captures folder.";
                RedistributeFrames();
                RefreshThumbs();
                RefreshContext();
                Touch();
            }
            else if (review.Outcome == ClipReviewOutcome.Replace && review.Replacement != null)
            {
                double seconds = review.Replacement["durationSeconds"]?.GetValue<double>() ?? 0;
                videos[index] = review.Replacement;
                status.Text = "Clip trimmed to " + ((int)Math.Round(seconds)).ToString(CultureInfo.InvariantCulture) + " s.";
                RefreshThumbs();
                RefreshContext();
                Touch();
            }
        }
        finally
        {
            reviewingClip = false;
            if (!IsDisposed) RefreshSend();
        }
    }

    void RemoveVideo(int index)
    {
        if (!CanEditAttachments || index < 0 || index >= videos.Count) return;
        videos.RemoveAt(index);
        RedistributeFrames();
        RefreshThumbs();
        RefreshContext();
        Touch();
    }

    void RedistributeFrames()
    {
        if (videos.Count == 0) return;
        int share = ReplayMath.FramesPerClip(videos.Count);
        for (int index = 0; index < videos.Count; index++)
        {
            try { videos[index] = ClipTrimmer.Reframe(videos[index], share); }
            catch { /* Keep the frames already saved with this clip. */ }
        }
    }

    void Attach(JsonObject clip)
    {
        if (videos.Count >= ReplayMath.MaxClips) return;
        videos.Add(clip);
        status.Text = "Recording added. Click it to review or trim.";
        RedistributeFrames();
        RefreshThumbs();
        RefreshContext();
        Touch();
    }

    void ToggleDictation()
    {
        if (dictating)
        {
            speech?.Stop();
            _ = Task.Run(async () =>
            {
                await Task.Delay(2000);
                Later(() => { if (dictating) FinishDictation(null); });
            });
            return;
        }
        if (sending || submitted) return;
        dictationBase = DictationText.Base(note.Text);
        dictationCommitted = "";
        dictating = true;
        note.ReadOnly = true;
        dictateButton.Text = "Stop";
        dictateButton.AccessibleName = "Stop dictation";
        mentions.Dismiss();
        mentionPopup.Hide();
        RefreshSend();
        status.Text = "Listening on this PC · Click Stop to review.";
        try { Program.Save(output, "status.json", new { phase = "dictation", dictationStage = "listening" }); } catch { /* The button state is enough if status cannot be written. */ }
        try
        {
            speech?.Dispose();
            speech = new DictationSession();
            speech.Hypothesis += text => Later(() => ShowHypothesis(text));
            speech.Phrase += text => Later(() => CommitPhrase(text));
            speech.Stopped += message => Later(() => FinishDictation(message));
            speech.Start();
        }
        catch (Exception error)
        {
            FinishDictation(string.IsNullOrWhiteSpace(error.Message)
                ? "On-device speech recognition is unavailable. Install a Windows speech language in Settings → Time & language → Speech. No audio was sent."
                : error.Message);
        }
    }

    void BeginSlowContext()
    {
        if (browserWindow != 0)
        {
            bool needPage = context["browser"] == null;
            collectingConsole = context["console"] == null;
            collectingNetwork = context["network"] == null;
            if (!needPage && !collectingConsole && !collectingNetwork) return;
            if (!collectingConsole && !collectingNetwork) collectingConsole = true;
            int generation = ++consoleGeneration;
            RefreshSend();
            _ = ReadBrowser(generation);
            return;
        }
        BeginConsole();
    }

    void BeginConsole()
    {
        if (consolePid <= 0 || context["console"] != null) return;
        collectingConsole = true;
        int generation = ++consoleGeneration;
        RefreshSend();
        _ = ReadConsole(generation);
    }

    async Task ReadBrowser(int generation)
    {
        JsonObject? page;
        try { page = await AppConsole.CollectBrowser(browserWindow, browserTitle); }
        catch { page = null; }
        Later(() => FinishSlow(generation, () => AppConsole.MergeBrowser(context, page)));
    }

    async Task ReadConsole(int generation)
    {
        List<JsonObject> entries;
        try { entries = await AppConsole.Collect(consolePid); }
        catch { entries = new List<JsonObject>(); }
        Later(() => FinishSlow(generation, () => AppConsole.Merge(context, entries)));
    }

    void FinishSlow(int generation, Func<bool> merge)
    {
        if (generation != consoleGeneration) return;
        collectingConsole = false;
        collectingNetwork = false;
        if (!sending && prepared == null && merge()) Touch();
        else RefreshSend();
        if (contextReview == null) return;
        contextReview.Collecting = false;
        contextReview.CollectingNetwork = false;
        contextReview.Reload();
    }

    void Later(Action action)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(action); } catch (InvalidOperationException) { /* The composer closed before the recognizer reported. */ }
    }

    void ShowHypothesis(string text)
    {
        if (!dictating || IsDisposed) return;
        note.Text = DictationText.Apply(dictationBase, dictationCommitted, text);
        note.SelectionStart = note.Text.Length;
    }

    void CommitPhrase(string text)
    {
        if (!dictating || IsDisposed) return;
        dictationCommitted = DictationText.Commit(dictationCommitted, text);
        string next = DictationText.Apply(dictationBase, dictationCommitted, "");
        if (next.Length > 16_000)
        {
            note.Text = next[..16_000];
            FinishDictation("Keep the description under 16000 characters.");
            return;
        }
        note.Text = next;
        note.SelectionStart = note.Text.Length;
    }

    void FinishDictation(string? error)
    {
        if (!dictating || IsDisposed) return;
        dictating = false;
        note.ReadOnly = false;
        dictateButton.Text = "Dictate";
        dictateButton.AccessibleName = "Start dictation";
        var current = speech;
        speech = null;
        current?.Dispose();
        RefreshSend();
        status.Text = error ?? "Transcript ready to review.";
        try { Program.Save(output, "status.json", new { phase = "composing", dictationStage = error == null ? "stopped" : "failed" }); } catch { /* The transcript stays in the note. */ }
    }

    void UpdateMentions()
    {
        if (updatingMentions || dictating) return;
        if (sending || !skillsReady) { mentions.Dismiss(); mentionPopup.Hide(); return; }
        mentions.Update(note.Text, note.SelectionStart, note.SelectionLength, skills);
        if (!mentions.Open) mentionPopup.Hide();
        else mentionPopup.Present(this, note, mentions);
    }

    void InsertMention()
    {
        if (!mentions.Open) return;
        var skill = mentions.Candidates[mentions.Selected];
        int start = mentions.Query?.Start ?? note.SelectionStart;
        int length = mentions.Query?.Length ?? note.SelectionLength;
        updatingMentions = true;
        note.Text = MentionSession.Apply(note.Text, start, length, skill.Id);
        note.SelectionStart = Math.Min(note.Text.Length, start + skill.Id.Length + 2);
        updatingMentions = false;
        mentions.Dismiss();
        mentionPopup.Hide();
        note.Focus();
    }
}

// Stays above the note without taking focus. Up and Down move the selection from the composer.
internal sealed class MentionPopup : Form
{
    readonly ListBox list = new() { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, IntegralHeight = false };
    int visibleStart;
    MentionSession? session;
    internal Action? Choose;

    internal MentionPopup()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        Size = new Size(280, 36);
        BackColor = Color.FromArgb(28, 28, 30);
        list.BackColor = BackColor;
        list.ForeColor = Color.FromArgb(236, 236, 238);
        Controls.Add(list);
        list.Click += (_, _) =>
        {
            if (session == null || list.SelectedIndex < 0) return;
            session.Selected = visibleStart + list.SelectedIndex;
            Choose?.Invoke();
        };
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Native.ExcludeFromCapture(Handle);
    }

    protected override bool ShowWithoutActivation => true;

    internal void Present(Form owner, TextBox note, MentionSession current)
    {
        session = current;
        visibleStart = Math.Max(0, Math.Min(current.Selected - 7, current.Candidates.Count - 8));
        list.Items.Clear();
        foreach (var skill in current.Candidates.Skip(visibleStart).Take(8))
        {
            string row = "@" + skill.Id;
            if (skill.Name.Length > 0 && !string.Equals(skill.Name, skill.Id, StringComparison.OrdinalIgnoreCase)) row += "   " + skill.Name;
            list.Items.Add(row);
        }
        int local = current.Selected - visibleStart;
        if (local >= 0 && local < list.Items.Count) list.SelectedIndex = local;
        Height = Math.Max(1, list.Items.Count) * 22 + 8;
        var caret = note.GetPositionFromCharIndex(Math.Max(0, Math.Min(note.SelectionStart, note.Text.Length)));
        var screenCaret = note.PointToScreen(caret);
        var area = Screen.FromControl(owner).WorkingArea;
        int y = screenCaret.Y - Height - 6;
        if (y < area.Top + 8) y = screenCaret.Y + note.Font.Height + 6;
        int x = Math.Min(Math.Max(area.Left + 8, screenCaret.X - 8), Math.Max(area.Left + 8, area.Right - Width - 8));
        Location = new Point(x, y);
        if (!Visible) base.Show(owner);
    }
}

// Desktop speech on this PC. Audio is not saved and there is no cloud recognizer.
internal sealed class DictationSession : IDisposable
{
    SpeechRecognitionEngine? engine;
    bool completed;
    internal event Action<string>? Hypothesis;
    internal event Action<string>? Phrase;
    internal event Action<string?>? Stopped;

    internal void Start()
    {
        var installed = SpeechRecognitionEngine.InstalledRecognizers();
        if (installed.Count == 0) throw new InvalidOperationException("On-device speech recognition is unavailable. Install a Windows speech language in Settings → Time & language → Speech. No audio was sent.");
        var created = new SpeechRecognitionEngine(installed[0]);
        try
        {
            created.SetInputToDefaultAudioDevice();
            created.LoadGrammar(new DictationGrammar());
            created.SpeechHypothesized += (_, args) => Hypothesis?.Invoke(args.Result?.Text ?? "");
            created.SpeechRecognized += (_, args) => Phrase?.Invoke(args.Result?.Text ?? "");
            created.RecognizeCompleted += (_, args) =>
            {
                if (completed) return;
                completed = true;
                Stopped?.Invoke(args.Error?.Message);
            };
            created.RecognizeAsync(RecognizeMode.Multiple);
            engine = created;
        }
        catch
        {
            created.Dispose();
            throw;
        }
    }

    internal void Stop()
    {
        try { engine?.RecognizeAsyncStop(); }
        catch (Exception error)
        {
            if (completed) return;
            completed = true;
            Stopped?.Invoke(error.Message);
        }
    }

    public void Dispose()
    {
        completed = true;
        var current = engine;
        engine = null;
        if (current == null) return;
        try { current.RecognizeAsyncCancel(); } catch { /* Already stopped. */ }
        current.Dispose();
    }
}
