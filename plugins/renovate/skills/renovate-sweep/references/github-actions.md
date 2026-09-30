# GitHub Actions

Read this for PRs whose `ecosystems` include `github-actions`: `uses:` references in `.github/workflows/` and in
`action.yml` files, and tool versions that Renovate updates inside workflows, e.g. `node-version`.

A tool version inside a workflow, such as `node-version` or `dotnet-version`, changes the runtime that CI builds and
tests on. Compare it with what the repo declares elsewhere (`engines`, `.nvmrc`, `global.json`). An update that makes
CI test a runtime the project doesn't support, or stop testing one it does, is the user's decision.

## Where the fix may go

This is the one case where the guardrails allow CI workflow changes: when the PR updates an action and the fix
belongs in a workflow that uses it. Find every use first, in `.github/` and in any `action.yml` in the repo.
Workflows and local actions under `.github/actions/` don't ship, but an `action.yml` the repo publishes does: a fix
there is the user's decision.

Keep Renovate's pinning style: a digest with a version comment (`@<sha> # v4.2.0`) stays a digest.

## Changelog sources

After the action's GitHub releases and compare view:

- the action's inputs and outputs at both versions. Diff them to find renamed, removed and new inputs:
  `gh api 'repos/<owner>/<action>/contents/action.yml?ref=<tag>' --jq .content | base64 -d`
  (some actions use `action.yaml`)
- the `runs.using` field of the same file: a Node runtime bump such as `node20` → `node24` needs a runner version
  that supports it. That matters for self-hosted runners and GitHub Enterprise Server.

## Verification

Workflows can't be run locally. Check the workflow change against the new `action.yml` (input names, required
inputs, output names), and list "workflow run" in the verdict's `notVerified`. The PR's own CI run after the push is
the real check.

## Known fixes

- **`Unexpected input(s) '<name>'`.** This is only a warning, and the step still passes, but it ignores the input.
  A green run doesn't prove the update is harmless. Rename or remove the input as the new `action.yml` says.
- **`Input required and not supplied: <name>`.** Add the new required input, with the value the action's docs give.
  If the value is a secret or a policy choice, recommend `ask-user`.
- **`Unable to resolve action` or `Can't find 'action.yml'`.** The tag or digest doesn't exist, or the action moved.
  Don't fix that by hand; report it. Renovate corrects the reference on its next run once upstream is fixed.
- **Artifacts break after an `actions/upload-artifact` or `actions/download-artifact` major.** From v4 on, artifacts
  are immutable: uploading the same name twice in one run fails with a conflict, and v4 can't download artifacts
  uploaded by v3. Both actions must move to the same major together. Give each upload a unique name, and download
  with `pattern` and `merge-multiple` where the workflow relied on merging.
- **A changed default in a major,** e.g. whether credentials are persisted or caching is on. Set the input
  explicitly to the old behavior only when the repo depends on it, and say so in the verdict.
