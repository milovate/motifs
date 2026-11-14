# macOS permissions

Motifs needs Screen Recording and optionally Accessibility. Dictation adds two
optional permissions. Only the user can approve them.
OpenCode's tool approval is separate and does not grant macOS access.

| Permission | Used for | Without it |
| --- | --- | --- |
| Screen Recording / Screen & System Audio Recording | Screenshot of the requested app window; instant replay and screen recording of the main display, only when you turn them on | Screenshot capture, replay and recording fail with setup instructions |
| Accessibility | Read the selected window's UI text, insert an attachment into OpenCode's draft, and observe clicks, scrolls, highlighted text and which field was typed into with the element's role/label (during screen recordings, or clicks only when you turn on **Record recent clicks**; typed characters are never read) | Screenshot-only results; automatic insertion and recorded steps are unavailable |
| Microphone | Listen only after clicking Dictate | Type the description instead |
| Speech Recognition | On-device voice-to-text in the composer | Type or use macOS keyboard dictation instead |

The settings name varies by macOS version. Screen capture, instant replay and screen
recording never record system audio or the microphone. Dictate processes microphone audio only while enabled, saves no audio file,
and requires on-device recognition support; no cloud fallback is used. It does not
need Full Disk Access or Input Monitoring. Denying voice permissions does not block
typing. Microphone and Speech Recognition prompts appear only after clicking Dictate.

Context collection needs no further permissions. Reading the captured app's
errors from the unified log uses `/usr/bin/log` as your user; macOS keeps private
values redacted. Custom log files are read only if you choose them, and only files
your user can already read. The browser extension needs no macOS permission; the
browser itself asks you to allow the unpacked extension. Values that look like
secrets are replaced with `[redacted]` before captured text leaves the Mac; an
optional secret-check model must run on this Mac (see the reference's [Secret redaction](reference.md#secret-redaction)
section). Screenshots and recordings are not redacted.

## Open a downloaded preview

Preview releases are not signed with an Apple Developer ID or notarized by
Apple. The first time you open Motifs from a download, macOS shows
**"Motifs" Not Opened: Apple could not verify "Motifs" is free of malware…**
Approve it once:

1. Click **Done**. Do not click **Move to Trash**.
2. Open Apple menu → **System Settings** → **Privacy & Security**.
3. Scroll down to **Security**. Next to **"Motifs" was blocked to protect your
   Mac**, click **Open Anyway**.
4. Enter your password or use Touch ID.
5. Open **Motifs** from Applications again. If macOS asks once more, click **Open**.

**Open Anyway** appears for about an hour after the blocked launch. If you don't
see it, open Motifs again and go back to step 2. Approve only a download from
[the Motifs releases page](https://github.com/milovate/motifs/releases) whose
checksum matches the release's `SHA256SUMS` (`shasum -a 256 <file>`). You don't
need to do this for a build you made yourself with `npm run build`.

## 1. Find the helper

Complete the [installation](../INSTALL.md) first. If you installed from the DMG,
the helper is **Motifs** in Applications, and the plugin folder links to it. For
a Git or ZIP installation at the default path:

```sh
open -R "$HOME/.config/opencode/plugins/motifs/Motifs.app"
```

Finder reveals **Motifs.app**. The app's display name is **Motifs**.
In a Git or ZIP installation, keep it inside the plugin directory.

From the Motifs menu bar, choose **Permission setup**. Select **Set up** next to
the permission you want. Drag the Motifs app tile into the permission list, then
turn it on. If it is already listed, use its switch.
You can also choose **Show in Finder** and add the app with **+** in System
Settings. Follow any macOS prompt to quit and reopen the helper. The guide
refreshes the status as macOS makes the grant available.

## 2. Enable screen capture

1. Open Apple menu → **System Settings** → **Privacy & Security**.
2. Select **Screen Recording** or **Screen & System Audio Recording**.
3. Enable **Motifs** if listed. Otherwise use **+** to add it.
4. In the file picker press **Command+Shift+G**, enter
   `~/.config/opencode/plugins/motifs/`, and select **Motifs.app**.
5. Approve the change, authenticating if macOS requests it. Follow any quit/reopen prompt.

If macOS attributes a direct command-line capture to **OpenCode** or the terminal
that launched it, approve only that responsible app as needed. Do not grant
permissions indiscriminately to every terminal or executable.

## 3. Enable Accessibility

1. Return to **Privacy & Security** → **Accessibility**.
2. Add the same **Motifs.app** with **+**, then enable its switch.
3. Authenticate if prompted.

Accessibility is powerful: it allows the helper to inspect UI and send paste
keystrokes to OpenCode. Grant it only after reviewing and trusting this code.

## 4. Restart and verify

1. Choose **Motifs → Quit Motifs** if the helper is already running.
2. In an OpenCode conversation, run `/motifs-start`. Alternatively:

   ```sh
   open "$HOME/.config/opencode/plugins/motifs/Motifs.app"
   ```

3. Confirm **Motifs** appears in the menu bar.
4. Press **Option+G** and click a non-sensitive test window in the dimmed overlay.
5. Confirm the floating composer opens with a screenshot, a **Context** chip, the
   destination and target selectors, and an empty note (no skill is added automatically). Close it
   without sending to verify cancellation. Optionally choose **Clipboard** and send to
   confirm Markdown is copied and nothing is pasted.
6. To test legacy insertion without a model call, choose **Motifs → Capture,
   annotate, and insert into current draft**, then click **Insert**. Confirm the
   screenshot and window text appear in the unsent OpenCode draft.
7. Test Dictate only if desired. Stop and review the transcript before continuing.
   **↗ Continue** opens a new session with an unsent draft; it never runs the model.
   Only the user's own Enter/Send in OpenCode submits that draft.

For helper-side diagnostics, inspect the local file:

```sh
cat "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/motifs/status.json"
```

`screenRecording` and `accessibility` reflect permission checks. Both
`hotkeyStatus: 0` and `hotkeyHandlerStatus: 0` mean the shortcut registered, not
that a physical key press reached it. `shortcutCount` should increase when you
press the shortcut; phase `inserted` confirms insertion into a draft.
Do not publish capture manifests, screenshots, or UI text as diagnostics.

## Troubleshooting

- **Switches enabled but still denied after rebuilding:** the local code signature
  changed. Quit Motifs, remove its old entry from both permission lists, add the
  newly built `.app`, enable it again, and restart the helper. Restarting only
  OpenCode does not restart an existing helper.
- **No slash commands:** check the plugin path and build, then reload OpenCode or
  restart its shared service with `opencode service restart`. Do not use V1.
- **No menu-bar helper:** run `/motifs-start`; verify the built helper exists.
- **Shortcut does nothing:** check for shortcut conflicts. Try the capture action
  in the Motifs menu. Inspect `shortcutCount` rather than assuming registration
  proves delivery.
- **Screenshot but little/no text:** confirm Accessibility permission. Some apps
  expose limited accessibility trees even with permission. Secure fields are
  omitted from the text dump, but anything visible can still appear in the image.
- **Draft insertion fails:** open a conversation in the OpenCode desktop app, not
  Settings or a modal dialog. Use **Motifs → Insert latest capture into OpenCode**
  or `/motifs-insert`. The terminal UI is not the automatic insertion target.
- **Managed Mac prevents approval:** ask your organization's administrator; do not
  edit the TCC database, disable SIP, or try to bypass system policy.

## Privacy and revocation

Captures are stored locally under `$XDG_DATA_HOME/opencode/motifs`, or
`~/.local/share/opencode/motifs`. Earlier PNGs remain after a new capture;
review/remove them through **Motifs → Open captures folder**. Captures pasted
into OpenCode also enter its attachment store. The composer only prepares a handoff:
an unsent OpenCode draft, Markdown on the clipboard, or an owner-only export folder.
Dictation never sends. The composer keeps an owner-only `bundle-*.json` for each
capture, saved as you edit so Recents can reopen it, holding your
description, window text, collected context (device and system state, console and
failed-request entries, steps recorded during a screen recording or recent clicks if
enabled, custom log tails; never location, typed text or which keys were pressed) and
include flags; delete these files to remove recent bundles. Steps and recent clicks
live only in the helper's memory until a capture copies them into the composer;
recording-only steps are dropped when the recording ends. The browser extension's
buffers and page steps live only in the browser's session memory, and it records page
steps only between the start and stop of a screen recording. Browser context travels only over an owner-only socket in
`~/Library/Application Support/Motifs/browser/` between two copies of the
same signed Motifs binary; each side refuses any other process.

Nothing is recorded unless you turn on **Keep instant replay** or start a screen
recording and pick what to record; macOS shows its screen-recording indicator whenever either
is running. The instant replay buffer holds only the last 30 seconds of the display,
in memory, and is written to disk only when you press Option+G. A screen recording
captures only what you picked in the overlay (one window, a dragged area, or the whole screen), leaves
paused time out, and stops after 5 minutes. MP4s, trimmed copies and key frames are
saved owner-only in the captures folder; OpenCode receives up to six key frames as
images plus the file paths, and only when you send. Once you submit, the agent can open
the MP4 and the context file from those paths. Motifs' own windows are excluded, but everything
else in the recorded display or area, including notifications and other apps'
content, can appear in the video. Turn replay off before showing sensitive content.

The helper is signed with the hardened runtime and only the microphone
entitlement, so another process cannot inject code into it to use its Screen
Recording or Accessibility grants. That does not protect files: anything running
as your user can still read the captures folder, so delete captures you no longer need. Endpoint files in the
local `composers/` subfolder contain authentication tokens: do not publish them.
Draft insertion does not send a
message, but sending the draft or invoking the agent tool exposes the returned
image/text to the selected model/provider.

The Add screenshot picker dims displays without saving whole-screen snapshots;
only the region confirmed by a drag is captured. Escape or switching away cancels
the picker. Region captures contain no accessibility dump. Cropped exports omit
the original window's accessibility text, but the clean original image and original
context remain in the private local capture history for non-destructive re-editing.
Removing a thumbnail detaches it from the draft; it does not erase saved capture files.

To revoke access, quit Motifs and turn off/remove its entries in Screen Recording,
Accessibility, Microphone, and Speech Recognition as applicable. Turn off
**Keep instant replay** and **Record recent clicks**, remove custom log files from the menu, and remove the
browser extension plus the `local.motifs.json` native messaging
manifests to stop the other context sources. Remove or disable
the plugin separately to stop future helper launches and its local composer bridge.

## Official references

- [Apple: control screen and system audio recording](https://support.apple.com/guide/mac-help/control-access-to-screen-and-system-audio-recording-mchld6aa7d23/mac)
- [Apple: allow Accessibility apps to access your Mac](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac)
- [OpenCode V2 plugin discovery and reload](https://opencode.ai/v2/docs/plugins/)
