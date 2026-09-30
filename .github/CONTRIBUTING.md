# Contributing to xzelsius-skills

Looking to contribute something? These skills started as tools for my own workflows, but they're written to work in other repos too, so bug reports,
ideas and pull requests are welcome. Every installed skill loads into its users' sessions, so the bar for new skills is deliberately high:
correctness, clarity and long-term maintainability come before speed.

- [Code of Conduct](#code-of-conduct)
- [Found a bug?](#bug-reports)
- [Missing a skill?](#skill-requests)
- [Before you start](#before-you-start)
- [Development setup](#development-setup)
- [Writing a skill](#writing-a-skill)
- [Pull requests](#pull-requests)
- [Security](#security)
- [Licensing and provenance](#licensing-and-provenance)

## Code of Conduct

Please read and follow our [Code of Conduct].

## Bug reports

A bug is a demonstrable problem caused by a skill or by the repo's tooling. For a skill, that usually means it doesn't activate when it should,
activates when it shouldn't, or does the wrong thing once it runs. Good bug reports are extremely helpful, so thanks!

Guidelines for bug reports:

1. Check whether the issue has already been reported — [Issues]
2. Check whether it has been fixed — update the plugin, or try the latest `main` (see [Trying a change locally](#trying-a-change-locally))
3. Isolate the problem: the smallest request that shows it
4. [Open an issue] that includes:
   - the host and its version, e.g. Claude Code, VS Code with Copilot, Codex, or `npx skills`
   - the plugin and skill, and the plugin version
   - what you asked, what the agent did, and what you expected instead
   - the relevant part of the transcript, with secrets and private details removed

A good bug report shouldn't leave others needing to chase you up for more information.

## Skill requests

Ideas for new skills, or for changes to existing ones, are welcome. Take a moment to check whether your idea fits [what we look
for](#what-we-look-for); it's up to you to make a strong case for it.

1. Check whether it has already been requested — [Issues]
2. [Open an issue] describing:
   - the user problem, and why the model gets it wrong without a skill
   - the proposed outcome
   - a small example of the desired behavior

## Before you start

- Search the existing issues and pull requests to avoid duplicates.
- Open an issue before a pull request for a new skill, a new plugin or any non-trivial change. This helps us agree on scope and avoids wasted work.
- Small fixes, such as typos, broken links or a clearly isolated correction, can go straight to a pull request.
- Keep changes small and focused. One skill or one fix per pull request is a good default.

### What we look for

We are most likely to accept skills that:

- fill a gap where the model, without the skill, gets real decisions wrong
- are clearly motivated by a real use case
- are likely to be used often and aren't specific to one repo
- are narrow in scope and easy to review
- are explicit about the tools and access they assume
- can be validated with concrete steps

We are less likely to accept skills that:

- duplicate guidance that another skill already has
- encode private environment details, credentials or company-specific facts
- depend on tools or access that most users won't have
- add broad frameworks, meta tooling or large reorganizations

Skills that depend on third-party tools are judged case by case, based on the provenance and maturity of those tools.

## Development setup

You need Node 22 or later, [GitHub CLI] 2.90 or later, and [Claude Code] (`claude`). Then:

```text
npm ci          installs the linters (markdownlint, ShellCheck, shfmt)
npm run check   runs every check without changing anything; the PR check runs the same
npm run fix     applies markdownlint's fixes and formats shell scripts with shfmt
```

`npm run check` validates the plugin manifests and the marketplace with `claude plugin validate --strict`, checks the skills against the Agent Skills
spec with `gh skill publish --dry-run`, and runs markdownlint, ShellCheck and shfmt.

- **VS Code** recommends the markdownlint, EditorConfig and ShellCheck extensions. Shell scripts are formatted by `npm run fix`, not by an extension.
- **Claude Code** runs `npm ci` at session start when `node_modules` is missing or out of date, and lints every file it edits.

### Trying a change locally

Load the plugin from your clone instead of the published version:

- **Claude Code:** `claude --plugin-dir plugins/<plugin>` for one session, or add the clone as a local marketplace with
  `/plugin marketplace add <path-to-clone>`. Both load the files in place. `claude --plugin-dir plugins/<plugin> plugin details <plugin>` lists what
  the plugin ships and its projected token cost.
- **VS Code:** add the plugin folder to `chat.pluginLocations`.
- **Codex:** add the clone as a local marketplace with `codex plugin marketplace add <path-to-clone>`.

Try the skill on the requests it's meant for, and on a few it should ignore.

## Writing a skill

Every rule for what goes into a skill, from layout, names and frontmatter to activation, content and writing style, is in [`AGENTS.md`]. It's written
for coding agents, but it applies to people just the same, and keeping it in one place means agents and people follow the same rules.

## Pull requests

Good pull requests are a fantastic help. They should stay focused in scope and avoid unrelated commits.

1. Fork the project and clone your fork
2. If you cloned a while ago, get the latest changes from upstream
3. Create a topic branch for your change
4. Make your change, and bump `version` in both manifests of the plugin if it should reach users
5. Run `npm run check` and fix what it reports
6. Rebase your branch onto the upstream `main` and push it to your fork
7. Open a pull request against `main` — [About pull requests]

The pull request title follows the format in [`AGENTS.md`]. In the description, say what you changed, why, and how you validated it: which host, which
prompts, and what the agent did. If validation needs access a reviewer won't have, say how to check it without that access, or why that isn't
possible.

The PR check runs `npm run check`, and code owners are asked for a review automatically. Maintainers may ask for clearer instructions, a smaller
scope, more explicit validation, or better compatibility with other hosts. Pull requests that are out of scope or too large to review may be closed,
usually with a suggestion for a smaller path forward.

## Security

- Don't include secrets, tokens or internal URLs in skills, examples or transcripts.
- If you find a security issue, don't open a public issue with the details. Report it privately through the repository's **Security** tab.

## Licensing and provenance

This repository is licensed under the [MIT License]. By contributing, you agree that your contribution is licensed under it, and you confirm that you
have the right to contribute it.

- Don't include copyrighted text from other projects.
- If existing work inspired you, rewrite it in your own words and adapt it to our conventions.

[Code of Conduct]: CODE_OF_CONDUCT.md
[Issues]: https://github.com/Xzelsius/skills/issues
[Open an issue]: https://github.com/Xzelsius/skills/issues/new
[GitHub CLI]: https://cli.github.com
[Claude Code]: https://claude.com/claude-code
[`AGENTS.md`]: ../AGENTS.md
[About pull requests]: https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/about-pull-requests
[MIT License]: ../LICENSE
