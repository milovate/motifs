import { constants } from "node:fs";
import { copyFile, mkdir, open, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { contextDocument, contextFilePath, draftText, markdownBundle, shareMarkdown, BUNDLE_SCHEMA } from "./bundle.js";

// Writes the bundle's full context beside it (owner-only, never through a symlink)
// and returns the path, or undefined when there is nothing to write.
export async function writeContextFile(bundle) {
  const body = contextDocument(bundle);
  if (!body) return undefined;
  const file = contextFilePath(bundle);
  const handle = await open(file, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW, 0o600);
  try {
    await handle.chmod(0o600);
    await handle.writeFile(`# Appshot context\n\n${body}\n`);
  } finally {
    await handle.close();
  }
  return file;
}

/**
 * A destination places a prepared bundle somewhere the user then acts on.
 * prepare() must never submit, send, or run anything on the user's behalf.
 *
 * @typedef {{ id: string, label: string, detail?: string }} Target
 * @typedef {"ready" | "not-installed" | "needs-auth" | "not-running"} DestinationStatus
 * @typedef {{ action: "opencode-draft", sessionID: string, title: string, directory: string, draftText: string }
 *   | { action: "desktop-draft", app: "claude" | "codex", draftText: string, directory?: string }
 *   | { action: "copy-text", text: string, message: string }
 *   | { action: "reveal-folder", path: string, message: string }} HandoffResult
 * @typedef {{
 *   id: string,
 *   label: string,
 *   accepts: { image: boolean, video: boolean, maxBytes?: number },
 *   status(): Promise<DestinationStatus>,
 *   targets(): Promise<Target[]>,
 *   actionLabel(target: Target): string,
 *   hint(target: Target): string,
 *   prepare(bundle: object, target: Target, request: { note: string, requestID: string }): Promise<HandoffResult>,
 * }} Destination
 */

export const HANDOFF_ACTIONS = ["opencode-draft", "desktop-draft", "copy-text", "reveal-folder"];
const STATUSES = ["ready", "not-installed", "needs-auth", "not-running"];

export function validateDestination(destination) {
  const fail = (reason) => {
    throw new Error(`Invalid destination ${JSON.stringify(destination?.id)}: ${reason}.`);
  };
  if (!destination || typeof destination !== "object") fail("not an object");
  if (typeof destination.id !== "string" || !/^[a-z][a-z0-9-]{0,31}$/.test(destination.id)) fail("id must be a short lowercase slug");
  if (typeof destination.label !== "string" || !destination.label.trim()) fail("missing label");
  const accepts = destination.accepts;
  if (!accepts || typeof accepts.image !== "boolean" || typeof accepts.video !== "boolean") fail("accepts must declare image and video");
  for (const method of ["status", "targets", "actionLabel", "hint", "prepare"]) if (typeof destination[method] !== "function") fail(`missing ${method}()`);
  return destination;
}

export function validateHandoff(result) {
  switch (result?.action) {
    case "opencode-draft":
      if (typeof result.sessionID !== "string" || typeof result.draftText !== "string") break;
      return result;
    case "desktop-draft":
      if (!["claude", "codex"].includes(result.app) || typeof result.draftText !== "string" || !result.draftText.trim()) break;
      if (result.app === "codex" && (typeof result.directory !== "string" || !path.isAbsolute(result.directory))) break;
      return result;
    case "copy-text":
      if (typeof result.text !== "string" || typeof result.message !== "string") break;
      return result;
    case "reveal-folder":
      if (typeof result.path !== "string" || !path.isAbsolute(result.path) || typeof result.message !== "string") break;
      return result;
    default:
      throw new Error(`Destination returned an unknown handoff action ${JSON.stringify(result?.action)}.`);
  }
  throw new Error(`Destination returned an incomplete ${result.action} handoff.`);
}

export async function describeDestinations(destinations) {
  return Promise.all(
    destinations.map(async (destination) => {
      const status = await destination.status().catch(() => "not-running");
      const targets = status === "ready" ? await destination.targets().catch(() => []) : [];
      return {
        id: destination.id,
        label: destination.label,
        accepts: destination.accepts,
        status: STATUSES.includes(status) ? status : "not-running",
        targets: targets.map((target) => ({
          id: target.id,
          label: target.label,
          ...(target.detail ? { detail: target.detail } : {}),
          actionLabel: destination.actionLabel(target),
          hint: destination.hint(target),
        })),
      };
    }),
  );
}

export function opencodeDestination(ctx) {
  const directory = ctx.location.directory;
  const target = { id: directory, label: path.basename(directory) || directory, detail: directory };
  return {
    id: "opencode",
    label: "OpenCode",
    accepts: { image: true, video: false, maxBytes: 30_000_000 },
    status: async () => "ready",
    targets: async () => [target],
    actionLabel: () => "Review in OpenCode",
    hint: () => "Opens an unsent draft in a new session. You press Enter.",
    async prepare(bundle, chosen, request) {
      if (chosen.id !== target.id) throw new Error("This OpenCode project is no longer loaded. Reopen the composer.");
      const contextFile = await writeContextFile(bundle);
      const session = await ctx.session.create({
        title: `Appshot: ${request.note.trim().split("\n")[0].slice(0, 80) || "Capture"} [${request.requestID.slice(-8)}]`,
        location: { directory, ...(ctx.location.workspaceID ? { workspaceID: ctx.location.workspaceID } : {}) },
      });
      return { action: "opencode-draft", sessionID: session.id, title: session.title, directory, draftText: draftText(bundle, request.note, contextFile) };
    },
  };
}

export function clipboardDestination() {
  const target = { id: "markdown", label: "Markdown" };
  return {
    id: "clipboard",
    label: "Clipboard",
    accepts: { image: true, video: true },
    status: async () => "ready",
    targets: async () => [target],
    actionLabel: () => "Copy Markdown",
    hint: () => "Copies a short summary: the note, file paths, key errors and the full-context file. Nothing is pasted for you.",
    async prepare(bundle, chosen, request) {
      if (chosen.id !== target.id) throw new Error("Unknown clipboard format.");
      const text = shareMarkdown(bundle, request.note, await writeContextFile(bundle));
      const count = bundle.media.length;
      const clips = bundle.videos.length;
      const parts = [count ? `${count} screenshot path${count === 1 ? "" : "s"}` : "", clips === 1 ? "the recording path" : clips ? `${clips} recording paths` : ""].filter(Boolean);
      return { action: "copy-text", text, message: `Copied Markdown${parts.length ? ` with ${parts.join(" and ")}` : ""}.` };
    },
  };
}

function desktopDestination(app, directory) {
  const label = app === "claude" ? "Claude" : "Codex";
  const target = directory
    ? { id: directory, label: path.basename(directory) || directory, detail: directory }
    : { id: "new-chat", label: "New chat" };
  return {
    id: app,
    label,
    accepts: { image: false, video: false },
    status: async () => "ready",
    targets: async () => [target],
    actionLabel: () => `Review in ${label}`,
    hint: () => "Opens a draft with local capture paths.",
    async prepare(bundle, _target, { note }) {
      const text = draftText(bundle, note, await writeContextFile(bundle), { attachImages: false });
      if (app === "claude" && text.length > 14_000) {
        throw new Error("This draft is too long for Claude Desktop. Shorten the note and try again.");
      }
      return { action: "desktop-draft", app, draftText: text, ...(directory ? { directory } : {}) };
    },
  };
}

export function folderDestination(exportRoot = path.join(os.homedir(), "Documents", "Appshots")) {
  const target = { id: "exports", label: path.basename(exportRoot) || exportRoot, detail: exportRoot };
  return {
    id: "folder",
    label: "Save to folder",
    accepts: { image: true, video: true },
    status: async () => (path.isAbsolute(exportRoot) ? "ready" : "not-installed"),
    targets: async () => [target],
    actionLabel: () => "Save bundle",
    hint: () => `Writes screenshots, any recording, README.md and bundle.json to ${exportRoot}.`,
    async prepare(bundle, chosen, request) {
      if (chosen.id !== target.id) throw new Error("Unknown export folder.");
      await mkdir(exportRoot, { recursive: true, mode: 0o700 });
      const stamp = new Date().toISOString().replace(/[:T]/g, "-").slice(0, 19);
      const slug = request.note.trim().split("\n")[0].toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "capture";
      const folder = path.join(exportRoot, `${stamp} ${slug} ${request.requestID.slice(-8)}`);
      await mkdir(folder, { mode: 0o700 });
      const names = bundle.media.map((_, index) => `screenshot-${index + 1}.png`);
      for (const [index, capture] of bundle.media.entries()) await copyFile(capture.screenshot, path.join(folder, names[index]));
      // recording.mp4 for the first clip, recording-2.mp4 and so on for the others.
      const videoName = (video, index) => {
        const clip = bundle.videos.indexOf(video);
        const stem = clip > 0 ? `recording-${clip + 1}` : "recording";
        return index < 0 ? `${stem}.mp4` : `${stem}-frame-${index + 1}.png`;
      };
      for (const video of bundle.videos) {
        await copyFile(video.video, path.join(folder, videoName(video, -1)));
        for (const [index, frame] of video.frames.entries()) await copyFile(frame.screenshot, path.join(folder, videoName(video, index)));
      }
      await writeFile(path.join(folder, "README.md"), markdownBundle(bundle, request.note, (_, index) => names[index], videoName), { mode: 0o600, flag: "wx" });
      const exported = {
        schema: BUNDLE_SCHEMA,
        id: bundle.id,
        createdAt: bundle.createdAt,
        note: request.note.trim(),
        media: [
          ...bundle.media.map((capture, index) => exportedShot(capture, names[index], bundle.include.windowText)),
          ...bundle.videos.map((video) => ({
            kind: "video",
            video: videoName(video, -1),
            source: video.source,
            area: video.area,
            target: video.target,
            startedAt: video.startedAt,
            durationSeconds: video.durationSeconds,
            pauses: video.pauses,
            frames: video.frames.map((frame, index) => ({ screenshot: videoName(video, index), offsetSeconds: frame.offsetSeconds })),
          })),
        ],
        context: exportedContext(bundle),
        include: bundle.include,
      };
      await writeFile(path.join(folder, "bundle.json"), JSON.stringify(exported, null, 2) + "\n", { mode: 0o600, flag: "wx" });
      return { action: "reveal-folder", path: folder, message: `Saved to ${path.basename(folder)}.` };
    },
  };
}

function exportedContext(bundle) {
  const context = {};
  if (bundle.include.device) Object.assign(context, { device: bundle.device, system: bundle.system, app: bundle.app, browser: bundle.browser });
  if (bundle.include.console) context.console = { entries: bundle.console };
  if (bundle.include.network) context.network = { entries: bundle.network };
  if (bundle.include.events) context.events = { entries: bundle.events };
  if (bundle.include.customLogs) context.customLogs = bundle.customLogs.map(({ name, text, truncated }) => ({ name, text, truncated }));
  return JSON.parse(JSON.stringify(context));
}

// Exports never carry paths back into the private captures folder.
function exportedShot(capture, screenshot, includeText) {
  const shot = { kind: "image", screenshot };
  for (const key of ["app", "bundleID", "title", "capturedAt", "annotatedAt", "warnings", "crop"]) if (capture[key] !== undefined) shot[key] = capture[key];
  if (includeText) shot.text = String(capture.text || "");
  return shot;
}

export function builtinDestinations(ctx, options = {}, platform = process.platform) {
  const desktop = platform === "darwin" ? [desktopDestination("claude"), desktopDestination("codex", ctx.location.directory)] : [];
  return [opencodeDestination(ctx), ...desktop, clipboardDestination(), folderDestination(options.exportDirectory)].map(validateDestination);
}
