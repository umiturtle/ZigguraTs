## What / Why

<!-- One sentence each. Link the task sheet under docs/tasks/ if there is one. -->

## Branch model

The branch names are validated by `bash scripts/gitflow.sh --check <name>` and CI runs its
`--self-test` and `--check-pr-base` tables on every push and PR. Pick the base that matches the
source branch:

| Source | PR base |
|---|---|
| `feature/<slug>` (including the one an agent branches from its `arena/<session>` ref) | `develop` |
| `release/<x.y.z>` | `main` (then back-merge to `develop`) |
| `hotfix/<x.y.z>` | `main` (then back-merge to `develop`) |
| `arena/<agent>` | not a PR head — branch `feature/<slug>` from it first |

- [ ] Source branch name is valid (`bash scripts/gitflow.sh --check <name>`)
- [ ] PR base matches the table above (`bash scripts/gitflow.sh --check-pr-base <base> <head>`)
- [ ] No `AGENTS.md` / `docs/roadmap/milestones.md` checkbox was edited

## Checks

- [ ] `./zigw quick-test`
- [ ] `python3 scripts/check-docs.py`
- [ ] `./zigw fmt --check src/ build.zig build.zig.zon`
- [ ] `bash scripts/gitflow.sh --self-test`
- [ ] 3 OS CI green
