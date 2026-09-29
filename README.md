# Skills

Skills for my own workflows, packaged as plugins for Claude Code, VS Code and Codex. They're written generically enough that others can use them too.

## What's Included

| Plugin     | What it does                                                                                                                                                      |
|------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `renovate` | Work through open Renovate PRs on GitHub: merge the safe ones one at a time, fix red builds within a small non-breaking budget, and report what needs a decision. |

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
