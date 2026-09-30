// PostToolUse hook: lints a file right after Claude Code edits it, with the linters of npm run check.
// Markdown gets markdownlint with --fix; shell scripts get shfmt, then ShellCheck. Whatever can't be
// fixed goes to stderr with exit code 2, which shows it to Claude so it can fix it.
// Fails open: missing node_modules, files outside the repo and unexpected input exit 0.

import { existsSync } from "node:fs";
import path from "node:path";

try {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  const file = JSON.parse(input).tool_input?.file_path;
  if (!file || !existsSync(file)) process.exit(0);

  const { root, markdownlint, shellcheck, shfmt } = await import("../../scripts/linters.mjs");
  const rel = path.relative(root, path.resolve(file)).replaceAll("\\", "/");
  if (!rel || rel.startsWith("../") || path.isAbsolute(rel) || rel.split("/").includes("node_modules")) {
    process.exit(0);
  }

  let report;
  if (rel.endsWith(".md")) {
    // --no-globs: lint only this file, not also the globs from .markdownlint-cli2.jsonc.
    report = markdownlint(["--no-globs", "--fix", `:${rel}`], { capture: true });
  } else if (rel.endsWith(".sh")) {
    await shfmt([rel], { write: true });
    report = await shellcheck([rel]);
  } else {
    process.exit(0);
  }

  // 1 means the linter found issues. Anything else is the linter failing, which fails open.
  if (report.status !== 1) process.exit(0);
  process.stderr.write(`Lint issues left in ${rel} after auto-fix. Fix them:\n${report.output}\n`);
  process.exit(2);
} catch {
  process.exit(0);
}
