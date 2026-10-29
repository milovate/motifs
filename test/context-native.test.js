import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("native system, console, custom log, event and browser context", { skip: process.platform !== "darwin" }, () => {
  const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const temporary = mkdtempSync(path.join(os.tmpdir(), "capture-studio-context-"));
  try {
    const binary = path.join(temporary, "context-tests");
    execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-module-cache-path", path.join(os.tmpdir(), "opencode/appshots-swift-cache"), ...["CaptureBundle.swift", "SystemContext.swift", "UserEvents.swift", "BrowserBridge.swift", "test/ContextTests.swift"].map((file) => path.join(root, file)), "-o", binary], { stdio: "pipe" });
    const result = execFileSync(binary, [temporary], { encoding: "utf8" });
    assert.match(result, /system, console, custom log, event buffer and browser bridge checks passed/);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
