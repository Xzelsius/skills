---
name: renovate-sweep-setup
description: >
  Create or review a repo's .github/renovate-sweep.conf, the settings of renovate-sweep and renovate-fix: detect what
  the skills would discover, ask only what detection can't decide, above all which dependencies ship to the repo's
  consumers, then write a minimal file and check it. Never commits. Runs only when invoked as /renovate-sweep-setup.
disable-model-invocation: true
license: MIT
allowed-tools: Bash(bash "${CLAUDE_SKILL_DIR}/scripts/sweep.sh" *)
---

# Renovate sweep setup

Create `.github/renovate-sweep.conf` for the repo in the current folder, or review the one it has. The skill takes no
arguments.

This skill writes a file. Run it only when the user invoked it by name (`/renovate-sweep-setup`); never start it on
your own.

`${CLAUDE_SKILL_DIR}` is the folder containing this SKILL.md. This skill uses the scripts and the config reference of
its sibling skill `renovate-sweep`:

- scripts: run them through `${CLAUDE_SKILL_DIR}/scripts/sweep.sh`, which allows only `detect` and `config`:
  `bash "${CLAUDE_SKILL_DIR}/scripts/sweep.sh" detect|config [args ...]`. Run them from the main checkout. Write each
  call out in full, with the path exactly as above and without shell variables or `cd` in front: the pre-approved
  commands match only that form.
- the keys and the syntax: `${CLAUDE_SKILL_DIR}/../renovate-sweep/references/config.md`

If `sweep.sh` exits 2 because `renovate-sweep` is missing, stop and pass its install instructions on to the user.

## Workflow

### 1. Detect

Run `sweep.sh detect`. It prints what the skills find in the repo on its default branch; its header comment describes
every line. If `committedConfig=yes` or `localConfig=yes`, the repo already has the file: go to step 5.

### 2. Decide what to ask

Ask at most four questions, and only where detection can't decide. Every question needs two to four real options.
A setting with only one possible value is no question: take that value, and name it in the hand-over.

1. **`mergeMethod`: always written, asked only with a choice.** It's the one setting that should be written down.
   With one method in `mergeMethods`, take it. With two or three, they're the options, in that order. If it's
   `unknown`, the `gh` token can't read the repo's merge settings: offer all three, and say that detection wasn't
   possible.
2. **`verify`: only with two or more candidates.** Candidates are a verification command that the files in
   `agentInstructions` name, a script in `buildScripts` (e.g. `./build.sh`), the scripts of the root `package.json`
   run with `packageManager` (e.g. `pnpm install --frozen-lockfile && pnpm test`), and what the `prWorkflows` run.
   Read those files to find them. Candidates that come down to the same command count as one; offer at most four.
   With exactly one, don't ask and don't write it; discovery finds it too. With none, don't ask either: the hand-over
   says that the sweep reports fixes instead of pushing them until `verify` is set.
3. **`bot`: only if the first login in `bots` isn't `renovate[bot]`.** With one login, take it. With several, they're
   the options.
4. **Consumer-facing dependencies: only if there are `hint` lines.** This question matters most: the sweep merges
   majors of dependencies that don't ship on its own, and the hints are the cases where discovery can't tell. Ask
   which of the hinted dependencies ship to the repo's consumers, and give each one's reason:
   - `shared-package-reference`: referenced in a shared `.props` or `.targets` file, which discovery doesn't read. It
     ships when a packable project gets it from there.
   - `dotnet-sdk`: the repo ships NuGet packages, and a new SDK major can change what they target or require.
   - `published-action`: the `uses:` references of the action the repo publishes run in every consumer's workflow.
   - `bundled-npm`: a published package builds with these bundlers, so what it bundles ships inside its output. The
     user names those packages.

   The options depend on how many dependencies the hints name: for one, "ships" and "doesn't ship"; for two or three,
   a multi-select with one option per dependency and "none of them"; for four or more, "all of them" and "none of
   them", while the user names the ones that ship as a free-text answer.

Never ask about anything else; the defaults apply until a sweep shows they don't fit. If nothing is left to ask, go
on with step 4.

### 3. Ask

Ask all questions at once. Use the host's question tool if it has one (`AskUserQuestion` in Claude Code), with the
detected value as the first option and marked as recommended. Without one, ask in one chat message, numbered, each
with its options.

Checkpoint: every question has an answer.

### 4. Write and check

1. Write `.github/renovate-sweep.conf` with only the keys the answers set, as `config.md` shows:
   - `[sweep]` with `mergeMethod`; `verify` only if the user chose one; `bot` only if it isn't `renovate[bot]`
   - a `[dependency "<name>"]` section with `consumerFacing = true` for each dependency the user marked

   Quote a value that contains `#` or `;`. Never write a key only to repeat its default.
2. Check it: `sweep.sh config --config .github/renovate-sweep.conf`. It must exit 0 and print the values you wrote.
   On exit 2, fix what it names and check again.

### 5. An existing file

Never overwrite an existing file.

1. Check it: `sweep.sh config --config .github/renovate-sweep.conf`, or plain `sweep.sh config` if only the
   committed file exists. Report every problem it prints.
2. Compare it with the detection: a `mergeMethod` that isn't in `mergeMethods`, a `bot` without PRs in `bots`, a
   `verify` whose script no longer exists, a hinted dependency that no rule covers.
3. Propose the changes as a diff, and apply them only when the user accepts. Check again after applying.

### 6. Hand over

Show the file, and tell the user in a few lines:

- the values taken without a question, e.g. the only merge method the repo allows, and a missing verification command
- nothing was committed; the skills read the file from the default branch, so it takes effect once it's merged there
- to try it first: `/renovate-sweep --dry-run --config .github/renovate-sweep.conf` (`/renovate:renovate-sweep` when
  installed as a plugin)
- `config.md` of `renovate-sweep` describes every key

## Validation

- `sweep.sh config --config .github/renovate-sweep.conf` exits 0 and prints exactly the values written.
- The only change in the checkout is `.github/renovate-sweep.conf`. Nothing was committed or pushed.
