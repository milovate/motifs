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
const app = path.join(root, "Capture Studio.app");
mkdirSync(path.join(app, "Contents/MacOS"), { recursive: true });
writeFileSync(path.join(app, "Contents/Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.opencode.capturestudio</string>
<key>CFBundleName</key><string>Capture Studio</string>
<key>CFBundleExecutable</key><string>CaptureStudio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.3</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSScreenCaptureUsageDescription</key><string>Capture a single app window when you request a capture.</string>
<key>NSMicrophoneUsageDescription</key><string>Transcribe your description when you click Dictate. Nothing is sent until you click Send.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Convert your spoken description into an editable draft using on-device recognition.</string>
</dict></plist>`);
execFileSync("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-O", "-module-cache-path", "/tmp/opencode-capture-studio-swift-cache", "-target", "arm64-apple-macosx14.0", ...["Appshots.swift", "AccessibilityReader.swift", "AnnotationEditor.swift", "Composer.swift", "ComposerUI.swift", "CaptureBundle.swift", "ComposerMentions.swift", "ComposerSpeech.swift", "SessionHandoff.swift", "HandoffFocus.swift", "StatusBarIcon.swift", "RegionCapture.swift", "ScreenshotAttachments.swift", "SystemContext.swift", "UserEvents.swift", "BrowserBridge.swift"].map(file => path.join(root, file)), "-o", path.join(app, "Contents/MacOS/CaptureStudio")], { stdio: "inherit" });
execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "local.opencode.capturestudio", app], { stdio: "inherit" });
console.log(`Built ${app}`);
