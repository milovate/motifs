import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
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

export function releaseReport({ version, target, commit, archive, sha256, bytes, tests, signed = false, createdAt = new Date(), node = process.version }) {
  return {
    version,
    target,
    commit,
    archive,
    sha256,
    bytes,
    tests,
    signed,
    node,
    createdAt: createdAt.toISOString(),
  };
}

function main() {
  const target = releaseTarget();
  if (!target) throw new Error("Run the release check on Apple Silicon macOS or x64 Windows.");
  const mac = target === "macos-arm64";
  const npm = process.env.npm_execpath;
  if (!npm) throw new Error("Run npm run release:check.");
  const args = process.argv.slice(2);
  const sign = args[0] === "--sign";
  if (args.length !== (sign ? 1 : 0)) throw new Error("Use npm run release:check -- --sign to sign the test package.");

  const commit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
  const scratch = mkdtempSync(path.join(tmpdir(), "motifs-release-check-"));
  const checkout = path.join(scratch, "checkout");
  const temp = path.join(scratch, "tmp");
  const env = { ...process.env, TMPDIR: temp, TEMP: temp, TMP: temp };
  const runNpm = (...args) => execFileSync(process.execPath, [npm, ...args], { cwd: checkout, env, stdio: "inherit" });
  let worktreeAdded = false;
  let reportDirectory;

  try {
    mkdirSync(temp);
    execFileSync("git", ["worktree", "add", "--detach", checkout, commit], { cwd: root, stdio: "inherit" });
    worktreeAdded = true;
    const { version } = JSON.parse(readFileSync(path.join(checkout, "package.json"), "utf8"));

    runNpm("ci", "--ignore-scripts");
    runNpm("run", "build");
    const test = spawnSync(process.execPath, [npm, "test"], {
      cwd: checkout, env, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"],
    });
    process.stdout.write(test.stdout ?? "");
    if (test.error) throw test.error;
    if (test.status !== 0) throw new Error("The local test suite failed.");
    const tests = tapSummary(test.stdout);
    const signer = path.join(checkout, "scripts", "sign-release.js");
    if (sign) execFileSync(process.execPath, [signer], { cwd: checkout, env, stdio: "inherit" });
    runNpm("run", "package:local");

    const filename = releaseArchiveName(version, target);
    const archive = path.join(checkout, "dist", filename);
    const unpacked = path.join(scratch, "unpacked");
    const packageRoot = path.join(unpacked, "motifs");
    mkdirSync(unpacked);
    if (mac) {
      execFileSync("/usr/bin/ditto", ["-x", "-k", archive, unpacked], { stdio: "inherit" });
      const bundle = path.join(packageRoot, "Capture Studio.app");
      execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle], { stdio: "inherit" });
    } else {
      execFileSync("tar.exe", ["-xf", archive, "-C", unpacked], { stdio: "inherit" });
    }
    const verifier = path.join(checkout, "scripts", "check-build-version.js");
    execFileSync(process.execPath, [verifier, packageRoot], { cwd: checkout, stdio: "inherit" });
    if (sign) execFileSync(process.execPath, [signer, packageRoot], { cwd: checkout, env, stdio: "inherit" });
    const sha256 = createHash("sha256").update(readFileSync(archive)).digest("hex");
    const dist = path.join(root, "dist");
    mkdirSync(dist, { recursive: true });
    reportDirectory = mkdtempSync(path.join(dist, `check-${commit.slice(0, 12)}-${target}-`));
    copyFileSync(archive, path.join(reportDirectory, filename));
    const report = releaseReport({
      version, target, commit, archive: filename, sha256, bytes: statSync(archive).size, tests, signed: sign,
    });
    writeFileSync(path.join(reportDirectory, `${filename}.sha256`), checksumLine(sha256, filename));
    writeFileSync(path.join(reportDirectory, "release-check.json"), JSON.stringify(report, null, 2) + "\n");
  } catch (error) {
    if (reportDirectory) rmSync(reportDirectory, { recursive: true, force: true });
    throw error;
  } finally {
    if (worktreeAdded) {
      execFileSync("git", ["worktree", "remove", "--force", checkout], { cwd: root, stdio: "inherit" });
    }
    rmSync(scratch, { recursive: true, force: true });
  }

  console.log(`Local release check passed. ZIP and report: ${reportDirectory}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
