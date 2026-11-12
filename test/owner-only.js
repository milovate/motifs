import assert from "node:assert/strict";
import { stat } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { accessPrincipals } from "../permissions.js";

const run = promisify(execFile);

export async function assertOwnerOnly(target, mode) {
  if (process.platform !== "win32") {
    assert.equal((await stat(target)).mode & 0o777, mode);
    return;
  }
  const user = (await run("whoami", { windowsHide: true })).stdout.trim().toLowerCase();
  const names = await accessPrincipals(target);
  assert.ok(names.includes(user), `expected ${user} on ${target}, got ${names.join(", ")}`);
  assert.ok(names.every((name) => name === user || name.endsWith("\\system") || name === "system"), `unexpected access on ${target}: ${names.join(", ")}`);
}
