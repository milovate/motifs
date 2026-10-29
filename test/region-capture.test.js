import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("region selection, cancellation and ordered screenshot attachments", { skip: process.platform !== "darwin" }, () => {
  const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const temporary = mkdtempSync(path.join(os.tmpdir(), "appshots-region-tests-"));
  try {
    const binary = path.join(temporary, "region-tests");
    execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-module-cache-path", path.join(os.tmpdir(), "opencode/appshots-swift-cache"), ...["RegionCapture.swift", "ScreenshotAttachments.swift", "test/RegionCaptureTests.swift"].map((file) => path.join(root, file)), "-o", binary], { stdio: "pipe" });
    assert.match(execFileSync(binary, { encoding: "utf8" }), /Region selection, cancellation and screenshot attachment contract checks passed/);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});
