import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("replay buffer, recording limit, MP4 writer and key frames", { skip: process.platform !== "darwin" }, () => {
  const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const temporary = mkdtempSync(path.join(os.tmpdir(), "motifs-replay-"));
  try {
    const binary = path.join(temporary, "replay-tests");
    execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-module-cache-path", path.join(os.tmpdir(), "opencode/motifs-swift-cache"), ...["ReplayRecorder.swift", "test/ReplayTests.swift"].map((file) => path.join(root, file)), "-o", binary], { stdio: "pipe" });
    const result = execFileSync(binary, [temporary], { encoding: "utf8", timeout: 120_000 });
    assert.match(result, /replay buffer, recording, MP4 writer and key frame checks passed/);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
