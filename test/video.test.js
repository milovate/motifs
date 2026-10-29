import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { BUNDLE_SCHEMA, contextDocument, draftText, markdownBundle, readBundle } from "../bundle.js";
import { clipboardDestination, folderDestination } from "../destinations.js";

const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=", "base64");
const MP4 = Buffer.from("000000186674797069736f6d0000020069736f6d69736f32", "hex");

async function videoBundle(t, video = {}, extra = {}) {
  const directory = await mkdtemp(path.join(tmpdir(), "capture-studio-video-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const screenshot = path.join(directory, "shot.png");
  await writeFile(screenshot, PNG);
  const mp4 = path.join(directory, "replay.mp4");
  await writeFile(mp4, MP4);
  const frames = [];
  for (let index = 0; index < 8; index += 1) {
    const frame = path.join(directory, `replay-frame-${index}.png`);
    await writeFile(frame, PNG);
    frames.push({ screenshot: frame, offsetSeconds: index * 5 });
  }
  const manifest = path.join(directory, `bundle-${randomUUID()}.json`);
  const media = [
    { kind: "image", screenshot, app: "Google Chrome", capturedAt: "2026-10-29T10:00:30Z", text: "Window" },
    { kind: "video", video: mp4, source: "replay", startedAt: "2026-10-29T10:00:00Z", durationSeconds: 30, frames, ...video },
  ];
  const context = { events: { entries: [{ time: "2026-10-29T10:00:12.400Z", kind: "click", app: "Chrome", role: "AXButton", title: "Pay" }, { time: "2026-10-29T09:50:00Z", kind: "app-switch", app: "Finder" }] } };
  await writeFile(manifest, JSON.stringify({ schema: BUNDLE_SCHEMA, id: "video", media, context, include: {}, ...extra }));
  return { directory, manifest, bundle: await readBundle(directory, manifest) };
}

test("video media entries are validated, capped and kept apart from screenshots", async (t) => {
  const { bundle } = await videoBundle(t);
  assert.equal(bundle.media.length, 1, "screenshots stay screenshots");
  assert.equal(bundle.videos.length, 1);
  const [video] = bundle.videos;
  assert.equal(video.source, "replay");
  assert.equal(video.durationSeconds, 30);
  assert.equal(video.frames.length, 6, "at most 6 key frames");
  assert.deepEqual(video.frames.map((frame) => frame.offsetSeconds), [0, 5, 10, 15, 20, 25]);
  const { bundle: odd } = await videoBundle(t, { source: "something", durationSeconds: 99_999 });
  assert.equal(odd.videos[0].source, "replay");
  assert.equal(odd.videos[0].durationSeconds, 300);
});

test("videos outside the captures folder or with the wrong type are refused", async (t) => {
  const { directory } = await videoBundle(t);
  const outside = await mkdtemp(path.join(tmpdir(), "capture-studio-outside-"));
  t.after(() => rm(outside, { recursive: true, force: true }));
  const foreign = path.join(outside, "x.mp4");
  await writeFile(foreign, MP4);
  const notVideo = path.join(directory, "notes.txt");
  await writeFile(notVideo, "x");
  for (const [video, message] of [[foreign, /MP4 files in the capture folder/], [notVideo, /MP4 files in the capture folder/], [undefined, /Invalid screen recording/]]) {
    const manifest = path.join(directory, `bundle-${randomUUID()}.json`);
    await writeFile(manifest, JSON.stringify({ schema: BUNDLE_SCHEMA, media: [{ kind: "video", video }] }));
    await assert.rejects(readBundle(directory, manifest), message);
  }
  const four = path.join(directory, `bundle-${randomUUID()}.json`);
  await writeFile(four, JSON.stringify({ schema: BUNDLE_SCHEMA, media: Array.from({ length: 4 }, () => ({ kind: "video", video: path.join(directory, "replay.mp4") })) }));
  await assert.rejects(readBundle(directory, four), /up to 3 screen recordings/);
});

test("the draft describes the recording, numbers its frames after the screenshots and times events", async (t) => {
  const { bundle } = await videoBundle(t);
  const draft = contextDocument(bundle);
  assert.match(draft, /Instant replay: 30\.0 s of the display, starting 2026-10-29T10:00:00Z/);
  assert.match(draft, process.platform === "win32" ? /Visible pixels can include Capture Studio's own windows/ : /Capture Studio's own windows are not recorded/);
  assert.match(draft, /Key frames attached as images 2–7, at \+0\.0 s, \+5\.0 s, \+10\.0 s, \+15\.0 s, \+20\.0 s, \+25\.0 s\./);
  assert.match(draft, /The full MP4 stays on the user's Mac and is not attached/);
  assert.match(draft, /Clicked button "Pay" in Chrome \(\+12\.4 s in instant replay\)/);
  assert.match(draft, /Switched to Finder\n|Switched to Finder$/m, "events outside the recording get no offset");
  assert.ok(!draft.includes("replay.mp4"), "local paths stay out of the context document");
  const lean = draftText(bundle, "Payment spinner never stops", "/captures/bundle-context.md");
  assert.match(lean, /- Instant replay: \/.*replay\.mp4 · 30\.0 s of the display · key frames attached as images 2–7: /);
  assert.match(lean, /- Full context \(.*steps 2.*recording timelines\): \/captures\/bundle-context\.md/);
  const { bundle: recording } = await videoBundle(t, { source: "recording", frames: [] });
  assert.match(contextDocument(recording), /Screen recording: 30\.0 s[\s\S]*No key frames were extracted/);
});

test("Markdown links the recording and the folder export copies it with its frames", async (t) => {
  const { directory, bundle } = await videoBundle(t);
  const copied = await clipboardDestination().prepare(bundle, { id: "markdown" }, { note: "note", requestID: randomUUID() });
  assert.match(copied.text, /^- Instant replay: 30\.0 s of the display · `\/[^`]*\/capture-studio-video-[^/]+\/replay\.mp4`$/m);
  assert.match(copied.text, /^Full context: `[^`]+-context\.md`$/m);
  assert.ok(!copied.text.includes("<appshot"), "clipboard summary leaves the full context in the file");
  assert.equal(copied.message, "Copied Markdown with 1 screenshot path and the recording path.");
  const exportRoot = path.join(directory, "exports");
  const result = await folderDestination(exportRoot).prepare(bundle, { id: "exports" }, { note: "note", requestID: randomUUID() });
  const files = (await readdir(result.path)).sort();
  assert.deepEqual(files, ["README.md", "bundle.json", "recording-frame-1.png", "recording-frame-2.png", "recording-frame-3.png", "recording-frame-4.png", "recording-frame-5.png", "recording-frame-6.png", "recording.mp4", "screenshot-1.png"]);
  assert.deepEqual(await readFile(path.join(result.path, "recording.mp4")), MP4);
  const exported = JSON.parse(await readFile(path.join(result.path, "bundle.json"), "utf8"));
  const video = exported.media.find((entry) => entry.kind === "video");
  assert.deepEqual({ ...video, frames: video.frames.length }, { kind: "video", video: "recording.mp4", source: "replay", area: "display", startedAt: "2026-10-29T10:00:00Z", durationSeconds: 30, pauses: [], frames: 6 });
  assert.ok(!JSON.stringify(exported).includes(path.basename(directory)), "exports carry no private paths");
  const readme = await readFile(path.join(result.path, "README.md"), "utf8");
  assert.match(readme, /\[Open the MP4\]\(<recording\.mp4>\)/);
  assert.match(readme, /!\[Frame at \+25\.0 s\]\(<recording-frame-6\.png>\)/);
  assert.match(markdownBundle(bundle, "n", () => "s.png"), new RegExp(`<\\/[^>]*${path.basename(directory)}\\/replay-frame-0\\.png>`), "clipboard Markdown uses absolute local frame paths");
});

test("several clips share six key frames, describe what they recorded and skip paused time", async (t) => {
  const { directory } = await videoBundle(t);
  const clip = async (name, extra) => {
    const mp4 = path.join(directory, `${name}.mp4`);
    await writeFile(mp4, MP4);
    const frames = [];
    for (let index = 0; index < 4; index += 1) {
      const frame = path.join(directory, `${name}-frame-${index}.png`);
      await writeFile(frame, PNG);
      frames.push({ screenshot: frame, offsetSeconds: index });
    }
    return { kind: "video", video: mp4, source: "recording", frames, ...extra };
  };
  const media = [
    await clip("one", { area: "window", target: "Safari", startedAt: "2026-10-29T10:00:00Z", durationSeconds: 20, pauses: [{ atSeconds: 5, durationSeconds: 60 }] }),
    await clip("two", { area: "area", target: "400 × 300 area", startedAt: "2026-10-29T10:05:00Z", durationSeconds: 10 }),
    await clip("three", { area: "bogus", startedAt: "2026-10-29T10:10:00Z", durationSeconds: 5 }),
  ];
  const events = [
    { time: "2026-10-29T10:00:03Z", kind: "click", app: "Safari", role: "AXButton", title: "Before pause" },
    { time: "2026-10-29T10:00:30Z", kind: "click", app: "Safari", role: "AXButton", title: "During pause" },
    { time: "2026-10-29T10:01:10Z", kind: "click", app: "Safari", role: "AXButton", title: "After pause" },
    { time: "2026-10-29T10:05:04Z", kind: "click", app: "Notes", role: "AXButton", title: "Second clip" },
  ];
  const manifest = path.join(directory, `bundle-${randomUUID()}.json`);
  await writeFile(manifest, JSON.stringify({ schema: BUNDLE_SCHEMA, media, context: { events: { entries: events } }, include: {} }));
  const bundle = await readBundle(directory, manifest);
  assert.deepEqual(bundle.videos.map((video) => video.frames.length), [4, 2, 0], "at most six frames across all clips");
  assert.deepEqual(bundle.videos.map((video) => video.area), ["window", "area", "display"]);
  const draft = contextDocument(bundle);
  assert.match(draft, /Screen recording 1: 20\.0 s of the "Safari" window, starting 2026-10-29T10:00:00Z\. Capture Studio's own windows are not recorded\. Paused 1 time; paused time is not in the clip\.\nKey frames attached as images 1–4/);
  assert.match(draft, /Screen recording 2: 10\.0 s of a 400 × 300 area of the screen[\s\S]*Key frames attached as images 5–6/);
  assert.match(draft, /Screen recording 3: 5\.0 s of the display[\s\S]*No key frames were extracted/);
  assert.match(draft, /"Before pause" in Safari \(\+3\.0 s in screen recording 1\)/);
  assert.match(draft, /"During pause" in Safari\n/, "events while paused have no offset");
  assert.match(draft, /"After pause" in Safari \(\+10\.0 s in screen recording 1\)/);
  assert.match(draft, /"Second clip" in Notes \(\+4\.0 s in screen recording 2\)/);
  const result = await folderDestination(path.join(directory, "exports")).prepare(bundle, { id: "exports" }, { note: "note", requestID: randomUUID() });
  const files = (await readdir(result.path)).filter((file) => file.startsWith("recording")).sort();
  assert.deepEqual(files, ["recording-2-frame-1.png", "recording-2-frame-2.png", "recording-2.mp4", "recording-3.mp4", "recording-frame-1.png", "recording-frame-2.png", "recording-frame-3.png", "recording-frame-4.png", "recording.mp4"]);
  const exported = JSON.parse(await readFile(path.join(result.path, "bundle.json"), "utf8"));
  assert.deepEqual(exported.media.map((entry) => [entry.video, entry.target, entry.pauses.length]), [["recording.mp4", "Safari", 1], ["recording-2.mp4", "400 × 300 area", 0], ["recording-3.mp4", undefined, 0]]);
  const copied = await clipboardDestination().prepare(bundle, { id: "markdown" }, { note: "note", requestID: randomUUID() });
  assert.equal(copied.message, "Copied Markdown with 3 recording paths.");
  assert.match(copied.text, /^- Screen recording 2: 10\.0 s of a 400 × 300 area of the screen · `/m);
});

test("bundles without video still read as before", async (t) => {
  const { directory } = await videoBundle(t);
  const manifest = path.join(directory, `bundle-${randomUUID()}.json`);
  await writeFile(manifest, JSON.stringify({ schema: BUNDLE_SCHEMA, media: [{ screenshot: path.join(directory, "shot.png") }] }));
  const bundle = await readBundle(directory, manifest);
  assert.deepEqual(bundle.videos, []);
  assert.ok(!contextDocument(bundle).includes("replay"));
});
