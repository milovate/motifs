import assert from "node:assert/strict";
import test from "node:test";
import { execFileSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, writeFile, readFile, readdir, realpath, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { BUNDLE_SCHEMA, readBundle, contextDocument, contextFilePath, draftText, markdownBundle, deviceSummary } from "../bundle.js";
import { builtinDestinations, clipboardDestination, describeDestinations, folderDestination, opencodeDestination, validateDestination, validateHandoff } from "../destinations.js";
import { startComposerBridge, submitComposer } from "../composer-bridge.js";
import { assertOwnerOnly } from "./owner-only.js";

const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=", "base64");
const DEVICE = { os: "macOS 15.2", arch: "arm64", model: "Mac15,8", cpu: "Apple M3 Max", memoryBytes: 64 * 2 ** 30, displays: [{ width: 3024, height: 1964, scale: 2 }], locale: "en_IN" };

async function fixture(t, bundle = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "appshots-destinations-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const screenshot = path.join(directory, "capture.png");
  await writeFile(screenshot, PNG);
  const shot = { kind: "image", app: "Fixture", title: "Page", screenshot, capturedAt: "2026-10-29T10:00:00Z", text: "Untrusted window text", originalScreenshot: path.join(directory, "original.png") };
  const manifest = path.join(directory, `bundle-${randomUUID()}.json`);
  await writeFile(manifest, JSON.stringify({ schema: BUNDLE_SCHEMA, id: "b1", createdAt: "2026-10-29T10:00:01Z", note: "Saved note", media: [shot], context: { device: DEVICE }, include: { windowText: true, device: true }, ...bundle }));
  const created = [];
  const prompts = [];
  const ctx = {
    location: { directory: "/fixture/project" },
    skill: { list: async () => ({ data: [{ id: "report", name: "Report" }] }) },
    session: {
      create: async (input) => { created.push(input); return { id: `ses_${created.length}`, title: input.title }; },
      prompt: async (input) => { prompts.push(input); },
    },
  };
  const exports = path.join(directory, "exports");
  const destinations = builtinDestinations(ctx, { exportDirectory: exports });
  return { directory, manifest, shot, ctx, created, prompts, exports, destinations, input: { requestID: randomUUID(), text: "Checkout button overlaps\nmore detail", skills: [], manifest } };
}

test("bundle manifest is read as the single source of truth, with legacy manifests still accepted", async (t) => {
  const f = await fixture(t);
  const bundle = await readBundle(f.directory, f.manifest);
  assert.equal(bundle.id, "b1");
  assert.equal(bundle.media.length, 1);
  assert.deepEqual(bundle.include, { windowText: true, device: true, console: true, network: true, events: true, customLogs: true });
  assert.equal(bundle.device.model, "Mac15,8");
  const legacy = path.join(f.directory, "legacy.json");
  await writeFile(legacy, JSON.stringify({ screenshots: [f.shot] }));
  const old = await readBundle(f.directory, legacy);
  assert.deepEqual(old.include, { windowText: true, device: true, console: true, network: true, events: true, customLogs: true });
  assert.equal(old.device, undefined);
  await writeFile(legacy, JSON.stringify({ schema: "capture-studio.bundle/99", media: [] }));
  await assert.rejects(readBundle(f.directory, legacy), /Unsupported/);
  await writeFile(legacy, JSON.stringify({ schema: BUNDLE_SCHEMA, media: [{ ...f.shot, screenshot: path.join(f.directory, "../outside.png") }] }));
  await assert.rejects(readBundle(f.directory, legacy));
});

test("include flags remove window text and device context from every rendering", async (t) => {
  const f = await fixture(t, { include: { windowText: false, device: false } });
  const bundle = await readBundle(f.directory, f.manifest);
  for (const text of [contextDocument(bundle), markdownBundle(bundle, "note", (shot) => shot.screenshot)]) {
    assert.ok(!text.includes("Untrusted window text"));
    assert.ok(!text.includes("Apple M3 Max"));
    assert.match(text, /Window text was excluded by the user/);
  }
  const other = await fixture(t);
  const included = await readBundle(other.directory, other.manifest);
  assert.match(contextDocument(included), /Apple M3 Max/);
  assert.match(contextDocument(included), /<appshot_accessibility_text>\nUntrusted window text/);
});

test("device summary never includes location and tolerates missing fields", () => {
  const lines = deviceSummary({ ...DEVICE, displays: [] });
  assert.deepEqual(lines, ["macOS 15.2 (arm64)", "Mac15,8", "Apple M3 Max", "64 GB memory", "Locale en_IN"]);
  assert.deepEqual(deviceSummary(undefined), []);
  assert.ok(!lines.join(" ").match(/latitude|longitude|city|timezone/i));
});

test("destination contract rejects incomplete plugins and unknown handoff actions", () => {
  const valid = clipboardDestination();
  assert.equal(validateDestination(valid), valid);
  for (const broken of [null, { ...valid, id: "Bad Id" }, { ...valid, label: "" }, { ...valid, accepts: { image: true } }, { ...valid, prepare: undefined }]) {
    assert.throws(() => validateDestination(broken), /Invalid destination/);
  }
  assert.throws(() => validateHandoff({ action: "send-message" }), /unknown handoff action/);
  assert.throws(() => validateHandoff({ action: "reveal-folder", path: "relative", message: "x" }), /incomplete/);
  assert.throws(() => validateHandoff({ action: "copy-text", message: "x" }), /incomplete/);
});

test("built-in destinations describe status, targets, action labels and hints", async (t) => {
  const f = await fixture(t);
  const described = await describeDestinations(f.destinations);
  assert.deepEqual(described.map((d) => d.id), ["opencode", "clipboard", "folder"]);
  assert.ok(described.every((d) => d.status === "ready" && d.targets.length === 1));
  assert.equal(described[0].targets[0].id, "/fixture/project");
  assert.equal(described[0].targets[0].label, "project");
  assert.equal(described[0].targets[0].actionLabel, "Review in OpenCode");
  assert.match(described[0].targets[0].hint, /You press Enter/);
  assert.equal(described[1].targets[0].actionLabel, "Copy Markdown");
  assert.equal(described[2].targets[0].detail, f.exports);
  const offline = { ...clipboardDestination(), id: "linear", label: "Linear", status: async () => "needs-auth", targets: async () => { throw new Error("must not list targets"); } };
  const [linear] = await describeDestinations([offline]);
  assert.deepEqual([linear.status, linear.targets], ["needs-auth", []]);
});

test("OpenCode destination creates an empty session and an unsent draft only", async (t) => {
  const f = await fixture(t);
  const bundle = await readBundle(f.directory, f.manifest);
  const destination = opencodeDestination(f.ctx);
  const [target] = await destination.targets();
  const result = await destination.prepare(bundle, target, { note: f.input.text, requestID: f.input.requestID });
  assert.equal(result.action, "opencode-draft");
  assert.match(result.draftText, /^Checkout button overlaps/);
  assert.ok(result.draftText.includes(bundle.media[0].screenshot) && result.draftText.includes(bundle.manifest), "the draft points at the screenshot and the bundle");
  assert.ok(!result.draftText.includes("Untrusted window text") && !result.draftText.includes("Apple M3 Max"), "window text and device details stay in the context file");
  const contextFile = contextFilePath(bundle);
  assert.ok(result.draftText.includes(`Full context (window text, device): ${contextFile}`));
  await assertOwnerOnly(contextFile, 0o600);
  const written = await readFile(contextFile, "utf8");
  assert.match(written, /Device context/);
  assert.match(written, /Untrusted window text/);
  assert.equal(draftText(bundle, "note", contextFile).split("\n").length < 10, true, "the draft stays short");
  assert.equal(f.created.length, 1);
  assert.equal(f.prompts.length, 0);
  await assert.rejects(destination.prepare(bundle, { id: "/other" }, { note: "x", requestID: f.input.requestID }), /no longer loaded/);
});

test("Clipboard destination returns Markdown for the helper to copy and creates no session", async (t) => {
  const f = await fixture(t);
  const result = await submitComposer(f.ctx, f.directory, { ...f.input, destination: "clipboard", target: "markdown" }, f.destinations);
  assert.equal(result.action, "copy-text");
  assert.match(result.text, /^## Checkout button overlaps/);
  assert.ok(result.text.includes(`\`${await realpath(f.shot.screenshot)}\``));
  assert.ok(!result.text.includes("Untrusted window text"), "window text stays in the context file");
  assert.match(await readFile(result.text.match(/^Full context: `([^`]+)`$/m)[1], "utf8"), /Untrusted window text/);
  assert.match(result.message, /1 screenshot path/);
  assert.equal(f.created.length, 0);
  assert.equal(f.prompts.length, 0);
});

test("Save to folder writes an owner-only, self-contained export without private paths", async (t) => {
  const f = await fixture(t);
  const result = await submitComposer(f.ctx, f.directory, { ...f.input, destination: "folder" }, f.destinations);
  assert.equal(result.action, "reveal-folder");
  assert.equal(path.dirname(result.path), f.exports);
  await assertOwnerOnly(result.path, 0o700);
  assert.deepEqual((await readdir(result.path)).sort(), ["README.md", "bundle.json", "screenshot-1.png"]);
  assert.deepEqual(await readFile(path.join(result.path, "screenshot-1.png")), PNG);
  await assertOwnerOnly(path.join(result.path, "bundle.json"), 0o600);
  const exported = JSON.parse(await readFile(path.join(result.path, "bundle.json"), "utf8"));
  assert.equal(exported.schema, BUNDLE_SCHEMA);
  assert.equal(exported.media[0].screenshot, "screenshot-1.png");
  assert.equal(exported.note, f.input.text);
  const raw = await readFile(path.join(result.path, "bundle.json"), "utf8");
  assert.ok(!raw.includes(f.directory), "exports must not leak the private captures folder");
  assert.match(await readFile(path.join(result.path, "README.md"), "utf8"), /!\[Screenshot 1\]\(<screenshot-1\.png>\)/);
  assert.equal(f.created.length, 0);
});

test("Save to folder preserves permissions on an existing export root", async (t) => {
  const f = await fixture(t);
  await mkdir(f.exports);
  if (process.platform !== "win32") await chmod(f.exports, 0o750);
  const permissions = async () => {
    if (process.platform === "win32") {
      return execFileSync("icacls", [f.exports], { encoding: "utf8", windowsHide: true });
    }
    return (await stat(f.exports)).mode & 0o777;
  };
  const before = await permissions();

  const result = await submitComposer(f.ctx, f.directory, { ...f.input, destination: "folder" }, f.destinations);

  assert.equal(path.dirname(result.path), f.exports);
  assert.equal(await permissions(), before);
  await assertOwnerOnly(result.path, 0o700);
});

test("unknown destinations and targets are rejected before anything is prepared", async (t) => {
  const f = await fixture(t);
  await assert.rejects(submitComposer(f.ctx, f.directory, { ...f.input, destination: "slack" }, f.destinations), /not available/);
  await assert.rejects(submitComposer(f.ctx, f.directory, { ...f.input, destination: "opencode", target: "/elsewhere" }, f.destinations), /no longer available/);
  assert.equal(f.created.length, 0);
  assert.deepEqual(await readdir(f.directory).then((names) => names.filter((name) => name === "exports")), []);
});

test("bridge lists destinations and routes prepare by destination without sending", async (t) => {
  const f = await fixture(t);
  const stop = await startComposerBridge(f.ctx, f.directory, f.destinations);
  t.after(stop);
  const [name] = await readdir(path.join(f.directory, "composers"));
  const descriptor = JSON.parse(await readFile(path.join(f.directory, "composers", name), "utf8"));
  const base = `http://127.0.0.1:${descriptor.port}`;
  const headers = { Authorization: `Bearer ${descriptor.token}` };
  assert.equal((await fetch(base + "/destinations")).status, 403);
  assert.equal((await fetch(base + "/destinations", { headers: { ...headers, Origin: "https://example.com" } })).status, 403);
  const { destinations } = await (await fetch(base + "/destinations", { headers })).json();
  assert.deepEqual(destinations.map((d) => d.id), ["opencode", "clipboard", "folder"]);
  const response = await fetch(base + "/prepare", { method: "POST", headers, body: JSON.stringify({ ...f.input, destination: "clipboard", target: "markdown" }) });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).action, "copy-text");
  const legacy = await (await fetch(base + "/prepare", { method: "POST", headers, body: JSON.stringify({ ...f.input, requestID: randomUUID() }) })).json();
  assert.equal(legacy.action, "opencode-draft");
  assert.equal(f.created.length, 1);
  assert.equal(f.prompts.length, 0);
});

test("folder destination honors the exportDirectory plugin option", async (t) => {
  const f = await fixture(t);
  const custom = path.join(f.directory, "custom");
  const [target] = await folderDestination(custom).targets();
  assert.equal(target.detail, custom);
  const fromOptions = builtinDestinations(f.ctx, { exportDirectory: custom }).find((d) => d.id === "folder");
  assert.equal((await fromOptions.targets())[0].detail, custom);
  const relative = folderDestination("exports");
  assert.equal(await relative.status(), "not-installed");
  await assert.rejects(submitComposer(f.ctx, f.directory, { ...f.input, destination: "folder" }, [relative]), /not ready/);
});
