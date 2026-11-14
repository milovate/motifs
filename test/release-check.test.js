import assert from "node:assert/strict";
import test from "node:test";
import { releaseArchiveName, releaseDiskImageName, releaseTarget } from "../platform.js";
import { releaseAssets, releaseNotes } from "../scripts/publish-release.js";
import { checksumLine, releaseReport, tapSummary } from "../scripts/release-check.js";

test("release targets cover the packaged platforms only", () => {
  assert.equal(releaseTarget("darwin", "arm64"), "macos-arm64");
  assert.equal(releaseTarget("win32", "x64"), "windows-x64");
  for (const [platform, arch] of [["darwin", "x64"], ["win32", "arm64"], ["linux", "x64"]]) {
    assert.equal(releaseTarget(platform, arch), undefined);
  }
  assert.equal(releaseArchiveName("0.5.0", "windows-x64"), "motifs-0.5.0-windows-x64.zip");
  assert.equal(releaseDiskImageName("0.5.0"), "motifs-0.5.0-macos-arm64.dmg");
});

test("the release check reads the test summary from TAP output", () => {
  const tap = "TAP version 13\nok 1 - a\n1..3\n# tests 3\n# suites 0\n# pass 2\n# fail 0\n# cancelled 0\n# skipped 1\n";
  assert.deepEqual(tapSummary(tap), { tests: 3, pass: 2, fail: 0, skipped: 1 });
  assert.deepEqual(tapSummary(tap.replaceAll("\n", "\r\n")), { tests: 3, pass: 2, fail: 0, skipped: 1 });
  assert.throws(() => tapSummary("ok 1 - a\n"), /did not report a summary/);
});

test("the release report ties the archive checksum to one commit", () => {
  const sha256 = "a".repeat(64);
  assert.equal(checksumLine(sha256, "motifs-0.5.0-macos-arm64.zip"), `${sha256}  motifs-0.5.0-macos-arm64.zip\n`);
  assert.deepEqual(releaseReport({
    version: "0.5.0",
    target: "macos-arm64",
    commit: "b".repeat(40),
    archive: "motifs-0.5.0-macos-arm64.zip",
    sha256,
    bytes: 1234,
    tests: { tests: 3, pass: 2, fail: 0, skipped: 1 },
    createdAt: new Date("2026-11-12T12:00:00Z"),
    node: "v22.0.0",
  }), {
    version: "0.5.0",
    target: "macos-arm64",
    commit: "b".repeat(40),
    archive: "motifs-0.5.0-macos-arm64.zip",
    sha256,
    bytes: 1234,
    tests: { tests: 3, pass: 2, fail: 0, skipped: 1 },
    signed: false,
    node: "v22.0.0",
    createdAt: "2026-11-12T12:00:00.000Z",
  });
});

test("the macOS release report also records the disk image checksum", () => {
  const diskImage = { name: "motifs-0.5.0-macos-arm64.dmg", sha256: "c".repeat(64), bytes: 5678 };
  const report = releaseReport({
    version: "0.5.0",
    target: "macos-arm64",
    commit: "b".repeat(40),
    archive: "motifs-0.5.0-macos-arm64.zip",
    sha256: "a".repeat(64),
    bytes: 1234,
    diskImage,
    tests: { tests: 3, pass: 2, fail: 0, skipped: 1 },
  });
  assert.deepEqual(report.diskImage, diskImage);
});

const checks = [
  { directory: "mac", report: { target: "macos-arm64", archive: "motifs-0.5.0-macos-arm64.zip", sha256: "a".repeat(64), diskImage: { name: "motifs-0.5.0-macos-arm64.dmg", sha256: "c".repeat(64) } } },
  { directory: "win", report: { target: "windows-x64", archive: "motifs-0.5.0-windows-x64.zip", sha256: "d".repeat(64) } },
];

test("a published release carries the DMG and both ZIPs", () => {
  assert.deepEqual(releaseAssets(checks).map(asset => [asset.directory, asset.name]), [
    ["mac", "motifs-0.5.0-macos-arm64.dmg"],
    ["mac", "motifs-0.5.0-macos-arm64.zip"],
    ["win", "motifs-0.5.0-windows-x64.zip"],
  ]);
  assert.throws(() => releaseAssets(checks.slice(0, 1)), /one macOS arm64 and one Windows x64/);
});

test("release notes link every download and warn about unsigned previews", () => {
  const assets = releaseAssets(checks);
  const preview = releaseNotes({ version: "0.5.0", commit: "b".repeat(40), signed: false, assets });
  for (const asset of assets) {
    assert.ok(preview.includes(`https://github.com/milovate/motifs/releases/download/v0.5.0/${asset.name}`));
  }
  assert.match(preview, /\*\*Preview\.\*\*/);
  assert.match(preview, /Open Anyway/);
  assert.doesNotMatch(preview, /\n\n\n/);
  const signed = releaseNotes({ version: "0.5.0", commit: "b".repeat(40), signed: true, assets });
  assert.doesNotMatch(signed, /Preview|Open Anyway|SmartScreen/);
});
