import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("native accessibility traversal retains deep content and semantic formatting", { skip: process.platform !== "darwin" }, () => {
  const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const temporary = mkdtempSync(path.join(os.tmpdir(), "appshots-reader-test-"));
  try {
    const binary = path.join(temporary, "reader-tests");
    execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-module-cache-path", "/tmp/opencode-appshots-swift-cache", path.join(root, "AccessibilityReader.swift"), path.join(root, "test/AccessibilityReaderTests.swift"), "-o", binary], { stdio: "pipe" });
    const output = execFileSync(binary, { encoding: "utf8" });
    assert.match(output, /5 regression groups passed/);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
