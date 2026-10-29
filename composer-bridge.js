import { createServer } from "node:http";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdir, writeFile, rename, unlink } from "node:fs/promises";
import path from "node:path";
import { readBundle } from "./bundle.js";
import { builtinDestinations, describeDestinations, validateHandoff } from "./destinations.js";

// One private, authenticated loopback endpoint per loaded OpenCode location.
// This bridge only prepares handoffs. It NEVER admits a prompt or starts a model.
export async function startComposerBridge(ctx, captures, destinations = builtinDestinations(ctx, ctx.options)) {
  const token = randomBytes(32).toString("hex");
  const directory = path.join(captures, "composers");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const descriptor = path.join(directory, `${randomUUID()}.json`);
  const submissions = new Map();
  const server = createServer(async (request, response) => {
    response.setHeader("Content-Type", "application/json");
    response.setHeader("Cache-Control", "no-store");
    // Reject browser-origin traffic, including authenticated requests.
    if (request.headers.origin || request.headers.authorization !== `Bearer ${token}`) {
      response.writeHead(403).end(JSON.stringify({ error: "Forbidden" }));
      return;
    }
    try {
      if (request.method === "GET" && request.url === "/skills") {
        const result = await ctx.skill.list();
        response.end(JSON.stringify({ skills: result.data.map(({ id, name, description }) => ({ id, name, description })) }));
        return;
      }
      if (request.method === "GET" && request.url === "/destinations") {
        response.end(JSON.stringify({ destinations: await describeDestinations(destinations) }));
        return;
      }
      if (request.method !== "POST" || request.url !== "/prepare") {
        response.writeHead(404).end(JSON.stringify({ error: "Not found" }));
        return;
      }
      const chunks = [];
      let bytes = 0;
      for await (const chunk of request) {
        bytes += chunk.length;
        if (bytes > 128_000) throw new Error("Composer request is too large.");
        chunks.push(chunk);
      }
      const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (typeof input.requestID !== "string" || !/^[a-f0-9-]{36}$/i.test(input.requestID)) throw new Error("Invalid submission ID.");
      const fingerprint = JSON.stringify(input);
      let submission = submissions.get(input.requestID);
      if (submission && submission.fingerprint !== fingerprint) throw new Error("This submission has already been sent. Open a new composer to send a different message.");
      if (!submission) {
        // Keep successes AND failures: an uncertain response must never auto-send twice.
        if (submissions.size >= 1000) throw new Error("Composer submission limit reached. Reload the plugin.");
        submission = { fingerprint, result: submitComposer(ctx, captures, input, destinations) };
        submissions.set(input.requestID, submission);
      }
      response.end(JSON.stringify(await submission.result));
    } catch (error) {
      response.writeHead(400).end(JSON.stringify({ error: error.message || "Could not submit capture." }));
    }
  });
  server.requestTimeout = 30_000;
  server.headersTimeout = 10_000;
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  server.unref();
  const temporary = descriptor + ".tmp";
  try {
    await writeFile(temporary, JSON.stringify({ directory: ctx.location.directory, port: server.address().port, token }), { mode: 0o600 });
    await rename(temporary, descriptor);
  } catch (error) {
    server.close();
    await unlink(temporary).catch(() => {});
    throw error;
  }
  return async () => {
    await unlink(descriptor).catch(() => {});
    server.close();
    server.closeIdleConnections();
  };
}

export async function submitComposer(ctx, captures, input, destinations = builtinDestinations(ctx, ctx.options)) {
  if (typeof input.text !== "string" || !input.text.trim() || input.text.length > 16_000) throw new Error("Describe the problem before sending (up to 16000 characters).");
  const destinationID = input.destination ?? "opencode";
  const destination = destinations.find((candidate) => candidate.id === destinationID);
  if (!destination) throw new Error("That destination is not available. Reopen the composer.");
  const bundle = await readBundle(captures, input.manifest);
  const available = (await ctx.skill.list()).data;
  if (!Array.isArray(input.skills) || !input.skills.every((id) => typeof id === "string" && available.some((skill) => skill.id === id))) throw new Error("A selected skill is no longer available. Reopen the composer.");
  if ((await destination.status()) !== "ready") throw new Error(`${destination.label} is not ready.`);
  const targets = await destination.targets();
  const target = input.target === undefined ? targets[0] : targets.find((candidate) => candidate.id === input.target);
  if (!target) throw new Error(`That ${destination.label} target is no longer available. Reopen the composer.`);
  return validateHandoff(await destination.prepare(bundle, target, { note: input.text, requestID: input.requestID }));
}

