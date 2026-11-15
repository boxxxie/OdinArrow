# Implementation Plan: Update Repo File Organization and Naming to Align with Typical Odin Library Conventions

## Phase 1: Audit & Target Layout Design
- [x] Task: Audit current repository structure, imports, and tooling configuration
    - [x] Inventory all `.odin` packages, `package` declarations, and `import` statements across `src/`, `tests/`, `tests_cpp/`, `examples/`, `programs/`, and `benchmarks/`
    - [x] Review `Makefile`, `ols.json`, `.github/workflows/`, `.gdumpignore`, and `README.md` for hardcoded directory assumptions and static-check gaps (`-disallow-do` and `-vet` errors)
- [x] Task: Define and document the target Odin library layout
    - [x] Finalize package/folder naming (`skadi/` with `package skadi`, `tests/*_test.odin`, `tests_cpp/arrow_cpp_test.odin`, split `programs/` into `examples/` and `benchmarks/`)
    - [x] Document the before/after mapping in `spec.md` so all moves are traceable
- [x] Task: Conductor - User Manual Verification 'Audit & Target Layout Design' (Protocol in workflow.md)

## Phase 2: Core Library & Package Restructure
- [x] Task: Reorganize core library package directory and file names
    - [x] Move `src/` to `skadi/` (`git mv`) preserving history and update `package odinarrow` -> `package skadi` across all 24 files
    - [x] Verify internal file naming (`snake_case.odin`, `ipc_mmap_unix.odin`, `ipc_mmap_other.odin`)
    - [x] Replace the 23 single-line `if ... do` statements in `skadi/` with `{ ... }` blocks
    - [x] Run `odin check skadi -no-entry-point -vet -strict-style -disallow-do -warnings-as-errors` and `odin doc skadi`
- [x] Task: Create `ols.json` configuration
    - [x] Configure `enable_format` and `checker_args` (`-vet -strict-style -disallow-do -warnings-as-errors`) in `ols.json`
- [x] Task: Conductor - User Manual Verification 'Core Library & Package Restructure' (Protocol in workflow.md)

## Phase 3: Tests, Examples, Programs Removal, and Benchmarks Alignment
- [x] Task: Update unit tests and C++ FFI tests to match target naming and imports
    - [x] Rename `tests/test_*.odin` -> `tests/*_test.odin` (`package skadi_tests`) and `tests_cpp/test_arrow_cpp.odin` -> `tests_cpp/arrow_cpp_test.odin` (`package skadi_tests_cpp`), updating `import oa "../skadi"`
    - [x] Verify `odin test tests` passes all tests
- [x] Task: Split `programs/` into `examples/` and `benchmarks/`, and update imports
    - [x] Move `programs/csv_to_parquet_odin` -> `examples/csv_to_parquet` and `programs/parquet_to_csv_odin` -> `examples/parquet_to_csv` (`package main`, `import oa "../../skadi"`)
    - [x] Move `programs/csv_to_parquet_ffi` -> `benchmarks/csv_to_parquet_ffi` and `programs/parquet_to_csv_ffi` -> `benchmarks/parquet_to_csv_ffi` (`package main`) and remove `programs/`
    - [x] Update imports in `examples/quickstart/`, `benchmarks/odin/`, and `benchmarks/odin_c/`, and fix `-vet` errors in `examples/parquet_to_csv/main.odin` and `benchmarks/odin/bench_main.odin`
    - [x] Verify `odin check` across all packages and `odin run examples/quickstart` succeed
- [x] Task: Conductor - User Manual Verification 'Tests, Examples, Programs Removal, and Benchmarks Alignment' (Protocol in workflow.md)

## Phase 4: Build Scripts, CI, and Documentation
- [x] Task: Update `Makefile`, CI workflows, `.gitignore`, and `.gdumpignore`
    - [x] Add `check` target and update `Makefile` targets (`test`, `test-cpp`, `parquet-*`, `csv-to-parquet-*`) to use new paths and `-vet -strict-style -disallow-do -warnings-as-errors`
    - [x] Update `.github/workflows/ci.yml` (use `make check`, fix `odin doc skadi` and remove stale checks), `.gitignore`, and `.gdumpignore`
- [x] Task: Update `README.md` and run full verification
    - [x] Update `README.md` build/import instructions, links, and project layout diagram
    - [x] Run `make check`, `make test`, and CLI build targets and confirm 100% pass with zero warnings
- [x] Task: Conductor - User Manual Verification 'Build Scripts, CI, and Documentation' (Protocol in workflow.md)
