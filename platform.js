import path from "node:path";
import { homedir } from "node:os";
import { rename, stat } from "node:fs/promises";

export const legacyToolName = "capture_studio";
export const legacyCommandName = (name) => name.replace(/^motifs/, "capture-studio");

export function platformConfig(platform = process.platform, env = process.env, home = homedir()) {
  if (!["darwin", "win32"].includes(platform)) throw new Error("Motifs requires macOS 14+ or Windows 10/11 (a local desktop session, not WSL).");
  const base = env.XDG_DATA_HOME || (platform === "win32" ? env.LOCALAPPDATA || path.join(home, "AppData", "Local") : path.join(home, ".local/share"));
  return {
    platform,
    captures: path.join(base, "opencode", "motifs"),
    legacyCaptures: path.join(base, "opencode", "capture-studio"),
    shortcut: platform === "win32" ? "Control+Alt+Shift+A" : "Option+G",
  };
}

// Never merge into a Motifs folder that already exists.
export async function migrateCaptures(config, io = { rename, stat }) {
  if (!config.legacyCaptures || await exists(config.captures, io) || !(await exists(config.legacyCaptures, io))) return false;
  await io.rename(config.legacyCaptures, config.captures);
  return true;
}

async function exists(file, io) {
  try {
    await io.stat(file);
    return true;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}

export function releaseTarget(platform = process.platform, arch = process.arch) {
  if (platform === "darwin" && arch === "arm64") return "macos-arm64";
  if (platform === "win32" && arch === "x64") return "windows-x64";
  return undefined;
}

export function releaseArchiveName(version, target) {
  return `motifs-${version}-${target}.zip`;
}

export function helperCommand(root, config, action, args = []) {
  const flags = [`--${action}`, "--output", config.captures, ...args];
  if (config.platform === "win32") {
    return { executable: path.join(root, "windows", "dist", "Motifs.exe"), args: flags };
  }
  const app = path.join(root, "Motifs.app");
  if (action === "capture") return { executable: path.join(app, "Contents/MacOS/Motifs"), args: flags };
  return { executable: "/usr/bin/open", args: [...(action === "watch" ? ["-g"] : ["-n"]), "-a", app, "--args", ...flags] };
}
