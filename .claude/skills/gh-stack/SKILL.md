---
name: gh-stack
description: Use when a change spans two or more dependent pull requests — chaining PRs with `gh pr create --base <branch>`, running `git rebase --onto` after a parent PR merges, retargeting with `gh pr edit --base`, or splitting a large feature into a reviewable chain. Also on the words stacked PRs, stacked diffs, стековые PR, цепочка PR.
---

# gh stack

## Overview

`gh stack` (extension `github/gh-stack`) manages a chain of dependent branches and the **stack object on GitHub**.

**What hand-rolling cannot do:** chaining `--base` alone does NOT create a stack on GitHub. You get N unrelated PRs whose only link is "1/3" typed in the body. The stack — chain UI, stack number, atomic merge — is a separate object, created only by `submit`, `sync`, or `link`.

Install if missing: `gh extension install github/gh-stack`.

## When to use

- Two or more PRs where each builds on the previous one
- You are about to type `gh pr create --base <feature-branch>`
- You are about to reason about `git rebase --onto <old-parent> <branch>` after a parent merged
- Someone else's stack you need to check out: `gh stack checkout <pr-number|pr-url|branch>`

**Not for:** a single independent PR. Plain `gh pr create` is correct there.

## Agent-critical behaviour (non-interactive terminals)

You are usually running without a TTY. That silently changes what these commands do:

| Command | Without a TTY |
|---|---|
| `gh stack submit` | Acts as `--auto`: skips the editor and **creates PRs as drafts**. Pass `--open` for ready-for-review. |
| `gh stack merge` | Merges the **whole stack** without confirmation, same as `--yes`. Always pass an explicit PR or stack number to limit it. |
| `gh stack sync` | Aborts instead of prompting if local and remote stacks diverged. Nothing is pushed. |
| `gh stack modify` / `switch` / `checkout` with no args | Interactive TUI only — you cannot drive these. Use explicit arguments. |

Read state with `gh stack view --json`. Outside a stack it exits **2** — check the exit code directly, not through a pipe (`cmd | head` gives you head's status, and the guard always passes).

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

`sync` replaces the entire `rebase --onto` + `push --force-with-lease` + `gh pr edit --base` sequence, including the squash-merge case. On a rebase conflict it restores every branch and tells you to run `gh stack rebase` (then `--continue` or `--abort`).

Merge atomically — all or nothing, everything below your choice included:

```bash
gh stack merge 4242 --squash --yes   # up to PR 4242
gh stack merge --squash --yes        # the ENTIRE stack — only when you mean it
```

## Quick reference

| Need | Command |
|---|---|
| See the stack + PR status | `gh stack view` / `--short` / `--json` |
| Adopt existing branches | `gh stack init branch1 branch2 branch3` |
| Push branches only, no PRs | `gh stack push` (per-branch, not atomic) |
| Stack PRs made by other tools | `gh stack link <pr-or-branch>...` |
| Restructure (drop/fold/reorder) | `gh stack modify` (TUI), then `gh stack submit` |
| Dismantle | `gh stack unstack` (`--local` to keep GitHub untouched) |

## Common mistakes

- **Assuming `--base` chaining gives the reviewer a stack.** It gives three separate PRs. Run `submit` or `link`.
- **`gh stack submit` in a script, then wondering why every PR is a draft.** Add `--open`.
- **Omitting the PR number from `merge`.** Without a TTY that merges the whole stack, unreviewed layers included.
- **Reaching for `git rebase --onto` after a merge.** That is what `sync` is for.
- **Deleting the parent branch before rebasing children.** `sync` handles the retarget; do not pre-clean.
