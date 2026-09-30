# The renovate-sweep config

`renovate-sweep` and `renovate-fix` read a repo's settings from `.github/renovate-sweep.conf` on the repo's default branch, written in
[git config syntax](https://git-scm.com/docs/git-config#_syntax). `/renovate-sweep-setup` creates the file: it detects what it can, and
asks about the rest.

- Every key is optional. A key that isn't set has its default, and without the file every key has its default.
- The committed file on the default branch counts, not a local edit. To try a draft, pass it to the skills with `--config <path>`.
- An unknown key or a wrong value stops every script with exit 2 and names the key, so a typo can't go unnoticed. Check a file with
  `bash <renovate-sweep>/scripts/config.sh --config .github/renovate-sweep.conf`.

```ini
[sweep]
    mergeMethod = squash
    verify = ./build.sh

[dependency "Microsoft.Extensions.*"]
    consumerFacing = true
```

## Keys

### `sweep.mergeMethod`

`squash`, `rebase` or `merge`. Set it: without it, the sweep takes the first method the repo allows of squash, rebase and merge, and that
only works if the `gh` token can read the repo's merge settings, which takes at least write access. If it can't, the sweep stops and asks
for this key.

### `sweep.verify`

The full verification a fix must pass before it's pushed, e.g. `./build.sh` or `npm ci && npm test`. Without it, the skills take it from
the repo's agent instructions, its build script, or what its pull request workflow runs.

### `sweep.bot`

The account Renovate opens PRs and commits as. Default: `renovate[bot]`. Self-hosted Renovate uses its own account, e.g.
`my-renovate[bot]`.

### `dependency "<glob>".consumerFacing`

`true` when the repo ships the dependency to its consumers, `false` when it doesn't. It overrides what discovery finds. A consumer-facing
major can force a major release of the repo, so the sweep never merges or fixes one; it researches it and asks.

The glob matches dependency names as Renovate's PR table shows them, e.g. `Microsoft.Extensions.*`, `@types/*`, `dotnet-sdk` or
`actions/checkout`. It's a shell pattern that ignores case: `*` matches any characters, `?` one character. When several rules match, the
last one in the file wins.

Discovery marks a dependency as consumer-facing when a packable NuGet project references it without `PrivateAssets="all"`, or when a
`package.json` that isn't private lists it under `dependencies`, `peerDependencies` or `optionalDependencies`. A project isn't packable
when it's under a `test/` or `tests/` folder, sets `IsTestProject` to true or `IsPackable` to false (in the project or a
`Directory.Build.props` above it), references `Microsoft.NET.Test.Sdk`, or uses the Web SDK (`Microsoft.NET.Sdk.Web`) without setting
`IsPackable` to true. Discovery misses these cases, which need a rule:

- package references in shared `.props` or `.targets` files, e.g. an `ItemGroup` with a condition on `IsTestProject`
- the .NET SDK (`dotnet-sdk`), when a new major changes what the shipped packages target or require
- a project that sets `IsPackable` to false outside a `Directory.Build.props`, e.g. in an imported `.props` file: discovery takes it as
  packable, so a rule with `consumerFacing = false` corrects its packages
- the `uses:` references in an `action.yml` the repo publishes, which run in every consumer's workflow
- packages that a published npm package bundles into its build output, e.g. from its `devDependencies`

`GlobalPackageReference` items never ship: NuGet adds them to every project with `PrivateAssets="All"`.

## Syntax

- Section and key names ignore case: `[Sweep]` and `mergemethod` work too.
- `#` and `;` start a comment. Quote a value that contains them: `verify = "dotnet build; dotnet test"`.
- A backslash starts an escape sequence, so write paths with `/`: `verify = pwsh ./build.ps1`.
