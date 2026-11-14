import assert from "node:assert/strict";
import test from "node:test";
import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { helperCommand, migrateCaptures, platformConfig } from "../platform.js";
import { capture, startDesktopServices, startHotkey } from "../index.js";

test("Windows uses local app data, with an explicit XDG override", () => {
  assert.equal(platformConfig("win32", { LOCALAPPDATA: "local-data" }, "home").captures, path.join("local-data", "opencode", "motifs"));
  assert.equal(platformConfig("win32", { XDG_DATA_HOME: "xdg", LOCALAPPDATA: "other" }).captures, path.join("xdg", "opencode", "motifs"));
  assert.equal(platformConfig("win32", {}, "home").captures, path.join("home", "AppData", "Local", "opencode", "motifs"));
  assert.throws(() => platformConfig("linux"), /not WSL/);
});

test("captures move once from the Capture Studio folder", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "motifs-migrate-"));
  try {
    const config = platformConfig("darwin", { XDG_DATA_HOME: base });
    assert.equal(config.legacyCaptures, path.join(base, "opencode", "capture-studio"));
    assert.equal(await migrateCaptures(config), false, "nothing to move");
    await mkdir(config.legacyCaptures, { recursive: true });
    await writeFile(path.join(config.legacyCaptures, "latest.json"), "{}");
    assert.equal(await migrateCaptures(config), true);
    assert.deepEqual(await readdir(config.captures), ["latest.json"]);
    await assert.rejects(readdir(config.legacyCaptures), { code: "ENOENT" });
    await mkdir(config.legacyCaptures);
    assert.equal(await migrateCaptures(config), false, "an existing Motifs folder is never merged into");
    assert.deepEqual(await readdir(config.legacyCaptures), []);
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("Windows helper arguments never pass through a shell", () => {
  const config = platformConfig("win32", { LOCALAPPDATA: "data with spaces" });
  const app = 'chrome & echo "not a command"';
  const command = helperCommand("plugin with spaces", config, "capture", ["--app", app]);
  assert.equal(command.executable, path.join("plugin with spaces", "windows", "dist", "Motifs.exe"));
  assert.deepEqual(command.args, ["--capture", "--output", config.captures, "--app", app]);
  assert.deepEqual(helperCommand("plugin", config, "annotate-latest").args, ["--annotate-latest", "--output", config.captures]);
});

test("Windows watcher is detached rather than waiting for a long-lived process", async () => {
  const config = platformConfig("win32", { LOCALAPPDATA: "local" });
  let launched;
  await startHotkey({
    mkdir: async (directory, options) => { assert.equal(directory, config.captures); assert.equal(options.recursive, true); },
    run: async () => assert.fail("must not wait for the tray process"),
    spawnHelper: async (...args) => { launched = args; },
  }, config);
  assert.match(launched[0], /Motifs\.exe$/);
  assert.deepEqual(launched[1], ["--watch", "--output", config.captures]);
});

test("missing Windows helper explains the build step", async () => {
  await assert.rejects(startHotkey({
    mkdir: async () => {},
    spawnHelper: async () => { throw Object.assign(new Error("missing"), { code: "ENOENT" }); },
  }, platformConfig("win32")), /npm run build/);
});

test("desktop startup opens the composer bridge before the helper", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "motifs-bridge-"));
  const target = { platform: "win32", captures: directory, shortcut: "Control+Alt+Shift+A" };
  let launched = false;
  const stop = await startDesktopServices({
    location: { directory: path.join(directory, "project") },
    options: {},
    skill: { list: async () => ({ data: [] }) },
    session: { create: async () => { throw new Error("startup must not create a session"); } },
  }, target, {
    mkdir: async () => {},
    run: async () => { throw new Error("the Windows helper is spawned, not awaited"); },
    spawnHelper: async (executable, args) => {
      assert.match(executable, /Motifs\.exe$/);
      assert.deepEqual(args, ["--watch", "--output", directory]);
      launched = true;
    },
  });
  assert.equal(launched, true);
  assert.equal((await readdir(path.join(directory, "composers"))).length, 1);
  await stop();
  await rm(directory, { recursive: true, force: true });
});

test("capture rejects invalid delays before launching a helper", async () => {
  for (const delay of [-1, 11, 1.5, "3"]) await assert.rejects(capture({ source: "live", delay }), /integer from 0 to 10/);
});
