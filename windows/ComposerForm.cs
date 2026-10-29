using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
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

// Floating review surface: screenshots, a note, destination, context, and a handoff
// that stops in an unsent draft, on the clipboard, or in a folder.
internal sealed class ComposerForm : Form
{
    readonly string output;
    readonly List<JsonObject> shots = new();
    readonly List<JsonObject> videos = new();
    readonly List<ComposerEndpoint> endpoints = new();
    readonly List<SkillChoice> skills = new();
    readonly FlowLayoutPanel thumbs = new() { AutoSize = true, WrapContents = false, Height = 64, Dock = DockStyle.Fill };
    readonly TextBox note = new() { Multiline = true, BorderStyle = BorderStyle.None, Font = new Font("Segoe UI", 14), PlaceholderText = "What feels wrong?", ScrollBars = ScrollBars.Vertical };
    readonly ComboBox destinationBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 150 };
    readonly ComboBox targetBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 180 };
    readonly Button contextButton = new() { Text = "Context", AutoSize = true };
    readonly Button recordButton = MakeButton("Record");
    readonly Button prefixButton = MakeButton("Prefix");
    readonly Button send = new() { Text = "Review in OpenCode", AutoSize = true, Enabled = false };
    readonly Label status = new() { AutoSize = true, MaximumSize = new Size(600, 0) };
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
    bool filling;
    bool skillsReady;
    readonly MentionSession mentions = new();
    readonly MentionPopup mentionPopup = new();
    bool updatingMentions;
    internal static ComposerForm? Open { get; private set; }
    internal bool CanRecord => !sending && !submitted && videos.Count < ReplayMath.MaxClips && !RecordingSession.Busy;

    internal ComposerForm(string output, IEnumerable<Snapshot> initial, IEnumerable<JsonObject>? clips = null, IReadOnlyList<JsonObject>? events = null)
    {
        this.output = output;
        settings = ComposerFiles.Settings(output);
        include = settings["include"] is JsonObject saved ? ComposerFiles.Clone(saved) : ComposerFiles.DefaultInclude();
        context = new JsonObject { ["device"] = ComposerFiles.Device(), ["system"] = ComposerFiles.SystemFacts() };
        CaptureContext.Apply(context, settings, events);
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
        var add = MakeButton("Add");
        add.Click += async (_, _) => await AddShot();
        add.AccessibleName = "Add a screenshot";
        recordButton.Click += async (_, _) => await RecordClip();
        recordButton.AccessibleName = "Record the screen";
        var recents = MakeButton("Recents");
        recents.Click += (_, _) => ShowRecents();
        var skillsButton = MakeButton("@");
        skillsButton.AccessibleName = "Choose skills";
        skillsButton.Click += (_, _) => ChooseSkills();
        prefixButton.Click += (_, _) => ShowPrefixes(prefixButton);
        var close = MakeButton("Close");
        close.Click += (_, _) => Close();
        actions.Controls.AddRange(new Control[] { contextButton, add, recordButton, recents, skillsButton, prefixButton, close });
        top.Controls.Add(thumbs, 0, 0);
        top.Controls.Add(actions, 1, 0);
        note.Dock = DockStyle.Fill;
        note.BackColor = Color.FromArgb(24, 24, 26);
        note.ForeColor = ForeColor;
        note.TextChanged += (_, _) => { autosave.Stop(); autosave.Start(); RefreshSend(); RefreshPrefix(); UpdateMentions(); };
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
        var shortcut = new Label { Text = "Ctrl+Enter", AutoSize = true, ForeColor = Color.FromArgb(170, 170, 176), Padding = new Padding(0, 8, 0, 0) };
        bottom.Controls.AddRange(new Control[] { destinationBox, targetBox, send, shortcut, status });
        Controls.Add(note);
        Controls.Add(bottom);
        Controls.Add(top);
        autosave.Tick += (_, _) => { autosave.Stop(); Persist(); };
        foreach (var button in actions.Controls) StyleQuiet((Button)button);
        StyleQuiet(contextButton);
        RefreshThumbs();
        RefreshContext();
        RefreshPrefix();
        mentionPopup.Choose = InsertMention;
        Shown += async (_, _) => await Discover();
        Open = this;
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
        var screen = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(screen.Left + Math.Max(16, (screen.Width - Width) / 2), screen.Bottom - Height - 48);
        note.Focus();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        if (Open == this) Open = null;
        base.OnFormClosed(e);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (RecordingSession.Active && Open == this) { e.Cancel = true; return; }
        if (sending && !submitted) { e.Cancel = true; return; }
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
        if (keyData == Keys.Escape && !sending) { Close(); return true; }
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
        int index = destinations.FindIndex(item => item.Id == preferred);
        if (destinationBox.Items.Count > 0) destinationBox.SelectedIndex = index >= 0 ? index : 0;
        filling = false;
        DestinationChanged();
    }

    void DestinationChanged()
    {
        filling = true;
        targetBox.Items.Clear();
        foreach (var target in Current?.Targets ?? new List<ComposerTarget>()) targetBox.Items.Add(target);
        targetBox.DisplayMember = "Label";
        if (targetBox.Items.Count > 0) targetBox.SelectedIndex = 0;
        filling = false;
        if (Current is ComposerDestination selected && selected.Status == "ready")
        {
            settings["defaultDestination"] = selected.Id;
            try { ComposerFiles.SaveSettings(output, settings); } catch (Exception error) { status.Text = error.Message; }
        }
        RefreshSend();
        _ = LoadSkills();
    }

    ComposerDestination? Current => destinationBox.SelectedItem as ComposerDestination;
    ComposerTarget? CurrentTarget => targetBox.SelectedItem as ComposerTarget;

    int skillGeneration;
    async Task LoadSkills()
    {
        int generation = ++skillGeneration;
        skillsReady = false;
        skills.Clear();
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
        send.Enabled = !sending && !submitted && skillsReady && Current?.Status == "ready" && target != null && (note.Text.Trim().Length > 0 || shots.Count > 0 || videos.Count > 0) && note.Text.Length <= 16_000;
        recordButton.Text = videos.Count == 0 ? "Record" : videos.Count + "/3";
        recordButton.Enabled = CanRecord;
        int included = ComposerFiles.Sources.Count(source => ComposerFiles.Included(include, source) && ContextReview.Count(source, shots, context) > 0);
        contextButton.Text = included == 0 ? "No context" : "Context " + included;
        contextButton.AccessibleDescription = ContextReview.TokenEstimate(ContextReview.IncludedCharacters(shots, context, include));
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
        for (int index = 0; index < shots.Count; index++)
        {
            int current = index;
            var panel = new Panel { Size = new Size(84, 60), Margin = new Padding(0, 4, 6, 0) };
            var picture = new PictureBox { Size = new Size(72, 52), SizeMode = PictureBoxSizeMode.Zoom, Cursor = Cursors.Hand, Location = new Point(0, 6) };
            try
            {
                var image = Image.FromFile(shots[index]["screenshot"]!.GetValue<string>());
                picture.Image = image;
                panel.Tag = image;
            }
            catch { picture.BackColor = Color.DimGray; }
            picture.AccessibleName = "Annotate screenshot " + (index + 1);
            picture.Click += (_, _) => Annotate(current);
            var remove = new Button { Text = "×", Size = new Size(18, 18), Location = new Point(64, 0), FlatStyle = FlatStyle.Flat };
            remove.AccessibleName = "Remove screenshot " + (index + 1);
            remove.Click += (_, _) => { shots.RemoveAt(current); RefreshThumbs(); RefreshContext(); Touch(); };
            panel.Controls.Add(picture);
            panel.Controls.Add(remove);
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
            picture.Click += (_, _) => Review(current);
            caption.Click += (_, _) => Review(current);
            var remove = new Button { Text = "×", Size = new Size(18, 18), Location = new Point(64, 0), FlatStyle = FlatStyle.Flat };
            remove.AccessibleName = "Remove recording " + (index + 1);
            remove.Click += (_, _) => { videos.RemoveAt(current); RefreshThumbs(); Touch(); };
            panel.Controls.Add(picture);
            panel.Controls.Add(caption);
            panel.Controls.Add(remove);
            thumbs.Controls.Add(panel);
        }
    }

    void Annotate(int index)
    {
        if (sending || index < 0 || index >= shots.Count) return;
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
        if (sending || RecordingSession.Busy || shots.Count >= 8) { if (shots.Count >= 8) status.Text = "A draft can contain up to 8 screenshots."; return; }
        Hide();
        try
        {
            using var overlay = new RegionOverlay();
            if (overlay.ShowDialog() != DialogResult.OK || overlay.Choice is not CaptureChoice choice) return;
            shots.Add(ComposerFiles.Media(await CaptureSelector.Take(choice, output)));
            RefreshThumbs();
            RefreshContext();
            Touch();
        }
        catch (Exception error) { status.Text = error.Message; }
        finally { if (!IsDisposed) Show(); }
    }

    void EditContext()
    {
        mentions.Dismiss();
        mentionPopup.Hide();
        using var dialog = new ContextDialog(shots, videos, context, include);
        dialog.ShowDialog(this);
        settings["include"] = ComposerFiles.Clone(include);
        try { ComposerFiles.SaveSettings(output, settings); } catch (Exception error) { status.Text = error.Message; }
        RefreshSend();
        Touch();
    }

    void ShowRecents()
    {
        var recent = ComposerFiles.Recents(output);
        if (recent.Count == 0) { status.Text = "No saved captures yet."; return; }
        using var dialog = new Form { Text = "Recent captures", ClientSize = new Size(420, 280), StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false };
        var list = new ListBox { Dock = DockStyle.Fill };
        foreach (var item in recent) list.Items.Add(item.Title + " · " + item.Screenshots);
        list.DoubleClick += (_, _) => dialog.DialogResult = DialogResult.OK;
        dialog.Controls.Add(list);
        if (dialog.ShowDialog(this) != DialogResult.OK || list.SelectedIndex < 0) return;
        try
        {
            var bundle = ComposerFiles.LoadBundle(recent[list.SelectedIndex].Path, output);
            shots.Clear();
            shots.AddRange(bundle.Shots);
            videos.Clear();
            videos.AddRange(bundle.Videos);
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
        if (!skillsReady) return;
        using var dialog = new Form { Text = "Skills", ClientSize = new Size(320, 360), StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false };
        var search = new TextBox { Dock = DockStyle.Top, PlaceholderText = "Find a skill" };
        var list = new CheckedListBox { Dock = DockStyle.Fill, CheckOnClick = true };
        bool fillingSkills = false;
        void Fill()
        {
            fillingSkills = true;
            list.Items.Clear();
            foreach (var skill in skills.Where(skill => search.Text.Length == 0 || (skill.Id + " " + skill.Name).Contains(search.Text, StringComparison.OrdinalIgnoreCase)))
                list.Items.Add("@" + skill.Id, ComposerFiles.Mentions(note.Text, skill.Id));
            fillingSkills = false;
        }
        search.TextChanged += (_, _) => Fill();
        list.ItemCheck += (_, args) =>
        {
            if (fillingSkills) return;
            string id = list.Items[args.Index]?.ToString()?.TrimStart('@') ?? "";
            BeginInvoke(() =>
            {
                if (args.NewValue == CheckState.Checked) { if (!ComposerFiles.Mentions(note.Text, id)) note.AppendText((note.Text.Length == 0 || note.Text.EndsWith(" ") ? "" : " ") + "@" + id + " "); }
                else note.Text = ComposerFiles.RemoveMention(note.Text, id);
            });
        };
        dialog.Controls.Add(list);
        dialog.Controls.Add(search);
        Fill();
        dialog.ShowDialog(this);
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
    }

    void RememberPrefix(string prefix)
    {
        if (prefix.Length == 0 || prefix.Length > 500) return;
        var prefixes = ComposerFiles.Prefixes(settings);
        if (prefixes.Contains(prefix)) return;
        prefixes.Insert(0, prefix);
        StorePrefixes(prefixes.Take(12).ToList());
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
        if (note.Text.Length == 0 && shots.Count == 0 && videos.Count == 0) return;
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
        finally { if (!IsDisposed) { Location = parked; Activate(); } }
    }

    void Review(int index)
    {
        if (sending || submitted || index < 0 || index >= videos.Count) return;
        mentions.Dismiss();
        mentionPopup.Hide();
        using var review = new ClipReviewForm(output, videos[index], context, ReplayMath.FramesPerClip(videos.Count));
        review.ShowDialog(this);
        if (review.Outcome == ClipReviewOutcome.Remove)
        {
            videos.RemoveAt(index);
            status.Text = "Clip removed. The MP4 stays in the captures folder.";
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

    void Attach(JsonObject clip)
    {
        if (videos.Count >= ReplayMath.MaxClips) return;
        videos.Add(clip);
        status.Text = "Recording added. Click it to review or trim.";
        int each = ReplayMath.FramesPerClip(videos.Count);
        foreach (var video in videos)
        {
            if (video["frames"] is not JsonArray frames) continue;
            while (frames.Count > each) frames.RemoveAt(frames.Count - 1);
        }
        RefreshThumbs();
        RefreshContext();
        Touch();
    }

    void UpdateMentions()
    {
        if (updatingMentions) return;
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
