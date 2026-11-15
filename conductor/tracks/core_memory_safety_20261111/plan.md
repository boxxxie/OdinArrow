# Implementation Plan: Core Memory Safety & Lifecycle Hardening

## Phase 1: Buffer & Buffer Pool Alignment Safety
Enforces strict 64-byte alignment in `Buffer_Pool` and handles buffer slice resizing safeguards.

- [x] Task: Buffer Pool and Buffer Slice Unit Tests (`50e9288`)
    - [x] Write failing test in `tests/core_fixes_test.odin` exercising `buffer_resize` on `buffer_slice` views (in `tests/core_regressions_test.odin`: `test_buffer_resize_rejects_slice_view_or_zero_allocator`)
    - [x] Write test verifying `Buffer_Pool` recycled block alignment with 64-byte alignment (in `tests/core_regressions_test.odin`: `test_buffer_pool_resize_and_alignment`)
    - [x] Verify tests fail as expected (Red Phase)
- [x] Task: Implement Buffer and Buffer Pool Fixes
    - [x] Update `skadi/buffer.odin`: reject slice views in `buffer_resize` with `mem.Allocator_Error.Mode_Not_Implemented` (`94b8978`)
    - [x] Update `skadi/buffer_pool.odin`: enforce `max(alignment, ARROW_ALIGNMENT)` and bucket by size and alignment (`free_list: map[_Pool_Key][dynamic]rawptr` keyed by `(size, align)` + aligned `_pool_get` + `buffer_make` passing `ARROW_ALIGNMENT`)
    - [x] Run `odin test tests -collection:skadi=skadi` and verify green status (171/171 `tests`, 21/21 `specs`)
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Buffer & Buffer Pool Alignment Safety' (Protocol in workflow.md)

---

## Phase 2: Builder Lifecycle & Aligned Bitmap Growth
Fixes builder reuse memory overflow and unaligned bitmap over-reads.

- [x] Task: Builder Reuse and Bitmap Allocation Tests (`50e9288`)
    - [x] Add failing test in `tests/core_fixes_test.odin` appending to builders immediately after `builder_finish` (in `tests/core_regressions_test.odin`: `test_builder_append_after_finish_without_reset`)
    - [x] Add test asserting bitmap buffer allocation size vs capacity rounded to 64 bytes (in `tests/core_regressions_test.odin`: `test_builder_null_finish_reset_null_bitmap_capacity`)
    - [x] Verify tests fail as expected (Red Phase)
- [x] Task: Implement Builder Lifecycle and Bitmap Growth Fixes (`94b8978`)
    - [x] Update `skadi/builders.odin`: reset `length`, `data_len`, `null_count` in `builder_finish` and `bool_builder_finish` (unified `builder_finish` handles `bool` and resets `length`/`null_count`)
    - [x] Update `skadi/var_length.odin`: reset state in `string_builder_finish`
    - [x] Align bitmap allocations to `ARROW_ALIGNMENT` (64 bytes) in `_builder_grow_bitmap` and `_sb_grow_bitmap`
    - [x] Run `odin test tests -collection:skadi=skadi` and verify green status
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Builder Lifecycle & Aligned Bitmap Growth' (Protocol in workflow.md)

---

## Phase 3: Division-by-Zero Guards & SIMD Unaligned Load Safety
Guards integer division on null slots and eliminates unaligned vector load faults.

- [x] Task: Integer Division on Nulls and Sliced SIMD Tests (`50e9288`)
    - [x] Add test for `compute_div` with null divisor slots on signed and unsigned integers (signed `i32` in `specs/workflows_spec_test.odin`; unsigned in `tests/core_regressions_test.odin`: `test_compute_div_unsigned_null_divisor`)
    - [x] Add test for SIMD operations (`min_max`, `sum`, `compare`, `cast`) on sliced arrays with odd offsets (`off = 1, 3, 5`) (`tests/compute_test.odin`, `specs/properties_compute_spec_test.odin`)
    - [x] Verify tests fail or crash (Red Phase)
- [x] Task: Implement Division Guards and Unaligned SIMD Loads (`2b5b284`)
    - [x] Update `skadi/compute.odin`: guard integer division in `_arith_impl` on validity bitmaps, zeroing null outputs (and `_validity_copy` trailing-bit masking fixed)
    - [x] Update `skadi/compute_simd.odin`: replace direct pointer casts with `intrinsics.unaligned_load` in `_min_max_i32_simd` and `_sum_f64_simd`
    - [x] Update `skadi/compare.odin` and `skadi/selection.odin`: ensure unaligned load safety for vector paths
    - [x] Update `skadi/compute_parallel.odin`: ensure `compute_filter_parallel` uses thread-safe memory allocations (`runtime.heap_allocator()`)
    - [x] Run `odin test tests -collection:skadi=skadi` and verify all tests pass
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Division-by-Zero Guards & SIMD Unaligned Load Safety' (Protocol in workflow.md)
