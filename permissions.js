import { execFile } from "node:child_process";
import { chmod } from "node:fs/promises";
import { promisify } from "node:util";

const run = promisify(execFile);

const extraSids = ["*S-1-5-32-544", "*S-1-5-32-545", "*S-1-5-11", "*S-1-1-0"];

// Unix mode bits do not restrict a Windows file. Match the helper: the current
// user and SYSTEM, with inherited access removed. An elevated token also leaves
// an explicit Administrators entry, which is removed by SID.
export async function ownerOnly(target, { directory = false } = {}) {
  if (process.platform !== "win32") {
    await chmod(target, directory ? 0o700 : 0o600);
    return;
  }
  const user = (await run("whoami", { windowsHide: true })).stdout.trim();
  if (!user || /[\r\n"]/.test(user)) throw new Error("Could not identify the current Windows user.");
  const rights = directory ? "(OI)(CI)F" : "F";
  await run("icacls", [target, "/inheritance:r"], { windowsHide: true });
  for (const sid of extraSids) await run("icacls", [target, "/remove:g", sid], { windowsHide: true }).catch(() => {});
  await run("icacls", [target, "/grant:r", `${user}:${rights}`, "/grant:r", `*S-1-5-18:${rights}`], { windowsHide: true });
}

export function principalsFromIcacls(stdout, target) {
  const file = String(target).toLowerCase();
  return stdout.split(/\r?\n/).flatMap((line) => {
    const mark = line.indexOf(":(");
    if (mark < 0) return [];
    let name = line.slice(0, mark).trim().toLowerCase();
    if (file && name.startsWith(file)) name = name.slice(file.length).trim();
    return name ? [name] : [];
  });
}

export async function accessPrincipals(target) {
  const { stdout } = await run("icacls", [target], { windowsHide: true });
  return principalsFromIcacls(stdout, target);
}
