import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("handoff waits for Electron focus and accepts only the requested search editor", { skip: process.platform !== "darwin" }, () => {
  const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const temporary = mkdtempSync(path.join(os.tmpdir(), "appshots-handoff-focus-"));
  try {
    const binary = path.join(temporary, "handoff-tests");
    execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-module-cache-path", path.join(os.tmpdir(), "opencode/appshots-swift-cache"), path.join(root, "HandoffFocus.swift"), path.join(root, "test/HandoffFocusTests.swift"), "-o", binary], { stdio: "pipe" });
    assert.match(execFileSync(binary, { encoding: "utf8" }), /focus ownership and asynchronous activation checks passed/);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});
