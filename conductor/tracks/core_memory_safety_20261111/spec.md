# Specification: Core Memory Safety & Lifecycle Hardening

## Overview
Remediates critical memory safety vulnerabilities, SIGFPE crash bugs, unaligned SIMD memory faults, builder reuse buffer overflows, and allocator corruption discovered in the Skadi core library during comprehensive code review.

## Functional Requirements

### 1. Integer Division-by-Zero and Overflow Protection (`skadi/compute.odin`)
- Prevent process crash (`SIGFPE`) in `compute_div` / `_arith_impl` when dividing integer arrays (`i8`..`i64`, `u8`..`u64`) where divisor slots contain null values (or zeros).
- Guard evaluation on validity bitmaps: when `left` or `right` is null or `right[i] == 0`, write 0 to destination without performing hardware division.
- Guard against signed minimum overflow trap (`min(T) / -1`) on invalid/null elements.

### 2. Builder Reuse and Aligned Bitmap Allocation (`skadi/builders.odin`, `skadi/var_length.odin`)
- Reset builder state in `builder_finish`, `bool_builder_finish`, and `string_builder_finish`: reset `b.length = 0`, `b.data_len = 0`, and `b.null_count = 0` so appending after `finish()` does not overflow heap buffers.
- Align bitmap buffer allocations in `_builder_grow_bitmap` and `_sb_grow_bitmap` to `ARROW_ALIGNMENT` (64 bytes).
- Prevent 56-byte out-of-bounds heap reads in `_validity_copy` and `ipc_write_file` caused by stamping 64-byte rounded sizes on unaligned 8-byte allocations.

### 3. Safe SIMD Loads on Sliced and IPC Arrays (`skadi/compute_simd.odin`, `skadi/compare.odin`, `skadi/selection.odin`, `skadi/compute.odin`)
- Replace direct pointer casts to `[^]#simd[K]T` with `intrinsics.unaligned_load(&vp[i])` (or loop peeling) across `_min_max_i32_simd`, `_sum_f64_simd`, `_compare_mono`, `_cast_impl`, and `_arith_impl`.
- Prevent `SIGSEGV` on sliced arrays (where `offset` is unaligned) and zero-copy IPC buffers (which are 8-byte aligned, not 64-byte aligned).
- Ensure `intrinsics.non_temporal_store` is only invoked when destination memory is properly aligned to `align_of(V)`.

### 4. Buffer Pool Alignment & Concurrency Protection (`skadi/buffer_pool.odin`, `skadi/compute_parallel.odin`)
- Enforce effective alignment `eff_align := max(alignment, ARROW_ALIGNMENT)` (64 bytes) for all blocks in `Buffer_Pool`, preserving `_Pool_Header` alignment and 64-byte Arrow guarantees.
- Reject concurrent usage of single-threaded `Buffer_Pool` instances across worker threads in `compute_filter_parallel`.

### 5. Buffer Resizing Invariants (`skadi/buffer.odin`)
- Reject resizing non-owning slice views (`allocator.procedure == nil`) by returning `mem.Allocator_Error.Mode_Not_Implemented` rather than corrupting parent memory or dereferencing nil.
- Safely initialize empty `Buffer{}` allocations when resized.

## Non-Functional Requirements
- **Performance**: Zero regression on SIMD kernel throughput for aligned contiguous arrays.
- **Memory Safety**: 100% leak-free execution and zero bad frees verified via `mem.Tracking_Allocator`.
- **Compiler Compatibility**: Zero warnings under `odin check . -vet-strict-style -disallow-do`.

## Acceptance Criteria
- [ ] `compute_div` on integer arrays containing nulls in the divisor completes without SIGFPE and sets output null bits properly.
- [ ] Appending to a builder immediately after `builder_finish` without `builder_reset` succeeds without heap corruption.
- [ ] Validity bitmaps created with nulls have sizes matching allocated capacity and read cleanly in `_validity_copy` and IPC serialization.
- [ ] SIMD kernels (`min_max`, `sum`, `compare`, `cast`, `arithmetic`) run against sliced arrays with odd offsets without faulting.
- [ ] `buffer_resize` returns `mem.Allocator_Error.Mode_Not_Implemented` when called on `buffer_slice`.
- [ ] All tests pass under `odin test tests -collection:skadi=skadi`.
