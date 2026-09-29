// SessionStart hook: runs npm ci when node_modules is missing or older than package-lock.json, so
// the lint hook and npm run check work without a setup step, in a fresh clone too.
// Never blocks the session: if the install fails, it tells Claude and exits 0.

import { spawnSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const lockfile = path.join(root, "package-lock.json");
const installed = path.join(root, "node_modules", ".package-lock.json");

if (!existsSync(lockfile)) process.exit(0);
if (existsSync(installed) && statSync(installed).mtimeMs >= statSync(lockfile).mtimeMs) process.exit(0);

// On Windows, npm is a .cmd shim, which only starts through a shell.
const result = spawnSync("npm ci --no-audit --no-fund --loglevel=error", { cwd: root, encoding: "utf8", shell: true });
if (result.status !== 0) {
  console.log(`npm ci failed, so the lint hook and npm run check can't run until it succeeds:\n${result.stderr || result.stdout}`);
}
process.exit(0);
