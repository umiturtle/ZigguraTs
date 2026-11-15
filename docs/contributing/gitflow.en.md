# Branch model (gitflow)

> **Audience**: anyone proposing a change to this repository or cutting a release.

This repository follows **gitflow**. The owner (a human) maintains the long-lived branches;
Arena agents running in parallel branch exactly one `feature/<slug>` from their session's
`arena/<session>` ref and open the PR against `develop`. Branch names and PR bases are validated
by [`scripts/gitflow.sh`](../../scripts/gitflow.sh), and CI runs its `--self-test` and
`--check-pr-base` tables on every push and pull request (rule 19).

## What each branch is for

| Branch | Purpose | Merge into | Tag |
|---|---|---|---|
| `main` | released state, always shippable | — | `vX.Y.Z` is cut here |
| `develop` | integration for the next release | `main` | never |
| `feature/<slug>` | one unit of work | PR to `develop` | never |
| `release/<x.y.z>` | version freeze and final polish | `main`, then back-merge to `develop` | `v<x.y.z>` on `main` |
| `hotfix/<x.y.z>` | urgent fix to a released version | `main`, then back-merge to `develop` | `v<x.y.z>` on `main` |
| `arena/<agent>` | an Arena session's working ref | never the PR head (branch `feature/<slug>` from it first) | never |

`<slug>` is lowercase alphanumeric plus `._-`; `<x.y.z>` is SemVer (pre-releases such as
`1.0.0-beta.1` are allowed). A string like `beta-1.0` cannot go into `build.zig.zon`, so it is not
a branch version either.

Today `main` holds the released state (`origin/main`) and `develop` integrates the next release.
`develop` stays ahead of `main` and reaches `main` through `release/*` when a version is frozen.

## Tool configuration

Installing the `git flow` tool gives you `git flow feature start <slug>` and friends. The source of
truth for the names is this repository's [`scripts/gitflow.sh`](../../scripts/gitflow.sh), and CI
runs the same tables (rule 19). To teach `git flow` those names, write the local keys once:

```bash
bash scripts/gitflow.sh --init
```

The keys are `gitflow.branch.master=main`, `gitflow.branch.develop=develop`,
`gitflow.prefix.feature=feature/`, `gitflow.prefix.release=release/`,
`gitflow.prefix.hotfix=hotfix/`, `gitflow.prefix.support=support/` and
`gitflow.prefix.versiontag=v`. `--init` only writes configuration; it never creates a branch.

## Validate a name

```bash
bash scripts/gitflow.sh --check feature/window-state
bash scripts/gitflow.sh --check release/0.1.1
bash scripts/gitflow.sh                 # current branch and its recommended base
bash scripts/gitflow.sh --self-test     # the naming table CI runs
```

The script **never creates a branch** — that is always the owner's job. An agent can only point a
PR's **base** at the `develop` branch the owner created (`--base develop`).

## Validate a PR base

The `gitflow-pr-base` CI job checks every pull request. You can reproduce the verdict locally:

```bash
bash scripts/gitflow.sh --check-pr-base develop feature/window-state
```

| PR base | Allowed head |
|---|---|
| `main` | `release/<x.y.z>` / `hotfix/<x.y.z>` only |
| `develop` | `feature/<slug>` / `arena/<agent>` / `release/<x.y.z>` / `hotfix/<x.y.z>` / `main` (back-merge after a release) |
| `feature/*` `release/*` `hotfix/*` `arena/*` | stacked work from the same family (including `arena/*`) |

A PR that points `feature/*` or `arena/*` straight at `main` fails. Next-release work enters
`develop`; fixes to a released version enter `main` through `release/*` or `hotfix/*`.

## Cutting a release

`build.zig.zon`'s `.version` is the single source of truth. `scripts/check-docs.py` checks that the
CLI version, release URLs, archive names and the sync ledger all say the same thing.

1. The owner branches `release/<x.y.z>` from `develop`.
2. Set `.version` in `build.zig.zon` to `x.y.z`.
3. Merge the `release/<x.y.z>` → `main` PR and confirm the 3-OS CI is green.
4. Tag the merge commit on `main`:

   ```bash
   git tag v<x.y.z> <main commit>
   git push origin v<x.y.z>
   ```

5. The [`Release`](../../.github/workflows/release.yml) workflow fires on `v*` and publishes the
   source archive → `zig fetch` hash → `zts` binaries for 3 OSes → `SHA256SUMS` → the GitHub
   release.
6. Back-merge `main` into `develop`; delete `release/<x.y.z>` once it is no longer needed.

The workflow uses `--verify-tag`, so push the tag **first**. `workflow_dispatch` is not used for
releases because `github.ref_name` would be a branch name.

## Branches CI reacts to

[`ci.yml`](../../.github/workflows/ci.yml) sets `push.branches` to `main` / `develop` /
`feature/**` / `release/**` / `hotfix/**` / `arena/**`. A push to any of them runs the same 3-OS
matrix. Pages and Release are restricted to `main` and tags.

## Coexisting with Arena agents

- Each session works on the `arena/<session>` branch the harness creates and leaves that ref as
  the session's work log.
- To open a PR, the agent branches **exactly one `feature/<slug>`** from its `arena/<session>` ref,
  pushes it and targets `develop`. The PR head is `feature/<slug>` and the base is `develop`
  (check it with `bash scripts/gitflow.sh --check-pr-base develop feature/<slug>`).
- That keeps the shared `arena/*` refs untouched while making the review and merge unit follow the
  gitflow names.
- [`AGENTS.md`](../../AGENTS.md) and `docs/roadmap/milestones.md` checkboxes are shared by every
  branch and are never edited. Progress lives in one file per task under `docs/tasks/<ID>-*.md`.

## Related

- [Repository map](repository-map.en.md)
- [Documentation sync ledger](doc-sync.en.md)
- [GitHub Actions operations](../environment/github-actions.md)
- For app authors adding the dependency → [`../learn/en/guides/package.md`](../learn/en/guides/package.md)
