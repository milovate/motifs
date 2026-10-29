import assert from "node:assert/strict";
import test from "node:test";
import path from "node:path";
import { helperCommand, platformConfig } from "../platform.js";
import { startHotkey, capture } from "../index.js";

test("Windows uses local app data, with an explicit XDG override", () => {
  assert.equal(platformConfig("win32", { LOCALAPPDATA: "local-data" }, "home").captures, path.join("local-data", "opencode", "capture-studio"));
  assert.equal(platformConfig("win32", { XDG_DATA_HOME: "xdg", LOCALAPPDATA: "other" }).captures, path.join("xdg", "opencode", "capture-studio"));
  assert.equal(platformConfig("win32", {}, "home").captures, path.join("home", "AppData", "Local", "opencode", "capture-studio"));
  assert.throws(() => platformConfig("linux"), /not WSL/);
});

test("Windows helper arguments never pass through a shell", () => {
  const config = platformConfig("win32", { LOCALAPPDATA: "data with spaces" });
  const app = 'chrome & echo "not a command"';
  const command = helperCommand("plugin with spaces", config, "capture", ["--app", app]);
  assert.equal(command.executable, path.join("plugin with spaces", "windows", "dist", "Appshots.exe"));
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
  assert.match(launched[0], /Appshots\.exe$/);
  assert.deepEqual(launched[1], ["--watch", "--output", config.captures]);
});

test("missing Windows helper explains the build step", async () => {
  await assert.rejects(startHotkey({
    mkdir: async () => {},
    spawnHelper: async () => { throw Object.assign(new Error("missing"), { code: "ENOENT" }); },
  }, platformConfig("win32")), /npm run build/);
});

test("capture rejects invalid delays before launching a helper", async () => {
  for (const delay of [-1, 11, 1.5, "3"]) await assert.rejects(capture({ source: "live", delay }), /integer from 0 to 10/);
});
