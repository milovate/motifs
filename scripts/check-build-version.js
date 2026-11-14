import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const packaged = process.argv[2];
const artifact = packaged ? path.resolve(packaged) : root;
const { version, macosBuildNumber } = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
const lock = JSON.parse(readFileSync(path.join(artifact, "package-lock.json"), "utf8"));
if (lock.version !== version || lock.packages?.[""]?.version !== version) {
  throw new Error(`package-lock.json does not match package.json version ${version}.`);
}

if (packaged) {
  const manifest = JSON.parse(readFileSync(path.join(artifact, "package.json"), "utf8"));
  if (manifest.version !== version) {
    throw new Error(`Packaged plugin reports ${manifest.version}, expected ${version}.`);
  }
  const { default: plugin } = await import(pathToFileURL(path.join(artifact, "index.js")));
  if (typeof plugin?.setup !== "function") throw new Error("The packaged OpenCode plugin has no setup entry point.");
}

const options = { cwd: artifact, encoding: "utf8" };
if (process.platform === "darwin") {
  const plist = "Motifs.app/Contents/Info.plist";
  const actualVersion = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleShortVersionString", plist], options).trim();
  const actualBuild = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleVersion", plist], options).trim();
  if (actualVersion !== version || actualBuild !== String(macosBuildNumber)) {
    throw new Error(`Motifs.app reports ${actualVersion} (build ${actualBuild}), expected ${version} (build ${macosBuildNumber}).`);
  }
  if (packaged) {
    const executable = "Motifs.app/Contents/MacOS/Motifs";
    const arch = execFileSync("/usr/bin/lipo", ["-archs", executable], options).trim();
    if (arch !== "arm64") throw new Error(`Motifs reports architecture ${arch}, expected arm64.`);
  }
} else if (process.platform === "win32") {
  const actualVersion = execFileSync("powershell.exe", [
    "-NoProfile", "-NonInteractive", "-Command",
    "(Get-Item -LiteralPath 'windows/dist/Motifs.exe' -ErrorAction Stop).VersionInfo.ProductVersion",
  ], options).trim();
  if (actualVersion !== version) {
    throw new Error(`Motifs.exe reports ${actualVersion || "no product version"}, expected ${version}.`);
  }
  if (packaged) {
    const output = path.join(artifact, "windows", "dist");
    const executable = readFileSync(path.join(output, "Motifs.exe"));
    // The DOS header points to the PE signature and COFF machine field.
    if (executable.length < 64 || executable.toString("ascii", 0, 2) !== "MZ") {
      throw new Error("Motifs.exe does not have a DOS header.");
    }
    const pe = executable.readUInt32LE(0x3c);
    if (pe < 64 || pe > executable.length - 6 || executable.readUInt32LE(pe) !== 0x00004550) {
      throw new Error("Motifs.exe does not have a valid PE header.");
    }
    const machine = executable.readUInt16LE(pe + 4);
    if (machine !== 0x8664) throw new Error(`Motifs.exe reports PE machine 0x${machine.toString(16)}, expected x64.`);
    for (const file of ["Motifs.dll", "Motifs.deps.json", "Motifs.runtimeconfig.json"]) {
      readFileSync(path.join(output, file));
    }
  }
} else {
  throw new Error("Check the built helper on macOS or Windows.");
}

console.log(`Verified ${packaged ? "packaged" : "built"} helper version ${version}.`);
