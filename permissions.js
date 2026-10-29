import { execFile } from "node:child_process";
import { chmod } from "node:fs/promises";
import { promisify } from "node:util";

const run = promisify(execFile);

// Unix mode bits do not restrict a Windows file. Match the helper: the current
// user and SYSTEM, with inherited access removed.
export async function ownerOnly(target, { directory = false } = {}) {
  if (process.platform !== "win32") {
    await chmod(target, directory ? 0o700 : 0o600);
    return;
  }
  const user = (await run("whoami", { windowsHide: true })).stdout.trim();
  if (!user || /[\r\n"]/.test(user)) throw new Error("Could not identify the current Windows user.");
  const rights = directory ? "(OI)(CI)F" : "F";
  await run("icacls", [target, "/inheritance:r", "/grant:r", `${user}:${rights}`, "/grant:r", `*S-1-5-18:${rights}`], { windowsHide: true });
}

export async function accessPrincipals(target) {
  const { stdout } = await run("icacls", [target], { windowsHide: true });
  return stdout.split(/\r?\n/).flatMap((line) => {
    const mark = line.indexOf(":(");
    if (mark < 0) return [];
    return [line.slice(0, mark).trim().toLowerCase()];
  });
}
