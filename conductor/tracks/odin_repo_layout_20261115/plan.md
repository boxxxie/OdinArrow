# Implementation Plan: Update Repo File Organization and Naming to Align with Typical Odin Library Conventions

## Phase 1: Audit & Target Layout Design
- [ ] Task: Audit current repository structure, imports, and tooling configuration
    - [ ] Inventory all `.odin` packages, `package` declarations, and `import` statements across `src/`, `tests/`, `specs/`, `tests_cpp/`, `examples/`, `programs/`, and `benchmarks/`
    - [ ] Review `Makefile`, `ols.json`, `.github/workflows/`, `.gdumpignore`, and `README.md` for hardcoded directory assumptions
- [ ] Task: Define and document the target Odin library layout
    - [ ] Finalize package/collection naming (e.g., `odinarrow/` package or collection root, `*_test.odin` naming, example/program/benchmark locations)
    - [ ] Document the before/after mapping in the track notes so all moves are traceable
- [ ] Task: Conductor - User Manual Verification 'Audit & Target Layout Design' (Protocol in workflow.md)

## Phase 2: Core Library & Package Restructure
- [ ] Task: Reorganize core library package directory and file names
    - [ ] Move/rename core library files into the canonical package structure (`git mv`) preserving history
    - [ ] Verify package declarations and internal file naming (`snake_case.odin`, OS suffixes)
    - [ ] Run `odin check` with `-vet -strict-style -disallow-do -warnings-as-errors` on the core package
- [ ] Task: Update `ols.json` and collection configuration
    - [ ] Configure `collections` (if applicable) and `checker_args` in `ols.json`
- [ ] Task: Conductor - User Manual Verification 'Core Library & Package Restructure' (Protocol in workflow.md)

## Phase 3: Tests, Specs, Examples, Programs & Benchmarks Alignment
- [ ] Task: Update unit tests and spec tests to match target naming and imports
    - [ ] Rename test files to idiomatic `*_test.odin` (if applicable) and update `import` paths
    - [ ] Verify `odin test` passes on all test and spec packages
- [ ] Task: Update `examples/`, `programs/`, `tests_cpp/`, and `benchmarks/`
    - [ ] Update `import` statements and any relative paths in `examples/quickstart/`, `programs/*/`, `tests_cpp/`, and `benchmarks/`
    - [ ] Verify `odin check` and `odin run examples/quickstart` succeed
- [ ] Task: Conductor - User Manual Verification 'Tests, Specs, Examples, Programs & Benchmarks Alignment' (Protocol in workflow.md)

## Phase 4: Build Scripts, CI, and Documentation
- [ ] Task: Update `Makefile`, CI workflows, `.gitignore`, and `.gdumpignore`
    - [ ] Update `Makefile` targets (`check`, `test`, `test-specs`, `test-cpp`, `bench-*`, `programs`) to use new paths/collection flags
    - [ ] Update `.github/workflows/` and `.gdumpignore` if paths changed
- [ ] Task: Update `README.md` and run full verification
    - [ ] Update `README.md` build/import instructions and directory links
    - [ ] Run `make check` and `make test` and confirm 100% pass with zero warnings
- [ ] Task: Conductor - User Manual Verification 'Build Scripts, CI, and Documentation' (Protocol in workflow.md)
