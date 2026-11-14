# Local releases

For a release PR, run `npm version X.Y.Z --no-git-tag-version` to update
`package.json` and `package-lock.json` together. Increase `macosBuildNumber`
in `package.json` above the previous macOS release build number. After building
on macOS or Windows, run `npm run verify:version` to check the helper's metadata
against `package.json`.

From a clean checkout, run `npm run build` followed by `npm run package:local`
to make a versioned ZIP in `dist/` for Apple Silicon macOS or x64 Windows.
The ZIP contains the OpenCode plugin and its native helper. On macOS the same
command also makes `motifs-<version>-macos-arm64.dmg`. The DMG's volume is
named `Motifs` and holds the `motifs` plugin folder and
[`Install Motifs.txt`](../packaging/macos/Install%20Motifs.txt), which refers to
`/Volumes/Motifs`. The local macOS build uses ad hoc signing. See [INSTALL.md](INSTALL.md#9-procedure-update-the-plugin)
for how to upgrade a ZIP installation.

Run `npm run release:check` on Apple Silicon macOS and x64 Windows to check a
release candidate locally. Check out the same commit on both machines. The
command builds, tests, and packages `HEAD` in a temporary checkout. It extracts
the ZIP and checks the plugin entry point, helper version, and architecture.
On macOS it also mounts the DMG and runs the same checks on its plugin folder.
Each run saves the packages, a `.sha256` checksum file for each, and a `release-check.json`
report in `dist/` with the commit, platform, version, and test counts. Run the Windows desktop checks in
[docs/windows.md](docs/windows.md) with the resulting Windows package.
From a checkout of the same commit, run `npm run release:verify -- <macOS check directory> <Windows check directory>`
to confirm both reports and ZIPs match that commit and version.

Once the desktop checks pass, run `npm run release:check -- --sign` on each
platform to sign the helper before packaging. On macOS, set
`MOTIFS_MACOS_TEAM_ID`, `MOTIFS_MACOS_SIGNING_IDENTITY` to the Developer ID
Application identity, and `MOTIFS_MACOS_NOTARY_PROFILE` to an existing
`notarytool` keychain profile. On Windows, put the Windows SDK's `signtool.exe`
on `PATH` and set `MOTIFS_WINDOWS_SIGNING_THUMBPRINT` to the local certificate's
thumbprint and `MOTIFS_WINDOWS_TIMESTAMP_URL` to its RFC 3161 timestamp service.
The command checks signatures after extracting the ZIP and records `signed: true`
in the report after those checks pass. Pass `--signed` before the two directories
when running `npm run release:verify` to require signed reports for both packages.
On macOS, `--sign` also signs, notarizes, and staples the DMG.

## Publish on GitHub

1. Point the README download links at the new version and merge the release
   PR into `main`.
2. Run `npm run release:check` on both platforms from that `main` commit.
3. From the same commit, run
   `npm run release:publish -- <macOS check directory> <Windows check directory>`.

The command repeats `release:verify`, refuses a commit that is not on
`origin/main`, a README that links another version, and an existing tag. It
then uses `gh release create` to tag `v<version>` and upload the DMG, both ZIPs,
and a combined `SHA256SUMS`. Without `--signed`, the release is a pre-release
titled "preview" with notes on approving unsigned helpers.
`/motifs-update` only offers stable releases, so it ignores previews.
Pass `--signed` before the directories to publish signed checks as a stable
release.
