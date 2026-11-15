# Implementation Plan: Repository Hygiene, Ignore Rules & Structured Conventional Commits

## Phase 1: Ignore Rules & Audit (`.gitignore`, `.gdumpignore`)
Ensures generated caches and vendor directories are properly ignored by Git and `gdump`.

- [x] Task: Update `.gitignore` and Audit `.gdumpignore` (`.gitignore`, `.gdumpignore`)
    - [x] Add `benchmarks/__pycache__/`, `__pycache__/`, `*.pyc`, and `.tmp/` to `.gitignore` if absent
    - [x] Run `gdump -l | xargs wc -c | sort -nr` to verify `.gdumpignore` keeps app-code bundles focused and excludes `deps/**`

---

## Phase 2: Full Verification & Structured Commits
Runs every compiler check and test suite, then commits work cleanly in scoped Conventional Commits.

- [x] Task: Run Full Verification Gate
    - [x] Run `odin check` (`-vet -strict-style -disallow-do -warnings-as-errors`) on `skadi`, `skadi/pipeline`, and `benchmarks/odin`
    - [x] Run `odin test tests -out:bin/test_runner -vet -strict-style -disallow-do` and `python3 -m unittest benchmarks/test_compare_1v1.py`
- [x] Task: Stage & Commit Logical Groups (`git`)
    - [x] Verify active branch (ensure not committing directly to `master` unless explicitly instructed)
    - [x] Split staged changes into clean Conventional Commits (core kernels/types, Sleipnir pipeline + deps, tests, benchmarks + CLI tools, Conductor + docs)
    - [x] Confirm `git status` is clean
