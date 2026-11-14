import assert from "node:assert/strict";
import test from "node:test";
import { checkForUpdates, compareVersions, parseVersion, updateMessage } from "../updates.js";
import { updateCheckText } from "../index.js";

const releasePage = "https://github.com/milovate/motifs/releases/tag/v0.5.0";

function github(status, body) {
  const requests = [];
  const fetch = async (url, options) => {
    requests.push({ url, options });
    return { status, ok: status >= 200 && status < 300, json: async () => body };
  };
  return { fetch, requests };
}

function release(assets = []) {
  return {
    tag_name: "v0.5.0",
    html_url: releasePage,
    assets: assets.map(name => ({ name, browser_download_url: `https://github.com/milovate/motifs/releases/download/v0.5.0/${name}` })),
  };
}

test("versions compare numerically, not as text", () => {
  assert.deepEqual(parseVersion("v1.10.0"), [1, 10, 0]);
  assert.equal(parseVersion("1.0.0-beta"), undefined);
  assert.equal(parseVersion("01.0.0"), undefined);
  assert.equal(compareVersions("0.10.0", "0.9.9"), 1);
  assert.equal(compareVersions("v0.4.3", "0.4.3"), 0);
  assert.equal(compareVersions("0.4.3", "0.5.0"), -1);
  assert.throws(() => compareVersions("latest", "0.4.3"), /Cannot compare/);
});

test("asks only for the latest stable release of this repository", async () => {
  const { fetch, requests } = github(200, release());
  await checkForUpdates({ current: "0.4.3", target: "macos-arm64", fetch });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, "https://api.github.com/repos/milovate/motifs/releases/latest");
  assert.equal(requests[0].options.headers.accept, "application/vnd.github+json");
  assert.ok(requests[0].options.signal);
});

test("offers the download that matches this computer", async () => {
  const { fetch } = github(200, release(["motifs-0.5.0-macos-arm64.zip", "motifs-0.5.0-windows-x64.zip"]));
  const result = await checkForUpdates({ current: "0.4.3", target: "windows-x64", fetch });
  assert.deepEqual(result, {
    status: "available",
    current: "0.4.3",
    latest: "0.5.0",
    page: releasePage,
    archive: "motifs-0.5.0-windows-x64.zip",
    download: "https://github.com/milovate/motifs/releases/download/v0.5.0/motifs-0.5.0-windows-x64.zip",
  });
  assert.match(updateMessage(result), /Download for this computer: .*windows-x64\.zip/);
  assert.match(updateMessage(result), /Nothing was downloaded or installed/);
});

test("falls back to the release page when this computer has no download", async () => {
  const { fetch } = github(200, release(["motifs-0.5.0-macos-arm64.zip"]));
  for (const target of ["windows-x64", undefined]) {
    const result = await checkForUpdates({ current: "0.4.3", target, fetch });
    assert.equal(result.download, undefined);
    assert.match(updateMessage(result), new RegExp(`no download for this computer. Release page: ${releasePage}`));
  }
});

test("ignores links that leave the Motifs repository", async () => {
  const body = release(["motifs-0.5.0-macos-arm64.zip"]);
  body.html_url = "https://example.com/motifs";
  body.assets[0].browser_download_url = "https://example.com/motifs.zip";
  const result = await checkForUpdates({ current: "0.4.3", target: "macos-arm64", fetch: github(200, body).fetch });
  assert.equal(result.page, "https://github.com/milovate/motifs/releases/latest");
  assert.equal(result.download, undefined);
});

test("reports an installed version that is current or newer", async () => {
  for (const current of ["0.5.0", "0.6.0"]) {
    const result = await checkForUpdates({ current, target: "macos-arm64", fetch: github(200, release()).fetch });
    assert.equal(result.status, "current");
    assert.match(updateMessage(result), new RegExp(`Motifs ${current} is up to date`));
  }
});

test("explains when nothing has been released yet", async () => {
  const result = await checkForUpdates({ current: "0.4.3", target: "macos-arm64", fetch: github(404, { message: "Not Found" }).fetch });
  assert.deepEqual(result, { status: "none", current: "0.4.3" });
  assert.match(updateMessage(result), /No stable Motifs release has been published yet/);
});

test("rejects unusable answers instead of guessing", async () => {
  await assert.rejects(checkForUpdates({ current: "0.4.3", fetch: github(403, {}).fetch }), /answered 403/);
  await assert.rejects(checkForUpdates({ current: "0.4.3", fetch: github(200, { tag_name: "nightly" }).fetch }), /not a version/);
  await assert.rejects(checkForUpdates({ current: "dev", fetch: github(200, release()).fetch }), /not a release version/);
});

test("the update command reads the installed version and reports failures as text", async () => {
  const readFile = async () => JSON.stringify({ version: "0.4.3" });
  assert.match(await updateCheckText({ readFile, fetch: github(404, {}).fetch }, "macos-arm64"), /^Motifs 0\.4\.3 is installed/);
  const offline = async () => { throw new Error("network down"); };
  assert.equal(await updateCheckText({ readFile, fetch: offline }, "macos-arm64"), "Motifs 0.4.3 could not check for updates: network down");
});
