# Capture Studio (Appshots fork)

This fork installs as **Capture Studio**, a separate plugin that can run alongside
OpenCode Appshots. It has its own helper app (`Capture Studio.app`, bundle ID
`local.opencode.capturestudio`) and therefore its own macOS permission entries. It
also has its own captures folder (`opencode/capture-studio`), shortcut
(**Option+G**; while the helper runs, Option+G no longer types © in other apps), `capture_studio` tool, and `/capture-studio*` commands.
On top of Appshots it adds destinations, bundles, context preview and recent captures.

A plugin for OpenCode V2. Captures one app window and the accessibility
text from that same window, then returns both as native model-visible tool content.
Supports macOS 14+ and an initial Windows 10/11 implementation. Requires a model
that accepts images. The macOS implementation was verified against OpenCode 2.0.24;
native Windows behavior still needs validation on a Windows desktop.

**Windows:** see [Windows setup and validation](docs/windows.md). The instructions
below describe macOS unless noted. Windows supports capture, UI Automation text,
a tray shortcut, annotation editing, and best-effort draft insertion.

## Installation

### Requirements

- macOS 14 or newer on Apple Silicon (the current build targets `arm64`).
- OpenCode V2 running locally on the Mac; verified against 2.0.24. OpenCode V1
  and a remote/Linux OpenCode server are not supported. For a local Windows server,
  use the separate [Windows instructions](docs/windows.md).
- Node.js with npm, Git, and Apple's Command Line Tools (`xcode-select --install`).
- An image-capable model. Use the OpenCode desktop app for automatic draft insertion.

### Install from source

Review the source before installing: this plugin can capture your windows and
uses Accessibility to read UI text and paste into OpenCode.

```sh
mkdir -p ~/.config/opencode/plugins
git clone https://github.com/milovate/opencode-appshots.git ~/.config/opencode/plugins/capture-studio
cd ~/.config/opencode/plugins/capture-studio
npm ci --ignore-scripts
npm run build
```

If that destination already exists, stop and inspect it; do not overwrite an
existing plugin. `npm ci` installs development/test dependencies only. Runtime
code has no npm dependencies. The build creates and locally ad-hoc signs
**Capture Studio.app**; no prebuilt or notarized binary is distributed here.

OpenCode V2 automatically discovers this global plugin directory. There is no
need to add a duplicate `plugins` entry or install an MCP server. After building,
reload OpenCode. If commands do not appear, run `opencode service restart`
(this interrupts the shared service's active work), then reopen OpenCode.

**Next: [enable macOS permissions](docs/macos-permissions.md).** The user must
approve these in System Settings; neither the plugin nor an agent can grant them.
For agent-assisted setup, follow [the setup checklist](docs/agent-setup.md).

### Validation scope

Run `npm test` to check native annotation geometry, inline editing, crop export,
history, region-selection gestures, screenshot collections, and plugin contracts.
The original annotation drag-test failure was traced to its Retina fixture using
logical point dimensions instead of source pixels, plus exact floating-point
equality; that fixture is now corrected. This is not a substitute for live desktop
validation of capture permissions, multi-display overlays, or OpenCode insertion.

### Install in another location

Clone and build there, then merge an absolute plugin directory into your existing
`~/.config/opencode/opencode.json(c)` without replacing unrelated settings:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["/absolute/path/to/opencode-appshots"]
}
```

Do not also install a second copy in the automatic discovery directory.

## Use

### macOS floating composer

The macOS shortcut opens a compact, borderless floating composer near the bottom
of the active screen. It follows the system's light/dark appearance, uses frosted
material, and grows with the description instead of reserving a large empty area.
Rebuild the helper and reload the plugin to apply source changes. Rebuilding changes
its local signature and may require renewing macOS grants; do not replace a running
installation without planning that permission step.

1. Focus the app window and press **Option+G**.
2. Describe what felt wrong in the borderless input. Click any screenshot thumbnail
   to annotate it, then choose **Done** to return. Its small **×** removes it from the
   draft, not from local capture history. Removing all screenshots allows a text-only draft.
   The **viewfinder / Add screenshot** button opens a dimmed-screen region picker:
   drag a rectangle and release to attach the selected pixels, or Escape to cancel.
   Each region stays a separate screenshot; up to eight can be attached. Each image
   must be under 15 MB and the collection under 30 MB. Region capture does not read
   accessibility text from outside the selected rectangle or save a whole-display image.
3. Choose where to send: **OpenCode**, **Clipboard**, or **Save to folder** (see
   [Destinations](#destinations)), then a target. For OpenCode the target is a connected
   project: a location with this plugin loaded in the local OpenCode service, not
   every folder on disk. The footer and send button show the destination's action,
   such as **Review in OpenCode**, **Copy Markdown**, or **Save bundle**. The last
   destination you choose becomes the default.
   The **Context** chip shows the window text and device info that will be included,
   with a rough token estimate. Uncheck either source to leave it out of every destination.
4. **@report** is prefilled into the editable text when available. Type **@** for
   autocomplete, use Up/Down to choose, and press Enter or Tab to insert a skill.
   Known mentions are highlighted. Deleting a mention removes the selection; loading
   skills again does not resurrect a deleted default. The **@** button opens the
   searchable skill picker. Email addresses are not skill mentions. The text is
   canonical; the selected skills are derived from it.
5. Optionally click the **microphone**, approve Microphone and Speech Recognition, speak,
   then stop and edit the transcript. Only on-device recognition is used; there is
   no cloud fallback or saved audio. Language/device availability varies.
6. Click the circular **↗** send button (Command+Return). With OpenCode, this creates
   a new root session, opens it in OpenCode, and pastes the screenshots, description,
   inline skill mentions, and included context into its **unsent input**.
   Review it there and press Enter yourself to run. The composer never submits a
   prompt, calls a model, or presses Enter in OpenCode. **×** or Escape cancels.
   Escape first dismisses an open @autocomplete menu. Full project paths are available in
   tooltips instead of occupying the composer.

OpenCode desktop must be running, with Accessibility approved. The helper opens
Home, searches for the exact new session ID, selects its uniquely titled result,
and verifies that session is active before filling an empty Prompt. It does not
overwrite existing draft text. If navigation or insertion cannot be verified, it
stops and retains the composer rather than submitting anything or silently using
another conversation. This desktop path still requires live acceptance testing.
The new session uses the project's defaults, not the current conversation's model.
Skill mentions remain visible in the OpenCode draft; no skill or user prompt is
admitted on the server before you submit that draft yourself.

An unchanged retry in the same composer is deduplicated while the plugin remains
loaded. After an uncertain handoff, the draft is retained and locked against changes;
check the session in OpenCode before opening another composer or reloading. There
is no cross-restart exactly-once guarantee and no automatic retry. The bridge
exposes `/skills`, `/destinations` and `/prepare`, not the former `/send`; old
helpers cannot auto-run prompts.

### Destinations

A destination is where a prepared capture goes. Each one only places the bundle
somewhere you then act on; none sends, submits, pastes, or runs anything for you.

| Destination | Target | What happens |
| --- | --- | --- |
| OpenCode | A loaded project | Creates an empty session and fills its unsent input |
| Clipboard | Markdown | Copies the note, context and absolute screenshot paths. Nothing is pasted |
| Save to folder | `~/Documents/Appshots` | Writes `screenshot-N.png`, `README.md` and `bundle.json` to a new owner-only folder, then reveals it in Finder |

Change the export folder with the plugin option `{ "exportDirectory": "/absolute/path" }`.
A relative path makes Save to folder unavailable.
Exports contain only the included context and never paths into the private captures folder.

Destinations are JavaScript modules loaded by the OpenCode plugin process
(`destinations.js`). Each is a plain object, checked once by `validateDestination`:

```ts
interface Destination {
  id: string;            // lowercase slug, e.g. "opencode"
  label: string;
  accepts: { image: boolean; video: boolean; maxBytes?: number };
  status(): Promise<"ready" | "not-installed" | "needs-auth" | "not-running">;
  targets(): Promise<{ id: string; label: string; detail?: string }[]>;
  actionLabel(target): string;
  hint(target): string;
  // Must never submit. Returns one of the handoff actions below.
  prepare(bundle, target, { note, requestID }): Promise<
    | { action: "opencode-draft"; sessionID; title; directory; draftText }
    | { action: "copy-text"; text; message }
    | { action: "reveal-folder"; path; message }
  >;
}
```

`GET /destinations` lists each destination's status and targets with their action
label and hint. `POST /prepare` accepts optional `destination` and `target` fields;
without them it prepares an OpenCode draft as before. The helper performs the
returned action: it opens the draft, writes the clipboard, or reveals the folder.
The helper refuses any other action. Because destinations run inside the plugin,
Clipboard and Save to folder are also only available while OpenCode has the
plugin loaded.

### Bundles and recent captures

Each send saves a **bundle**: `bundle-<id>.json` in the captures folder, owner-only.
It is the single local record of that capture: screenshot paths and window text,
your note, device context, and the include flags you chose. It is written only
when you send, never while you type. **Appshot → Recent bundles** lists the latest
eight and reopens one in the composer, for example to send it to a different
destination. Screenshots deleted since then are reported and left out.
**Appshot → Default destination** sets which destination the composer preselects.
This is stored in an owner-only `settings.json` in the captures folder.

Device context covers the macOS version, architecture, Mac model, CPU, memory,
displays and locale. It never includes location, host name, user name or network details.

### Context sources

The **Context** chip opens a review popover with one tab per source, an entry count,
a preview, an include checkbox and a size estimate. Unchecked sources are left out of
every destination. Sources that take a moment (console, browser) show
"collecting…" and fill in while you type. A reopened bundle shows the context stored
with it, not a fresh collection.

| Source | What is collected | When |
| --- | --- | --- |
| Window | Accessibility text of the captured window | At capture |
| Device | Mac model, macOS, CPU, memory, displays, locale; memory pressure and the captured app's footprint; battery level/charging/power source; free/total space on the home volume; thermal state and Low Power Mode; captured app name, bundle ID and version; for browsers, page URL, title and user agent | At capture |
| Console | Native apps: errors and faults the captured app wrote to the unified log in the last 5 minutes (`/usr/bin/log show`; private values stay `<private>`). Browsers: the extension's console messages and uncaught errors for the visible tab | Starts at capture, finishes in about 1–2 s |
| Network | Browsers only: failed requests (HTTP status ≥ 400 or network error) for the visible tab, with method, URL, status/error and resource type. No headers or bodies; credentials and values of query parameters such as `token`, `key`, `secret`, `password`, `auth`, `session`, `code` or `sig` are replaced with `[redacted]` | From the extension's buffer at capture |
| Clicks | Off by default. When **Context sources → Record recent clicks** is on: the last 10 minutes (up to 100) of clicks, with the clicked element's accessibility role and label, and app switches. Kept in memory only and cleared when turned off or the helper quits. Keystrokes are never observed; secure fields keep only their role | Continuously, in memory, while enabled |
| Logs | The last 64 KB of up to 4 files chosen under **Context sources → Custom log files**. Paths are stored in the owner-only `settings.json`; exports include only the file name | At capture |

Logs, console messages, page content and click labels are untrusted app content. The
draft wraps them in `<appshot_context>` blocks with a warning not to follow
instructions inside them. Logs and events share one 60,000-character budget; the
oldest entries are dropped first, with a note.

#### Browser extension (Chrome, Brave, Edge, Arc, Chromium)

Browser console and network context come from the bundled MV3 extension in
`browser-extension/`. It keeps a per-tab buffer (300 console entries, 200 failed
requests, 10 minutes) in the browser's in-memory session storage and hands over
only the visible tab of each window, when the helper asks during a capture of that
browser. Nothing is sent anywhere else.

1. Choose **Appshot → Context sources → Connect browser extension…**. This writes a
   native messaging host manifest named `local.opencode.capturestudio.json` into each
   installed browser's `NativeMessagingHosts` folder. It allows only the pinned
   extension ID `ffjgcjgbehaoabcniapiljdcpeehoocd`, and it is written only when you
   choose this menu item.
2. In the browser, open `chrome://extensions` (or the browser's equivalent), turn on
   **Developer mode**, choose **Load unpacked**, and select the `browser-extension` folder
   revealed in Finder.
3. Reload the tabs you want to debug. Console messages are recorded from page load.

The browser starts Capture Studio's executable as the native host. The host and
the menu-bar helper talk over an owner-only Unix socket in
`~/Library/Application Support/Capture Studio/browser/`. Each side checks the other's
code signature through the socket's audit token and refuses any process that is not
the same signed Capture Studio binary. Other apps therefore cannot request or read
browser context, and nothing is written to disk on the way. To disconnect, remove
the extension and delete those manifest files.

### Instant replay and screen recording

Both record at about 10 frames per second, scaled to at most 1920 pixels on the long
side, as H.264 video without audio. Capture Studio's own windows, including the
composer and the recording controls, are excluded. Both use the existing Screen
Recording permission, and macOS shows its own screen-recording indicator while either runs.

- **Instant replay** is off by default. **Appshot → Context sources → Keep instant
  replay (last 30 s)** keeps the most recent 30 seconds of the main display in memory
  (capped at 150 MB); older video is discarded continuously, and nothing is written to
  disk. The menu-bar icon shows a ring while it is on. Pressing **Option+G** writes those
  30 seconds to an MP4 and attaches it to the composer with the screenshot. Turning it
  off or quitting the helper discards the buffer. The setting is stored in the
  owner-only `settings.json`.
- **Screen recording** starts from **Appshot → Start screen recording…**,
  **Option+Shift+G**, or the composer's add button (**Screen recording…**). A bar asks
  what to record: the **Display**, the front **Window** of the app you were using (only
  that window, even when others overlap it), or an **Area** you drag. Return starts and
  Escape cancels. While recording, a floating pill shows the time with **Restart**
  (discard and start over), **Pause**/**Resume** (paused time is left out of the clip)
  and **Stop**; an area recording also shows a dashed outline. The menu-bar icon shows a
  filled dot. Recordings stop by themselves after 5 minutes of recorded time. Stopping
  adds the clip to the composer that asked for it, or opens a new composer with
  freshly collected context.

A composer holds up to three clips. Each is saved owner-only in the captures folder
as an MP4 plus key frames (PNG, at most 1280 pixels on the long side). Six key frames
are sent in total, split across the clips: six for one clip, three each for two, two
each for three. The bundle records each clip's source, what it captured, start time,
duration, pauses and frame offsets.

Click a clip to review it: play it, see blue markers for clicks, red for console
errors and failed requests, and orange for warnings, and drag the handles (or press
I and O) to trim. **Use trimmed clip** writes a new MP4 for the selection and takes
key frames from it; the original file is left in the captures folder. **Remove clip**
detaches it. On send:

- **OpenCode** attaches the key frames as images after the screenshots. The draft
  says what each clip recorded, lists the frame offsets, and gives the time of each
  click, console message and failed request within its clip. The MP4s stay on your Mac.
- **Clipboard** Markdown links the MP4s and the key frames.
- **Folder** export copies `recording.mp4`, `recording-2.mp4`, … and their
  `recording-frame-N.png` / `recording-2-frame-N.png` key frames.

The local video and frames are untrusted app content and are marked as such in the draft.

The composer routes Command+A/C/X/V/Z and Command+Shift+Z locally, including in
its borderless accessory window. Dictation shows permission/startup/finishing
states, waits for final recognition results after Stop, and uses the preferred
spoken language rather than region-formatting overrides. Denied access and missing
on-device language support are shown explicitly. `--permissions` includes non-prompting
dictation diagnostics; `status.json` records stages/permissions/errors, never transcripts.

The menu bar uses a monochrome capture-frame/speech-bubble template icon rather
than a text label. Its tooltip and accessibility label still identify Appshots.

Handoff lookup verification re-reads the live search input after OpenCode replaces
the Home control with its floating search panel. Empty-draft checks recognize the
U+200B placeholder exposed by OpenCode's contenteditable without changing user text.

For an explicitly requested replay/debug of an already-created session, the helper
accepts `--open-session-draft <file.json> --output <captures-folder>`. The JSON must
be in that folder, under 300 KB, and contain `sessionID`, `title`, `draftText`, and a
`shot` manifest whose PNG is also in the captures folder. Keep it owner-only and
delete it after testing: like a saved bundle, this explicit replay file contains
draft text. This command does not capture, create a session, or submit
a prompt; it only opens that exact session and inserts into its verified empty input.
Never use it to overwrite an existing draft or test with a model submission.

The bridge listens only on `127.0.0.1` with a random per-location bearer token,
rejects browser-origin requests, and publishes its endpoint in owner-only files
under the local captures folder's `composers/` directory. Do not share these files.
Plugin cleanup closes the endpoint and removes its descriptor. Stale descriptors
left after a crash are ignored when they cannot authenticate/connect.

This composer is **macOS-only**. Windows retains its existing insertion workflow.
The composer and microphone still require a live desktop acceptance test; passing
contract tests or Swift type-checking does not verify native interaction.

### Existing draft-insertion workflow

On macOS, choose **Appshot → Capture, annotate, and insert into current draft**
instead of the shortcut to use the original flow below. Windows keeps its shortcut.

1. Check for **Appshot** in the menu bar. If it is missing, run `/capture-studio-start`
   in an OpenCode conversation. This starts the shortcut helper without a model call.
2. Focus the window to share and choose the capture-and-insert menu action.
3. The annotation editor opens nearly as large as your screen, with the image filling
   the canvas without padding or cropping. Drag the grip at the left of the borderless
   floating toolbar to reposition it. Choose Arrow, Box,
   Draw, Text, or Crop. Drag the **+ crosshair** over the image to draw. Text puts a
   live caret directly on the picture: type there, Return commits, Shift+Return adds
   a line, Escape cancels the edit, and clicking elsewhere commits it. No label
   dialog is opened. Choose a color and stroke width as needed. Click
   **Insert** (Command+Return) when ready. **×**, Escape, or the red window button
   cancels and returns focus to the app you were using. Escape first clears a
   selection; press it again to close. The next shortcut opens
   a fresh editor; repeated shortcuts while editing bring the current editor forward.
   Undo and Redo use Command+Z and Command+Shift+Z.
4. OpenCode comes forward. The screenshot is attached to the current conversation's
   input, and the capture's timestamp and accessibility text are appended to the draft.
5. Add your question and send when ready.

An existing draft is preserved. The helper restores your clipboard after pasting,
unless you copy something else during insertion. If OpenCode is in Settings or a
dialog, open a conversation and choose **Appshot → Insert latest capture into OpenCode**.
That menu action also lets you insert the previous capture without taking another.
The `/capture-studio-insert` command provides the same replay action from OpenCode.

Choose **Appshot → Annotate latest capture** to edit a saved image, or
**Annotate clipboard image** for an image you copied. The editor saves a new PNG
with the marks included and preserves the original capture and accessibility text.
You can insert without drawing anything. **Capture and insert without annotation**
keeps the immediate-paste workflow available in the menu. The `/capture-studio-annotate`
command opens the latest capture in the editor after OpenCode reloads the plugin.
Images already attached inside OpenCode need to be removed and replaced with the
annotated image. The inserted PNG contains the marks, while the capture manifest
retains editable objects over the original image. **Annotate latest capture**
restores those objects; undo history starts fresh on reopen. Captures exported
before version 0.4 remain flattened, so their old marks cannot be individually
selected. New marks over those images remain editable.

Drawing tools stay active after each gesture; choose **Select** (V) to edit objects. Click an object to
select it, then drag to move it. Drag the corner handles to resize a box or drawing,
or resize text; arrow handles adjust its endpoints. Double-click text, press Return
with text selected, or use its right-click menu to edit it. Color and stroke changes
apply to the selected object. Delete removes it, Command+D duplicates it, and arrow
keys move it by one image pixel (Shift+arrow moves ten). Undo/Redo includes moves,
resizes, styling, text edits, deletion, and duplication. V selects; A, R, P, and T
choose Arrow, Box, Draw, and Text. C chooses Crop. Drag the crop rectangle, then
choose **Apply Crop** or press Return. **Reset Crop** restores the full original;
Escape cancels the pending selection. Crop and reset participate in Undo/Redo.
Cropping is non-destructive: the original image and editable marks stay local,
while only the cropped pixels are exported. Original-window accessibility text is
omitted from cropped-image delivery to avoid sharing content outside the crop.
Reset Crop restores that original context when exporting the full image again.
Selection outlines, handles, crop shading, and the editing caret are never exported.

You can also ask: “Use appshot to capture Google Chrome and explain this error.”
The agent calls `capture_studio` with `app: "Google Chrome"`. An app bundle ID also works.
Live capture without an app name uses the foreground app, so requesting it while
OpenCode is frontmost captures OpenCode itself. The shortcut avoids that problem.

The insertion menu uses the frontmost OpenCode window's conversation and leaves
the message unsent. `/capture-studio` also remains available to retrieve the saved image
and text through the agent tool. The macOS shortcut opens the composer.

## Permissions

See [macOS permissions: step-by-step setup and troubleshooting](docs/macos-permissions.md).

Add **Capture Studio.app** (inside this plugin folder) to these macOS settings:

- System Settings → Privacy & Security → **Screen & System Audio Recording**
- System Settings → Privacy & Security → **Accessibility**

macOS may attribute a command-line capture to **OpenCode** or the terminal used
to launch it; grant the responsible app shown by macOS. Restart OpenCode after
granting access. The helper checks access; it never grants permissions itself.
To restart this helper after a permission change, choose **Quit Capture Studio** and
run `/capture-studio-start`. You can also open the bundled .app directly.
The helper is ad-hoc signed with the hardened runtime, so other processes cannot
inject libraries into it to borrow these grants.
Rebuilding this locally signed helper changes its code signature. If its permission
checks remain denied while the switches appear enabled, remove its old entries
from both permission lists, add the current .app again, and enable the switches.
Then restart Appshots. Reopening only OpenCode does not restart an existing helper.
Without Accessibility, capture returns a screenshot-only result and automatic
input insertion explains that Accessibility access is required. Recording recent
clicks also needs Accessibility (to observe clicks and read the clicked element's
role and label); no Input Monitoring permission is requested because keys are never read.
Without Screen Recording, it fails with setup instructions.

## Storage and scope

Captures are saved to `$XDG_DATA_HOME/opencode/capture-studio`, or by default
`~/.local/share/opencode/capture-studio` on macOS and `%LOCALAPPDATA%\opencode\appshots`
on Windows. macOS uses owner-only permissions; the Windows helper protects its
capture directory with an ACL for the current user and SYSTEM. A new capture
replaces the latest pointer but keeps earlier PNGs.
Use **Appshot → Open captures folder** to review or remove saved captures.

The macOS reader follows the selected window's accessibility tree in UI order and emits
an indented hierarchy with readable roles, link/page URLs, values, placeholders,
help, and selected/disabled/editable/expanded states when the app exposes them.
Empty layout branches and redundant single-child anonymous containers are pruned;
named groups, groups with meaningful states, and branches with several children are
preserved. Adjacent plain text fragments are grouped with paragraph breaks without
crossing controls or links. JSON punctuation/token runs are joined compactly;
link labels already represented by their parent are omitted from child text. Boolean values retain their type and read as on/off.
Selected text is included when the app exposes it, including Chrome's document
text-marker selection. A page selection takes precedence over stale selection
from an unfocused address field; a focused input retains its own selection.
Both draft insertion and tool output include the selected-text guidance from the
Codex example. The focused element is reported only when it belongs to that window. Duplicate
static text inside an editor is omitted when its value already contains that text;
repeated messages elsewhere are retained. Secure text fields and their descendants
are excluded from the text dump.

Traversal supports 6,000 elements, 128 nesting levels, eight seconds, and 120,000
characters. Every exceeded limit or failed element read produces an explicit
warning in both the text and capture manifest. These limits keep capture responsive;
the result is a best-effort snapshot, and apps may expose less context than they display.
Images
still contain what the window displays. Automatic insertion focuses OpenCode's
Prompt input and sends Command+Down and Command+V to that app. It never sends
Return or clicks Send. Pasted attachments enter OpenCode's local attachment store;
the selected model receives the draft when you send it.

Composer drafts are held in memory while you type. Sending saves an owner-only
bundle alongside the retained PNGs. It contains screenshot paths, accessibility text,
**your description**, the collected context (device, system, console, network, clicks,
custom log tails) and include flags, so recent bundles can be
reopened. Delete `bundle-*.json` files from the captures folder to remove them.
OpenCode receives the description, inline skill mentions, ordered screenshot
attachments and included context in its unsent draft; no model runs until the user
submits it. Clipboard and Save to folder put the same content where you chose. It
leaves your Mac only if you paste or share it yourself.

Only one hotkey helper runs per captures directory. Annotation and replay commands
are forwarded to that helper when it is running, so closing an editor does not
leave a second helper instance or block the next capture. Disable its automatic start
by configuring this plugin with `{ "hotkey": false }` in its OpenCode options;
named-app capture remains available. The menu-bar helper stays available across
plugin reloads until you choose **Quit Capture Studio**. This avoids losing the global
shortcut when multiple OpenCode projects load the plugin at once. If you quit it
from the menu, run `/capture-studio-start` to restart it. Reopening the OpenCode window
alone may reuse its existing server and does not necessarily reload the plugin.

The private `status.json` file in the captures folder records shortcut registration,
current permission checks, and the latest capture/insertion stage. It contains
diagnostics rather than the accessibility text or screenshot data.
Press Option+G while the window you want to share is focused.
The shortcut uses the macOS global hotkey dispatcher. `hotkeyStatus: 0` and
`hotkeyHandlerStatus: 0` confirm registration, not physical key delivery.
`shortcutCount` and `lastShortcutAt` update when the helper actually receives the
shortcut; if they do not change, the key event did not reach the helper.
Phase `inserted` means the helper confirmed the captured timestamp in the draft.

## Develop

`npm install --ignore-scripts` installs the official SDK used by contract tests.
Runtime code has no npm dependencies. Run `npm test` and `npm run build`.
The build creates and ad-hoc signs the local helper app; rebuilding may require
renewing macOS permission grants. The included build targets Apple Silicon.

Plugin API reference: https://opencode.ai/v2/docs/build/plugins/
Plugin loading reference: https://opencode.ai/v2/docs/plugins/
Appshots reference: https://learn.chatgpt.com/docs/appshots
