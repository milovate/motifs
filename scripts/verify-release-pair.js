import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { releaseArchiveName, releaseDiskImageName } from "../platform.js";

const args = process.argv.slice(2);
const requireSigned = args[0] === "--signed";
const inputs = requireSigned ? args.slice(1) : args;
if (inputs.length !== 2) {
  throw new Error("Run npm run release:verify -- [--signed] <macOS check directory> <Windows check directory>.");
}

const root = fileURLToPath(new URL("../", import.meta.url));
const options = { cwd: root, encoding: "utf8" };
const commit = execFileSync("git", ["rev-parse", "HEAD"], options).trim();
const { version } = JSON.parse(execFileSync("git", ["show", `${commit}:package.json`], options));
const platforms = ["macos-arm64", "windows-x64"];
const verified = new Set();

for (const directory of inputs) {
  const report = JSON.parse(readFileSync(path.join(directory, "release-check.json"), "utf8"));
  if (!platforms.includes(report.target) || verified.has(report.target)) {
    throw new Error(`Expected one macOS arm64 and one Windows x64 report. Unexpected platform ${report.target}.`);
  }
  if (report.commit !== commit || report.version !== version) {
    throw new Error(`${report.target} reports ${report.version} at ${report.commit}, expected ${version} at ${commit}.`);
  }
  if (report.tests?.fail !== 0 || !Number.isInteger(report.tests.pass) || report.tests.pass < 1 ||
      report.tests.pass + report.tests.skipped !== report.tests.tests) {
    throw new Error(`${report.target} has no passing test summary.`);
  }
  if (requireSigned && report.signed !== true) throw new Error(`${report.target} has no signed release report.`);
  const expectedArchive = releaseArchiveName(version, report.target);
  if (report.archive !== expectedArchive) throw new Error(`Expected archive ${expectedArchive}.`);
  const packages = [[expectedArchive, report.sha256]];
  if (report.target === "macos-arm64") {
    const expectedDiskImage = releaseDiskImageName(version);
    if (report.diskImage?.name !== expectedDiskImage) throw new Error(`Expected disk image ${expectedDiskImage}.`);
    packages.push([expectedDiskImage, report.diskImage.sha256]);
  }
  for (const [name, recorded] of packages) {
    const sha256 = createHash("sha256").update(readFileSync(path.join(directory, name))).digest("hex");
    if (sha256 !== recorded) throw new Error(`${name} does not match its recorded SHA-256 checksum.`);
  }
  verified.add(report.target);
}

console.log(`Verified both Motifs ${version} packages at commit ${commit}.`);
