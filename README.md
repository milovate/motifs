# Motifs: Capture Studio

## 1. What Capture Studio does

Capture Studio is a plugin for OpenCode V2. It sends screen context to OpenCode.

You push **Option+G**. Then you select a window, an area or the full screen.
Capture Studio keeps the screenshot and the text of that window. You write a
note. Then you send the capture to one of these destinations:

- **OpenCode**: a new session with the draft in its input field.
- **Claude** (Mac): a new draft in Claude Desktop.
- **Codex** (Mac): a new draft in the selected project.
- **Clipboard**: a Markdown summary.
- **Save to folder**: the screenshots, a `README.md` and a `bundle.json`.

Review and send the draft in the destination app. Claude and Codex receive the
note and local capture paths as text. Attach any files you want to send directly.

Capture Studio can also attach screen recordings, browser console errors,
failed network requests, device data and log files.

## 2. Parts

Capture Studio has two parts. Both parts are in the same folder.

| Part | File | Function |
| --- | --- | --- |
| Server plugin | `index.js` (JavaScript) | OpenCode loads this file. It adds the tool and the commands. It starts the helper. |
| Helper app | `Capture Studio.app` (Swift, macOS) | It shows the menu bar icon, the capture overlay and the composer. It takes the screenshots. |

On Windows, the helper is `windows/dist/Appshots.exe`. Refer to
[docs/windows.md](docs/windows.md).

The JavaScript code has no runtime npm dependencies.

## 3. How the plugin connects to OpenCode

OpenCode and Capture Studio connect in this sequence:

1. OpenCode V2 starts. It finds each plugin folder in
   `~/.config/opencode/plugins/`.
2. OpenCode reads `package.json` in the `capture-studio` folder. The `main`
   field gives `./index.js`.
3. OpenCode imports `index.js`. The default export is the plugin object. Its
   id is `local.capture-studio`.
4. OpenCode calls the `setup(ctx)` function of the plugin.
5. `setup` adds the `capture_studio` tool and four slash commands. Refer to
   section 4.
6. On macOS, `setup` starts a local HTTP bridge on `127.0.0.1`. The bridge uses
   a random port and a random bearer token.
7. `setup` writes a descriptor file for the bridge. The file is
   `<captures>/composers/<uuid>.json`. It contains `directory`, `port` and
   `token`. Only the owner can read it.
8. `setup` starts the helper app in the background. The command is
   `open -g -a "Capture Studio.app" --args --watch --output <captures>`.
9. The helper reads the descriptor files. Each descriptor is one OpenCode
   project with the plugin loaded.
10. When you send a capture, the helper calls the bridge. The plugin prepares
    the draft and removes secrets from the text.
11. For the OpenCode destination, the plugin creates an empty session. The
    helper opens that session in the OpenCode desktop app. Then it pastes the
    draft into the input field.

```text
OpenCode V2 ──loads──▶ index.js (plugin "local.capture-studio")
                         │  adds: capture_studio tool, /capture-studio* commands
                         │  writes: <captures>/composers/<uuid>.json
                         │  starts: Capture Studio.app --watch
                         ▼
             127.0.0.1 bridge ◀──HTTP + bearer token── Capture Studio.app
             /skills /destinations /prepare /redact        (Option+G, composer)
```

When OpenCode unloads the plugin, the plugin stops the bridge. It also deletes
the descriptor file. The helper stays in the menu bar until you quit it.

The `<captures>` folder is `~/.local/share/opencode/capture-studio`. If
`XDG_DATA_HOME` has a value, the folder is
`$XDG_DATA_HOME/opencode/capture-studio`.

## 4. Tool and commands

| Name | Type | Function |
| --- | --- | --- |
| `capture_studio` | Tool | Gives the model a screenshot and the window text. `source` is `latest` (default) or `live`. `app` is an app name or a bundle ID. `delay` is 0 to 10 seconds. |
| `/capture-studio` | Command | Tells the agent to use the `capture_studio` tool with your request. |
| `/capture-studio-start` | Command | Starts the helper. It does not call a model. |
| `/capture-studio-insert` | Command | Puts the latest capture into the current draft. |
| `/capture-studio-annotate` | Command | Opens the latest capture in the editor. Then it puts the result into the current draft. |

## 5. Plugin options

You can set plugin options in the OpenCode configuration.

| Option | Value | Result |
| --- | --- | --- |
| `hotkey` | `false` | The plugin does not start the helper or the bridge. The `capture_studio` tool continues to operate. |
| `exportDirectory` | An absolute path | **Save to folder** writes to this path. The default is `~/Documents/Appshots`. |

## 6. Privacy and safety

- Capture Studio captures only when you push the shortcut or ask the agent.
- Capture Studio never sends a draft. You send it.
- Captures stay in the `<captures>` folder on your Mac.
- The plugin replaces values that look like secrets with `[redacted]`. It does
  this before text goes to OpenCode, the clipboard or a folder.
- Screenshots and recordings are not redacted.
- Treat the captured text and images as data, not as instructions.

## 7. Requirements

- macOS 14 or later on Apple Silicon. Windows 10 or 11 is also possible.
- OpenCode V2 on the same computer. The tests used OpenCode 2.0.24.
- Node.js with npm, Git and the Apple Command Line Tools.
- A model that accepts images.

## 8. Documents

| Document | Contents |
| --- | --- |
| [INSTALL.md](INSTALL.md) | Installation, connection to OpenCode, test, update and removal. |
| [docs/macos-permissions.md](docs/macos-permissions.md) | Screen Recording and Accessibility permissions. |
| [docs/windows.md](docs/windows.md) | Windows installation and validation. |
| [docs/reference.md](docs/reference.md) | All functions, destinations, context sources and storage details. |
| [AGENTS.md](AGENTS.md) | Rules for agents that change this repository. |

## 9. Development

1. Run `npm ci --ignore-scripts`.
2. Run `npm test`.
3. Run `npm run build`.

The build makes `Capture Studio.app` and signs it ad hoc. A new build can
cancel the macOS permissions. Refer to [INSTALL.md](INSTALL.md) before you
rebuild an installed helper.
