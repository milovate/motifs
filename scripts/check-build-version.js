import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = new URL("../", import.meta.url);
const { version, macosBuildNumber } = JSON.parse(readFileSync(new URL("package.json", root), "utf8"));
const lock = JSON.parse(readFileSync(new URL("package-lock.json", root), "utf8"));
if (lock.version !== version || lock.packages?.[""]?.version !== version) {
  throw new Error(`package-lock.json does not match package.json version ${version}.`);
}

const options = { cwd: fileURLToPath(root), encoding: "utf8" };
if (process.platform === "darwin") {
  const plist = "Capture Studio.app/Contents/Info.plist";
  const actualVersion = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleShortVersionString", plist], options).trim();
  const actualBuild = execFileSync("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleVersion", plist], options).trim();
  if (actualVersion !== version || actualBuild !== String(macosBuildNumber)) {
    throw new Error(`Capture Studio.app reports ${actualVersion} (build ${actualBuild}), expected ${version} (build ${macosBuildNumber}).`);
  }
} else if (process.platform === "win32") {
  const actualVersion = execFileSync("powershell.exe", [
    "-NoProfile", "-NonInteractive", "-Command",
    "(Get-Item -LiteralPath 'windows/dist/Appshots.exe' -ErrorAction Stop).VersionInfo.ProductVersion",
  ], options).trim();
  if (actualVersion !== version) {
    throw new Error(`Appshots.exe reports ${actualVersion || "no product version"}, expected ${version}.`);
  }
} else {
  throw new Error("Check the built helper on macOS or Windows.");
}

console.log(`Verified helper version ${version}.`);
