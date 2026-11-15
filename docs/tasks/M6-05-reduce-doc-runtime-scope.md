# Task M6-05: Reduce documentation and runtime scope

- **Status**: `in_progress`
- **Branch**: `arena/docs-runtime-simplification`
- **Scope**: `.github/`, `docs/`, `examples/`, `scripts/`, `src/`, `tests/`, project metadata
- **Upstream Reference**: Not applicable; this task integrates repository-wide documentation, CLI, and runtime changes.
- **Next Step**: Run the required docs, formatting, and Zig test checks; resolve any failures before preparing the main-target PR.

---

## 1. Purpose and Definition of Done

- [ ] Review the full diff and ensure its scope matches the requested main-target integration.
- [ ] Run `python3 scripts/check-docs.py` and the documented Zig formatting check.
- [ ] Run `./zigw quick-test` and address failures.
- [ ] Resolve `git diff --check` findings.
- [ ] Verify the package version, release URLs, and intended API removals before publishing the PR.
- [ ] Push the arena branch and create a PR targeting `main`.

---

## 2. Current Progress Checkpoint

- **Completed**:
  - Confirmed there are no staged changes; the current local `main` had 281 unstaged entries (224 modified, 57 deleted) and no untracked files.
  - Confirmed local `main` is eight commits ahead of `origin/main`; the user approved including those commits in the PR.
  - Created `arena/docs-runtime-simplification` from the current local `main` without changing the working-tree diff.
- **In progress / last state**:
  - The broad documentation, CLI, and runtime changes remain unstaged on this branch.
  - `git diff --check` reports new blank lines at EOF in `docs/decisions/0003-zig-017-runtime-findings.md` and `docs/roadmap/m2-m5-platform-and-ecosystem.md`.

---

## 3. Decisions and Notes

- The proposed PR includes both the eight commits currently ahead of `origin/main` and the current working-tree changes, as explicitly approved by the user.
- The working-tree diff changes the package version and published URLs from `0.1.1` / `ZigguraTs` to `0.1.0` / `Z-Ts`; verify this is intentional before publishing.
- The diff removes store autosave / restore diagnostics and native monitor/cursor provider wiring; confirm tests and docs reflect the resulting behavior.
