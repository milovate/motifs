import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { checksumLine } from "./release-check.js";
import { repository } from "../updates.js";

const root = fileURLToPath(new URL("../", import.meta.url));

export function releaseAssets(reports) {
  const mac = reports.find(({ report }) => report.target === "macos-arm64");
  const windows = reports.find(({ report }) => report.target === "windows-x64");
  if (!mac || !windows) throw new Error("Publish needs one macOS arm64 and one Windows x64 release check.");
  return [
    { directory: mac.directory, name: mac.report.diskImage.name, sha256: mac.report.diskImage.sha256 },
    { directory: mac.directory, name: mac.report.archive, sha256: mac.report.sha256 },
    { directory: windows.directory, name: windows.report.archive, sha256: windows.report.sha256 },
  ];
}

export function releaseNotes({ version, commit, signed, assets }) {
  const download = name => `https://github.com/${repository}/releases/download/v${version}/${name}`;
  const [dmg, macZip, windowsZip] = assets.map(asset => asset.name);
  const lines = [`## Motifs ${version}`, ""];
  if (!signed) {
    lines.push("**Preview.** These packages are not signed with an Apple Developer ID or a Windows code-signing certificate.", "");
  }
  lines.push(
    "Motifs currently runs as an OpenCode V2 plugin with a native helper, so each download contains the plugin folder.",
    "",
    "| Platform | Download | Install |",
    "| --- | --- | --- |",
    `| macOS (Apple silicon, 14+) | [DMG](${download(dmg)}) · [ZIP](${download(macZip)}) | Open the DMG and follow \`Install Motifs.txt\`. |`,
    `| Windows x64 (10 or 11) | [ZIP](${download(windowsZip)}) | Extract the \`motifs\` folder and follow [Windows setup](https://github.com/${repository}/blob/v${version}/docs/windows.md). Needs the .NET 8 Desktop Runtime. |`,
    "",
  );
  if (!signed) {
    lines.push(
      "On macOS, approve the helper once: after the first launch is blocked, open **System Settings → Privacy & Security** and click **Open Anyway**.",
      "On Windows, SmartScreen may say \"Windows protected your PC\". Choose **More info → Run anyway** only for a download whose checksum matches `SHA256SUMS`.",
      "",
    );
  }
  lines.push(`Built and checked locally from [\`${commit.slice(0, 12)}\`](https://github.com/${repository}/commit/${commit}).`);
  return lines.join("\n") + "\n";
}

function git(...args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
}

function main() {
  const args = process.argv.slice(2);
  const signed = args[0] === "--signed";
  const directories = signed ? args.slice(1) : args;
  if (directories.length !== 2) {
    throw new Error("Run npm run release:publish -- [--signed] <macOS check directory> <Windows check directory>.");
  }
  const verify = spawnSync(process.execPath, [path.join(root, "scripts", "verify-release-pair.js"), ...args], { cwd: root, stdio: "inherit" });
  if (verify.status !== 0) throw new Error("The release checks do not match this commit.");

  const commit = git("rev-parse", "HEAD");
  const { version } = JSON.parse(git("show", `${commit}:package.json`));
  git("fetch", "--quiet", "origin", "main");
  if (spawnSync("git", ["merge-base", "--is-ancestor", commit, "origin/main"], { cwd: root }).status !== 0) {
    throw new Error(`Merge ${commit.slice(0, 12)} into origin/main before publishing it.`);
  }
  if (!git("show", `${commit}:README.md`).includes(`releases/download/v${version}/`)) {
    throw new Error(`Point the README downloads at v${version} before publishing it.`);
  }
  const tag = `v${version}`;
  if (spawnSync("gh", ["release", "view", tag, "--repo", repository], { stdio: "ignore" }).status === 0) {
    throw new Error(`Release ${tag} already exists.`);
  }

  const reports = directories.map(directory => ({
    directory,
    report: JSON.parse(readFileSync(path.join(directory, "release-check.json"), "utf8")),
  }));
  const assets = releaseAssets(reports);
  const temp = mkdtempSync(path.join(tmpdir(), "motifs-publish-"));
  try {
    const sums = path.join(temp, "SHA256SUMS");
    writeFileSync(sums, assets.map(asset => checksumLine(asset.sha256, asset.name)).join(""));
    const notes = path.join(temp, "notes.md");
    writeFileSync(notes, releaseNotes({ version, commit, signed, assets }));
    execFileSync("gh", [
      "release", "create", tag, "--repo", repository, "--target", commit,
      "--title", `Motifs ${version}${signed ? "" : " (preview)"}`, "--notes-file", notes,
      ...(signed ? [] : ["--prerelease"]),
      ...assets.map(asset => path.join(asset.directory, asset.name)), sums,
    ], { cwd: root, stdio: "inherit" });
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
  console.log(`Published Motifs ${version} at https://github.com/${repository}/releases/tag/${tag}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
