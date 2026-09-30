# NuGet and .NET

Read this for PRs whose `ecosystems` include `nuget`: package references, `global.json` (the .NET SDK) and
`dotnet-tools.json`.

## Changelog sources

After the upstream GitHub releases and compare view:

- the package's dependencies per version, from the nuspec:
  `curl -s https://api.nuget.org/v3-flatcontainer/<id-lowercase>/<version>/<id-lowercase>.nuspec`
- the versions that exist: `curl -s https://api.nuget.org/v3-flatcontainer/<id-lowercase>/index.json`
- for analyzer packages, `AnalyzerReleases.Shipped.md` in the upstream repo: new rules, and rules whose default
  severity changed
- the package layout: `build/` and `buildTransitive/` props and targets change the build of every consumer, and an
  analyzer package may need a newer Roslyn than the SDK in `global.json` has

## Public API

Repos that use `Microsoft.CodeAnalysis.PublicApiAnalyzers` track their API in `PublicAPI.Shipped.txt` and
`PublicAPI.Unshipped.txt` per project:

- `PublicAPI.Shipped.txt` stays untouched.
- `PublicAPI.Unshipped.txt` may get new entries only for members that already exist, e.g. members the analyzer now
  tracks. Never add `*REMOVED*` lines: those mark a breaking change.
- Copy the symbol text exactly from the RS0016 message, and keep the file's order and line endings.

## Known fixes

- **`RS0016` for members that already exist, after a PublicApiAnalyzers update.** Version 5 tracks the
  compiler-generated members of records (`Equals`, `PrintMembers`, `<Clone>$`, ...). Add the symbols from the errors
  to `PublicAPI.Unshipped.txt`. That's additive, not a public API change.
- **An API moved or was renamed in a test-only dependency.** A mechanical rename in the tests, checked against the
  upstream source of both versions.
- **New analyzer warnings fail the build (`TreatWarningsAsErrors`) after an SDK or analyzer update.** Fix them in
  tests or build configuration within the budget. When they're in shipped code, or fixing them means suppressing a
  rule, recommend `ask-user`.
