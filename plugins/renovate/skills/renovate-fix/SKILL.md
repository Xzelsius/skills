---
name: renovate-fix
description: >
  Analyze one Renovate PR on GitHub (failing CI, upstream changelog, impact on this repo, local reproduction) and
  prototype a minimal non-breaking fix in a separate worktree, ending with a verdict. Read-only on GitHub.
  USE FOR: "why is Renovate PR #123 red", "can we merge this Renovate major", "fix the build of this dependency
  update", "what changed in this update and does it affect us"; also the per-PR worker of renovate-sweep.
  DO NOT USE FOR: merging, approving or pushing Renovate PRs (renovate-sweep does that), Dependabot or other PRs,
  Renovate configuration.
argument-hint: "<pr-number> [worktree-path] [--research-only]"
license: MIT
allowed-tools: Bash(bash "${CLAUDE_SKILL_DIR}/scripts/sweep.sh" *) Bash(gh pr view *) Bash(gh pr checks *) Bash(gh pr diff *) Bash(gh run view *) Bash(gh run list *) Bash(gh release view *) Bash(gh release list *) Bash(git ls-remote *)
---

# Renovate fix

Analyze Renovate PR `$0`. Work in the worktree `$1` if one is given. With `--research-only`, stop after the impact
analysis (step 4) and propose no fix.

`${CLAUDE_SKILL_DIR}` is the folder containing this SKILL.md. This skill uses the scripts and references of its
sibling skill `renovate-sweep`:

- scripts: run them through `${CLAUDE_SKILL_DIR}/scripts/sweep.sh`, which allows only the read-only ones:
  `bash "${CLAUDE_SKILL_DIR}/scripts/sweep.sh" renovate-prs|ci-errors|worktree [args ...]`. Run them from the main
  checkout unless a step says otherwise. Write each call out in full, with the path exactly as above and without
  shell variables or `cd` in front: the pre-approved commands match only that form.
- references: `${CLAUDE_SKILL_DIR}/../renovate-sweep/references/<ecosystem>.md`

If `sweep.sh` exits 2 because `renovate-sweep` is missing, stop and pass its install instructions on to the user.

## When to use and when not

- Use it to find out why a Renovate PR is red, what an update changes for this repo, or whether a small fix makes it
  mergeable.
- It never writes to GitHub. To merge, approve or push, the user runs `renovate-sweep`, or does it themselves.
- Not for Dependabot or hand-written PRs, and not for Renovate's configuration.

## Inputs

- `$0`, the PR number (required).
- `$1`, a worktree path (optional). `renovate-sweep` passes one. Without it, create one in step 1.
- `--research-only` (optional): changelog and impact only.

Everything else is discovered in step 1.

## Contract

- **Read-only on GitHub:** never push, comment, review, label, merge, close, rerun or edit anything.
- **Work only inside the worktree:** never switch, edit or build the main checkout.
- **Upstream source:** check third-party APIs and behavior against the upstream source on GitHub, e.g.
  `gh api 'repos/<owner>/<repo>/contents/<path>?ref=<tag>'`, not against a local package cache or decompiled output.
- **Iterate fast:** build and run filtered tests while iterating. Run the full verification once, at the end.

## Guardrails

A fix must meet every rule below. If it can't, propose no fix and recommend `ask-user`. The repo's `## Renovate`
section can change the budget and the allowed places.

- **Non-breaking.** No public API removed, renamed or changed, and no commit that would need a breaking-change
  marker. The ecosystem reference says how the repo's public API is tracked.
- **No runtime behavior change** in code the repo ships.
- **Never:**
  - change the supported target frameworks or runtime versions
  - suppress or downgrade analyzers, warnings or lint rules
  - skip, delete or weaken tests
  - pin, ignore or downgrade the update, or change Renovate's configuration
  - touch CI workflows, unless the PR updates a GitHub Action and the fix belongs in a workflow that uses it
- **No new dependencies.** When upstream recommends swapping to a sibling package, propose the swap with
  `ask-user`.
- **Budget: at most 20 changed lines in total**, counted with `git diff --numstat` across every file, including
  public API files. For anything larger, report the proposed diff and its size; the user decides.
- **Allowed places**, by default:
  - test code: test projects and folders, `*.test.*` and `*.spec.*` files
  - build configuration: e.g. MSBuild `.props` and `.targets` files, `package.json` scripts and tool settings
  - docs text that names the dependency
  - what the ecosystem reference adds, e.g. public API files for members that already exist

## Workflow

1. **Set up.**
   1. Run `sweep.sh renovate-prs $0` for the PR's branch, base, deps, `ecosystems` and `ci`. Pass
      `--bot <login>` if the repo's instructions name another bot account.
   2. Without `$1`, create the worktree: `sweep.sh worktree add $0 <branch>`. It prints the path. The root for
      saved results is its parent folder; `sweep.sh worktree root` prints it too.
   3. Read the repo's agent instructions (`AGENTS.md`, `CLAUDE.md`, and the files they import), especially a
      `## Renovate` section. Then read the reference of each ecosystem in `ecosystems` that has one: `nuget.md`,
      `npm.md` or `github-actions.md`. Other ecosystems have no reference; the generic steps still apply.
   4. Find two commands: a fast one for iterating (build, then filtered tests) and the full verification. Take them
      from the agent instructions, otherwise from the build script, otherwise from what CI runs on pull requests.
   5. Find the commit rules: the agent instructions, a commitlint config, `.github/semantic.yml`, or a PR title
      check in `.github/workflows/`. Without any, use Conventional Commits.

   Checkpoint: you have the worktree path, the root, the ecosystem references and both commands.

2. **CI.** If `ci.ci` is `fail`, run `sweep.sh ci-errors $0`. Then find out when the branch went red: compare its
   last green and first red runs (`gh api 'repos/{owner}/{repo}/actions/runs?branch=<branch>'`) with the base
   branch's commits in between. The cause is often a change on the base branch, not the update itself.
3. **Changelog.** Renovate's release notes are often empty or partial. For a major, read every release in the range,
   not only those Renovate lists. Sources, in this order:
   1. the upstream repo's GitHub releases, and its compare view between the two tags
   2. a `CHANGELOG` file, migration guide or docs source in the upstream repo, at the new tag
   3. the ecosystem sources in the reference, e.g. package metadata from the registry
4. **Impact.** Search this repo for every API, option, input and package that the relevant changes touch. Mark each
   change "affects us" or "doesn't affect us", with file:line evidence.

   With `--research-only`, skip to step 8.
5. **Reproduce** in the worktree: build first, then filtered tests. Probe edits are temporary; revert them.
6. **Fix** within the guardrails. Check the known fixes in the ecosystem reference and the repo's instructions
   first. Don't commit; leave the change uncommitted in the worktree.
7. **Verify.** Build and run the filtered tests, then the full verification command, all in the worktree. If
   something can't be verified locally, such as a workflow change, list it in `notVerified`.
8. **Save** both results in the root, next to the worktree, not inside it:
   - the patch as `pr-$0.patch`, including new files: `git -C <worktree> add -A`, then
     `git -C <worktree> diff --cached --binary > <root>/pr-$0.patch`. Measure the budget with
     `git -C <worktree> diff --cached --numstat`.
   - the verdict as `pr-$0.json`
9. **Return** the verdict as your final answer. When the user invoked this skill directly, rather than through
   `renovate-sweep`, also tell them the worktree path, that nothing was pushed, and that
   `bash "${CLAUDE_SKILL_DIR}/scripts/sweep.sh" worktree remove $0` deletes the worktree and the saved files.

## Verdict

```json
{
  "pr": 277,
  "head": "<sha that was analyzed>",
  "dependency": "FastEndpoints",
  "updateType": "major",
  "from": "6.2.0",
  "to": "8.3.0",
  "ci": "red",
  "rootCause": "one to three sentences",
  "changelog": [{ "version": "7.0.1", "change": "...", "affectsUs": true, "evidence": "test/...:377" }],
  "fix": {
    "patchFile": "<root>/pr-277.patch",
    "files": ["test/..."],
    "linesChanged": 4,
    "touchesShippedCode": false,
    "publicApi": "none",
    "commitMessage": "test: ..."
  },
  "verification": { "build": "pass", "filteredTests": "7/7", "fullVerification": "pass" },
  "recommendation": "fix-then-merge",
  "reason": "why this recommendation",
  "notVerified": ["..."]
}
```

- **`head`:** the SHA you analyzed. The sweep compares it with the PR's current head.
- **`fix`:** `null` when no change is needed or none is proposed. `publicApi` is `none` or `additive`.
  `commitMessage` follows the repo's commit rules; it's never a feature and never marked as breaking.
- **`recommendation`:** one of
  - `merge`: no fix needed. CI is green, or there's no CI and the full verification passed locally, and no change in
    the changelog breaks the repo.
  - `fix-then-merge`: a fix within the guardrails and the budget, fully verified.
  - `resolve-minor-instead`: the major needs more than the guardrails allow, but a minor or digest PR of the same
    dependency can be merged instead.
  - `ask-user`: everything else, e.g. over budget, breaking, unclear, or research only. Include the proposed diff if
    there is one.

## Validation

- `verification` reports what actually ran and its result. A step that didn't run is `"not run"`, never `"pass"`.
- `fix.linesChanged` equals the sum of both columns of `git diff --cached --numstat`.
- `fix.files` matches the files in the patch, and every one of them is in an allowed place.
- `git -C <main checkout> status --short` is unchanged.

## Common pitfalls

- Blaming the update when the base branch broke the build. Step 2 compares both.
- Trusting Renovate's release notes for a major. They skip releases and truncate long notes.
- Checking an API against the local package cache instead of the upstream source at the right tag.
- Counting only source lines for the budget. Public API files, tests and config count too.
- Recommending `merge` for a green major without reading the changelog. Behavior changes don't always fail tests.
- Fixing in shipped code because the fix is small. Small isn't the rule; "tests and build configuration only" is,
  unless the repo says otherwise.
