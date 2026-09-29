// The linters behind `npm run check` and the Claude Code lint hook. All of them come from
// node_modules, so every machine and the PR check run the same versions: markdownlint-cli2, and
// ShellCheck and shfmt compiled to WebAssembly.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createReadOnlyPreopen, loadModule, run } from "@vscode-shellcheck/shellcheck-wasm/node";
import { format } from "@wasm-fmt/shfmt";
import { parse as editorconfig } from "editorconfig";

export const root = path.resolve(fileURLToPath(new URL("..", import.meta.url)));

const markdownlintBin = path.join(
  path.dirname(fileURLToPath(import.meta.resolve("markdownlint-cli2"))),
  "markdownlint-cli2-bin.mjs",
);

// Runs markdownlint-cli2 from the repo root, so it finds .markdownlint-cli2.jsonc.
export function markdownlint(args, { capture = false } = {}) {
  const result = spawnSync(process.execPath, [markdownlintBin, ...args], {
    cwd: root,
    encoding: "utf8",
    stdio: capture ? "pipe" : "inherit",
  });
  return { status: result.status ?? 2, output: capture ? result.stdout + result.stderr : "" };
}

// Shell scripts, tracked and new alike, relative to the repo root.
export function shellFiles() {
  const result = spawnSync("git", ["ls-files", "--cached", "--others", "--exclude-standard", "--", "*.sh"], {
    cwd: root,
    encoding: "utf8",
  });
  if (result.status !== 0) throw new Error(`git ls-files failed: ${result.stderr}`);
  return result.stdout.split("\n").filter((file) => file && existsSync(path.join(root, file)));
}

// Runs ShellCheck on files relative to the repo root. The root is the guest's "/", so ShellCheck
// finds .shellcheckrc and sourced files there, as it would natively.
export async function shellcheck(files) {
  const module = await loadModule();
  const preopen = createReadOnlyPreopen(root);
  try {
    const result = run(module, { args: files, env: { PWD: "/" }, preopens: [preopen] });
    const text = new TextDecoder();
    return { status: result.exitCode, output: text.decode(result.stdout) + text.decode(result.stderr) };
  } finally {
    preopen.dispose();
  }
}

// Formats shell scripts as shfmt would. Returns the files that aren't formatted (with `write`, they
// are rewritten instead) and the ones shfmt can't parse.
export async function shfmt(files, { write = false } = {}) {
  const unformatted = [];
  const errors = [];
  for (const file of files) {
    const full = path.join(root, file);
    const source = readFileSync(full, "utf8");
    let formatted;
    try {
      formatted = format(source, file, await shfmtOptions(full));
    } catch (error) {
      errors.push(`${file}: ${error instanceof Error ? error.message : error}`);
      continue;
    }
    if (formatted === source) continue;
    if (write) writeFileSync(full, formatted);
    else unformatted.push(file);
  }
  return { unformatted, errors };
}

// The EditorConfig keys that shfmt reads, mapped the way shfmt maps them (cmd/shfmt/main.go).
async function shfmtOptions(file) {
  const props = await editorconfig(file);
  const on = (key) => props[key] === true || props[key] === "true";
  return {
    indent: props.indent_style === "space" ? Number(props.indent_size) || 8 : 0,
    binaryNextLine: on("binary_next_line"),
    switchCaseIndent: on("switch_case_indent") || on("case_indent"),
    spaceRedirects: on("space_redirects"),
    funcNextLine: on("function_next_line"),
    minify: on("minify"),
  };
}
