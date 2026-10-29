# Windows setup (initial implementation)

## Requirements and installation

- Windows 10/11 in an interactive desktop session, with OpenCode V2 running locally.
  WSL and remote/Linux servers cannot capture the Windows desktop.
- Node.js/npm, Git, and the **.NET 8 SDK** (including the Windows Desktop runtime).
  The current build is framework-dependent, for the architecture of the installed SDK.
- An image-capable model. Draft insertion requires the OpenCode desktop app.

Clone this repository into an unused directory. Do not overwrite an existing
plugin or unrelated OpenCode settings. In PowerShell, from the cloned directory:

```powershell
npm ci --ignore-scripts
npm run build
npm test
```

The build creates `windows/dist/Appshots.exe` and accompanying runtime files.
Keep that entire folder together. No npm runtime dependencies, administrator
privileges, PowerShell execution-policy changes, or macOS permissions are needed.
The helper runs as the current user and never requests elevation or `uiAccess`.

For an installation outside the automatic plugin discovery directory, merge the
plugin's absolute directory into your existing OpenCode configuration:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": ["C:/path/to/motifs"]
}
```

Do not register the same plugin twice. Reload OpenCode. If a service restart is
needed, warn about interrupting active work before `opencode service restart`.

## Capture and use

1. Run `/capture-studio-start` if the Capture Studio system tray icon is missing.
   The plugin also starts a private loopback bridge, the same one macOS uses, so
   the helper can list destinations and prepare a draft.
2. Press **Control+Alt+Shift+A**. The screen dims. **Drag** a region, **click** a
   window, or press **Enter** for the whole display. Escape cancels. A window
   capture uses `PrintWindow` and UI Automation for that window. A region or full
   screen capture is the visible pixels in that rectangle.
3. The composer opens at the bottom of the screen. Add a note, click a thumbnail
   to annotate it, and use **Add** for another capture (up to 8). **Context**
   reviews window text, device, console, network, steps, and logs. Each source
   has an include switch, a preview, Markdown, and a rough token estimate.
   **Recents** reopens a saved capture. Type **@** to pick a skill from the
   loaded project; Up and Down move through the matches, and Enter or Tab inserts
   one. Escape closes that list before it closes the composer. **Prefix** saves a
   reusable opening, puts it at the start of the note, and removes it when chosen
   again. Nothing is sent while you edit.
4. Choose **OpenCode**, **Clipboard**, or **Save to folder**, then a target.
   **Ctrl+Enter** or the action button prepares the bundle through the bridge.
   OpenCode opens a new unsent session and pastes the screenshots and draft.
   Clipboard copies Markdown. Save to folder writes the bundle and reveals it.
   None of these presses Enter or clicks Send.
5. Review the result and send it yourself. If handoff fails, the bundle remains
   in the captures folder. `/capture-studio` can still read the latest window capture.

The tray can also open an empty composer, annotate or insert the latest capture,
annotate a clipboard image, open the captures folder, or quit the watcher.
`/capture-studio-insert` and `/capture-studio-annotate` both open the latest capture in the editor.
Only one watcher runs per capture directory in the current desktop session.
`{ "hotkey": false }` in plugin options disables automatic watcher startup.
Quitting the watcher does not stop explicitly requested live tool captures.

For live capture, ask the agent to capture a running process, e.g.
`appshot({ "app": "chrome.exe" })` or `appshot({ "app": "notepad" })`.
Names match process names exactly, case-insensitively (not window titles or macOS
bundle IDs). If several windows match, the foreground matching window is used;
otherwise capture fails and asks you to focus the intended window. `source=live`
without an app captures the foreground window, which may be OpenCode itself.
`delay` allows 0–10 seconds to switch windows. `source=latest` takes no new capture.

## Annotation editing

Choose **Arrow**, **Box**, **Draw**, or **Text**, then drag over the image (click for
Text). Text opens a multiline dialog; use its OK button to accept. Color and stroke
width apply to new marks and the selected object. The editor switches to Select
after creating a mark.

- **Select** an object by clicking its stroke, or the body of a text label. Drag to
  move it. Drag corner handles to resize a box, freehand path, or text label; arrow
  handles adjust endpoints. Coordinates and stroke widths are in original image
  pixels, independent of window resizing, image zoom-to-fit, or letterboxing.
- Double-click text, press Return with text selected, or click **Edit text** to edit.
- Delete removes the selection. Ctrl+D duplicates it. Arrow keys nudge by one image
  pixel; Shift+arrow moves ten. Ctrl+Z undoes, Ctrl+Y or Ctrl+Shift+Z redoes. History
  includes creation, movement, resizing, style changes, text edits, and deletion.
- V selects; A, R, P, and T choose Arrow, Box, Draw, and Text. Escape first clears a
  selection; with no selection, it closes the editor without saving current edits.
- **Save only** saves the annotated image and editable objects without inserting.
  **Insert into OpenCode** saves and then pastes, leaving the draft unsent. Neither
   action sends a message. Cancel discards unsaved changes. If an earlier Insert
   attempt failed, its saved annotations remain available even after Cancel.

Saving creates a new PNG with marks flattened into the pixels and updates
`latest.json`. It preserves the original PNG, timestamp, and accessibility text;
the latter describes the original capture, not the drawn labels. Reopening a saved
capture restores editable Windows objects over the original image with fresh undo
history. Selection outlines and handles are never exported. Images without editable
Windows object data are treated as flattened originals. Captures imported from the
clipboard have no accessibility text. Existing OpenCode attachments must be removed
and replaced to show new annotations.

Limits: 500 objects, 20000 points total, 10000 characters per text label, 40 million
image pixels, 15 MB PNG, and 4 MB manifest. Invalid or oversized edits fail with an
error rather than replacing the saved capture.

## Privacy, limits, and differences from macOS

- A clicked window is captured with `PrintWindow`. That path has no desktop-crop
  fallback, so overlapping windows stay out of the image. A dragged region or
  Enter captures the visible pixels in that rectangle, which can include
  whatever is on screen there. The composer says which kind you took.
- Windows UI Automation reads that same window's control tree. Password controls
  and descendants are excluded from text, **not from screenshot pixels**.
  Names, values, selected text, focus, and disabled state are included when exposed.
  Windows text formatting is not equivalent to the richer macOS reader.
- UI Automation is best effort: 6000 elements, 128 levels, 8 seconds, and 120000
  characters. Warnings report partial reads and exceeded limits. A blocked native
  call can exceed the traversal deadline; tool captures time out after 30 seconds
  and shortcut captures run in an isolated process with a 25-second timeout.
- Minimized, elevated, protected/DRM, secure-desktop, and some hardware-accelerated
  windows cannot be captured reliably. Some apps produce a blank image despite
  reporting success. **Always review the result.** Do not elevate Appshots to work
  around an application's security boundary.
- Draft insertion depends on OpenCode exposing an editable UI Automation element
  named `Prompt`. It refuses ambiguous OpenCode windows and stops if focus changes.
  A paste request is not proof of attachment success: inspect the draft before
  sending or retrying. Clipboard formats may not all round-trip through Windows.

Storage defaults to `%LOCALAPPDATA%\opencode\capture-studio`, overridable with
`XDG_DATA_HOME`. The helper restricts the capture directory to the current user and
SYSTEM. PNG files and `latest.json` persist until you delete them; cancellation
does not erase a saved capture. `status.json` records watcher/capture stages without
including screenshot bytes or accessibility text. `paste_requested` is explicitly
unverified, not a confirmed insertion. Never commit any capture files.

## Validation checklist

Windows build, JavaScript contracts, and synthetic native annotation regressions
run in `.github/workflows/windows.yml`. Native tests cover image-space geometry,
selection hit tests, resizing, keyboard edits, undo/redo, editable manifest round
trips, preservation of the original, and exported pixels without capturing a real
window or touching an OpenCode draft.
This is not a substitute for native desktop validation, which has not been run
from the macOS development environment. Before calling Windows support verified:

- Build and run `npm test` on Windows; Swift tests should be skipped there.
- Capture a test app using the shortcut and process-name tool; compare image and
  text with the same window, including selected text and a password test field.
- Test multiple windows, minimized windows, unsupported/blank captures, elevated
  apps, non-ASCII text, mixed-DPI monitors, and shortcut conflicts.
- Start the watcher twice; verify one tray icon and hotkey registration. Quit and
  restart it. Inspect `status.json` if the shortcut does not fire.
- Test Insert with an existing draft, clipboard changes, Settings/dialogs, missing
  Prompt accessibility, and multiple OpenCode windows. Verify **nothing is sent**.
- Cancel a preview and confirm no draft change; use `/capture-studio` for the saved image.
- Draw each object type, select/move/resize/edit it, undo/redo, save, reopen, and
  confirm exported marks agree with the editor on mixed-DPI monitors. Test Cancel
  and clipboard-image annotation, and confirm handles are absent from the PNG.
- Open the composer from the shortcut. Send the same capture to Clipboard and
  Save to folder, then to OpenCode, and confirm each one leaves an unsent result.
  Open Context, compare the preview with the captured window, switch a source off,
  and confirm the switch sticks after reopening a recent capture. Type `@` and
  confirm Enter inserts a skill mention instead of sending.
- Verify the capture-folder ACL and that the tool rejects an external PNG path.
