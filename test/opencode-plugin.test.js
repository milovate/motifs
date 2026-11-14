import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("Motifs.app installs and refreshes only its own OpenCode plugin copy", { skip: process.platform !== "darwin" }, () => {
  const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const temporary = mkdtempSync(path.join(os.tmpdir(), "motifs-opencode-plugin-"));
  try {
    const binary = path.join(temporary, "opencode-plugin-tests");
    const fixture = path.join(temporary, "fixture");
    mkdirSync(fixture);
    execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-module-cache-path", path.join(os.tmpdir(), "opencode/motifs-swift-cache"), path.join(root, "OpenCodePlugin.swift"), path.join(root, "test/OpenCodePluginTests.swift"), "-o", binary], { stdio: "pipe" });
    assert.match(execFileSync(binary, [fixture], { encoding: "utf8" }), /OpenCode plugin install checks passed/);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
});
