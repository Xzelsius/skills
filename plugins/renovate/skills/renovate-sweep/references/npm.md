# npm, pnpm and Yarn

Read this for PRs whose `ecosystems` include `npm`: `package.json`, lockfiles, and Node version files such as
`.nvmrc`.

Install exactly what the lockfile says: `npm ci`, `pnpm install --frozen-lockfile`, or `yarn install --immutable`
(`--frozen-lockfile` on Yarn 1), with the manager version that a `packageManager` field pins. A repo with several
`package.json` files may have one lockfile per folder; work in the folder the PR changes.

## Changelog sources

After the upstream GitHub releases and compare view:

- the upstream repo, if the release notes don't link it: `npm view <package> repository.url`
- the published `package.json` of a version, for its `engines`, `peerDependencies` and `exports`:
  `npm view <package>@<version> engines peerDependencies exports --json`
- `@types/*` packages come from DefinitelyTyped and have no changelog. Compare their declarations between the two
  versions instead: `npm pack @types/<name>@<version>` downloads the tarball.

## Known fixes

- **`ERESOLVE` or a peer dependency conflict.** Another package's peer range doesn't allow the new version yet.
  Recommend waiting for that package, or grouping both updates in Renovate. Never add `overrides`, `resolutions` or
  `--legacy-peer-deps` as a fix: that ignores the update's constraint.
- **`EBADENGINE`, or the new version needs a newer Node.** The update raises the supported runtime. That's the
  user's decision: `ask-user`.
- **`ERR_REQUIRE_ESM`, or the package is now ESM-only.** Moving the consumer to ESM changes the module system:
  `ask-user`, unless only test or build scripts are affected and the change fits the budget.
- **TypeScript errors after an `@types/*` or library update.** Type-only changes in tests are fine within the
  budget. In shipped code they are only fine when they change no runtime behavior and no exported type.
- **New lint errors after a lint config or plugin update.** Fixing the findings is fine in tests, and in docs code
  that doesn't ship. Never turn the new rules off. For findings in shipped code, recommend `ask-user`.
- **A lockfile change beyond Renovate's is needed.** Renovate maintains the lockfile. If the fix needs another
  lockfile change, it's over budget: `ask-user`.
