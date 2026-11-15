# Working with Jujutsu (jj, optional)

> **Audience**: anyone who wants to shape diffs with `jj` instead of plain `git`.

`git` is the source of truth for this repository. CI, [`scripts/status.sh`](../../scripts/status.sh),
[`scripts/gitflow.sh`](../../scripts/gitflow.sh) and GitHub pull requests all look at **git
branches**. `jj` is an optional layer on top, used in **colocated mode**; you can develop without
it. Agents follow the git workflow in [`AGENTS.md`](../../AGENTS.md).

## Install

```bash
# 1. Binary (Linux x86_64 shown; use the matching asset from jj's Releases)
mkdir -p ~/.local/bin
curl -sL https://github.com/jj-vcs/jj/releases/download/v0.47.1/jj-v0.47.1-x86_64-unknown-linux-musl.tar.gz \
  | tar -xz -C ~/.local/bin

# 2. Colocate this checkout (.jj/ only; git history is untouched)
jj git init --colocate

# 3. Identity (match git's user.name / user.email)
jj config set --user user.name  "…"
jj config set --user user.email "…"
jj metaedit --update-author        # apply it to the existing working-copy commit
```

`.jj/` is in `.gitignore`. The `vendor/` submodules are ignored by jj.

## Bookmarks are git branches

A jj **bookmark** maps to a git branch. Colocating imports the existing branches as bookmarks, so
the gitflow names (`main` / `develop` / `feature/*` / `arena/*`) work unchanged.

```bash
jj bookmark list        # the git branch equivalent
# follow the remote on future fetches (once)
jj bookmark track develop@origin feature/gitflow-adoption@origin
```

## Day to day

```bash
jj st                        # the working-copy diff
jj describe -m "feat: ..."   # message on the current commit
jj new                       # stack an empty commit for the next change
jj log -r '::@'              # ancestors
```

To open a pull request, point a bookmark at the git branch name and push it:

```bash
# branching feature/<slug> from arena/<session>
jj new main                                  # move to the base commit
jj bookmark set feature/<slug> -r @          # the PR head
jj git push -b feature/<slug>

gh pr create --base develop --head feature/<slug> --title "..." --body "..."
```

`jj git push` updates the same refs as `git push`, so CI's `gitflow-pr-base` job and
`bash scripts/gitflow.sh --check-pr-base develop feature/<slug>` keep working.

## Caveats

- **Do not mix git and jj in the same working copy at once.** Run `jj st`, then use one tool for
  that turn.
- jj rewrites commits by default (auto-amend). If you rewrote a pushed bookmark, update it with
  `jj git push -b <name>` — never rewrite the shared `main` / `develop` history.
- Agents (`arena/*`) and CI are git-based. jj is an extra layer for local human work.
- In a colocated checkout, `scripts/status.sh` still reports git state only.

## Related

- [Branch model (gitflow)](gitflow.en.md) — PR bases and branch names
- [Repository map](repository-map.en.md) — which files to touch
- [Repository troubleshooting](troubleshooting.en.md)
