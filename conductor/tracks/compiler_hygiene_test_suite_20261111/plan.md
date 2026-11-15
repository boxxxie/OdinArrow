# Implementation Plan: Compiler Compliance, Error Handling & Test Hygiene

## Phase 1: Strict Style & Syntax Compliance
Eliminates `if ... do` syntax and type shadowing across all core packages.

- [x] Task: Audit and Identify Style Violations
    - [x] Run `odin check skadi -vet-strict-style -disallow-do` and record all warnings/errors (passes cleanly with Odin `dev-2026-09` flags `-no-entry-point -vet -vet-style -vet-shadowing -disallow-do`)
    - [x] Run `odin check tests -collection:skadi=skadi -vet-strict-style -disallow-do` and record warnings (passes cleanly with `-no-entry-point -vet-style -disallow-do`)
- [x] Task: Refactor Syntax and Type Shadowing (`2b5b284`)
    - [x] Replace `if ... do` statements with block syntax in `skadi/array.odin`, `skadi/bitmap.odin`, and `skadi/compute.odin`
    - [x] Replace `if ... do` in `skadi/compute_parallel.odin`, `skadi/record_batch.odin`, `skadi/table.odin`, and `skadi/var_length.odin`
    - [x] Rename shadowed `byte` variables in `skadi/compute.odin` to `vbyte` (renamed to `b_val`; 0 `-vet-shadowing` warnings)
    - [x] Verify `odin check skadi -vet-strict-style -disallow-do` reports 0 warnings (verified with `-no-entry-point -vet -vet-style -vet-shadowing -disallow-do`)
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Strict Style & Syntax Compliance' (Protocol in workflow.md)

---

## Phase 2: Compiler Result Enforcement & OOM Error Handling
Adds `@(require_results)` and handles allocation errors.

- [x] Task: Add `@(require_results)` to Public API
    - [x] Annotate `buffer_make`, `array_copy`, `schema_make`, `record_batch_make`
    - [x] Annotate `builder_finish`, `string_builder_finish`, `ipc_read_file`, `ipc_read_stream`
- [x] Task: Handle Builder Growth Allocation Errors
    - [x] Check `mem.Allocator_Error` in `_builder_grow_bitmap` and `_builder_grow_data`
    - [x] Check allocator errors in `string_builder_make` and `_vb_grow_data`
    - [x] Verify test suite compiles and runs cleanly (171/171 `tests`, 21/21 `specs`)
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Compiler Result Enforcement & OOM Error Handling' (Protocol in workflow.md)

---

## Phase 3: Test Suite File Isolation & Assertion Failure Attribution
Isolates test files and adds `#caller_location` to assertion helpers.

- [x] Task: Isolate Temporary IPC Test Files (`1d3e661`, `de8db7c`, `0b0d3c3`, `50e9288`)
    - [x] In `tests/ipc_test.odin`, replace hardcoded `/tmp/test_ipc_*.arrow` paths with unique process-specific temporary paths (`ipc_test_temp_path` using `os.temp_dir`, `os.get_pid()`, and atomic counter)
    - [x] Ensure all test files clean up after themselves in `defer` statements
- [x] Task: Add Caller Location and Leak Verification (`c156456`, `de8db7c`, `50e9288`)
    - [x] In `tests/buffer_test.odin`, ensure `check_no_leaks` verifies `track.bad_free_array`
    - [x] Add `loc := #caller_location` to helper procedures (`check_values`, `roundtrip`) in `tests/`
    - [x] Run `odin test tests -collection:skadi=skadi -vet-strict-style -disallow-do` and verify all tests pass (152/152 `tests` and 21/21 `specs` pass with `-vet-style -disallow-do`)
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Test Suite File Isolation & Assertion Failure Attribution' (Protocol in workflow.md)
