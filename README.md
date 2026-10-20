# OpenCode Appshots

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
git clone https://github.com/milovate/opencode-appshots.git ~/.config/opencode/plugins/appshots
cd ~/.config/opencode/plugins/appshots
npm ci --ignore-scripts
npm run build
```

If that destination already exists, stop and inspect it; do not overwrite an
existing plugin. `npm ci` installs development/test dependencies only. Runtime
code has no npm dependencies. The build creates and locally ad-hoc signs
**OpenCode Appshots.app**; no prebuilt or notarized binary is distributed here.

OpenCode V2 automatically discovers this global plugin directory. There is no
need to add a duplicate `plugins` entry or install an MCP server. After building,
reload OpenCode. If commands do not appear, run `opencode service restart`
(this interrupts the shared service's active work), then reopen OpenCode.

**Next: [enable macOS permissions](docs/macos-permissions.md).** The user must
approve these in System Settings; neither the plugin nor an agent can grant them.
For agent-assisted setup, follow [the setup checklist](docs/agent-setup.md).

### Known test limitation

The original macOS publication validation built the helper and passed 10 of 11 tests. The native
annotation test fails at `native mouse gesture moves selected text in image
coordinates`, also when run alone. Annotation dragging is not fully validated;
do not interpret this release as a clean test suite. Run `npm test` to reproduce.
Basic capture can bypass annotation through the Appshot menu.

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

1. Check for **Appshot** in the menu bar. If it is missing, run `/appshots-start`
   in an OpenCode conversation. This starts the shortcut helper without a model call.
2. Focus the window to share and press **Control + Option + Command + A**.
3. The annotation editor opens nearly as large as your screen, with the image filling
   the canvas without padding or cropping. Drag the grip at the left of the borderless
   floating toolbar to reposition it. Choose Arrow, Box,
   Draw, or Text. Drag the **+ crosshair** over the image to draw; Text uses an I-beam
   and opens a label dialog. Choose a color and stroke width as needed. Click
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
The `/appshots-insert` command provides the same replay action from OpenCode.

Choose **Appshot → Annotate latest capture** to edit a saved image, or
**Annotate clipboard image** for an image you copied. The editor saves a new PNG
with the marks included and preserves the original capture and accessibility text.
You can insert without drawing anything. **Capture and insert without annotation**
keeps the immediate-paste workflow available in the menu. The `/appshots-annotate`
command opens the latest capture in the editor after OpenCode reloads the plugin.
Images already attached inside OpenCode need to be removed and replaced with the
annotated image. The inserted PNG contains the marks, while the capture manifest
retains editable objects over the original image. **Annotate latest capture**
restores those objects; undo history starts fresh on reopen. Captures exported
before version 0.4 remain flattened, so their old marks cannot be individually
selected. New marks over those images remain editable.

After drawing an object, the editor switches to **Select**. Click an object to
select it, then drag to move it. Drag the corner handles to resize a box or drawing,
or resize text; arrow handles adjust its endpoints. Double-click text, press Return
with text selected, or use its right-click menu to edit it. Color and stroke changes
apply to the selected object. Delete removes it, Command+D duplicates it, and arrow
keys move it by one image pixel (Shift+arrow moves ten). Undo/Redo includes moves,
resizes, styling, text edits, deletion, and duplication. V selects; A, R, P, and T
choose Arrow, Box, Draw, and Text. Selection outlines and handles are never exported.

You can also ask: “Use appshot to capture Google Chrome and explain this error.”
The agent calls `appshot` with `app: "Google Chrome"`. An app bundle ID also works.
Live capture without an app name uses the foreground app, so requesting it while
OpenCode is frontmost captures OpenCode itself. The shortcut avoids that problem.

The shortcut uses the frontmost OpenCode window's conversation and leaves the
message unsent. `/appshot` also remains available to retrieve the saved image
and text through the agent tool. The shortcut is Control + Option + Command + A.

## Permissions

See [macOS permissions: step-by-step setup and troubleshooting](docs/macos-permissions.md).

Add **OpenCode Appshots.app** (inside this plugin folder) to these macOS settings:

- System Settings → Privacy & Security → **Screen & System Audio Recording**
- System Settings → Privacy & Security → **Accessibility**

macOS may attribute a command-line capture to **OpenCode** or the terminal used
to launch it; grant the responsible app shown by macOS. Restart OpenCode after
granting access. The helper checks access; it never grants permissions itself.
To restart this helper after a permission change, choose **Quit Appshots** and
run `/appshots-start`. You can also open the bundled .app directly.
Rebuilding this locally signed helper changes its code signature. If its permission
checks remain denied while the switches appear enabled, remove its old entries
from both permission lists, add the current .app again, and enable the switches.
Then restart Appshots. Reopening only OpenCode does not restart an existing helper.
Without Accessibility, capture returns a screenshot-only result and automatic
input insertion explains that Accessibility access is required.
Without Screen Recording, it fails with setup instructions.

## Storage and scope

Captures are saved to `$XDG_DATA_HOME/opencode/appshots`, or by default
`~/.local/share/opencode/appshots` on macOS and `%LOCALAPPDATA%\opencode\appshots`
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

Only one hotkey helper runs per captures directory. Annotation and replay commands
are forwarded to that helper when it is running, so closing an editor does not
leave a second helper instance or block the next capture. Disable its automatic start
by configuring this plugin with `{ "hotkey": false }` in its OpenCode options;
named-app capture remains available. The menu-bar helper stays available across
plugin reloads until you choose **Quit Appshots**. This avoids losing the global
shortcut when multiple OpenCode projects load the plugin at once. If you quit it
from the menu, run `/appshots-start` to restart it. Reopening the OpenCode window
alone may reuse its existing server and does not necessarily reload the plugin.

The private `status.json` file in the captures folder records shortcut registration,
current permission checks, and the latest capture/insertion stage. It contains
diagnostics rather than the accessibility text or screenshot data.
Press Control+Option+Command+A while the window you want to share is focused.
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
