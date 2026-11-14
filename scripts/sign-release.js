import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const source = fileURLToPath(new URL("../", import.meta.url));
const packaged = process.argv[2];
const root = packaged ? path.resolve(packaged) : source;

function setting(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Set ${name} before signing or verifying a release.`);
  return value;
}

function run(command, args) {
  return execFileSync(command, args, { stdio: "inherit" });
}

if (process.platform === "darwin") {
  const bundle = path.join(root, "Motifs.app");
  const team = setting("MOTIFS_MACOS_TEAM_ID");
  if (!/^[A-Z0-9]{10}$/.test(team)) throw new Error("Expected a 10-character Apple Team ID.");
  const requirement = `identifier "local.motifs" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "${team}"`;
  const verify = () => run("/usr/bin/codesign", ["--verify", "--deep", "--strict", `-R=${requirement}`, bundle]);

  if (!packaged) {
    const identity = setting("MOTIFS_MACOS_SIGNING_IDENTITY");
    const profile = setting("MOTIFS_MACOS_NOTARY_PROFILE");
    run("/usr/bin/xcrun", ["--find", "notarytool"]);
    run("/usr/bin/xcrun", ["--find", "stapler"]);
    run("/usr/bin/codesign", [
      "--force", "--sign", identity, "--options", "runtime", "--timestamp",
      "--entitlements", path.join(source, "Motifs.entitlements"), bundle,
    ]);
    verify();

    const temp = mkdtempSync(path.join(tmpdir(), "motifs-notarize-"));
    try {
      const archive = path.join(temp, "Motifs.zip");
      run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle, archive]);
      const response = JSON.parse(execFileSync("/usr/bin/xcrun", [
        "notarytool", "submit", archive, "--keychain-profile", profile, "--wait", "--output-format", "json",
      ], { encoding: "utf8" }));
      if (response.status !== "Accepted") {
        throw new Error(`Apple notarization ${response.status} for submission ${response.id}.`);
      }
      run("/usr/bin/xcrun", ["stapler", "staple", bundle]);
    } finally {
      rmSync(temp, { recursive: true, force: true });
    }
  }
  verify();
  run("/usr/bin/xcrun", ["stapler", "validate", bundle]);
} else if (process.platform === "win32") {
  const thumbprint = setting("MOTIFS_WINDOWS_SIGNING_THUMBPRINT").toUpperCase();
  if (!/^[A-F0-9]{40}$/.test(thumbprint)) throw new Error("Expected a 40-digit Windows signing certificate thumbprint.");
  const timestamp = packaged ? undefined : new URL(setting("MOTIFS_WINDOWS_TIMESTAMP_URL"));
  if (timestamp && !["http:", "https:"].includes(timestamp.protocol)) throw new Error("Use an HTTP or HTTPS RFC 3161 timestamp URL.");

  for (const name of ["Motifs.exe", "Motifs.dll"]) {
    const file = path.join(root, "windows", "dist", name);
    if (!packaged) {
      run("signtool.exe", ["sign", "/sha1", thumbprint, "/fd", "SHA256", "/tr", timestamp.href, "/td", "SHA256", file]);
    }
    run("signtool.exe", ["verify", "/pa", "/tw", file]);
    const signer = execFileSync("powershell.exe", [
      "-NoProfile", "-NonInteractive", "-Command",
      "(Get-AuthenticodeSignature -LiteralPath $env:MOTIFS_SIGNATURE_FILE).SignerCertificate.Thumbprint",
    ], { env: { ...process.env, MOTIFS_SIGNATURE_FILE: file }, encoding: "utf8" }).trim();
    if (signer.toUpperCase() !== thumbprint) throw new Error(`${name} was signed with a different certificate.`);
  }
} else {
  throw new Error("Sign or verify the release on macOS or Windows.");
}
