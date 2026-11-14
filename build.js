import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const { version, macosBuildNumber } = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
if (typeof version !== "string" || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version)) {
  throw new Error("Set package.json version to a numeric major.minor.patch version.");
}
if (process.platform === "win32") {
  execFileSync("dotnet", [
    "publish", path.join(root, "windows/Motifs.csproj"),
    "-c", "Release", "-o", path.join(root, "windows/dist"),
    `-p:Version=${version}`, "-p:IncludeSourceRevisionInInformationalVersion=false",
  ], { stdio: "inherit" });
  console.log("Built Windows helper in windows/dist");
  process.exit(0);
}
if (process.platform !== "darwin") throw new Error("Build Motifs on macOS or Windows.");
if (!Number.isSafeInteger(macosBuildNumber) || macosBuildNumber < 1) {
  throw new Error("Set package.json macosBuildNumber to a positive integer.");
}
const app = path.join(root, "Motifs.app");
mkdirSync(path.join(app, "Contents/MacOS"), { recursive: true });
const resources = path.join(app, "Contents/Resources");
const iconset = path.join(os.tmpdir(), "motifs-AppIcon.iconset");
mkdirSync(resources, { recursive: true });
rmSync(iconset, { recursive: true, force: true });
mkdirSync(iconset, { recursive: true });
for (const size of [16, 32, 128, 256, 512]) {
  for (const [scale, suffix] of [[1, ""], [2, "@2x"]]) {
    execFileSync("/usr/bin/sips", ["-z", String(size * scale), String(size * scale), path.join(root, "assets/AppIcon.png"), "--out", path.join(iconset, `icon_${size}x${size}${suffix}.png`)], { stdio: "ignore" });
  }
}
execFileSync("/usr/bin/iconutil", ["-c", "icns", iconset, "-o", path.join(resources, "AppIcon.icns")], { stdio: "inherit" });
rmSync(iconset, { recursive: true, force: true });
copyFileSync(path.join(root, "assets/Bubble.png"), path.join(resources, "Bubble.png"));
writeFileSync(path.join(app, "Contents/Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.motifs</string>
<key>CFBundleName</key><string>Motifs</string>
<key>CFBundleDisplayName</key><string>Motifs</string>
<key>CFBundleExecutable</key><string>Motifs</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${macosBuildNumber}</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSScreenCaptureUsageDescription</key><string>Capture a single app window when you request a capture.</string>
<key>NSMicrophoneUsageDescription</key><string>Transcribe your description when you click Dictate. Nothing is sent until you click Send.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Convert your spoken description into an editable draft using on-device recognition.</string>
</dict></plist>`);
execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-O", "-module-cache-path", "/tmp/motifs-swift-cache", "-target", "arm64-apple-macosx14.0", ...["Motifs.swift", "AccessibilityReader.swift", "AnnotationEditor.swift", "Composer.swift", "ComposerUI.swift", "CaptureBundle.swift", "ComposerMentions.swift", "ComposerSpeech.swift", "SessionHandoff.swift", "HandoffFocus.swift", "StatusBarIcon.swift", "RegionCapture.swift", "ScreenshotAttachments.swift", "SystemContext.swift", "UserEvents.swift", "BrowserBridge.swift", "ReplayRecorder.swift", "RecordingUI.swift", "ClipReview.swift", "ContextPicker.swift", "Recents.swift", "PermissionGuide.swift"].map(file => path.join(root, file)), "-o", path.join(app, "Contents/MacOS/Motifs")], { stdio: "inherit" });
// The hardened runtime stops other processes from injecting code that would inherit
// this app's Screen Recording and Accessibility grants. Dictation needs audio input;
// no entitlement may relax library validation or allow DYLD environment variables.
execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "local.motifs", "--options", "runtime", "--entitlements", path.join(root, "Motifs.entitlements"), app], { stdio: "inherit" });
console.log(`Built ${app}`);
