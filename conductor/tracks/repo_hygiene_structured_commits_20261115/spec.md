# Specification: Repository Hygiene, Ignore Rules & Structured Conventional Commits

## Overview
All completed feature, optimization, pipeline, and benchmark work currently sits uncommitted in the working tree alongside untracked artifacts such as `benchmarks/__pycache__/`. Before concluding, the repository needs clean ignore rules, full verification across all build targets, and well-scoped Conventional Commits on the active working branch.

---

## Functional Requirements

### 1. Update Ignore Rules (`.gitignore`, `.gdumpignore`)
- Add `benchmarks/__pycache__/`, `*.pyc`, `.tmp/`, and transient benchmark/test binary outputs to `.gitignore` as needed so `git status` contains zero generated Python bytecode or temporary scratch files.
- Audit `.gdumpignore` via `gdump -l` to confirm dependency code (`deps/**`), generated binaries, docs, and non-application artifacts remain properly filtered for app-code dumps.

### 2. Full Repository Verification Gate
- Verify every Odin package and target with strict flags after final edits:
  - `odin check skadi -no-entry-point -vet -strict-style -disallow-do -warnings-as-errors`
  - `odin check skadi/pipeline -no-entry-point -vet -strict-style -disallow-do -warnings-as-errors`
  - `odin check benchmarks/odin -vet -strict-style -disallow-do -warnings-as-errors`
  - `odin test tests -out:bin/test_runner -vet -strict-style -disallow-do` (100% pass, `0` leaks)
  - `python3 -m unittest benchmarks/test_compare_1v1.py`

### 3. Structured Conventional Commits (Working Branch Only)
- Partition modified and untracked tracked-worthy files into logical Conventional Commits (`feat`, `perf`, `test`, `docs`, `chore`, `build`) — never bundling unrelated subsystems into one giant commit.
- Confirm clean `git status` after commits. Do **not** push to `master` or trigger release/deploy actions without explicit user approval.

---

## Non-Functional Requirements
- **Strict Branch Safety:** Never commit or push directly to `master` (or merge into `master`) without explicit user authorization in that turn.
- **No Unintended Files:** Verify no compiled executables, `.tmp/` artifacts, or `__pycache__/` files are staged.

---

## Acceptance Criteria
- [x] `.gitignore` and `.gdumpignore` cleanly exclude `benchmarks/__pycache__/`, `.tmp/`, build artifacts, and `deps/**` (in `.gdumpignore`).
- [x] All `odin check`, `odin test tests`, and Python comparator unit tests pass with 0 warnings and 0 leaks.
- [x] Working tree is committed cleanly on a non-`master` branch (or verified with user before creating/committing if currently on `master`) in logical Conventional Commits with clean `git status`.

---

## Out of Scope
- Pushing to `master`, creating release tags, or modifying remote CI deployment triggers.
