import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test from "node:test";

test("Windows native annotation geometry, history, persistence, and pixels", { skip: process.platform !== "win32" }, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "motifs-annotation-test-"));
  try {
    const helper = fileURLToPath(new URL("../windows/dist/Motifs.exe", import.meta.url));
    const { stdout } = await promisify(execFile)(helper, ["--test-annotations", "--output", directory], { windowsHide: true, timeout: 30_000 });
    assert.match(stdout, /Windows annotation regressions passed/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("Windows composer bundle, destinations, and region geometry", { skip: process.platform !== "win32" }, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "motifs-composer-test-"));
  try {
    const helper = fileURLToPath(new URL("../windows/dist/Motifs.exe", import.meta.url));
    const { stdout } = await promisify(execFile)(helper, ["--test-composer", "--output", directory], { windowsHide: true, timeout: 30_000 });
    assert.match(stdout, /Windows composer regressions passed/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("Windows screen recording writes an MP4", { skip: process.platform !== "win32" }, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "motifs-recording-test-"));
  try {
    const helper = fileURLToPath(new URL("../windows/dist/Motifs.exe", import.meta.url));
    const { stdout } = await promisify(execFile)(helper, ["--test-recording", "--output", directory], { windowsHide: true, timeout: 120_000 });
    assert.match(stdout, /Windows recording regressions passed/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("Windows helper rejects invalid requests without producing capture content", { skip: process.platform !== "win32" }, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "motifs-windows-test-"));
  const helper = fileURLToPath(new URL("../windows/dist/Motifs.exe", import.meta.url));
  try {
    const run = promisify(execFile);
    for (const [args, message] of [
      [["--delay", "11"], /Delay must be from 0 to 10/],
      [["--app", "motifs-test-nonexistent-process-53dc48"], /No visible window matches/],
    ]) {
      await assert.rejects(run(helper, ["--capture", "--output", directory, ...args], { windowsHide: true, timeout: 10_000 }), (error) => {
        assert.equal(error.code, 1);
        assert.equal(error.stdout, "");
        assert.match(error.stderr, message);
        return true;
      });
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
