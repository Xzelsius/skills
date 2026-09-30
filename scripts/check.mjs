// Repo checks: plugin manifests, the marketplace, skill frontmatter, and the linters.
//
// Usage: npm run check   checks everything and changes nothing; the PR check runs the same
//        npm run fix     applies markdownlint's fixes and formats shell scripts with shfmt
//
// Needs Node 22 or later, gh 2.90 or later (for gh skill), the Claude Code CLI (claude), and bash for
// the config fixtures. `npm ci` installs everything else.

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";

if (Number(process.versions.node.split(".")[0]) < 22) {
  console.error(`Node 22 or later is required, found ${process.version}.`);
  process.exit(2);
}

let linters;
try {
  linters = await import("./linters.mjs");
} catch (error) {
  console.error(`The linters aren't installed. Run \`npm ci\` first. (${error.message})`);
  process.exit(2);
}
const { root, markdownlint, shellFiles, shellcheck, shfmt } = linters;

if (process.argv.includes("--fix")) {
  const lint = markdownlint(["--fix"]);
  const { errors } = await shfmt(shellFiles(), { write: true });
  for (const error of errors) console.error(`shfmt: ${error}`);
  process.exit(lint.status === 0 && errors.length === 0 ? 0 : 1);
}

for (const tool of ["gh", "claude"]) {
  if (!onPath(tool)) {
    console.error(`missing tool: ${tool}`);
    process.exit(2);
  }
}

const marketplacePath = ".claude-plugin/marketplace.json";
const schema = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json";
const allowed = ["$schema", "name", "version", "description", "author", "homepage", "repository", "license", "keywords"];
let failed = false;

const marketplace = readJson(marketplacePath) ?? {};
const pluginsDir = path.join(root, "plugins");
const plugins = existsSync(pluginsDir)
  ? readdirSync(pluginsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort()
  : [];

// Each plugin folder has two identical manifests with Agent Plugins 1.0 fields only, and a
// marketplace entry.
for (const plugin of plugins) {
  const portable = `plugins/${plugin}/plugin.json`;
  const claudeManifest = `plugins/${plugin}/.claude-plugin/plugin.json`;

  if (!existsSync(path.join(root, portable))) {
    fail(`${plugin}: plugin.json is missing`);
    continue;
  }
  if (!existsSync(path.join(root, claudeManifest))) {
    fail(`${plugin}: .claude-plugin/plugin.json is missing`);
    continue;
  }
  if (!readFileSync(path.join(root, portable)).equals(readFileSync(path.join(root, claudeManifest)))) {
    fail(`${plugin}: plugin.json and .claude-plugin/plugin.json differ`);
  }

  const manifest = readJson(portable);
  if (!manifest) continue;
  if (manifest.$schema !== schema) fail(`${plugin}: $schema must be ${schema}`);
  const extra = Object.keys(manifest).filter((key) => !allowed.includes(key));
  if (extra.length > 0) fail(`${plugin}: fields outside Agent Plugins 1.0: ${extra.join(", ")}`);

  const name = manifest.name ?? "";
  if (name !== plugin) fail(`${plugin}: name "${name}" doesn't match the folder`);
  if (!/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/.test(name) || name.length > 64) {
    fail(`${plugin}: name must be lowercase letters, digits and single hyphens, at most 64 characters`);
  }
  if (typeof manifest.version !== "string" || manifest.version.length === 0) fail(`${plugin}: version is missing`);

  if (!marketplace.plugins?.some((entry) => entry.name === plugin && entry.source === `./plugins/${plugin}`)) {
    fail(`${plugin}: no entry in ${marketplacePath} with source ./plugins/${plugin}`);
  }
}

// Each marketplace entry with a local source points to an existing plugin folder.
for (const { source } of marketplace.plugins ?? []) {
  if (typeof source !== "string") continue;
  const dir = path.join(root, source);
  if (!existsSync(dir) || !statSync(dir).isDirectory()) fail(`${marketplacePath}: source ${source} doesn't exist`);
}

// Claude Code's own validation of the marketplace and of each plugin.
if (exec("claude", ["plugin", "validate", "--strict", "."]) !== 0) failed = true;
for (const plugin of plugins) {
  if (exec("claude", ["plugin", "validate", "--strict", `plugins/${plugin}/`]) !== 0) failed = true;
}

// Skill frontmatter against the Agent Skills spec.
const hasSkills = plugins.some((plugin) => {
  const skills = path.join(pluginsDir, plugin, "skills");
  return existsSync(skills) && readdirSync(skills).some((skill) => existsSync(path.join(skills, skill, "SKILL.md")));
});
if (hasSkills) {
  if (exec("gh", ["skill", "publish", "--dry-run", "."]) !== 0) failed = true;
} else {
  console.log("no skills yet, skipping gh skill publish --dry-run");
}

// Configs: a skill with a scripts/config.sh must give the results that scripts/fixtures/<skill>-config/ expects.
const configSkills = plugins.flatMap((plugin) => {
  const skills = path.join(pluginsDir, plugin, "skills");
  if (!existsSync(skills)) return [];
  return readdirSync(skills)
    .filter((skill) => existsSync(path.join(skills, skill, "scripts", "config.sh")))
    .map((skill) => ({ skill, script: `plugins/${plugin}/skills/${skill}/scripts/config.sh` }));
});
for (const { skill, script } of configSkills) runConfigFixtures(skill, script);

// markdownlint takes its globs from .markdownlint-cli2.jsonc.
if (markdownlint([]).status !== 0) failed = true;

// Shell scripts, tracked and new alike, so this also works before the first commit.
const scripts = shellFiles();
if (scripts.length > 0) {
  const lint = await shellcheck(scripts);
  process.stdout.write(lint.output);
  if (lint.status !== 0) failed = true;

  const { unformatted, errors } = await shfmt(scripts);
  for (const file of unformatted) fail(`${file} isn't formatted as shfmt would; run npm run fix`);
  for (const error of errors) fail(`shfmt: ${error}`);
}

if (!failed) console.log("all checks passed");
process.exit(failed ? 1 : 0);

function fail(message) {
  console.error(`FAIL: ${message}`);
  failed = true;
}

function readJson(file) {
  try {
    return JSON.parse(readFileSync(path.join(root, file), "utf8"));
  } catch (error) {
    fail(`${file}: ${error.message}`);
    return undefined;
  }
}

// Each valid/<name>.conf makes `config.sh --config` exit 0 and print valid/<name>.stdout. Each
// invalid/<name>.conf makes it exit 2 and print invalid/<name>.stderr.
function runConfigFixtures(skill, script) {
  const fixtures = `scripts/fixtures/${skill}-config`;
  if (!existsSync(path.join(root, fixtures))) {
    fail(`${skill}: ${fixtures} is missing; add fixtures for its config.sh`);
    return;
  }
  const bash = bashPath();
  const lines = (text) => text.split(/\r?\n/).map((line) => line.trimEnd()).filter(Boolean);
  let count = 0;

  for (const [kind, status, stream] of [["valid", 0, "stdout"], ["invalid", 2, "stderr"]]) {
    const dir = path.join(root, fixtures, kind);
    const inputs = existsSync(dir) ? readdirSync(dir).filter((name) => name.endsWith(".conf")).sort() : [];
    for (const name of inputs) {
      count++;
      const file = `${fixtures}/${kind}/${name}`;
      const expectedFile = file.replace(/\.conf$/, `.${stream}`);
      if (!existsSync(path.join(root, expectedFile))) {
        fail(`${file}: the expected output ${path.basename(expectedFile)} is missing`);
        continue;
      }
      const result = spawnSync(bash, [script, "--config", file], { cwd: root, encoding: "utf8" });
      const expected = lines(readFileSync(path.join(root, expectedFile), "utf8"));
      const actual = lines(result[stream] ?? "");
      if (result.status !== status) {
        fail(`${file}: config.sh exited ${result.status ?? result.error?.message}, expected ${status}: ${(result.stderr ?? "").trim()}`);
      } else if (!isDeepStrictEqual(actual, expected)) {
        fail(`${file}: config.sh printed\n  ${actual.join("\n  ")}\nexpected\n  ${expected.join("\n  ")}`);
      }
    }
  }
  if (count === 0) fail(`${fixtures}: no fixtures`);
  else console.log(`${fixtures}: ${count} fixtures checked`);
}

// bash for the scripts. On Windows, the bash on PATH is often WSL's, so take Git Bash, which sits next to
// git: <git>/mingw64/libexec/git-core → <git>/bin/bash.exe.
function bashPath() {
  if (process.platform !== "win32") return "bash";
  const execPath = spawnSync("git", ["--exec-path"], { encoding: "utf8" }).stdout?.trim() ?? "";
  const gitBash = path.resolve(execPath, "..", "..", "..", "bin", "bash.exe");
  return execPath && existsSync(gitBash) ? gitBash : "bash";
}

// Runs a CLI with its output passed through. On Windows, CLIs installed with npm are .cmd shims,
// which only start through a shell. The arguments here never need quoting.
function exec(command, args) {
  const result =
    process.platform === "win32"
      ? spawnSync([command, ...args].join(" "), { cwd: root, stdio: "inherit", shell: true })
      : spawnSync(command, args, { cwd: root, stdio: "inherit" });
  return result.status ?? 1;
}

// Whether a command is on PATH, trying the Windows extensions from PATHEXT.
function onPath(command) {
  const extensions = process.platform === "win32" ? (process.env.PATHEXT ?? ".EXE;.CMD").split(";") : [""];
  return (process.env.PATH ?? "")
    .split(path.delimiter)
    .some((dir) => dir && extensions.some((extension) => existsSync(path.join(dir, command + extension))));
}
