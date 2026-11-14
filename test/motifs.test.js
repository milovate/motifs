import assert from "node:assert/strict";
import test from "node:test";
import path from "node:path";
import { platformConfig } from "../platform.js";
import plugin, { capture, startHotkey, selectedTextGuidance } from "../index.js";
import { Schema } from "effect";
import { Tool } from "@opencode-ai/schema/tool";

test("registers a direct, permission-scoped tool and slash command", async () => {
  const registered = [];
  const commands = {};
  let prompt;
  let synthetic;
  await plugin.setup({
    options: { hotkey: false },
    tool: { transform: async (callback) => callback({ add: (tool) => registered.push(tool) }) },
    command: { transform: async (callback) => callback({ add: (command) => { commands[command.name] = command; } }) },
    session: {
      prompt: async (request) => { prompt = request; },
      synthetic: async (request) => { synthetic = request; },
    },
  });
  const fetch = globalThis.fetch;
  globalThis.fetch = async () => ({ status: 404, ok: false, json: async () => ({}) });
  try {
    await commands["motifs-update"].execute({ sessionID: "fixture-session" });
  } finally {
    globalThis.fetch = fetch;
  }
  assert.equal(synthetic.sessionID, "fixture-session");
  assert.equal(synthetic.resume, false);
  assert.match(synthetic.text, /No stable Motifs release has been published yet/);
  assert.equal(prompt, undefined);
  assert.deepEqual(registered.map((tool) => [tool.name, tool.options.permission, tool.options.codemode]), [["motifs", "motifs", false], ["capture_studio", "capture_studio", false]]);
  assert.match(registered[1].description, /^Deprecated alias of the motifs tool\./);
  for (const name of ["motifs", "motifs-start", "motifs-insert", "motifs-annotate", "motifs-update"]) {
    const legacy = commands[name.replace(/^motifs/, "capture-studio")];
    assert.equal(typeof commands[name].execute, "function");
    assert.equal(legacy.execute, commands[name].execute, `${legacy.name} runs the same command as ${name}`);
    assert.match(legacy.description, new RegExp(`^Deprecated: use /${name}\\. `));
  }
  await commands["motifs"].execute({ sessionID: "fixture-session", delivery: "queue", prompt: { text: "explain this", attachments: [] } });
  assert.match(prompt.text, /source=latest/);
  assert.match(prompt.text, /explain this$/);
  assert.equal(prompt.sessionID, "fixture-session");
  assert.equal(prompt.delivery, "queue");
  assert.deepEqual(prompt.attachments, []);
});

test("starts the shortcut as a macOS app with its own permission identity", async () => {
  let launch;
  await startHotkey({
    mkdir: async () => {},
    run: async (...args) => { launch = args; },
  }, platformConfig("darwin"));
  assert.equal(launch[0], "/usr/bin/open");
  assert.deepEqual(launch[1].slice(0, 2), ["-g", "-a"]);
  assert.match(launch[1][2], /Motifs\.app$/);
  assert.deepEqual(launch[1].slice(3, 6), ["--args", "--watch", "--output"]);
});

test("latest capture includes the actual image bytes in model content", async () => {
  const io = fixture();
  const result = await capture({}, io);
  assert.match(result.content[0].text, /not live state/);
  assert.match(result.content[0].text, /untrusted/);
  assert.ok(result.content[0].text.endsWith(selectedTextGuidance));
  assert.ok(result.content[0].text.indexOf(selectedTextGuidance) > result.content[0].text.indexOf("</motif_accessibility_text>"));
  assert.match(result.content[0].text, /AXStaticText: fixture/);
  assert.equal(result.content[1].uri, `data:image/png;base64,${io.png.toString("base64")}`);
  for (const content of result.content) Schema.decodeUnknownSync(Tool.Content)(content);
});

test("delivers Codex-style hierarchy without the old 40000-character cutoff", async () => {
  const io = fixture();
  io.snapshot.text = "standard window Test\n\tHTML content Fixture, URL: https://example.test\n\t\ttext " + "x".repeat(50_000) + "\nThe focused UI element is text field Prompt";
  const result = await capture({}, io);
  assert.match(result.content[0].text, /Window: "Test", App: Fixture\./);
  assert.ok(result.content[0].text.includes(io.snapshot.text));
  io.snapshot.text = "x".repeat(120_001);
  const truncated = await capture({}, io);
  assert.match(truncated.content[0].text, /Accessibility text truncated: exceeded/);
});

test("annotated capture delivers the exported PNG and labels accessibility text as original", async () => {
  const io = fixture();
  io.snapshot.annotatedAt = "2026-10-19T00:00:00Z";
  io.snapshot.originalScreenshot = "original-is-not-the-delivered-image.png";
  const result = await capture({}, io);
  assert.match(result.content[0].text, /includes user annotations\. Accessibility text describes the original capture/);
  assert.match(result.content[0].text, /AXStaticText: fixture/);
  assert.equal(result.content[1].uri, `data:image/png;base64,${io.png.toString("base64")}`);
});

test("app names stay subprocess arguments and imply a live capture", async () => {
  const io = fixture();
  const hostileName = 'Chrome; $(touch /tmp/should-not-exist)';
  await capture({ app: hostileName, delay: 3 }, io);
  assert.deepEqual(io.args.slice(-4), ["--app", hostileName, "--delay", "3"]);
  assert.equal(io.args[0], "--capture");
});

test("missing permission surfaces the native error without fake image content", async () => {
  const io = fixture();
  io.run = async () => { throw Object.assign(new Error("command failed"), { stderr: "Screen Recording permission is required." }); };
  await assert.rejects(capture({ source: "live" }, io), /Screen Recording permission is required/);
});

test("a missing latest capture explains the shortcut workflow", async () => {
  const io = fixture();
  io.readFile = async () => { throw Object.assign(new Error("missing"), { code: "ENOENT" }); };
  await assert.rejects(capture({}, io), /Option\+G|Control\+Alt\+Shift\+A/);
});

test("refuses a manifest pointing outside the capture directory", async () => {
  const io = fixture();
  io.snapshot.screenshot = "/tmp/other.png";
  await assert.rejects(capture({}, io), /capture directory/);
});

test("refuses non-PNG and oversized files", async () => {
  const io = fixture();
  io.png = Buffer.from("not an image");
  await assert.rejects(capture({}, io), /not a valid PNG/);
  io.stat = async () => ({ size: 15_000_001 });
  await assert.rejects(capture({}, io), /exceeds 15 MB/);
});

function fixture() {
  const directory = platformConfig().captures;
  const io = {
    png: Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=", "base64"),
    snapshot: { app: "Fixture", bundleID: "local.fixture", title: "Test", capturedAt: "2026-10-07T00:00:00Z", text: "AXStaticText: fixture", warnings: [], screenshot: path.join(directory, "fixture.png") },
    args: [],
    async run(_executable, args) { io.args = args; return { stdout: JSON.stringify(io.snapshot) }; },
    async readFile(file) { return file.endsWith("latest.json") ? JSON.stringify(io.snapshot) : io.png; },
    async realpath(file) { return file; },
    async stat() { return { size: io.png.length }; },
  };
  return io;
}
