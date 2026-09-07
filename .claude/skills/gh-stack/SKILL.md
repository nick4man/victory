---
name: gh-stack
description: Use when a change spans two or more dependent pull requests — chaining PRs with `gh pr create --base <branch>`, running `git rebase --onto` after a parent PR merges, retargeting with `gh pr edit --base`, or splitting a large feature into a reviewable chain. Also on the words stacked PRs, stacked diffs, стековые PR, цепочка PR, слой стека, «разбить большой PR», `gh stack submit/sync/rebase/merge`, gs alias. RELATED (.claude/docs/delegation-map.md) — every PR in the stack still goes through the mandatory `/code-review <PR#>`; pair with skill `session-coordination` when working from parallel worktrees.
---

# gh stack

## Overview

`gh stack` (extension `github/gh-stack`, v0.1.1 here) manages a chain of dependent branches and the **stack object on GitHub**. The payoff is one thing: the reviewer sees 200 lines instead of 2000, and you do not wait for part one to merge before starting part two.

**What hand-rolling cannot do:** chaining `--base` alone does NOT create a stack on GitHub. You get N unrelated PRs whose only link is "1/3" typed in the body. The stack — chain UI, stack number, atomic merge — is a separate object, created only by `submit`, `sync`, or `link`.

Check it is there: `gh stack --version`. Install if missing: `gh extension install github/gh-stack`.

## When to use

| Situation | Call |
|---|---|
| One file, one logical step | plain PR — a stack only gets in the way |
| Refactor + a feature on top of it | **stack**: layer 1 refactor, layer 2 feature |
| Migration + service + controller + view | **stack** along the architecture layers |
| Several independent features | NOT a stack — parallel branches off `main` |
| A 40-commit branch you now have to slice | `gh stack init b1 b2 b3` over existing branches, or `modify` |

The criterion is **dependency**. A stack means "B is meaningless without A". If A and B are independent, a stack imposes a false merge order and blocks you against yourself.

- Two or more PRs where each builds on the previous one
- You are about to type `gh pr create --base <feature-branch>`
- You are about to reason about `git rebase --onto <old-parent> <branch>` after a parent merged
- Someone else's stack you need to check out: `gh stack checkout <pr-number|pr-url|branch>`

**Not for:** a single independent PR. Plain `gh pr create` is correct there.

## Agent-critical behaviour (non-interactive terminals)

You are usually running without a TTY. That silently changes what these commands do:

| Command | Without a TTY |
|---|---|
| `gh stack submit` | Acts as `--auto`: skips the editor and **creates PRs as drafts**. Pass `--open` for ready-for-review, or `gh pr ready <N>` afterwards. |
| `gh stack merge` | Merges the **whole stack** without confirmation, same as `--yes`. Only a **PR number** limits it — and a bare number is resolved as a *stack* number first, so `merge 7` may merge everything. See the merge section. |
| `gh stack sync` | Aborts instead of prompting if local and remote stacks diverged. Nothing is pushed. |
| `gh stack modify` / `switch` / `checkout` with no args | Interactive TUI only — you cannot drive these. Use explicit arguments, or `gh stack up [n]` / `down [n]` / `top` / `bottom` / `trunk` to navigate. |

`gh stack modify` has no non-interactive equivalent at all: restructure by hand with git, or leave it to the user.

Read state with `gh stack view --json` → `{trunk, currentBranch, branches[{name, base, isCurrent, isMerged, isQueued, needsRebase}]}`. Parse that rather than reading the ASCII tree. Outside a stack it exits **2** — check the exit code directly, not through a pipe (`cmd | head` gives you head's status, and the guard always passes).

## The three workflows

```bash
# 1. Build the stack
gh stack init feat/migration feat/service feat/tg-buttons   # bottom to top
gh stack add -Am "Add owner intake service" feat/service    # add a layer later
gh stack submit --open                                      # push + create PRs + create the stack

# 2. Parent branch changed (review fixes)
gh stack sync            # fetch, cascade-rebase, atomic force-with-lease push, relink

# 3. Parent PR merged
gh stack sync            # fast-forwards trunk, rebases the rest, retargets PRs
```

`init` accepts several names at once and **adopts existing branches** — that is the supported way to turn work you already wrote into a stack. `--base develop` if trunk is not the default branch.

`add` variants: `add <branch>` new empty layer; `add -Am "msg" <branch>` stage everything (untracked included), commit, then create the layer; `-u` instead of `-A` for tracked files only; `add -m "msg"` with no name generates one from the message (`09-07-fix_login_bug`) — prefer an explicit `claude/<task>` or `fix/<smth>` name here.

⚠️ **Verified quirk:** if the current stack branch has **no commits yet**, `add` does not create a new layer — it drops the commit into that same branch and warns `Branch X has no prior commits`. Not an error: call `add` again for the next layer. Fill layer one with a commit first, then grow the stack.

`sync` replaces the entire `rebase --onto` + `push --force-with-lease` + `gh pr edit --base` sequence, including the squash-merge case. It does **not** open PRs — only `submit` does. On a rebase conflict it restores every branch and tells you to run `gh stack rebase` (fix → `git add` → `gh stack rebase --continue`, or `--abort`). `sync` itself takes only `--prune` and `--remote`: `--prune` drops local branches of merged PRs and moves the checkout to the first live layer, keeping stack metadata intact.

The partial-rebase flags live on **`rebase`, not `sync`** (verified: `gh stack sync --no-trunk` → `unknown flag`). `gh stack rebase --downstack` / `--upstack` limit it to part of the stack; `--no-trunk` leaves trunk alone, useful while `main` moves under you.

**The working tree must be clean.** Verified: with a dirty tree the rebase fails on the first checkout and leaves the stack half-applied.

Merge atomically — all or nothing, everything below your choice included:

```bash
gh stack merge 4242 --squash --yes   # up to PR 4242 — IF 4242 is not also a stack number
gh stack merge --squash --yes        # the ENTIRE stack — only when you mean it
```

🚨 **A bare number is tried as a *stack* number first, and only then as a PR number** (`gh stack merge --help`). A stack number does not limit anything — it selects a whole stack to merge. So `gh stack merge 7` can squash unreviewed layers into `main` while you believe you capped it at layer 7. Before merging, confirm from `gh stack view --json` which PR number is your intended ceiling, and check that the number is not also a live stack number.

One guard is built in: `merge` refuses PRs that are drafts. Since `submit` without a TTY creates drafts, a stack submitted by an agent cannot be merged until `gh pr ready <N>` — the accident above needs a stack that was deliberately opened first.

In `view`, statuses read: `✓` merged, `◎` queued, `○` open, `⚠` needs rebase. On `⚠`, run `sync` before anything else.

## victory62 rules

1. **`main` = prod, direct push forbidden.** A stack changes nothing there: the bottom layer is still based on `main` and still gets in only through a PR. `gh stack merge` goes through the GitHub API — legal; `git push origin main` — not.
2. 🚨 **HTTPS push here hangs and dies on a 300 s timeout.** `submit`, `push` and `sync` call `git push` internally and cannot be handed `-c http.version=HTTP/1.1`. So fix it once per repository **before the first `submit`**: `git config http.version HTTP/1.1`. Without this `gh stack submit` hangs silently for five minutes and fails, and it looks like an extension bug when it is transport.
3. **Code review is mandatory per PR of the stack**, not for the stack as a whole. Order stays: code → green CI → `/code-review <PR#>` → fixes → only then `merge`. Tell the reviewer the PR is a stack layer whose base is not `main` — otherwise they read the diff and wonder where the extra code came from (it is the layer below).
4. **CI on a PR is 9 checks.** A stack multiplies them by the number of layers.
5. Dates in PR bodies and commits — `dd.MM.yy`.

### Stack state is per-worktree, not shared

`gh stack` keeps local tracking in **`.git/gh-stack`** — which for a worktree is `.git/worktrees/<name>/gh-stack`, i.e. **every worktree has its own independent stack**. Verified: a stack built in one worktree is invisible from another (`gh stack view` there shows its own stack, or nothing).

- Do not expect `gh stack view` in `victory` to show a stack assembled in `victory-urgent-collector`. That is design, not drift or data loss.
- Run one stack in one worktree, from start to merge.
- If you do need it elsewhere, do not rebuild it by hand — pull it from GitHub: `gh stack checkout <branch|PR#|stack#>`, which fetches the branches and creates local tracking in place.
- This is the opposite of the inbox queue, which *is* shared via `git --git-common-dir`. Do not carry one intuition over to the other.

Next to it live `.git/**/gh-stack.lock` (advisory lock — `another gh-stack process may be running` means a second command is still hanging around) and `gh-stack.rerere-declined`.

🚨 **On stash:** the stash stack is shared across worktrees and other sessions. To park changes before a rebase, make a temporary WIP commit (it ends up inside the layer anyway) rather than a bare `git stash`.

## Quick reference

| Need | Command |
|---|---|
| See the stack + PR status | `gh stack view` / `--short` / `--json` |
| Adopt existing branches | `gh stack init branch1 branch2 branch3` |
| Push branches only, no PRs | `gh stack push` (per-branch, not atomic; skips merged/queued) |
| Stack PRs made by other tools | `gh stack link <pr-or-branch>...` (bottom-up; accepts branch names, PR numbers, URLs) |
| Restructure (drop/fold/insert/reorder) | `gh stack modify` (TUI), then `gh stack submit` — otherwise GitHub keeps the old bases |
| Dismantle | `gh stack unstack` (`--local` to keep GitHub untouched) |
| Point at a different remote | `git config gh-stack.remote <remote>` |

## Common mistakes

- **Assuming `--base` chaining gives the reviewer a stack.** It gives three separate PRs. Run `submit` or `link`.
- **`gh stack submit` in a script, then wondering why every PR is a draft.** Add `--open`.
- **Trusting a number in `merge` to cap it.** Without a TTY it merges the whole stack, unreviewed layers included — and a bare number is read as a stack number before a PR number.
- **Reaching for `git rebase --onto` after a merge.** That is what `sync` is for.
- **Deleting the parent branch before rebasing children.** `sync` handles the retarget; do not pre-clean.
- **`gh stack modify` without a following `submit`.** The local stack is restructured, GitHub still has the old base chain.

## Diagnostics

| Symptom | Cause / fix |
|---|---|
| `submit`/`push`/`sync` hangs, dies after ~300 s | HTTPS transport. `git config http.version HTTP/1.1` |
| `another gh-stack process may be running` | stale `.git/**/gh-stack.lock` from an interrupted command; confirm no process, then delete the lock |
| `gh stack view` in another worktree shows a different stack | state is per-worktree — normal. `gh stack checkout <branch>` |
| `Local main has diverged from origin/main` | the rebase targets `origin/main`, local `main` is untouched. Usually what you want |
| rebase failed at `checking out <branch>` | dirty working tree — this happens *before* any rebase starts, so `--continue` answers `no rebase in progress`. Commit or park the changes, then re-run `gh stack sync` (or `gh stack rebase`) from the top. `--continue`/`--abort` are for the *conflict* path only |
| "Stack synced" vs "Branches synced" | first — the stack object on GitHub was updated; second — branches pushed but no stack exists (fewer than 2 PRs) |
| PR created and nobody reviews it | `submit --auto` made a draft. `--open`, or `gh pr ready <N>` |
| `merge` refused by branch protection | GitHub evaluates the rules at merge time; bypassing merge requirements for stacks is unsupported — fix the PR |
