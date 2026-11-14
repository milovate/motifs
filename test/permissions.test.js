import assert from "node:assert/strict";
import test from "node:test";
import { principalsFromIcacls } from "../permissions.js";

test("Windows access listings ignore the filename on the first line", () => {
  const target = "C:\\Users\\runner\\AppData\\Local\\Temp\\capture\\context.md";
  const stdout = [
    `${target} NT AUTHORITY\\SYSTEM:(F)`,
    "                 BUILTIN\\Administrators:(F)",
    "                 RUNNER\\runner:(F)",
    "",
    "Successfully processed 1 files; Failed processing 0 files",
  ].join("\r\n");
  assert.deepEqual(principalsFromIcacls(stdout, target), ["nt authority\\system", "builtin\\administrators", "runner\\runner"]);
});
