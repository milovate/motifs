import { execFileSync } from "node:child_process";
import { copyFileSync, cpSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { releaseArchiveName, releaseDiskImageName, releaseTarget } from "../platform.js";

const root = fileURLToPath(new URL("../", import.meta.url));
const { version } = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
const target = releaseTarget();
if (!target) {
  throw new Error("Package Motifs on Apple Silicon macOS or x64 Windows.");
}
const mac = target === "macos-arm64";

const files = execFileSync("git", [
  "ls-files", "-z", "--", ":(top,glob)*.js", "package.json", "package-lock.json",
  "LICENSE", "README.md", "INSTALL.md", "AGENTS.md", "assets/AppIcon.png", "docs/", "browser-extension/",
], { cwd: root, encoding: "utf8" }).split("\0").filter(file => file && file !== "build.js");
const output = path.join(root, "dist");
const filename = releaseArchiveName(version, target);
mkdirSync(output, { recursive: true });
const staging = mkdtempSync(path.join(output, ".motifs-"));
const volume = path.join(staging, "volume");
const plugin = path.join(volume, "motifs");
const archive = path.join(staging, filename);

try {
  for (const file of files) {
    const destination = path.join(plugin, file);
    mkdirSync(path.dirname(destination), { recursive: true });
    copyFileSync(path.join(root, file), destination);
  }

  if (mac) {
    const app = "Capture Studio.app";
    execFileSync("/usr/bin/ditto", [path.join(root, app), path.join(plugin, app)], { stdio: "inherit" });
    execFileSync("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", plugin, archive], { stdio: "inherit" });
    // Install Motifs.txt refers to /Volumes/Motifs, so the volume name must stay "Motifs".
    copyFileSync(path.join(root, "packaging", "macos", "Install Motifs.txt"), path.join(volume, "Install Motifs.txt"));
    const diskImage = releaseDiskImageName(version);
    execFileSync("/usr/bin/hdiutil", [
      "create", "-quiet", "-fs", "APFS", "-format", "ULFO", "-volname", "Motifs",
      "-srcfolder", volume, path.join(staging, diskImage),
    ], { stdio: "inherit" });
    renameSync(path.join(staging, diskImage), path.join(output, diskImage));
    console.log(`Packaged ${path.join(output, diskImage)}`);
  } else {
    cpSync(path.join(root, "windows", "dist"), path.join(plugin, "windows", "dist"), {
      recursive: true,
      filter: file => path.extname(file).toLowerCase() !== ".pdb",
    });
    execFileSync("tar.exe", ["-a", "-cf", archive, "-C", volume, "motifs"], { stdio: "inherit" });
  }

  renameSync(archive, path.join(output, filename));
} finally {
  rmSync(staging, { recursive: true, force: true });
}

console.log(`Packaged ${path.join(output, filename)}`);
