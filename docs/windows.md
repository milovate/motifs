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

**Control+Alt+Shift+R** starts a screen recording. The same chooser appears: drag a
region, click a window, or press Enter for the display under the pointer. Escape
cancels before anything is written. There is no audio. A floating bar shows the
time, **Restart**, **Pause**, and **Stop**. The time turns orange in the last 30
seconds, and the recording stops at 5 minutes. Pause time is kept out of the clip.
Restart discards what was recorded and starts again. Stop writes an H.264 MP4 plus
key-frame PNGs into the captures folder and attaches the clip to the open composer,
or opens a composer when none is open. Nothing is sent. A composer holds 3 clips.
The bar and the dashed area outline set display affinity and are hidden while each
frame is grabbed. An area recording shows that outline just outside the rectangle. A window
recording follows that window's rectangle; unlike a still window capture, it is the
visible pixels there, so overlapping windows can appear. Click a clip in the
composer to review it. The filmstrip has yellow handles; drag them, or press
**I** and **O**, to choose at least half a second. **Space** plays that selection
and the arrow keys step. **Use trimmed clip** writes a new MP4 and takes key
frames from the selection. The original file stays in the captures folder.
**Remove clip** detaches it and leaves the file. Nothing is sent.

**Keep instant replay (last 30 s)** stays off until you turn it on from the tray.
The choice is saved in `settings.json` and restored the next time the watcher
starts. While it is on, Capture Studio keeps the last 30 seconds of the display
under the pointer in memory: about 8 frames a second, long side at most 1280
pixels, and at most 150 MB. **Ctrl+Alt+Shift+A** copies that buffer before the
chooser opens. After you confirm a screenshot, it writes an H.264 MP4 plus key
frames and attaches the clip with the screenshot. Cancelling the chooser leaves
the buffer in memory. Turning replay off or quitting the watcher discards it.
The sample is visible pixels. Capture Studio windows set display affinity so capture
APIs that honor it leave them out. The recording bar and the area outline are also
hidden for each frame grab. There is no audio. Sampling pauses while the chooser is open and while a
screen recording is in progress.

**Record recent clicks** stays off until you turn it on from the tray. While it
is on, the last 10 minutes of clicks and app switches stay in memory (300 at
most). A screen recording collects steps even when that item is off: clicks,
scrolls, drags, selected text (up to 200 characters), and which field you typed
into. The key you pressed is never stored. Password fields keep only their role.
Clicks on Capture Studio itself are left out. Quitting the watcher, or turning
the item off while nothing is recording, discards the memory buffer.

**Custom log files** in the tray accepts up to 4 files. A capture reads the last
64 KB of each regular file at that moment. The paths are saved in `settings.json`.
What is sent includes the file name and the tail, not a live watch.

**Show composer button** is on by default. While the capture chooser is open, a
small button sits above the hint. Clicking it closes the chooser and opens an
empty composer. Its menu can hide it. The chooser closes before any screenshot
is taken, so the button is not in the image.

**Dictate** in the composer uses a Windows speech language installed on this PC.
It does not save audio and it does not send audio to a cloud recognizer. Stop
leaves the transcript in the note for you to edit. Send stays disabled until
dictation stops. If no speech language is installed, the button says so.

**Connect browser extension…** writes one native messaging host manifest and
registers it for each installed copy of Chrome, Chrome Canary, Brave, Edge,
Chromium, or Arc, then reveals the `browser-extension` folder. Load that folder as an unpacked
extension, then reload the tabs you want to debug. A capture of that browser
window asks for the visible tab's console messages and failed requests. A
screen recording asks the extension to record page steps and collects them
when the recording stops. The helper and the host accept only each other:
the peer must be this same `Appshots.exe`. Nothing is written to disk on the way.

**Local secret-check model…** saves an `http://127.0.0.1`, `localhost`, or `::1`
address and an optional model name. Hosted addresses are ignored. Save and test
asks that address to score one sample value. Known secret formats are still
redacted without a model, and values that only might be secrets are redacted
when the model does not answer.

The tray icon is the capture frame and speech bubble. A filled dot means a recording is in progress, a ring means instant replay is on, a small dot means the last capture succeeded, and a mark in the bubble means the shortcut or a capture failed. The strokes are black on a light taskbar and white on a dark one.

The tray menu follows the macOS menu. **Recent bundles** reopens a saved capture.
**Default destination** chooses OpenCode, Clipboard, Save to folder, or another
destination the composer has seen. **Context sources** holds instant replay,
recent clicks, log files, the browser extension, and the local secret-check model.
**Capture, annotate, and insert into current draft** captures the focused window,
opens the editor, and inserts when you choose **Insert into OpenCode**.
**Capture and insert without annotation** captures that window and inserts it.
**Insert latest capture into OpenCode** inserts the saved capture and does not
open the editor. **Annotate latest capture** and **Annotate clipboard image**
open the editor. The tray can also open an empty composer, start or stop a
recording, show the composer button, open the captures folder, or quit the watcher.
`/capture-studio-insert` inserts the latest capture into the current draft.
`/capture-studio-annotate` opens that capture in the editor.
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
after creating a mark. **Crop** is separate: drag a rectangle, then apply it.

- **Select** an object by clicking its stroke, or the body of a text label. Drag to
  move it. Drag corner handles to resize a box, freehand path, or text label; arrow
  handles adjust endpoints. Coordinates and stroke widths are in original image
  pixels, independent of window resizing, image zoom-to-fit, or letterboxing.
- Double-click text, press Return with text selected, or click **Edit text** to edit.
- Delete removes the selection. Ctrl+D duplicates it. Arrow keys nudge by one image
  pixel; Shift+arrow moves ten. Ctrl+Z undoes, Ctrl+Y or Ctrl+Shift+Z redoes. History
  includes creation, movement, resizing, style changes, text edits, deletion, crop, and reset.
- **Crop** (C) drags a rectangle in original image pixels. **Apply Crop** or Enter
  keeps it. The editor then shows only that rectangle, and the saved PNG contains
  only those pixels. Marks stay where you drew them; they are not flattened or
  moved. **Reset Crop** restores the full image. **Cancel Crop**, or Escape, drops
  the rectangle you are dragging and returns to Select. A pending crop is applied
  when you save or insert. The long side of a saved image is at most 2560 pixels.
- A crop omits the original window's accessibility text from delivery and records
  `Cropped screenshot: original-window accessibility text is omitted so content outside the crop is not shared.`
  The text remains in the capture file for Reset Crop. Resetting removes that warning
  and restores the text.
- **Copy image** (Ctrl+C), or right-clicking an empty part of the image, copies the
  annotated and cropped PNG. It does not insert a draft. Right-clicking a mark
  offers edit, duplicate, and delete.
- V selects; A, R, P, T, and C choose Arrow, Box, Draw, Text, and Crop. Escape first
  cancels a pending crop, then clears a selection; with neither, it closes the editor
  without saving current edits.
- **Save only** saves the annotated image and editable objects without inserting.
  **Insert into OpenCode** saves and then pastes, leaving the draft unsent. Neither
   action sends a message. Cancel discards unsaved changes. If an earlier Insert
   attempt failed, its saved annotations remain available even after Cancel.

Saving creates a new PNG with marks flattened into the pixels and updates
`latest.json`. It preserves the original PNG and timestamp. Accessibility text
describes the original capture, not the drawn labels. A crop leaves that text
out of the delivered capture, as described above. Reopening a saved capture
restores editable Windows objects and the crop over the original image with fresh
undo history. Selection outlines, handles, and crop shading are never exported.
Images without editable
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
- Screen recording also captures visible pixels, including a clicked window's
  rectangle, and does not record audio. It stops at 5 minutes. The control bar and
  the dashed area outline are hidden for each frame grab. Capture Studio windows
  set display affinity so capture APIs that honor it leave them out.
- Instant replay is off by default. While the tray item is checked, the last 30
  seconds of the display under the pointer stay in memory, capped at 150 MB. A
  confirmed capture writes that buffer. Cancelling the chooser leaves it in
  memory. The sample is visible pixels and can include Capture Studio's own
  windows. There is no audio.
- Record recent clicks is off by default. The buffer is memory only. Screen
  recordings add scrolls, drags, selections, and the field that received typing.
  Key codes and typed characters are not recorded. Secure fields keep their role
  and lose their label, and a selection inside one is dropped. Custom logs are
  read only for files you chose, and only the last 64 KB when you capture.
- The browser extension is registered only from **Connect browser extension…**.
  Console messages, failed requests, and page steps stay in the browser until a
  capture or the end of a recording asks for them. The named pipe allows the
  current user and SYSTEM, and the helper refuses any peer that is not
  `Appshots.exe`.
- The composer button is on by default and only appears over the capture chooser.
  Hiding it is saved. Dictate uses the installed Windows speech language, keeps
  no audio file, and has no cloud fallback. The secret-check model must be an
  address on this PC; a hosted address in `settings.json` is ignored.
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
SYSTEM. The plugin does the same for the composer endpoint file, the context file
beside a bundle, and a Save to folder export. PNG files and `latest.json` persist until you delete them; cancellation
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
  **Insert latest capture** pastes without opening the editor. **Capture and insert
  without annotation** captures the focused window and pastes it. **Capture,
  annotate, and insert** opens the editor first.
- Cancel a preview and confirm no draft change; use `/capture-studio` for the saved image.
- Draw each object type, select/move/resize/edit it, undo/redo, save, reopen, and
  confirm exported marks agree with the editor on mixed-DPI monitors. Crop with C,
  apply, and confirm the PNG is only that rectangle and the window text is omitted
  from the draft. Reset Crop and confirm the text returns. Copy image, then paste
  somewhere other than OpenCode. Test Cancel and clipboard-image annotation, and
  confirm handles are absent from the PNG.
- Open the composer from the shortcut. Send the same capture to Clipboard and
  Save to folder, then to OpenCode, and confirm each one leaves an unsent result.
  Open Context, compare the preview with the captured window, switch a source off,
  and confirm the switch sticks after reopening a recent capture. Type `@` and
  confirm Enter inserts a skill mention instead of sending.
- Record a short display clip with **Control+Alt+Shift+R**. Pause, restart, and
  stop. Confirm the MP4 and key frames appear in the composer and the control bar
  and dashed outline are absent from those frames. Escape on the bar discards the clip. Confirm nothing
  is sent. Reopen the capture from Recents. Click the clip, trim it with the
  yellow handles, and choose **Use trimmed clip**. Confirm a second MP4 appears
  and the original file is still in the captures folder.
- Turn on **Keep instant replay (last 30 s)**, wait a few seconds, and capture.
  Confirm the composer shows the screenshot and an instant-replay clip. Cancel
  the chooser and confirm the captures folder gains no replay MP4. Turn replay
  off and confirm the tray tooltip returns to the capture shortcut.
- With **Show composer button** on, start a capture and click the round button.
  Confirm the composer opens and the captures folder gains no new screenshot.
  Hide the button from its menu and confirm the next chooser has none.
- Click **Dictate**, speak, then **Stop**. Confirm the words are in the note and
  nothing was sent. With no speech language installed, confirm the button explains
  that instead of sending audio anywhere.
- Choose **Connect browser extension…**, load the unpacked extension, reload a
  tab, and capture that browser window. Confirm Context shows the page and its
  console errors, and that cancelling the chooser adds nothing. Record a short
  clip while clicking a button on the page and confirm the step names the button
  and not a keystroke.
- Choose **Local secret-check model…**, enter `http://127.0.0.1:8000`, and save.
  Confirm a hosted address is refused. Turn it off afterward if you were only testing.
- Turn on **Record recent clicks**, click another app, and capture. Confirm
  Context shows the click and not a keystroke. Turn it off and confirm a new
  capture has no leftover steps. Add a log file, capture, and confirm Context
  shows only the tail of that file. Remove the log file afterward.
- Record a short clip, click and scroll in another app while it runs, then stop.
  Confirm Context lists those steps and the clip. Confirm the recording bar's
  own buttons are not listed.
- Verify the capture-folder ACL and that the tool rejects an external PNG path.
