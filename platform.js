import path from "node:path";
import { homedir } from "node:os";

export function platformConfig(platform = process.platform, env = process.env, home = homedir()) {
  if (!["darwin", "win32"].includes(platform)) throw new Error("Motifs requires macOS 14+ or Windows 10/11 (a local desktop session, not WSL).");
  const base = env.XDG_DATA_HOME || (platform === "win32" ? env.LOCALAPPDATA || path.join(home, "AppData", "Local") : path.join(home, ".local/share"));
  return {
    platform,
    captures: path.join(base, "opencode", "capture-studio"),
    shortcut: platform === "win32" ? "Control+Alt+Shift+A" : "Option+G",
  };
}

export function helperCommand(root, config, action, args = []) {
  const flags = [`--${action}`, "--output", config.captures, ...args];
  if (config.platform === "win32") {
    return { executable: path.join(root, "windows", "dist", "Appshots.exe"), args: flags };
  }
  const app = path.join(root, "Capture Studio.app");
  if (action === "capture") return { executable: path.join(app, "Contents/MacOS/CaptureStudio"), args: flags };
  return { executable: "/usr/bin/open", args: [...(action === "watch" ? ["-g"] : ["-n"]), "-a", app, "--args", ...flags] };
}
