# Agent guide

This repo is a plugin marketplace called `xzelsius-skills`. Each folder under `plugins/` is one plugin, and every skill sits directly in its plugin's
`skills/` folder. Plans and decisions are in `docs/`.

Claude Code is the reference host. VS Code and Codex install the same plugins, and `npx skills` installs the skills flat, so keep skills host-neutral
where that's cheap.

## Layout

```text
.claude-plugin/marketplace.json                 marketplace; lists every plugin
plugins/<plugin>/plugin.json                    Agent Plugins 1.0 manifest
plugins/<plugin>/.claude-plugin/plugin.json     Claude Code manifest, identical to plugin.json
plugins/<plugin>/skills/<skill>/SKILL.md        one folder per skill, no deeper nesting
plugins/<plugin>/skills/<skill>/scripts/        bundled scripts
plugins/<plugin>/skills/<skill>/references/     detail the skill loads on demand
package.json                                    the linters, installed by npm ci
scripts/check.mjs                               repo checks, run by npm run check
scripts/linters.mjs                             markdownlint, ShellCheck and shfmt, shared by the checks and the lint hook
.claude/hooks/setup.mjs                         SessionStart hook; runs npm ci when node_modules is missing or stale
.claude/hooks/lint.mjs                          PostToolUse hook; lints every file Claude Code edits
```

## Names

- A plugin is named after its domain, e.g. `renovate`.
- A skill name works without the plugin name: `renovate-sweep`, not `sweep`.
- Names use lowercase letters, digits and hyphens, start with a letter, have no doubled or trailing hyphen, and are at most 64 characters long. A
  skill's folder name equals its `name`.
- Never use the name of a bundled command, such as `code-review`, `review`, `simplify`, `init`, `run` or `loop`.
- Names a skill creates at runtime, such as temp folders and local branches, start with the skill's name. Don't add env vars starting with
  `RENOVATE_`: Renovate reads them as its own configuration.

## Writing a skill

Frontmatter:

```yaml
---
name: renovate-fix
description: >
  What the skill does, in one or two sentences.
  USE FOR: the requests, symptoms and error messages a user would actually type.
  DO NOT USE FOR: neighboring tasks that belong to another skill.
license: MIT
---
```

- Write `description` as a `>` block scalar. A plain scalar breaks on the colon and space in `USE FOR:`. Keep it well below 1,024 characters, because
  every installed skill's description sits in every session's context.
- Set `disable-model-invocation: true` on skills with side effects. Also say in the body that the skill runs only when the user invoked it by name,
  because not every host honors the field.
- Write `allowed-tools` as one space-separated string, not as a YAML list.
- Refer to bundled files as `${CLAUDE_SKILL_DIR}/...`. Define it once in the body as "the folder containing this SKILL.md", for hosts that don't
  substitute it.

Body sections, in this order: When to use and when not, Inputs, Workflow (numbered steps with checkpoints), Validation, Common pitfalls. Together
they answer what outcome the skill produces, when an agent uses it, and how the agent validates success. Keep the body under 500 lines, and move rare
or expensive paths into `references/`.

Activation:

- The `description` is the only text a host sees when it decides whether to load a skill. Put the user's own words in it: requests, symptoms, error
  messages and artifact names.
- Separate sibling skills on the real difference between them, not their shared topic, and add the matching `DO NOT USE FOR:` clause to both.
- Re-read every `DO NOT USE FOR:` clause against the requests the skill exists for. An exclusion can lock out the skill's own purpose.

Content:

- Encode the decisions the model gets wrong, and cut what it gets right without the skill. A skill that reads as reference prose adds nothing.
- Prefer "when A, do B, never C, verify D" rules over lists of plausible alternatives, and end with a concrete result: the exact command, the verdict
  line, the findings table.
- Scale the output to the input. A twelve-section report for a small change is worse than a short direct answer.
- Discover repo facts, such as paths, build commands and conventions, instead of requiring them as inputs. A repo corrects wrong guesses in a section
  of its own agent instructions, e.g. `## Renovate` in its `AGENTS.md`.
- Report validation truthfully. Claiming success after a failed step is the worst possible outcome.
- Add stop conditions, so the skill doesn't over-apply. Then check that it doesn't now do less than the model would without it.
- Where a host feature matters, say what to do without it, e.g. "one subagent per PR if your host supports it, otherwise one PR at a time".
- Verify claims about how a tool or API behaves by running it, not by reading about it.
- Don't duplicate text across skills, and don't copy text from other projects. Rewrite what inspired you in your own words.

Writing style:

- Be concise and specific. Define a term the first time it appears.
- Use numbered steps for workflows and checklists for requirements.
- Avoid heavy formatting and clever wording that an agent could misread.
- Keep commands cross-platform where practical; otherwise say which environment they support.

## Adding a plugin

1. Create `plugins/<plugin>/plugin.json` with the Agent Plugins 1.0 fields only: `$schema`, `name`, `version`, `description`, `author`, `homepage`,
   `repository`, `license`, `keywords`.
2. Copy it unchanged to `plugins/<plugin>/.claude-plugin/plugin.json`.
3. Add an entry to `.claude-plugin/marketplace.json` with `"source": "./plugins/<plugin>"`.
4. Add a row to the plugin table in `README.md`.

For now, plugins ship only skills. Hooks, MCP servers and agents need one file per host; read `docs/plans/naming-and-distribution.md` before adding
any.

## Versioning

Bump `version` in both manifests of a plugin with every change that should reach users. VS Code updates only when it changes, and Claude Code keeps
users on their cached copy until it does. Work in progress stays on a branch, because hosts install every skill in a published plugin.

## Checks

Run `npm ci` once to install the linters. Claude Code runs it at session start, and a hook lints every file it edits. Before committing, run
`npm run check`, the same command as the PR check. `npm run fix` applies markdownlint's fixes and formats shell scripts with shfmt.

Besides Node 22 or later, the checks need `gh` 2.90 or later and `claude`.

## Pull requests

Pull request titles follow Conventional Commits with one of the types in `.github/semantic.yml`: `feat`, `fix`, `docs`, `refactor`, `style`, `test`,
`chore` or `revert`, e.g. `feat(renovate): handle grouped updates`.
