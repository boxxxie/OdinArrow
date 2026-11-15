# Specification: Compute Precision, Type Safety & Encoding Integrity

## Overview
Hardens Skadi compute kernels, fused operators, dictionary/RLE encoders, and table constructors against heap over-reads from unchecked cross-column types, 64-bit integer comparison precision corruption above $2^{53}$, silent null-handling bugs, and unbounded temporary allocator memory growth in sort routines.

## Functional Requirements

### 1. Cross-Column Type Safety & Schema Validation
- `compute_arithmetic` (`skadi/compute.odin`): Enforce `left.type == right.type`. Return error/nil rather than casting differing bit-width buffers and reading out of bounds.
- `compute_agg_where_compare` (`skadi/fusion.odin`): Verify `values.type == pred.type` before predicate evaluation.
- `record_batch_make` (`skadi/record_batch.odin`): Assert or return error if `columns[i].type != schema.fields[i].type`.
- `table_from_record_batches` (`skadi/table.odin`): Verify that corresponding field types and names match across all record batches before constructing a Table.

### 2. Exact 64-Bit Integer Comparisons (`skadi/compare.odin`, `skadi/fusion.odin`)
- Eliminate per-element `f64(data[i])` casts in comparisons and selection vectors that silently lose precision for integers greater than $2^{53}$.
- Add exact 64-bit integer comparison procedures:
  - `compute_compare_i64` and `compute_compare_u64`
  - `compute_select_compare_i64`
  - `selection_refine_compare_i64`
  - `compute_agg_where_compare_i64`
- Perform inner comparison loops natively in the integer type `T`, or use exact IEEE-754 floor/ceil boundary reduction outside the loop.

### 3. Null-Aware Encodings and Operations (`skadi/compute.odin`, `skadi/dict.odin`, `skadi/rle.odin`)
- `compute_take`: Check `indices.buffers[0]`. When an index is null, emit a null value in the output array rather than treating it as valid index 0. Enforce array bounds assertions on primitive indices.
- `str_dict_group_sum`: Validate `weights.type` (confirming `Float64_Type`) and check validity bitmap before summing.
- `str_dict_encode`, `dict_encode`, `rle_encode`: Propagate source validity bitmaps so null slots remain null in encoded arrays.
- `dict_encode` on floating point types: Normalize and deduplicate `NaN` representations in dictionary hash maps.

### 4. Bounded Temporary Allocator Scoping in Sorts (`skadi/compute.odin`, `skadi/umbra.odin`)
- In `_radix_sort_indices`, `_sort_indices_typed`, `_sort_indices_string`, and `umbra_sort_indices`, wrap temporary buffer allocations with:
  ```odin
  runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
  ```
- Ensure repeated sorting over large arrays does not leak memory or cause unbounded growth on `context.temp_allocator`.

## Non-Functional Requirements
- **Precision**: Exact results for all 64-bit signed and unsigned values across the full integer range.
- **Robustness**: Incompatible types in arithmetic or table operations must fail gracefully with descriptive error status.
- **Memory Boundaries**: Zero uncollected scratch memory on `context.temp_allocator` after sort invocations.

## Acceptance Criteria
- [ ] Comparing an `i64` array containing `9007199254740993` against a scalar correctly distinguishes equality without rounding down to `9007199254740992`.
- [ ] `compute_arithmetic` between mismatched types (e.g. `Int32` and `Float64`) is cleanly rejected.
- [ ] `table_from_record_batches` rejects batches with mismatched column types.
- [ ] `compute_take` with null indices outputs null elements instead of reading index 0.
- [ ] `dict_encode` and `rle_encode` correctly preserve validity bitmaps and deduplicate NaNs.
- [ ] Sorting an array 25 times under a tracking temp allocator records 0 net persistent allocations.
- [ ] All tests pass under `odin test tests -collection:skadi=skadi`.
