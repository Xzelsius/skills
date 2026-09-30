---
name: renovate-sweep
description: >
  Work through all open Renovate PRs of a GitHub repo until none is left that it may resolve: merge green updates one at
  a time, review majors against their changelogs, fix red builds within a small non-breaking budget, and report what
  needs a decision. Runs only when invoked as /renovate-sweep.
argument-hint: "[pr-number ...] [--dry-run] [--config <path>]"
disable-model-invocation: true
license: MIT
allowed-tools: Bash(bash "${CLAUDE_SKILL_DIR}/scripts/config.sh" *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/renovate-prs.sh" *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/ci-errors.sh" *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/wait-rebase.sh" *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/watch-pr.sh" *) Bash(bash "${CLAUDE_SKILL_DIR}/scripts/worktree.sh" *) Bash(gh pr view *) Bash(gh pr checks *) Bash(gh run view *) Bash(gh run list *) Bash(git ls-remote *) Bash(git apply --numstat *)
---

# Renovate sweep

Sweep the open Renovate PRs: $ARGUMENTS

This skill merges, approves and pushes. Run it only when the user invoked it by name (`/renovate-sweep`); never start
it on your own.

`${CLAUDE_SKILL_DIR}` is the folder containing this SKILL.md. The scripts are in `${CLAUDE_SKILL_DIR}/scripts/`; run
them as `bash "${CLAUDE_SKILL_DIR}/scripts/<name>.sh"` from the main checkout. Write each call out in full, with
the path exactly as written here and without shell variables or `cd` in front: the pre-approved commands match only
that form. A script that needs arguments prints its usage when run without them.

## Inputs

- PR numbers (optional): restrict the sweep to these PRs. Without them, the sweep takes every open PR by the bot.
- `--dry-run`: plan, analyze and report without any GitHub write: no approval, merge, rerun, rebase request or push.
  Workers still run, since they're read-only.
- `--config <path>`: use this config file instead of the one committed on the default branch, e.g. a draft. Pass it
  to `config.sh`, `renovate-prs.sh`, `wait-rebase.sh` and every worker.

Repo settings come from `.github/renovate-sweep.conf`, which step 1.2 loads; `${CLAUDE_SKILL_DIR}/references/config.md`
describes the keys.

## Rules

- **Writes:** this session does every GitHub write, one at a time. Workers (`renovate-fix`) are read-only.
- **Approvals:** never approve a PR, or enable auto-merge on it, when it has `modifiedByOthers=yes`. If the commit is
  yours, that would be self-approval. The user approves those PRs.
- **Renovate's commit:** never rebase it, and never force-push over it. Wait for Renovate's own rebase
  (`wait-rebase.sh`), then push on top with `push-guarded.sh`. A Renovate job that's already running can otherwise
  overwrite the fix.
- **Consumer-facing majors:** `consumerFacing=yes` means the repo ships the dependency to its consumers, so its major
  can force a major release of the repo. Never merge or fix it; research it and ask the user.
- **One PR in flight:** up to date and green, then approved, then merged, then the next. Many repos require
  up-to-date branches and dismiss approvals on every push, including Renovate's rebases, so approving several PRs at
  once fails.
- **Fixes:** stay within `renovate-fix`'s guardrails. Anything more is the user's decision.
- **No PR comments.** The analysis goes into the final report; the user decides what gets posted.
- **Reruns:** only when `ci-errors.sh` prints `PATTERN: none`, and at most once per PR per sweep.
- **Stop:** the sweep ends when no remaining PR is one this skill may still resolve. A round that changes nothing on
  GitHub and leaves every plan unchanged ends it too.

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
2. The settings: `config.sh`. If it exits 2, stop and show its messages; the user fixes the file. Every key it prints
   is final, except that an empty `mergeMethod` or `verify` means "not set": steps 3 and 4 discover those two. Don't
   research any other setting, and don't report settings as missing.
3. Merge settings: `gh api 'repos/{owner}/{repo}' --jq '{allow_auto_merge, allow_squash_merge, allow_rebase_merge,
   allow_merge_commit}'`.
   - The merge method is `mergeMethod` if it's set. If the repo doesn't allow it, stop and say so.
   - Otherwise take the first allowed method of squash, rebase and merge. If the fields are `null`, the `gh` token
     can't read the settings: stop and ask the user to set `mergeMethod` in the config. Never guess a method. With
     `--dry-run`, don't stop; the report says that `mergeMethod` is needed.
   - Auto-merge is available only if `allow_auto_merge` is `true`. `null` counts as not available.
4. The full verification command: `verify` if it's set, otherwise the agent instructions (`AGENTS.md`, `CLAUDE.md`,
   and the files they import), otherwise the repo's build script (`build.sh`, `build.ps1`, a NUKE or Cake project,
   `package.json` scripts), otherwise what the pull request workflow in `.github/workflows/` runs. The worker
   discovers the same.
5. The root for worktrees and saved results: `worktree.sh root`.

Checkpoint: you have the merge method, whether auto-merge is available, and the verification command. If there is no
way to verify a fix locally, the fixed queue (step 5) is skipped, and PRs that need a fix are reported instead.

### 2. Inventory and plan

Run `renovate-prs.sh [pr ...]`. It prints a block of `key=value` lines per PR; its header comment describes every
field. `consumerFacing` already includes the config's dependency rules; take it as it is.

Re-run the inventory at the start of every round. The plan always comes from GitHub's current state, so an interrupted
sweep continues where it stopped.

Group the PRs by dependency (the `dep=` names, case-insensitive). For each PR, the first matching rule wins:

1. `draft=yes`: skip it and report "left open".
2. `modifiedByOthers=yes`, and `<root>/pr-<n>.pushed` holds its `head`: a sweep fixed it. Report "awaiting your
   approval". If `mergeState=BEHIND`, run `wait-rebase.sh --request <n>`, which makes Renovate recreate the branch
   without the fix, and send the PR through the fixed queue again.
3. `modifiedByOthers=yes` otherwise: someone else is working on it. Skip it.
4. `stability=pending`: the minimum release age isn't reached yet. Report "waiting"; don't wait for it.
5. `consumerFacing=yes` and `update=major`: a worker with `--research-only`, then report "needs your decision".
6. `update=major`, or `update=minor` with `zeroVer=yes`: a worker, for the changelog review and a fix if CI is red.
7. `ci=fail`: run `ci-errors.sh <n>` and act on its last line.
   - `PATTERN: none`: rerun the failed runs (`gh run rerun <run-id> --failed`) and re-check next round.
   - `PATTERN: external`: report "needs your decision" with the check's link.
   - `PATTERN: known`: a worker.
8. `ci=none`, so the repo has no CI: a worker, which verifies the update locally. Merge only on a `merge` verdict.
9. `ci=pending`: the merge queue, which waits for the checks.
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
   > `<n> <worktree> [--research-only] [--config <path>]`, follow it exactly, and return its verdict JSON as your final
   > answer. The main checkout is `<absolute path>`. Never touch the main checkout.

Check every `fix-then-merge` verdict before accepting it: `git apply --numstat <root>/pr-<n>.patch` lists the files
and their added and deleted lines. The total must be at most 20 lines, and every file must be in a place that
`renovate-fix`'s guardrails allow. Otherwise treat the verdict as `ask-user`, and say why in the report.

What happens with each verdict:

- **`merge`:** the PR goes into the merge queue.
- **`fix-then-merge`:** the PR goes into the fixed queue.
- **`ask-user`:** the PR is reported.

Checkpoint: every PR has a verdict or a plan row that doesn't need one.

### 4. Merge queue (PRs nobody changed)

Order: digest, then pin and lockfile, then patch, then minor, then majors with a `merge` verdict. For each PR, one at
a time:

1. **Bring it up to date** if `mergeState` is `BEHIND` or `DIRTY`:
   - `rebasing=behind-base-branch`: `wait-rebase.sh <n>`. On exit 1, run `wait-rebase.sh --request <n>` once.
   - otherwise: `wait-rebase.sh --request <n>`, since Renovate won't rebase on its own.
   - still exit 1: leave the PR for the next round. Exit 3 or 4: re-plan the PR next round.

   On exit 0 it prints the new head. Use that head from now on, not the one from the inventory.
2. **Wait for CI:** `watch-pr.sh <n> <head>`, called again on exit 1, up to 3 calls. If the checks are red, plan the
   PR again (step 2). If they're still pending, leave it for the next round.
3. **Approve and merge.** Approve only if `review=REVIEW_REQUIRED`: `gh pr review <n> --approve`. Then
   `gh pr merge <n> --<method> --match-head-commit <head>`, adding `--auto` if auto-merge is available (step 1.3).
   Without auto-merge, merge only once `mergeState` is `CLEAN` or `HAS_HOOKS`: `ci=pass` isn't enough, because
   `gh pr checks --required` lists only the checks that have already reported. `CHANGES_REQUESTED` means a person
   objected: skip the PR and report it.
4. **Wait for the merge:** `watch-pr.sh --until merged <n> <head>`, up to 3 calls. Exit 2 means the head changed and
   the approval is gone: start over at step 1. Red checks: plan the PR again.
5. **Clean up:** `worktree.sh remove <n>` if the PR has a worktree. Re-run the inventory before the next PR.

### 5. Fixed queue (after the merge queue is empty)

Fixes are pushed only now, one at a time, so they neither go stale nor lose approvals while the other PRs merge.

1. **Wait for Renovate's rebase:** as in step 4.1. The branch is still Renovate's alone.
2. **Apply the fix:** `worktree.sh reset <n> <branch>`, then `git -C <worktree> apply <root>/pr-<n>.patch`. If the
   patch no longer applies, run the worker for this PR again.
3. **Commit and verify:**
   - Commit in the worktree with the verdict's `commitMessage`.
   - Run the full verification command in the worktree.
   - Record the verified tree: `git -C <worktree> rev-parse 'HEAD^{tree}'`.
4. **Push:** `push-guarded.sh <n> <worktree> <branch> <base> <tree>`. This is a write, so it's never pre-approved. It
   refuses anything but a fast-forward of the verified tree, and it turns off the PR's auto-merge first, so the fix
   can't merge before the user has reviewed it. If it refuses because the base branch moved, go back to step 1. After
   a successful push, write the new head SHA to `<root>/pr-<n>.pushed`.
5. **Hand over to the user:** `watch-pr.sh <n> <new head>`. Once the checks are green, tell the user that the PR is
   ready for their approval, with a two-line summary of the fix, and that it merges once they approve and merge it;
   send a push notification if your host can. Then wait up to 60 minutes for the merge:
   `watch-pr.sh --until merged <n> <new head>`, up to 7 calls. If it isn't merged by then, stop and report. The next
   fix can only follow once this PR is merged, because the merge puts the next fixed branch behind, and Renovate
   doesn't rebase a branch with other people's commits.

### 6. Clean up and report

1. `worktree.sh prune` removes the worktrees of PRs that are no longer open. Check that `git status --short` of the
   main checkout matches step 1.
2. Report a table with the columns PR, dependency, `from → to`, update type, outcome and reason. The outcomes are:
   merged, merged after your approval, awaiting your approval, needs your decision, left open, waiting, skipped.
3. For every PR left open, add the analysis: the root cause, the changelog items that affect the repo, and the
   proposed diff with its size.
4. If there's no config file (`source` is empty) or it doesn't set `mergeMethod`, add one line:
   `/renovate-sweep-setup` creates or reviews `.github/renovate-sweep.conf`.

Scale the report to the sweep: three merged patches need three table rows, not a section per PR.

## Validation

- Every "merged" outcome is backed by `watch-pr.sh` printing `MERGED`. Never report a PR as merged because auto-merge
  was enabled.
- If a step failed or was skipped, the report says so. A sweep that merged nothing is a valid result.
