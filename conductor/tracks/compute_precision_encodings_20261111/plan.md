# Implementation Plan: Compute Precision, Type Safety & Encoding Integrity

## Phase 1: Cross-Column & Table Schema Type Safety Guards
Guards arithmetic, aggregations, record batches, and table builders against mismatched types.

- [x] Task: Cross-Column Type Safety Tests (`50e9288`)
    - [x] Add failing test attempting `compute_arithmetic` with differing types (e.g. `i32` + `f64`), asserting rejection (`tests/compute_test.odin`: `test_compute_arithmetic_type_mismatch_error`)
    - [x] Add failing test creating a `Table` from record batches with mismatched schemas (`tests/core_regressions_test.odin`: `test_table_from_record_batches_rejects_mismatched_schema`, `test_record_batch_make_rejects_type_mismatch`)
    - [x] Verify tests fail as expected (Red Phase)
- [x] Task: Implement Type Safety Checks
    - [x] Update `skadi/compute.odin`: verify `left.type == right.type` in `compute_arithmetic`
    - [x] Update `skadi/fusion.odin`: verify `values.type == pred.type` in `compute_agg_where_compare`
    - [x] Update `skadi/record_batch.odin`: verify `columns[i].type == schema.fields[i].type`
    - [x] Update `skadi/table.odin`: verify column types match across batches in `table_from_record_batches`
    - [x] Run `odin test tests -collection:skadi=skadi` and verify green status (171/171 `tests`, 21/21 `specs`)
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Cross-Column & Table Schema Type Safety Guards' (Protocol in workflow.md)

---

## Phase 2: Exact 64-Bit Integer Comparisons & Fused Operators
Eliminates $2^{53}$ precision loss by implementing exact 64-bit integer comparisons.

- [x] Task: 64-Bit Comparison Precision Tests (`50e9288`)
    - [x] Add test comparing `i64` and `u64` values around $2^{53} + 1$ against scalars, asserting exact ordering and equality (`specs/properties_compute_spec_test.odin`)
    - [x] Add test for `selection_refine_compare` and `compute_agg_where_compare` on large integers (`specs/properties_compute_spec_test.odin`, `tests/compute_test.odin`: `test_agg_where_compare_i64_on_float_columns`)
    - [x] Verify tests fail due to `f64` rounding (Red Phase)
- [x] Task: Implement Exact 64-Bit Comparisons (`2b5b284`)
    - [x] Update `skadi/compare.odin`: implement `compute_compare_i64`, `compute_compare_u64`, `compute_select_compare_i64`, and `selection_refine_compare_i64`
    - [x] Update `skadi/fusion.odin`: implement `compute_agg_where_compare_i64` (including `Float32_Type`/`Float64_Type` via `_cmp_f64_vs_i64`)
    - [x] Replace per-element `f64(data[i])` casts with native `T` comparison loops
    - [x] Run `odin test tests -collection:skadi=skadi` and verify precision tests pass
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Exact 64-Bit Integer Comparisons & Fused Operators' (Protocol in workflow.md)

---

## Phase 3: Null-Aware `compute_take`, Dictionary, and RLE Encodings
Fixes silent null-handling bugs across index taking and compression encodings.

- [x] Task: Null Handling Tests for Take, Dict, and RLE
    - [x] Add test for `compute_take` where indices array contains null slots, expecting null outputs (`specs/properties_compute_spec_test.odin`)
    - [x] Add test for `dict_encode` and `rle_encode` on arrays with null values, verifying validity bitmap preservation (`tests/dict_test.odin`, `tests/rle_test.odin`: `test_rle_encode_decode_preserves_nulls`)
    - [x] Add test for `dict_encode` on floats containing multiple `NaN` values, verifying single dictionary entry (`tests/dict_test.odin`: `test_dict_nan_dedup_and_null_decode`)
    - [x] Verify tests pass cleanly (Green Phase)
- [x] Task: Implement Null Handling Fixes (`2b5b284`)
    - [x] Update `skadi/compute.odin`: inspect `indices.buffers[0]` in `compute_take` and emit nulls accordingly
    - [x] Update `skadi/dict.odin`: propagate validity bitmaps and canonicalize `NaN` keys in `dict_encode`
    - [x] Update `skadi/rle.odin`: preserve validity bitmaps in `rle_encode`
    - [x] Run `odin test tests -collection:skadi=skadi` and verify all tests pass
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Null-Aware compute_take, Dictionary, and RLE Encodings' (Protocol in workflow.md)

---

## Phase 4: Temp-Allocator Scoping in Sort Kernels
Enforces bounded scratch memory on `context.temp_allocator` during sorting.

- [x] Task: Sort Scratch Memory Leak Tests
    - [x] Add test running `compute_sort_indices` 25 times under a `mem.Tracking_Allocator` on `context.temp_allocator` (`tests/compute_test.odin`: `test_compute_sort_indices_temp_allocator_no_leak`)
    - [x] Verify outstanding allocation count is 0 with guards
- [x] Task: Implement Temp-Allocator Guards (`2b5b284`)
    - [x] Update `skadi/compute.odin` (`_radix_sort_indices`, `_sort_indices_typed`, `_sort_indices_string`): add `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD`
    - [x] Update `skadi/umbra.odin` (`umbra_sort_indices`): add temp allocator guard
    - [x] Verify tracking allocator reports 0 persistent allocations after sort execution
- [ ] Task: Conductor - User Manual Verification 'Phase 4: Temp-Allocator Scoping in Sort Kernels' (Protocol in workflow.md)
