# Implementation Plan: Arrow IPC Sliced Serialization & Refcounted Lifetime

## Phase 1: Refcounted Shared Backing for Multi-Batch IPC
Ensures zero-copy memory-mapped file buffers remain valid until all record batches are freed.

- [x] Task: Multi-Batch Free Order Unit Test (`c156456`, `50e9288`)
    - [x] Add failing test in `tests/core_fixes_test.odin` loading a multi-batch IPC file, freeing `batches[0]`, and reading values from `batches[1]` (in `specs/workflows_spec_test.odin`: `spec_ipc_multi_batch_independent_lifetimes`)
    - [x] Verify test fails / segfaults with current single-batch ownership (Red Phase)
- [x] Task: Implement Shared Refcounted Backing (`44c5bff`)
    - [x] Update `skadi/record_batch.odin`: define `Shared_Backing` struct with atomic refcount and unmap/free procedure (`_IPC_Backing`)
    - [x] Update `skadi/ipc.odin`: attach `Shared_Backing` to each decoded `Record_Batch` in `ipc_read_file` and `ipc_read_stream`
    - [x] Update `record_batch_free` to decrement refcount and release backing upon reaching 0
    - [x] Remove redundant `cols_copy` allocation in `_ipc_decode_record_batch`
    - [x] Run `odin test tests -collection:skadi=skadi` and verify green status (152/152 `tests`, 21/21 `specs`)
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Refcounted Shared Backing for Multi-Batch IPC' (Protocol in workflow.md)

---

## Phase 2: Sliced Array IPC Serialization
Fixes broken IPC encoding for sliced arrays across validity, data, and offset buffers.

- [x] Task: Sliced Array IPC Serialization Tests (`c156456`, `50e9288`)
    - [x] Add failing test serializing sliced primitive array (`offset > 0`) to IPC and verifying decoded values (in `specs/ipc_matrix_spec_test.odin`: `spec_ipc_sliced_batch_serializes_slice_window`)
    - [x] Add failing test serializing sliced string array (`offset > 0`) to IPC and verifying decoded strings (in `specs/ipc_matrix_spec_test.odin`: `spec_ipc_sliced_batch_serializes_slice_window`)
    - [x] Add test with sliced validity bitmaps verifying bit alignment and null counts (in `specs/ipc_matrix_spec_test.odin`: `spec_ipc_sliced_batch_serializes_slice_window`)
    - [x] Verify tests fail as expected (Red Phase)
- [x] Task: Implement Sliced Serialization Logic (`44c5bff`)
    - [x] Update `skadi/ipc.odin` in `_ipc_encode_record_batch`:
        - Bit-shift validity bitmaps and boolean bitmaps starting from `col.offset` (`_ipc_pack_bits`)
        - Slice primitive data buffers by `col.offset * width`
        - Re-base string/binary offset buffers to 0 and slice value bytes accordingly
    - [x] Verify serialized buffers conform strictly to the Arrow IPC Feather v2 specification
    - [x] Run `odin test tests -collection:skadi=skadi` and verify all tests pass
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Sliced Array IPC Serialization' (Protocol in workflow.md)

---

## Phase 3: Tail Magic & Duplicate Schema Validation
Enforces IPC tail magic checking and fixes stream reader schema replacement memory leaks.

- [x] Task: Tail Magic and Stream Schema Replacement Tests (`c156456`, `50e9288`, plus pre-schema batch guard)
    - [x] Add test attempting to read IPC file missing `IPC_MAGIC_TAIL`, expecting failure (`tests/ipc_test.odin`: `test_ipc_rejects_corrupt_tail_magic`)
    - [x] Add test streaming multiple `_IPC_HEADER_SCHEMA` messages under tracking allocator to detect leaks (`tests/ipc_test.odin`: `test_ipc_stream_duplicate_schema_no_leak` + `test_ipc_stream_record_batch_before_schema_no_leak`)
    - [x] Verify tests fail as expected (Red Phase)
- [x] Task: Implement Tail Magic and Stream Schema Cleanups (`44c5bff`)
    - [x] Update `ipc_read_file` to verify 6-byte `IPC_MAGIC_TAIL` at end of file
    - [x] Update `ipc_read_stream` to deallocate previous schema before replacing with a new schema (and skip/reject `RecordBatch` frames before `schema_ok`)
    - [x] Run `odin test tests -collection:skadi=skadi` and verify clean, leak-free execution
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Tail Magic & Duplicate Schema Validation' (Protocol in workflow.md)
