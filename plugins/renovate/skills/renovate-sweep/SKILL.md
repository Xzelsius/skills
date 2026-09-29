---
name: renovate-sweep
description: >
  Work through all open Renovate PRs of a GitHub repo until none is left that it may resolve: merge green updates one at
  a time, review majors against their changelogs, fix red builds within a small non-breaking budget, and report what
  needs a decision.
  USE FOR: "sweep the Renovate PRs", "merge the Renovate PRs", "work through the dependency updates", a backlog of
  open Renovate PRs.
  DO NOT USE FOR: analyzing or fixing a single Renovate PR without merging it (use renovate-fix), Dependabot PRs,
  writing or changing Renovate configuration.
argument-hint: "[pr-number ...] [--dry-run] [--bot <login>]"
disable-model-invocation: true
license: MIT
allowed-tools: Bash(bash "${CLAUDE_SKILL_DIR}/scripts/renovate-prs.sh" *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/ci-errors.sh" *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/wait-rebase.sh" *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/watch-pr.sh" *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/worktree.sh" *) Bash(gh pr view *) Bash(gh pr checks *) Bash(gh run view *) Bash(gh run list *) Bash(git ls-remote *)
---

# Renovate sweep

Sweep the open Renovate PRs: $ARGUMENTS

This skill merges, approves and pushes. Run it only when the user invoked it by name (`/renovate-sweep`); never start
it on your own.

`${CLAUDE_SKILL_DIR}` is the folder containing this SKILL.md. The scripts are in `${CLAUDE_SKILL_DIR}/scripts/`; run
them as `bash "${CLAUDE_SKILL_DIR}/scripts/<name>.sh"` from the main checkout. Write each call out in full, with
the path exactly as written here and without shell variables or `cd` in front: the pre-approved commands match only
that form. Each script prints its usage when run without arguments.

## When to use and when not

- Use it for a repo on GitHub with several open Renovate PRs that should be merged, fixed or triaged in one go.
- For one PR that should only be analyzed or fixed locally, use `renovate-fix` instead. It never writes to GitHub.
- Not for Azure DevOps, GitLab or Dependabot. Not for changing Renovate's configuration.

## Inputs

- PR numbers (optional): restrict the sweep to these PRs. Without them, the sweep takes every open PR by the bot.
- `--dry-run`: plan, analyze and report without any GitHub write: no approval, merge, rerun, rebase request or push.
  Workers still run, since they're read-only.
- `--bot <login>`: the account Renovate uses, default `renovate[bot]`. Self-hosted Renovate uses its own account. Pass
  it to `renovate-prs.sh` and `wait-rebase.sh`.

Everything else is discovered (step 1). Defaults apply where discovery finds nothing.

## Rules

- **Writes:** this session does every GitHub write, one at a time. Workers (`renovate-fix`) are read-only.
- **Approvals:** never approve a PR, or enable auto-merge on it, when it has a commit by anyone but the bot
  (`modifiedByOthers`). If the commit is yours, that would be self-approval. The user approves those PRs.
- **Renovate's commit:** never rebase it, and never force-push over it. Wait for Renovate's own rebase
  (`wait-rebase.sh`), then push on top as a guarded fast-forward (`push-guarded.sh`). A Renovate job that's already
  running can otherwise overwrite the fix.
- **Consumer-facing majors:** a PR with `consumerFacing` set updates something the repo ships to its consumers. Its
  major can force a major release of the repo, so never merge or fix it. Research it and ask the user.
- **Fixes:** stay within `renovate-fix`'s guardrails and budget. Anything more is the user's decision.
- **No PR comments.** The analysis goes into the final report. The user decides what gets posted.
- **Reruns:** only when `ci-errors.sh` prints `PATTERN: none`, and at most once per PR per sweep.
- **Stop:** the sweep ends when no remaining PR is one this skill may still resolve. A round that changes nothing on
  GitHub and leaves every plan unchanged ends it too.

### Why one PR at a time

Many repos require branches to be up to date before merging and dismiss approvals on every push, including Renovate's
rebases. Approving several PRs at once then fails: the first merge puts the others behind, Renovate rebases them, and
those rebases dismiss their approvals. So exactly one PR is in flight at a time: up to date and green, then approved,
then merged, then the next one. This works under every combination of these settings.

### Waiting

`wait-rebase.sh` and `watch-pr.sh` return after 540 seconds at most, below the 10-minute cap that agent shells put on
one command. Run them with a shell timeout of 10 minutes; in Claude Code, pass `timeout: 600000` to the Bash tool.
Exit 1 means "timeout, still waiting": call again as the step says. If your host can run a command in the background
and notify you when it ends, you may do that instead with a larger `--timeout`.

## Workflow

### 1. Discover the repo

Do this once per sweep.

1. Check `gh auth status`. Make sure the current folder is the repo's main checkout (`git rev-parse --show-toplevel`).
   Note `git status --short`, so you can leave the checkout exactly as it was.
2. Read the repo's agent instructions (`AGENTS.md`, `CLAUDE.md`, and the files they import). A `## Renovate` section
   there overrides everything below, e.g. which dependencies are consumer-facing, the allowed fix locations, the
   budget, the build commands, the merge method or the bot login.
3. Merge settings: `gh api 'repos/{owner}/{repo}' --jq '{allow_auto_merge, allow_squash_merge, allow_rebase_merge,
   allow_merge_commit}'`. Use the first allowed method of squash, rebase and merge, unless the repo's instructions
   name one.
4. The full verification command: from the agent instructions, otherwise the repo's build script (`build.sh`,
   `build.ps1`, a NUKE or Cake project, `package.json` scripts), otherwise what the pull request workflow in
   `.github/workflows/` runs. The worker discovers the same.
5. The root for worktrees and saved results: `worktree.sh root`.

Checkpoint: you know the merge method, whether auto-merge is available, and the verification command. If there is no
way to verify a fix locally, the fixed queue (step 5) is skipped, and PRs that need a fix are reported instead.

### 2. Inventory and plan

Run `renovate-prs.sh [--bot <login>] [pr ...]`. It prints JSON per PR, with `updateType`, `deps`, `consumerFacing`,
`zeroVer`, `ecosystems`, `ci`, `mergeState`, `rebasing`, `modifiedByOthers` and more; its header comment lists every
field. Apply the repo's `## Renovate` overrides to `deps[].consumerFacing` before planning.

Re-run the inventory at the start of every round. The plan always comes from GitHub's current state, so an interrupted
sweep continues where it stopped.

Group the PRs by dependency (`deps[].name`, case-insensitive). For each PR, the first matching rule wins:

1. `draft`: skip it and report "left open".
2. `modifiedByOthers`, and `<root>/pr-<n>.pushed` holds its `head`: a sweep fixed it. Report "awaiting your
   approval". If `mergeState` is `BEHIND`, run `wait-rebase.sh --request <n>`, which makes Renovate recreate the
   branch without the fix, and send the PR through the fixed queue again.
3. `modifiedByOthers` otherwise: someone else is working on it. Skip it.
4. `ci.stability == pending`: the minimum release age isn't reached yet. Report "waiting"; don't wait for it.
5. `consumerFacing` and `updateType == major`: a worker with `--research-only`, then report "needs your decision".
6. `updateType == major`, or a `minor` with `zeroVer`: a worker, for the changelog review and a fix if CI is red.
7. `ci.ci == fail`: run `ci-errors.sh <n>` and act on its last line.
   - `PATTERN: none`: rerun the failed runs once (`gh run rerun <run-id> --failed`) and re-check next round.
   - `PATTERN: external`: report "needs your decision" with the check's link.
   - `PATTERN: known`: a worker.
8. `ci.ci == none`, so the repo has no CI: a worker, which verifies the update locally. Merge only on a `merge`
   verdict.
9. `ci.ci == pending`: the merge queue, which waits for the checks.
10. A green digest, pin, lockfile, patch or minor: the merge queue, unless a major PR for the same dependency is still
    open. The major goes first. If it merges, Renovate closes this PR. If it ends up unresolved, this PR proceeds.

With `--dry-run`, stop after the plan, the workers and the report. Say for every PR what the sweep would have done.

### 3. Fan out to workers

For each PR that needs a worker:

1. Create its worktree: `worktree.sh add <n> <branch>`. It prints the path.
2. Start one subagent per PR if your host supports it, at most 5 at a time, because local builds are CPU-heavy.
   Without subagents, run `renovate-fix` yourself for one PR after another. In Claude Code, use a general-purpose
   agent and don't set `isolation`: the worktree already exists.
3. Give each subagent this prompt:

   > Invoke the `renovate-fix` skill (`renovate:renovate-fix` when installed as a plugin) with the arguments
   > `<n> <worktree> [--research-only]`, follow it exactly, and return its verdict JSON as your final answer. The main
   > checkout is `<absolute path>`. Never touch the main checkout.

Check every `fix-then-merge` verdict against the guardrails before accepting it: `fix.linesChanged` is within the
budget, `fix.publicApi` is `none` or `additive`, `fix.touchesShippedCode` is `false` unless the repo allows it, and
every file in `fix.files` is in an allowed location. If any check fails, treat the verdict as `ask-user`.

What happens with each verdict:

- **`merge`:** the PR goes into the merge queue.
- **`fix-then-merge`:** the PR goes into the fixed queue.
- **`resolve-minor-instead`:** the minor or digest PR of the same dependency goes into the merge queue, and the major
  is reported.
- **`ask-user`:** the PR is reported.

Checkpoint: every PR has a verdict or a plan row that doesn't need one.

### 4. Merge queue (PRs nobody changed)

Order: digest, then pin and lockfile, then patch, then minor, then majors with a `merge` verdict. For each PR, one at
a time:

1. **Bring it up to date** if `mergeState` is `BEHIND` or `DIRTY`:
   - `rebasing == behind-base-branch`: `wait-rebase.sh <n>`. On exit 1, run `wait-rebase.sh --request <n>` once.
   - otherwise: `wait-rebase.sh --request <n>`, since Renovate won't rebase on its own.
   - still exit 1: leave the PR for the next round. Exit 3 or 4: re-plan the PR next round.
2. **Wait for CI:** `watch-pr.sh <n> <head>`, called again on exit 1, up to 3 calls. If the checks are red, plan the
   PR again (step 2). If they're still pending, leave it for the next round.
3. **Approve and merge.** Approve only if `reviewDecision` is `REVIEW_REQUIRED`: `gh pr review <n> --approve`. Then
   `gh pr merge <n> --<method> --match-head-commit <head>`, adding `--auto` if auto-merge is allowed. Without
   auto-merge, merge only once `mergeState` is `CLEAN` or `HAS_HOOKS`. `CHANGES_REQUESTED` means a person objected:
   skip the PR and report it.
4. **Wait for the merge:** `watch-pr.sh --until merged <n> <head>`, up to 3 calls. Exit 2 means the head changed and
   the approval is gone: start over at step 1. Red checks: plan the PR again.
5. **Clean up:** `worktree.sh remove <n>` if the PR has a worktree. Re-run the inventory before the next PR.

### 5. Fixed queue (after the merge queue is empty)

Fixes are pushed only now, one at a time, so they neither go stale nor lose approvals while the other PRs merge.

1. **Wait for Renovate's rebase:** as in step 4.1. The branch is still Renovate's alone.
2. **Apply the fix:** `worktree.sh reset <n> <branch>`, then `git -C <worktree> apply <root>/pr-<n>.patch`. If the
   patch no longer applies, run the worker for this PR again.
3. **Commit and verify:**
   - Commit in the worktree with the verdict's `commitMessage`. It follows the repo's commit rules; it's never a
     feature and never marked as breaking.
   - Run the full verification command in the worktree.
   - Record the verified tree: `git -C <worktree> rev-parse 'HEAD^{tree}'`.
4. **Push:** `push-guarded.sh <worktree> <branch> <base> <tree>`. This is a write, so it's never pre-approved. If it
   refuses because the base branch moved, go back to step 1. After a successful push, write the new head SHA to
   `<root>/pr-<n>.pushed`.
5. **Hand over to the user:** `watch-pr.sh <n> <new head>`. Once the checks are green, tell the user that the PR is
   ready for their approval, with a two-line summary of the fix; send a push notification if your host can. Then
   wait up to 60 minutes for the merge: `watch-pr.sh --until merged <n> <new head>`, up to 7 calls. If it isn't
   merged by then, stop and report. The next fix can only follow once this PR is merged, because the merge puts the
   next fixed branch behind, and Renovate doesn't rebase a branch with other people's commits.

### 6. Clean up and report

1. `worktree.sh prune` removes the worktrees of PRs that are no longer open. Check that `git status --short` of the
   main checkout matches step 1.
2. Report a table with the columns PR, dependency, `from → to`, update type, outcome and reason. The outcomes are:
   merged, merged after your approval, awaiting your approval, needs your decision, left open, waiting, skipped.
3. For every PR left open, add the analysis: the root cause, the changelog items that affect the repo, and the
   proposed diff with its size. The user decides whether any of it goes into a PR comment.

Scale the report to the sweep: three merged patches need three table rows, not a section per PR.

## Validation

- Every "merged" outcome is backed by `watch-pr.sh` printing `MERGED`. Never report a PR as merged because auto-merge
  was enabled.
- Every pushed fix passed the full verification command on exactly the pushed tree; `push-guarded.sh` enforces that.
- The main checkout's branch and `git status --short` are the same as at the start.
- `worktree.sh list` shows only worktrees of PRs that are still open.
- If a step failed or was skipped, the report says so. A sweep that merged nothing is a valid result.

## Common pitfalls

- Approving the next PR before the previous one merged. Its approval is dismissed by the rebase that follows.
- Rebasing a Renovate branch yourself, or pushing with `--force`. Use `wait-rebase.sh`, then `push-guarded.sh`.
- Taking `ci.ci == pass` as mergeable. `gh pr checks --required` lists only checks that have already reported; the
  merge itself (`--auto`, or `mergeState` without it) is the gate.
- Merging a minor while the same dependency's major is still undecided. Renovate then rebases the major on top, and
  the major's analysis is stale.
- Waiting in one long command. It hits the shell's timeout; call the wait scripts again instead.
- Reporting a consumer-facing major as "left open" without the research. The user needs the changelog items that
  affect the repo to decide.
