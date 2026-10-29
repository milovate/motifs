import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import os from "node:os";
import path from "node:path";
import { ambiguousSpans, configuredJudge, createSession, decisionJudge, localJudgeURL, looksRandom, redactBundle, redactText, redactionSummary } from "../redact.js";
import { contextDocument, draftText } from "../bundle.js";

const github = "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8";
const aws = "AKIA" + "IOSFODNN7EXAMPLE";
const jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
const random = "Zx81Qp0LmN4vT7rKc2Wd9YbE5";

test("known secret formats are always replaced", async () => {
  const session = createSession();
  const text = [
    `export GITHUB_TOKEN=${github}`,
    `aws ${aws}`,
    `Authorization: Bearer ${jwt}`,
    "postgres://admin:hunter2pass@db.internal:5432/app",
    'config = { "password": "correct horse" }',
    "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----",
  ].join("\n");
  const result = await redactText(text, session);
  for (const secret of [github, aws, jwt, "hunter2pass", "correct", "MIIEow"]) assert.ok(!result.includes(secret), `${secret} must be redacted`);
  assert.match(result, /postgres:\/\/admin:\[redacted\]@db\.internal/, "labels around a secret stay readable");
  assert.match(result, /Authorization: Bearer \[redacted\]/);
  assert.equal(session.report.fallback, 0, "known formats never need the judge");
  assert.ok(session.report.rule >= 6);
});

test("ordinary text, ids and already redacted values are left alone", async () => {
  const text = "Order 1234567 failed at https://shop.test/orders/1234567?page=2&id=7 for 3f2504e0-4f89-11d3-9a0c-0305e82c3301 · token=[redacted] · see /Users/me/Documents/project/readme.md";
  const session = createSession();
  assert.equal(await redactText(text, session), text);
  assert.equal(session.report.total, 0);
  assert.ok(!looksRandom("aaaaaaaaaaaaaaaaaaaaaaaa1") && !looksRandom("checkout-button-primary") && looksRandom(random));
});

test("secrets in URL paths and ordinary parameters are found as ambiguous values", () => {
  const spans = ambiguousSpans(`GET https://api.test/api/keys/abc123/rotate?id=${random}&page=2 and https://cdn.test/a/${random}.js`);
  assert.deepEqual(spans.map((span) => [span.kind, span.value]), [["url-path", "abc123"], ["url-value", random], ["url-path", random + ".js"]]);
});

test("ambiguous values are redacted when no local model answers", async () => {
  const session = createSession();
  const result = await redactText(`POST https://api.test/api/keys/abc123 failed; trace ${random}`, session);
  assert.equal(result, "POST https://api.test/api/keys/[redacted] failed; trace [redacted]");
  assert.equal(session.report.fallback, 2);
  assert.match(redactionSummary(session.report), /2 values that looked like secrets were replaced with \[redacted\] \(2 unconfirmed/);
});

test("a local judge keeps values it calls ordinary and redacts the rest", async () => {
  const states = [];
  const judge = async (state) => {
    states.push(state);
    return state.includes("⟦abc123⟧") ? 0.92 : 0.05;
  };
  const session = createSession(judge);
  const result = await redactText(`GET https://api.test/api/keys/abc123 and build ${random} and again ${random}`, session);
  assert.equal(result, `GET https://api.test/api/keys/[redacted] and build ${random} and again ${random}`);
  assert.equal(states.length, 2, "each distinct value is asked once");
  assert.ok(states[0].includes("api/keys/⟦abc123⟧"), "the judge sees the value marked in its surrounding text");
  assert.deepEqual([session.report.model, session.report.kept, session.report.fallback], [1, 2, 0]);
});

test("a failing judge falls back to redaction", async () => {
  const session = createSession(async () => {
    throw new Error("offline");
  });
  assert.equal(await redactText(`id ${random}`, session), "id [redacted]");
  assert.equal(session.report.fallback, 1);
});

test("only an endpoint on this Mac can be the judge", () => {
  assert.equal(localJudgeURL("http://127.0.0.1:8000"), "http://127.0.0.1:8000/v1/systemone");
  assert.equal(localJudgeURL("http://localhost:8888/v1/systemone"), "http://localhost:8888/v1/systemone");
  for (const raw of ["https://api.typesafe.ai", "http://10.0.0.5:8000", "http://user:pw@localhost:8000", "http://localhost.evil.test", "", undefined]) assert.equal(localJudgeURL(raw), undefined, String(raw));
  assert.equal(decisionJudge("https://api.cloudflare.com/client/v4/ai/run/@cf/cloudflare/clef"), undefined, "hosted Clef or Jev is refused");
});

test("the decision judge speaks the Jev-compatible API", async () => {
  let received;
  const server = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    received = { url: request.url, body: JSON.parse(Buffer.concat(chunks).toString("utf8")) };
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify({ answers: { secret: { noul: 0.83 } } }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const directory = await mkdtemp(path.join(os.tmpdir(), "redact-"));
    await writeFile(path.join(directory, "settings.json"), JSON.stringify({ redaction: { judge: `http://127.0.0.1:${server.address().port}`, model: "laya" } }));
    const judge = await configuredJudge(directory);
    assert.equal(await judge("key ⟦abc123⟧"), 0.83);
    assert.equal(received.url, "/v1/systemone");
    assert.equal(received.body.model, "laya");
    assert.equal(received.body.state.text, "key ⟦abc123⟧");
    assert.equal(received.body.questions.secret.type, "noul");
    assert.equal(await configuredJudge(path.join(directory, "missing")), undefined);
  } finally {
    server.close();
  }
});

test("bundles are redacted everywhere they leave the Mac, except the user's note", async () => {
  const bundle = {
    id: "b",
    manifest: "/tmp/captures/b.json",
    media: [{ screenshot: "/tmp/captures/s.png", app: "Terminal", title: `token ${github}`, text: `OPENAI_API_KEY=sk-proj-${random}` }],
    videos: [],
    browser: { url: `https://app.test/reset/${random}`, title: "Reset" },
    console: [{ time: "", level: "error", message: `401 for Bearer ${jwt}`, source: "browser" }],
    network: [{ time: "", method: "GET", url: "https://api.test/api/keys/abc123?id=7", status: 500 }],
    events: [{ time: "", kind: "select", text: `password: hunter2pass`, url: `https://app.test/?invite=${random}` }],
    customLogs: [{ name: "server.log", text: `boot ok\naws ${aws}` }],
    include: { windowText: true, device: true, console: true, network: true, events: true, customLogs: true },
  };
  const safe = await redactBundle(bundle);
  const everything = JSON.stringify({ ...safe, redaction: undefined });
  for (const secret of [github, random, jwt, "abc123", "hunter2pass", aws]) assert.ok(!everything.includes(secret), `${secret} must not leave the Mac`);
  assert.equal(bundle.media[0].text, `OPENAI_API_KEY=sk-proj-${random}`, "the saved bundle is not modified");
  assert.match(safe.network[0].url, /\/api\/keys\/\[redacted\]\?id=7$/);
  assert.ok(safe.redaction.total >= 7);
  const note = `my own key ${github}`;
  assert.ok(draftText(safe, note, "/tmp/captures/b-context.md").includes(note), "the note is the user's own words");
  assert.match(draftText(safe, note, "/tmp/captures/b-context.md"), /- Redacted: \d+ values that looked like secrets/);
  assert.match(contextDocument(safe), /^\d+ values that looked like secrets were replaced/);
});
