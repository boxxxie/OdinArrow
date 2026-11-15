# Specification: Update Repo File Organization and Naming to Align with Typical Odin Library Conventions

## Overview
Skadi (formerly OdinArrow) previously organized its core library under `src/` (`package odinarrow`), unit tests under `tests/test_*.odin`, C++ interop tests under `tests_cpp/test_arrow_cpp.odin`, examples under `examples/quickstart/`, CLI programs and FFI benchmark wrappers under `programs/`, and benchmarks under `benchmarks/`. In the Odin ecosystem, libraries expose a named package directory (`skadi/` with `package skadi`), use `*_test.odin` test file naming, place runnable examples in `examples/` (`package main`), and configure `ols.json` so editor tooling matches `Makefile` and CI checks.

This track audits the repository layout and updates directory structure, package names, file names, static checks (`-vet -strict-style -disallow-do -warnings-as-errors`), build/CI configuration, and documentation to follow idiomatic Odin library conventions.

## Target Before/After Mapping
- **Core library:** `src/*.odin` (`package odinarrow`) -> `skadi/*.odin` (`package skadi`)
- **Unit tests:** `tests/test_*.odin` (`package odinarrow_tests`, `import oa "../src"`) -> `tests/*_test.odin` (`package skadi_tests`, `import oa "../skadi"`)
- **C++ FFI tests:** `tests_cpp/test_arrow_cpp.odin` (`package odinarrow_tests_cpp`, `import oa "../src"`) -> `tests_cpp/arrow_cpp_test.odin` (`package skadi_tests_cpp`, `import oa "../skadi"`)
- **Native CLI examples:** `programs/csv_to_parquet_odin/` & `programs/parquet_to_csv_odin/` -> `examples/csv_to_parquet/` & `examples/parquet_to_csv/` (`package main`, `import oa "../../skadi"`)
- **FFI benchmark wrappers:** `programs/csv_to_parquet_ffi/` & `programs/parquet_to_csv_ffi/` -> `benchmarks/csv_to_parquet_ffi/` & `benchmarks/parquet_to_csv_ffi/` (`package main`)
- **Benchmarks & examples:** `examples/quickstart/`, `benchmarks/odin/`, `benchmarks/odin_c/` updated to `import oa "../../skadi"` (and `package main` for `benchmarks/odin/`)

## Functional Requirements
1. **Package Layout:**
   - Move `src/` to `skadi/` with `package skadi` across all 24 library files, and update all internal imports across `tests/`, `tests_cpp/`, `examples/`, and `benchmarks/`.
2. **File & Test Naming Alignment:**
   - Ensure all `.odin` source files use consistent `snake_case` naming and idiomatic OS/arch suffixes (`*_unix.odin`, `*_other.odin`).
   - Standardize test file naming to `*_test.odin` in `tests/` and `tests_cpp/`, and standardize executable packages (`examples/*`, `benchmarks/odin`, `benchmarks/*_ffi`) to `package main`.
3. **Build, Tooling, and CI Updates:**
   - Add `ols.json` matching `Makefile` flags (`-vet -strict-style -disallow-do -warnings-as-errors`).
   - Add a `make check` target and update `Makefile`, `.github/workflows/ci.yml`, `.gitignore`, and `.gdumpignore` for the updated paths.
4. **Documentation & Examples Alignment:**
   - Update `README.md`, `examples/`, and `benchmarks/` imports and build commands so every documented command works out-of-the-box.

## Non-Functional Requirements
- **Zero Behavioral Regression:** All existing unit tests, C++ FFI interop tests (when Arrow C++ is available), CLI programs, and quickstart examples must continue to pass without functional changes.
- **Strict Static Checks:** Every Odin package in the repository must pass `odin check` with `-vet -strict-style -disallow-do -warnings-as-errors`.

## Acceptance Criteria
- [x] Canonical Odin library package structure (`skadi/`, `package skadi`) is documented and implemented.
- [x] All `.odin` files, test files (`*_test.odin`), and directories follow consistent Odin `snake_case` conventions, and `programs/` is cleanly split into `examples/` and `benchmarks/`.
- [x] All internal imports in `tests/`, `tests_cpp/`, `examples/`, and `benchmarks/` resolve to `skadi`.
- [x] `make check` and `make test` pass with zero warnings or errors.
- [x] `README.md`, `ols.json`, `Makefile`, and CI workflows match the updated layout.

## Out of Scope
- Refactoring internal algorithms, API signatures, or adding new Arrow compute/IPC features.
- Changing C++ or Python benchmark logic beyond updating paths/imports if moved.
