<p align="center">
  <img src="assets/AppIcon.png" alt="" width="88" height="88">
</p>
<h1 align="center">Motifs</h1>
<p align="center">Screenshots, recordings, and app context for OpenCode V2.</p>
<p align="center">
  <a href="INSTALL.md">macOS setup</a> ·
  <a href="docs/windows.md">Windows setup</a> ·
  <a href="docs/reference.md">Reference</a>
</p>

Motifs gives OpenCode a screenshot or recording of what you’re working on, with
the context you choose to include. Capture a bug, mark up the image, add a note,
and review the draft in OpenCode before sending it.

## Capture and share

- **Capture a window, region, or display.** Press <kbd>⌥</kbd> <kbd>G</kbd> on
  Mac, choose what to capture, and annotate or crop the screenshot.
- **Record a reproduction.** Press <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>G</kbd> on Mac
  to record the steps leading up to a bug.
- **Choose the context.** Include window text, browser console errors, failed
  requests, device details, or selected logs. Preview the context before sharing.
- **Choose where it goes.** Open an unsent OpenCode draft, copy a Markdown
  summary, or save a self-contained folder with the capture and context.

## Get started

Motifs runs alongside the **OpenCode V2 desktop app** on the same computer.

| Platform | Requirements | Setup |
| --- | --- | --- |
| macOS | Apple Silicon, macOS 14 or later | [Install Motifs](INSTALL.md) and [grant capture permissions](docs/macos-permissions.md) |
| Windows | Windows 10 or 11 in a local desktop session | [Build and set up the Windows helper](docs/windows.md) |

After setup, run `/capture-studio-start` in OpenCode if the helper isn’t running.
Use `/capture-studio` when you want OpenCode to use a saved capture, or
`/capture-studio-annotate` to edit it first. See the
[command and capture reference](docs/reference.md) for the full workflow.

## Privacy

Captures and settings are stored locally. Motifs leaves OpenCode drafts unsent.
It redacts text that matches known secret formats before preparing a handoff.
Review screenshots and recordings before sharing because their pixels can still
contain sensitive information.

## Development

```sh
npm ci --ignore-scripts
npm run build
npm test
```

The JavaScript plugin has no runtime npm dependencies. See
[AGENTS.md](AGENTS.md) for contributor instructions.
