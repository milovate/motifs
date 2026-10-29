import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("native floating composer layout, input sizing and searchable skills", { skip: process.platform !== "darwin" }, () => {
  const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const temporary = mkdtempSync(path.join(os.tmpdir(), "appshots-composer-ui-"));
  try {
    const binary = path.join(temporary, "composer-tests");
    execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-module-cache-path", path.join(os.tmpdir(), "opencode/appshots-swift-cache"), ...["Composer.swift", "ComposerUI.swift", "AnnotationEditor.swift", "CaptureBundle.swift", "ComposerMentions.swift", "ComposerSpeech.swift", "StatusBarIcon.swift", "ReplayRecorder.swift", "ClipReview.swift", "RecordingUI.swift", "ContextPicker.swift", "Recents.swift", "test/ComposerTests.swift"].map((file) => path.join(root, file)), "-o", binary], { stdio: "pipe" });
    const result = execFileSync(binary, [temporary], { encoding: "utf8" });
    assert.match(result, /compact layout, adaptive sizing, skill chips, search and consent checks passed/);
    assert.match(result, /device context, bundle manifest, recents, settings and destination wiring checks passed/);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
