# Specification: Compiler Compliance, Error Handling & Test Hygiene

## Overview
Aligns the Skadi codebase with strict Odin compiler checks (`-vet-strict-style`, `-disallow-do`), decorates constructors with `@(require_results)`, handles out-of-memory errors cleanly, isolates test temporary files, and improves test failure diagnostics with `#caller_location`.

## Functional Requirements

### 1. Strict Compiler Compliance (`-vet-strict-style -disallow-do`)
- Refactor all single-line `if ... do ...` statements into idiomatic block syntax `if ... { ... }` across:
  - `skadi/array.odin`
  - `skadi/bitmap.odin`
  - `skadi/compute.odin`
  - `skadi/compute_parallel.odin`
  - `skadi/record_batch.odin`
  - `skadi/table.odin`
  - `skadi/var_length.odin`
- Eliminate shadowing of the built-in `byte` type in `skadi/compute.odin` (replace `byte := vbits[...]` with `vbyte` or `raw_byte`).
- Ensure all packages in `skadi/`, `examples/` / `benchmarks/`, and `tests/` pass `odin check` under `-vet-strict-style -disallow-do` with zero warnings.

### 2. Constructor Result Annotations & OOM Propagation
- Annotate all resource-allocating constructors with `@(require_results)`:
  - `buffer_make`, `array_copy`, `builder_finish`, `string_builder_finish`, `schema_make`, `record_batch_make`, `ipc_read_file`, `ipc_read_stream`.
- In `builder_make`, `_builder_grow_bitmap`, `_builder_grow_data`, `string_builder_make`, and `_sb_grow_data`, verify and handle allocator return status (`mem.Allocator_Error`), preventing unhandled OOM conditions.

### 3. Test Suite Hardening & Isolation
- In `tests/ipc_test.odin`, replace hardcoded `/tmp/test_ipc_*.arrow` paths with unique process/thread IDs or in-memory streams to prevent file collisions during concurrent test execution.
- In `tests/buffer_test.odin`, ensure `check_no_leaks` verifies both `track.allocation_map` and `track.bad_free_array`.
- Add `loc := #caller_location` to assertion helpers (such as `check_values` and `roundtrip`) so test failure messages point directly to the line of the test calling the helper rather than inside the helper body.

## Non-Functional Requirements
- **Diagnostic Clarity**: Immediate identification of failing test expressions and lines.
- **Maintainability**: Clean, idiomatic Odin code formatted via `odinfmt -w`.
- **Zero Warnings**: Strict zero-tolerance policy for compiler warnings.

## Acceptance Criteria
- [ ] `odin check skadi -vet-strict-style -disallow-do` produces zero warnings or errors.
- [ ] Unused constructor results trigger compiler error due to `@(require_results)`.
- [ ] Concurrent test executions do not interfere with temporary IPC files.
- [ ] Test helper assertion failures report caller line numbers.
- [ ] Full test suite passes: `odin test tests -collection:skadi=skadi -vet-strict-style -disallow-do`.
