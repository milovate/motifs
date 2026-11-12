import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { releaseArchiveName, releaseTarget } from "../platform.js";

const root = fileURLToPath(new URL("../", import.meta.url));

export function tapSummary(tap) {
  const count = name => Number(tap.match(new RegExp(`^# ${name} (\\d+)$`, "m"))?.[1] ?? NaN);
  const summary = { tests: count("tests"), pass: count("pass"), fail: count("fail"), skipped: count("skipped") };
  if (Object.values(summary).some(Number.isNaN)) throw new Error("The test run did not report a summary.");
  return summary;
}

export function checksumLine(sha256, filename) {
  return `${sha256}  ${filename}\n`;
}

export function releaseReport({ version, target, commit, archive, sha256, bytes, tests, createdAt = new Date(), node = process.version }) {
  return {
    version,
    target,
    commit,
    archive,
    sha256,
    bytes,
    tests,
    node,
    createdAt: createdAt.toISOString(),
  };
}

function git(...args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
}

function requireCleanCheckout() {
  const changes = git("status", "--porcelain", "--untracked-files=no");
  if (changes) throw new Error(`Commit or stash these changes before a release check:\n${changes}`);
}

function step(name, args) {
  console.log(`\n== ${name}`);
  execFileSync(process.execPath, args, { cwd: root, stdio: "inherit" });
}

function main() {
  const target = releaseTarget();
  if (!target) throw new Error("Run the release check on Apple Silicon macOS or x64 Windows.");
  requireCleanCheckout();
  const commit = git("rev-parse", "HEAD");
  const { version } = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));

  step("Build", ["build.js"]);
  step("Verify helper version", ["scripts/check-build-version.js"]);

  const scratch = mkdtempSync(path.join(os.tmpdir(), "motifs-release-check-"));
  let tests;
  try {
    const tap = path.join(scratch, "tests.tap");
    step("Test", [
      "--test",
      "--test-reporter=spec", "--test-reporter-destination=stdout",
      "--test-reporter=tap", `--test-reporter-destination=${tap}`,
      "test/*.test.js",
    ]);
    tests = tapSummary(readFileSync(tap, "utf8"));
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }

  step("Package", ["scripts/package-local.js"]);
  requireCleanCheckout();
  if (git("rev-parse", "HEAD") !== commit) throw new Error("HEAD moved during the release check.");

  const archive = releaseArchiveName(version, target);
  const archivePath = path.join(root, "dist", archive);
  const sha256 = createHash("sha256").update(readFileSync(archivePath)).digest("hex");
  const report = releaseReport({ version, target, commit, archive, sha256, bytes: statSync(archivePath).size, tests });
  const base = archivePath.replace(/\.zip$/, "");
  writeFileSync(`${archivePath}.sha256`, checksumLine(sha256, archive));
  writeFileSync(`${base}.release-check.json`, `${JSON.stringify(report, null, 2)}\n`);

  console.log(`\nRelease check passed for ${archive}`);
  console.log(`Commit ${commit}, ${tests.pass} passed, ${tests.skipped} skipped`);
  console.log(`SHA-256 ${sha256}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
