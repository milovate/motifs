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

1. Run `/capture-studio-start` if the Appshots system tray icon is missing.
2. Focus a non-sensitive test window and press **Control+Alt+Shift+A**.
3. Review and annotate the screenshot in the editor (see below). **Cancel** closes
   it without inserting or sending anything. Escape clears a selection first,
   then closes the editor. The capture remains saved locally.
4. **Insert into OpenCode** saves the annotations, then attempts to focus the
   desktop app's `Prompt` input,
   append the screenshot and text, and leave the draft unsent. Have exactly one
   OpenCode conversation window open. Review both the attachment and draft text.
   Insertion never presses Return or clicks Send, and does not replace the draft.
   Clipboard restoration is best effort and will not overwrite a newer user copy.
5. Add your question and send when ready. If insertion fails, use `/capture-studio` in
   the intended conversation to retrieve the saved screenshot and text instead.

The tray menu can review/reinsert or annotate the latest capture, annotate a
clipboard image, open the captures folder, or quit the watcher.
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

- Captures only the selected top-level window using `PrintWindow`. There is no
  desktop-crop fallback that could include overlapping unrelated windows.
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

Storage defaults to `%LOCALAPPDATA%\opencode\appshots`, overridable with
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
- Verify the capture-folder ACL and that the tool rejects an external PNG path.
