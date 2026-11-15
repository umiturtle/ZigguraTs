# Task M6-05: Reduce documentation and runtime scope

- **Status**: `review`
- **Branch**: `arena/docs-runtime-simplification`
- **Scope**: `.github/`, `docs/`, `examples/`, `scripts/`, `src/`, `tests/`, project metadata
- **Upstream Reference**: Not applicable; this task integrates repository-wide documentation, CLI, and runtime changes.
- **Next Step**: Monitor CI on PRs #28 and #29; after #28 merges, retarget #29 to `main` and confirm the package-version / URL change is intentional.

---

## 1. Purpose and Definition of Done

- [ ] Review the full diff and ensure its scope matches the requested main-target integration.
- [x] Run `python3 scripts/check-docs.py` and the documented Zig formatting check.
- [x] Run `./zigw quick-test` and address failures.
- [x] Resolve `git diff --check` findings.
- [ ] Verify the package version, release URLs, and intended API removals before merging.
- [x] Push the arena branches and create stacked PRs #28 and #29.

---

## 2. Current Progress Checkpoint

- **Completed**:
  - Split the eight existing commits into PR #28 (`arena/m6-04-feature`) targeting `main`.
  - Committed the 282-file documentation, CLI, runtime, and metadata diff on `arena/docs-runtime-simplification` and opened PR #29 stacked on #28.
  - Passed `python3 scripts/check-docs.py`, `python3 scripts/gen-framework-tutorials.py --check`, `./zigw fmt --check src/ build.zig build.zig.zon`, `./zigw quick-test` (333 passed, 2 native-only skipped), and `git diff --check`.
- **In progress / last state**:
  - CI is running on both PRs.
  - PR #29 changes the package version and published URLs; those values still need confirmation before merge.

---

## 3. Decisions and Notes

- The first PR carries the eight existing commits; this follow-up PR carries the separate working-tree diff and is stacked on the first.
- PR #29 changes the package version and published repository URLs; verify the new version and slug are intentional before merge.
- The diff removes store autosave / restore diagnostics and native monitor/cursor provider wiring; confirm tests and docs reflect the resulting behavior.
