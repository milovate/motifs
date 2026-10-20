import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
if (process.platform === "win32") {
  execFileSync("dotnet", ["publish", path.join(root, "windows/Appshots.csproj"), "-c", "Release", "-o", path.join(root, "windows/dist")], { stdio: "inherit" });
  console.log("Built Windows helper in windows/dist");
  process.exit(0);
}
if (process.platform !== "darwin") throw new Error("Build Appshots on macOS or Windows.");
const app = path.join(root, "OpenCode Appshots.app");
mkdirSync(path.join(app, "Contents/MacOS"), { recursive: true });
writeFileSync(path.join(app, "Contents/Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.opencode.appshots</string>
<key>CFBundleName</key><string>OpenCode Appshots</string>
<key>CFBundleExecutable</key><string>Appshots</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.3</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSScreenCaptureUsageDescription</key><string>Capture a single app window when you request an Appshot.</string>
</dict></plist>`);
execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-O", "-module-cache-path", "/tmp/opencode-appshots-swift-cache", "-target", "arm64-apple-macosx14.0", path.join(root, "Appshots.swift"), path.join(root, "AccessibilityReader.swift"), path.join(root, "AnnotationEditor.swift"), "-o", path.join(app, "Contents/MacOS/Appshots")], { stdio: "inherit" });
execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "local.opencode.appshots", app], { stdio: "inherit" });
console.log(`Built ${app}`);
