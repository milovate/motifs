import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("annotation coordinates, undo and exported pixels agree", () => {
  const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const temporary = mkdtempSync(path.join(os.tmpdir(), "appshots-annotation-test-"));
  try {
    const binary = path.join(temporary, "annotation-tests");
    execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-module-cache-path", "/tmp/opencode-appshots-swift-cache", path.join(root, "AnnotationEditor.swift"), path.join(root, "test/AnnotationTests.swift"), "-o", binary], { stdio: "pipe" });
    assert.match(execFileSync(binary, { encoding: "utf8" }), /pixels, dimensions and private export passed/);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
