# Specification: Update Repo File Organization and Naming to Align with Typical Odin Library Conventions

## Overview
OdinArrow currently organizes its core library under `src/`, unit tests under `tests/`, spec tests under `specs/`, C++ interop tests under `tests_cpp/`, examples under `examples/`, CLI programs under `programs/`, and benchmarks under `benchmarks/`. In the Odin ecosystem, libraries typically expose a named package directory (or collection-friendly root/package layout), co-locate or cleanly separate `*_test.odin` suites, use consistent `snake_case` file and package naming, and configure `ols.json` collections so downstream users can import the library cleanly without ad-hoc `src` path aliases.

This track audits the current repository layout and updates directory structure, package names, file names, build/CI configuration, and documentation to follow idiomatic Odin library conventions.

## Functional Requirements
1. **Package & Collection Layout:**
   - Establish a canonical Odin library package/collection layout (e.g., naming the library package directory `odinarrow/` or `arrow/` or configuring an Odin collection in `ols.json` and `Makefile` `-collection:` flags) so imports match `README.md` (`import oa "odinarrow"` or equivalent) consistently across `examples/`, `programs/`, `benchmarks/`, `tests/`, and `specs/`.
2. **File & Test Naming Alignment:**
   - Ensure all `.odin` source files use consistent `snake_case` naming and idiomatic OS/arch suffixes (e.g., `*_unix.odin`, `*_other.odin`).
   - Standardize test file organization and naming (`*_test.odin` rather than `test_*.odin` where appropriate, or co-located/structured test packages matching `odin test` conventions).
3. **Build, Tooling, and CI Updates:**
   - Update `Makefile`, `ols.json`, `.github/workflows/`, `.gitignore`, and `.gdumpignore` to reflect the updated paths, collections, and `-vet -strict-style -disallow-do -warnings-as-errors` check targets.
4. **Documentation & Examples Alignment:**
   - Update `README.md`, `examples/quickstart/`, `programs/`, and `benchmarks/` imports and build commands so every documented command works out-of-the-box.

## Non-Functional Requirements
- **Zero Behavioral Regression:** All existing unit tests, spec tests, C++ FFI interop tests (when Arrow C++ is available), and quickstart examples must continue to pass without functional changes.
- **Strict Static Checks:** Every Odin package in the repository must pass `odin check` with `-vet -strict-style -disallow-do -warnings-as-errors`.

## Acceptance Criteria
- [ ] Canonical Odin library package/collection structure is documented and implemented.
- [ ] All `.odin` files, test files, and directories follow consistent Odin `snake_case` and `*_test.odin` naming conventions.
- [ ] All internal imports in `tests/`, `specs/`, `examples/`, `programs/`, and `benchmarks/` resolve via the canonical package/collection path.
- [ ] `make check` and `make test` pass with zero warnings or errors.
- [ ] `README.md`, `ols.json`, `Makefile`, and CI workflows match the updated layout.

## Out of Scope
- Refactoring internal algorithms, API signatures, or adding new Arrow compute/IPC features.
- Changing C++ or Python benchmark logic beyond updating paths/imports if moved.
