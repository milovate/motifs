import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, writeFile, readFile, readdir, stat, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { startComposerBridge, submitComposer } from "../composer-bridge.js";

async function fixture(t) {
  const directory = await mkdtemp(path.join(tmpdir(), "appshots-composer-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=", "base64");
  const screenshot = path.join(directory, "capture.png");
  await writeFile(screenshot, png);
  const manifest = path.join(directory, "capture.json");
  await writeFile(manifest, JSON.stringify({ app: "Fixture", title: "Page", screenshot, capturedAt: "2026-10-21", text: "Untrusted page text", annotatedAt: "2026-10-21" }));
  const created = [];
  const prompts = [];
  const ctx = {
    location: { directory: "/fixture/project", workspaceID: "workspace" },
    skill: { list: async () => ({ data: [{ id: "report", name: "Report", content: "private skill content" }, { id: "other", name: "Other" }] }) },
    session: {
      create: async (input) => { created.push(input); return { id: `ses_fixture${created.length}`, title: input.title }; },
      prompt: async (input) => { prompts.push(input); },
    },
  };
  return { ctx, directory, manifest, png, created, prompts, input: { requestID: randomUUID(), text: "This button feels broken", skills: ["report"], manifest } };
}

const contextOf = (draft) => readFile(draft.match(/^- Full context[^:]*: (.+)$/m)[1], "utf8");

test("composer prepares a fresh root session and an unsent draft, never invokes a model", async (t) => {
  const f = await fixture(t);
  const first = await submitComposer(f.ctx, f.directory, f.input);
  const second = await submitComposer(f.ctx, f.directory, { ...f.input, requestID: randomUUID() });
  assert.notEqual(first.sessionID, second.sessionID);
  assert.equal(f.created.length, 2);
  assert.deepEqual(f.created[0].location, { directory: "/fixture/project", workspaceID: "workspace" });
  assert.equal(f.created[0].parentID, undefined);
  assert.equal(f.prompts.length, 0, "preparation must not admit or generate a message");
  assert.match(first.draftText, /^This button feels broken/);
  assert.match(first.draftText, /untrusted app content/);
  assert.ok(first.draftText.includes(path.join(f.directory, "capture.png")), "the draft gives the screenshot path");
  assert.ok(!first.draftText.includes("Untrusted page text"), "window text is in the context file, not the prompt");
  assert.match(await contextOf(first.draftText), /Accessibility text describes the original capture/);
  assert.match(first.title, /\[[a-f0-9-]{8}\]$/i);
});

test("validates the draft, skills and exact capture before creating any session", async (t) => {
  const f = await fixture(t);
  for (const change of [{ text: "x".repeat(16_001) }, { skills: ["missing"] }, { skills: "report" }, { manifest: path.join(f.directory, "latest.json") }]) {
    await assert.rejects(submitComposer(f.ctx, f.directory, { ...f.input, ...change }));
  }
  assert.equal(f.created.length, 0);
  const noteless = await submitComposer(f.ctx, f.directory, { ...f.input, text: " " });
  assert.match(noteless.title, /^Appshot: Capture \[/, "a screenshot can be sent without a note");
  f.created.length = 0;
  await writeFile(f.manifest, JSON.stringify({ screenshot: path.join(f.directory, "../outside.png") }));
  await assert.rejects(submitComposer(f.ctx, f.directory, f.input));
  assert.equal(f.created.length, 0);
});

test("prepares multiple ordered screenshots and does not leak cropped-out context", async (t) => {
  const f = await fixture(t);
  const first = JSON.parse(await readFile(f.manifest, "utf8"));
  const secondPath = path.join(f.directory, "region.png");
  await writeFile(secondPath, f.png);
  const second = { ...first, app: "Region two", screenshot: secondPath, text: "", originalAccessibilityText: "PRIVATE OUTSIDE CROP", warnings: ["Cropped screenshot: outside context omitted."] };
  await writeFile(f.manifest, JSON.stringify({ screenshots: [first, second] }));
  const result = await submitComposer(f.ctx, f.directory, f.input);
  assert.ok(result.draftText.indexOf("Screenshot 1 of 2") < result.draftText.indexOf("Screenshot 2 of 2"));
  assert.match(result.draftText, /Region two/);
  assert.ok(!result.draftText.includes("PRIVATE OUTSIDE CROP"));
  assert.ok(!(await contextOf(result.draftText)).includes("PRIVATE OUTSIDE CROP"));
  assert.equal(f.prompts.length, 0);
});

test("intentional empty screenshot collections create text-only drafts", async (t) => {
  const f = await fixture(t);
  await writeFile(f.manifest, JSON.stringify({ screenshots: [] }));
  const result = await submitComposer(f.ctx, f.directory, f.input);
  assert.equal(result.draftText, f.input.text);
  assert.equal(f.created.length, 1);
  assert.equal(f.prompts.length, 0);
});

test("all screenshots are validated before a session is created", async (t) => {
  const f = await fixture(t);
  const first = JSON.parse(await readFile(f.manifest, "utf8"));
  for (const screenshots of [[first, { screenshot: path.join(f.directory, "../outside.png") }], Array(9).fill(first), null, "invalid"]) {
    await writeFile(f.manifest, JSON.stringify({ screenshots }));
    await assert.rejects(submitComposer(f.ctx, f.directory, f.input));
  }
  const padded = Buffer.alloc(8_000_000);
  f.png.copy(padded);
  await writeFile(first.screenshot, padded);
  await writeFile(f.manifest, JSON.stringify({ screenshots: Array(4).fill(first) }));
  await assert.rejects(submitComposer(f.ctx, f.directory, f.input), /30 MB/);
  assert.equal(f.created.length, 0);
});

test("accessibility context has one combined budget across screenshots", async (t) => {
  const f = await fixture(t);
  const first = JSON.parse(await readFile(f.manifest, "utf8"));
  await writeFile(f.manifest, JSON.stringify({ screenshots: [{ ...first, text: "a".repeat(120_000) }, { ...first, text: "OUTSIDE_COMBINED_BUDGET" }] }));
  const result = await submitComposer(f.ctx, f.directory, f.input);
  const written = await contextOf(result.draftText);
  assert.ok(!written.includes("OUTSIDE_COMBINED_BUDGET"));
  assert.match(written, /combined 120000-character delivery limit/);
  assert.ok(result.draftText.length < 2_000, "the prompt stays short even with large window text");
});

test("loopback bridge is private, rejects browser traffic, and only explicit sends create sessions", async (t) => {
  const f = await fixture(t);
  const stop = await startComposerBridge(f.ctx, f.directory);
  t.after(stop);
  const folder = path.join(f.directory, "composers");
  const [name] = await readdir(folder);
  const file = path.join(folder, name);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  const descriptor = JSON.parse(await readFile(file, "utf8"));
  const base = `http://127.0.0.1:${descriptor.port}`;
  const headers = { Authorization: `Bearer ${descriptor.token}`, "Content-Type": "application/json" };
  assert.equal((await fetch(base + "/skills")).status, 403);
  assert.equal((await fetch(base + "/skills", { headers: { ...headers, Origin: "https://example.com" } })).status, 403);
  const listed = await (await fetch(base + "/skills", { headers })).json();
  assert.equal(listed.skills[0].id, "report");
  assert.equal(listed.skills[0].content, undefined);
  assert.equal(f.created.length, 0);
  assert.equal((await fetch(base + "/send", { method: "POST", headers, body: JSON.stringify(f.input) })).status, 404, "old helpers cannot automatically send messages");
  const send = (input) => fetch(base + "/prepare", { method: "POST", headers, body: JSON.stringify(input) });
  const [a, b] = await Promise.all([send(f.input), send(f.input)]);
  assert.equal(a.status, 200);
  assert.deepEqual(await a.json(), await b.json());
  assert.equal(f.created.length, 1);
  assert.equal(f.prompts.length, 0);
  assert.equal((await send({ ...f.input, text: "changed" })).status, 400);
  assert.equal(f.created.length, 1);
  await send({ ...f.input, requestID: randomUUID() });
  assert.equal(f.created.length, 2);
  await stop();
  assert.deepEqual(await readdir(folder), []);
});

test("uncertain session creation is not automatically retried", async (t) => {
  const f = await fixture(t);
  let count = 0;
  f.ctx.session.create = async () => { count++; throw new Error("connection lost"); };
  const stop = await startComposerBridge(f.ctx, f.directory);
  t.after(stop);
  const [name] = await readdir(path.join(f.directory, "composers"));
  const descriptor = JSON.parse(await readFile(path.join(f.directory, "composers", name), "utf8"));
  for (let i = 0; i < 2; i++) {
    const response = await fetch(`http://127.0.0.1:${descriptor.port}/prepare`, { method: "POST", headers: { Authorization: `Bearer ${descriptor.token}` }, body: JSON.stringify(f.input) });
    assert.equal(response.status, 400);
    assert.match((await response.json()).error, /connection lost/);
  }
  assert.equal(f.created.length, 0);
  assert.equal(count, 1);
});

test("secrets are redacted before any destination sees them, and the helper can redact pasted text", async (t) => {
  const f = await fixture(t);
  const token = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8";
  const capture = JSON.parse(await readFile(f.manifest, "utf8"));
  await writeFile(f.manifest, JSON.stringify({ ...capture, text: `GITHUB_TOKEN=${token}\nGET https://api.test/api/keys/abc123` }));
  const result = await submitComposer(f.ctx, f.directory, f.input);
  const written = await contextOf(result.draftText);
  assert.ok(!written.includes(token) && !written.includes("abc123"), "the context file carries no secrets");
  assert.match(written, /api\/keys\/\[redacted\]/);
  assert.match(result.draftText, /- Redacted: 2 values that looked like secrets/);
  assert.ok(JSON.parse(await readFile(f.manifest, "utf8")).text.includes(token), "the local capture keeps the original");
  const stop = await startComposerBridge(f.ctx, f.directory);
  t.after(stop);
  const [name] = await readdir(path.join(f.directory, "composers"));
  const descriptor = JSON.parse(await readFile(path.join(f.directory, "composers", name), "utf8"));
  const redact = (headers) => fetch(`http://127.0.0.1:${descriptor.port}/redact`, { method: "POST", headers, body: JSON.stringify({ text: `token ${token}` }) });
  assert.equal((await redact({})).status, 403, "redaction needs the bridge token");
  const redacted = await (await redact({ Authorization: `Bearer ${descriptor.token}` })).json();
  assert.equal(redacted.text, "token [redacted]");
  assert.equal(redacted.redaction.rule, 1);
});
