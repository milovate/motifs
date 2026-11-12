import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const inputs = process.argv.slice(2);
if (inputs.length !== 2) {
  throw new Error("Run npm run release:verify -- <macOS check directory> <Windows check directory>.");
}

const root = fileURLToPath(new URL("../", import.meta.url));
const options = { cwd: root, encoding: "utf8" };
const commit = execFileSync("git", ["rev-parse", "HEAD"], options).trim();
const { version } = JSON.parse(execFileSync("git", ["show", `${commit}:package.json`], options));
const platforms = ["macos-arm64", "windows-x64"];
const verified = new Set();

for (const directory of inputs) {
  const report = JSON.parse(readFileSync(path.join(directory, "release-check.json"), "utf8"));
  if (!platforms.includes(report.platform) || verified.has(report.platform)) {
    throw new Error(`Expected one macOS arm64 and one Windows x64 report. Unexpected platform ${report.platform}.`);
  }
  if (report.commit !== commit || report.version !== version) {
    throw new Error(`${report.platform} reports ${report.version} at ${report.commit}, expected ${version} at ${commit}.`);
  }
  const expectedArchive = `motifs-${version}-${report.platform}.zip`;
  if (report.archive !== expectedArchive) throw new Error(`Expected archive ${expectedArchive}.`);
  const archive = path.join(directory, expectedArchive);
  const sha256 = createHash("sha256").update(readFileSync(archive)).digest("hex");
  if (sha256 !== report.sha256) throw new Error(`${expectedArchive} does not match its recorded SHA-256 checksum.`);
  verified.add(report.platform);
}

console.log(`Verified both Motifs ${version} packages at commit ${commit}.`);
