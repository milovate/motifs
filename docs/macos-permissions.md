# macOS permissions

Appshots needs two separate macOS permissions. Only the user can approve them.
OpenCode's tool approval is separate and does not grant macOS access.

| Permission | Used for | Without it |
| --- | --- | --- |
| Screen Recording / Screen & System Audio Recording | Screenshot of the requested app window | Screenshot capture fails with setup instructions |
| Accessibility | Read the selected window's UI text and insert an attachment into OpenCode's draft | Screenshot-only results; automatic insertion is unavailable |

The settings name varies by macOS version. Despite the setting's name, Appshots
does not record audio. It does not need Full Disk Access or Input Monitoring.

## 1. Build and find the helper

Complete the [installation](../README.md#installation) first. For the default path:

```sh
open -R "$HOME/.config/opencode/plugins/appshots/OpenCode Appshots.app"
```

Finder reveals **OpenCode Appshots.app**. Keep it at the path where it was built:
the plugin expects the helper inside its own directory.

## 2. Enable screen capture

1. Open Apple menu → **System Settings** → **Privacy & Security**.
2. Select **Screen Recording** or **Screen & System Audio Recording**.
3. Enable **OpenCode Appshots** if listed. Otherwise use **+** to add it.
4. In the file picker press **Command+Shift+G**, enter
   `~/.config/opencode/plugins/appshots/`, and select **OpenCode Appshots.app**.
5. Approve the change, authenticating if macOS requests it. Follow any quit/reopen prompt.

If macOS attributes a direct command-line capture to **OpenCode** or the terminal
that launched it, approve only that responsible app as needed. Do not grant
permissions indiscriminately to every terminal or executable.

## 3. Enable Accessibility

1. Return to **Privacy & Security** → **Accessibility**.
2. Add the same **OpenCode Appshots.app** with **+**, then enable its switch.
3. Authenticate if prompted.

Accessibility is powerful: it allows the helper to inspect UI and send paste
keystrokes to OpenCode. Grant it only after reviewing and trusting this code.

## 4. Restart and verify

1. Choose **Appshot → Quit Appshots** if the helper is already running.
2. In an OpenCode conversation, run `/appshots-start`. Alternatively:

   ```sh
   open "$HOME/.config/opencode/plugins/appshots/OpenCode Appshots.app"
   ```

3. Confirm **Appshot** appears in the menu bar.
4. Focus a non-sensitive test window and press **Control+Option+Command+A**.
5. In the annotation editor, click **Insert**. Confirm the screenshot and window
   text appear in the OpenCode draft. The helper does **not** send the message.
6. Review the attachment and text before sending anything to a model.

For helper-side diagnostics, inspect the local file:

```sh
cat "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/appshots/status.json"
```

`screenRecording` and `accessibility` reflect permission checks. Both
`hotkeyStatus: 0` and `hotkeyHandlerStatus: 0` mean the shortcut registered, not
that a physical key press reached it. `shortcutCount` should increase when you
press the shortcut; phase `inserted` confirms insertion into a draft.
Do not publish capture manifests, screenshots, or UI text as diagnostics.

## Troubleshooting

- **Switches enabled but still denied after rebuilding:** the local code signature
  changed. Quit Appshots, remove its old entry from both permission lists, add the
  newly built `.app`, enable it again, and restart the helper. Restarting only
  OpenCode does not restart an existing helper.
- **No slash commands:** check the plugin path and build, then reload OpenCode or
  restart its shared service with `opencode service restart`. Do not use V1.
- **No menu-bar helper:** run `/appshots-start`; verify the built helper exists.
- **Shortcut does nothing:** check for shortcut conflicts. Try the capture action
  in the Appshot menu. Inspect `shortcutCount` rather than assuming registration
  proves delivery.
- **Screenshot but little/no text:** confirm Accessibility permission. Some apps
  expose limited accessibility trees even with permission. Secure fields are
  omitted from the text dump, but anything visible can still appear in the image.
- **Draft insertion fails:** open a conversation in the OpenCode desktop app, not
  Settings or a modal dialog. Use **Appshot → Insert latest capture into OpenCode**
  or `/appshots-insert`. The terminal UI is not the automatic insertion target.
- **Managed Mac prevents approval:** ask your organization's administrator; do not
  edit the TCC database, disable SIP, or try to bypass system policy.

## Privacy and revocation

Captures are stored locally under `$XDG_DATA_HOME/opencode/appshots`, or
`~/.local/share/opencode/appshots`. Earlier PNGs remain after a new capture;
review/remove them through **Appshot → Open captures folder**. Captures pasted
into OpenCode also enter its attachment store. Draft insertion does not send a
message, but sending the draft or invoking the agent tool exposes the returned
image/text to the selected model/provider.

To revoke access, quit Appshots and turn off/remove its entries in both permission
lists. Remove or disable the plugin separately to stop future helper launches.

## Official references

- [Apple: control screen and system audio recording](https://support.apple.com/guide/mac-help/control-access-to-screen-and-system-audio-recording-mchld6aa7d23/mac)
- [Apple: allow Accessibility apps to access your Mac](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac)
- [OpenCode V2 plugin discovery and reload](https://opencode.ai/v2/docs/plugins/)
