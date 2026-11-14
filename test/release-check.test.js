import assert from "node:assert/strict";
import test from "node:test";
import { releaseArchiveName, releaseTarget } from "../platform.js";
import { checksumLine, releaseReport, tapSummary } from "../scripts/release-check.js";

test("release targets cover the packaged platforms only", () => {
  assert.equal(releaseTarget("darwin", "arm64"), "macos-arm64");
  assert.equal(releaseTarget("win32", "x64"), "windows-x64");
  for (const [platform, arch] of [["darwin", "x64"], ["win32", "arm64"], ["linux", "x64"]]) {
    assert.equal(releaseTarget(platform, arch), undefined);
  }
  assert.equal(releaseArchiveName("0.5.0", "windows-x64"), "motifs-0.5.0-windows-x64.zip");
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
