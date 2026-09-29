# Skills

Skills for my own workflows, packaged as plugins for Claude Code, VS Code and Codex. They're written generically enough that others can use them too.

## What's Included

| Plugin     | What it does                                |
|------------|---------------------------------------------|
| `renovate` | Skills for working with Renovate on GitHub. |

### renovate

- `/renovate-sweep` works through all open Renovate PRs of a repo: it merges green updates one at a time, reviews majors against their
  changelogs, fixes red builds within a small non-breaking budget, and reports what needs a decision. It runs only when you invoke it.
- `renovate-fix` analyzes one Renovate PR and prototypes a fix in a separate worktree, without writing to GitHub.

Both need bash (Git Bash on Windows), `git`, `jq`, and `gh` logged in to the repo's host. They discover the repo's build commands and conventions.
A repo corrects what discovery gets wrong in a `## Renovate` section of its `AGENTS.md` or `CLAUDE.md`, e.g. which dependencies ship to consumers
or where fixes may go.

## Install

### Claude Code

```text
/plugin marketplace add xzelsius/skills
/plugin install <plugin>@xzelsius-skills
```

Update with `claude plugin update <plugin>@xzelsius-skills`, or turn on auto-update for the marketplace under `/plugin` > **Marketplaces**.

### VS Code

Add the marketplace in `settings.json`:

```jsonc
{
  "chat.plugins.enabled": true,
  "chat.plugins.marketplaces": ["xzelsius/skills"]
}
```

Then install from the **Agent Plugins** view (search `@agentPlugins` in the Extensions view). Updates come with **Extensions: Check for Extension
Updates**, or daily with `extensions.autoUpdate`.

### Codex

```text
codex plugin marketplace add xzelsius/skills
```

Then install from `/plugins` in Codex. Update with `codex plugin marketplace upgrade xzelsius-skills`.

### Without plugins

```text
npx skills add xzelsius/skills -g
```

This installs the skills as plain folders, without the plugin namespace, so their names can collide with other skills. Update with
`npx skills update`.

## Contributing

See the [contributing guide](.github/CONTRIBUTING.md) and the [Code of Conduct](.github/CODE_OF_CONDUCT.md).
