import { releaseArchiveName } from "./platform.js";

export const repository = "milovate/motifs";
const latestReleaseUrl = `https://api.github.com/repos/${repository}/releases/latest`;
const repositoryPage = `https://github.com/${repository}/`;

export function parseVersion(version) {
  const match = /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(String(version));
  return match ? match.slice(1).map(Number) : undefined;
}

export function compareVersions(a, b) {
  const [left, right] = [parseVersion(a), parseVersion(b)];
  if (!left || !right) throw new Error(`Cannot compare versions ${a} and ${b}.`);
  for (let index = 0; index < 3; index++) {
    if (left[index] !== right[index]) return Math.sign(left[index] - right[index]);
  }
  return 0;
}

function repositoryLink(url) {
  return typeof url === "string" && url.startsWith(repositoryPage) ? url : undefined;
}

// The latest-release endpoint skips drafts and prereleases, so only stable releases are offered.
export async function checkForUpdates({ current, target, fetch = globalThis.fetch }) {
  if (!parseVersion(current)) throw new Error(`The installed version ${current} is not a release version.`);
  const response = await fetch(latestReleaseUrl, {
    headers: { accept: "application/vnd.github+json", "user-agent": "motifs-update-check" },
    signal: AbortSignal.timeout(10_000),
  });
  if (response.status === 404) return { status: "none", current };
  if (!response.ok) throw new Error(`GitHub answered ${response.status} when asked for the latest Motifs release.`);
  const release = await response.json();
  const latest = String(release.tag_name ?? "").replace(/^v/, "");
  if (!parseVersion(latest)) throw new Error(`The latest Motifs release tag ${JSON.stringify(release.tag_name)} is not a version.`);
  const page = repositoryLink(release.html_url) ?? `${repositoryPage}releases/latest`;
  if (compareVersions(latest, current) <= 0) return { status: "current", current, latest, page };
  const archive = target && releaseArchiveName(latest, target);
  const asset = archive && release.assets?.find(item => item.name === archive);
  const download = repositoryLink(asset?.browser_download_url);
  return { status: "available", current, latest, page, ...(download ? { archive, download } : {}) };
}

export function updateMessage(result) {
  switch (result.status) {
    case "none":
      return `Motifs ${result.current} is installed. No stable Motifs release has been published yet.`;
    case "current":
      return `Motifs ${result.current} is up to date. The latest stable release is ${result.latest}: ${result.page}`;
    case "available":
      return [
        `Motifs ${result.latest} is available. You have ${result.current}.`,
        result.download ? `Download for this computer: ${result.download}` : `This release has no download for this computer. Release page: ${result.page}`,
        "To upgrade, follow \"Update the plugin\" in INSTALL.md. Nothing was downloaded or installed.",
      ].join("\n");
    default: {
      const status = result.status;
      throw new Error(`Unknown update status ${status}.`);
    }
  }
}
