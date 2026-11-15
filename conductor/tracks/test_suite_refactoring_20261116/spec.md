# Specification: Test Suite Refactoring, Branch Test Backporting & Coverage Completion

## Overview
Following the comprehensive audit of `master` (`f5ee1b1`) and the downstream MR branch chain (`perf/core-simd-and-ipc`, `feat/sleipnir-pipeline`, `perf/parquet-csv-vectorization`, `feat/benchmarks-ci-docs`, `feat/atdd`) captured in [reference_conversation_audit.md](./reference_conversation_audit.md) ([Conversation a23115f9-4792-4da2-a30b-ee2c4f9f5eeb](conversation://a23115f9-4792-4da2-a30b-ee2c4f9f5eeb)), this track:
1. Backports **15 compatible tests** (11 as-is and 4 adapted/extracted) from the downstream MR branches onto `master` so core regressions and audit gaps are covered immediately on the base branch.
2. Refactors the `specs/` and `tests/` suites for modularity, fast temp-file hygiene, and strict assertion quality.
3. Completes missing test coverage across uncovered public `skadi/` procedures, RLE/Dictionary null & `NaN` edge cases, string/float/slice sorting, arithmetic & casting, multi-threaded `*_parallel` kernels, Arrow C++ FFI parity, and Parquet/CSV CLI & error paths.

## Functional Requirements

### 1. Backport Compatible Tests from Downstream MR Branches (15 Tests)
- **Move 11 tests as-is (with `-vet-style` compliance verified):**
  1. `test_buffer_make_uninit_alignment_and_lifecycle` (from `56fbd38` -> `tests/buffer_test.odin`)
  2. `test_dict_nan_dedup_and_null_decode` (from `56fbd38` -> `tests/dict_test.odin`)
  3. `test_rle_encode_decode_preserves_nulls` (from `56fbd38` -> `tests/rle_test.odin`)
  4. `test_compute_sort_indices_temp_allocator_no_leak` (from `56fbd38` -> `tests/compute_test.odin`)
  5. `test_compute_div_unsigned_null_divisor` (from `9ad608a` -> `tests/core_regressions_test.odin`)
  6. `test_compute_sum_simd_integers_and_null_mix` (from `9ad608a` -> `tests/core_regressions_test.odin`)
  7. `test_radix_sort_string_and_umbra_ties` (from `9ad608a` -> `tests/core_regressions_test.odin`)
  8. `test_compare_and_refine_f64_avx2` (from `9ad608a` -> `tests/core_regressions_test.odin`, renamed to `test_compare_and_refine_f64_and_i64`)
  9. `test_radix_sort_u32_edge_cases` + `_verify_radix_sort_stability` (from `9ad608a` -> `tests/core_regressions_test.odin`)
  10. `test_decode_rle_into_bit_widths_and_tails` (from `855cc76` -> `tests/parquet_internals_test.odin`)
  11. `test_csv_and_out_simd_16byte_boundaries` (from `855cc76` -> `tests/parquet_internals_test.odin`)
- **Move 4 tests with minor extraction/adaptation (stripping MR-only APIs and replacing C-style `? :` ternaries with Odin `if ... else`):**
  12. `test_umbra_long_tie_break_offsets_and_mixed_lengths` (from `9adeae8` -> `tests/umbra_test.odin`; omit `import pipeline "../skadi/pipeline"`).
  13. `test_compute_filter_parallel_varlen` (from `9ad608a` -> `tests/core_regressions_test.odin`; remove the two `oa.string_builder_reserve_data` calls and replace `(i & 1) == 0 ? "even_item" : "odd"` with `"even_item" if (i & 1) == 0 else "odd"`).
  14. `test_ipc_wide_multibatch_mixed_sliced_and_overwrite_truncation` + `_verify_mixed_batches` (from Parts 2 & 3 of `test_ipc_vectored_write_wide_multibatch_and_partial_iovec` in `9ad608a` -> `tests/core_regressions_test.odin`; omit Part 1's `_IPC_IOVec` / `_ipc_advance_iovecs` and convert C-style `? :` ternaries to Odin `if ... else`).
  15. `test_builder_lazy_bitmap_and_reset` (extracted from the `Primitive_Builder` half of `test_builder_lazy_bitmap_and_reserve_data` in `9ad608a` -> `tests/core_regressions_test.odin`; omit `string_builder_reserve_data` / `binary_builder_reserve_data`).

### 2. Test Suite Refactoring & Assertion Hardening
- **Modularize ATDD Layer 2 (`specs/dsl_test.odin`) and Layer 3 (`specs/driver_arrow_test.odin`):**
  - Split `specs/dsl_test.odin` (1,082 lines) by domain into `specs/dsl_core_test.odin`, `specs/dsl_ipc_test.odin`, and `specs/dsl_parquet_csv_test.odin`.
  - Split `specs/driver_arrow_test.odin` (1,135 lines) by domain into `specs/driver_core_test.odin`, `specs/driver_ipc_test.odin`, and `specs/driver_parquet_csv_test.odin`.
  - Preserve `loc := #caller_location` propagation on all Layer 2 DSL and Layer 3 driver assertions.
- **Tighten Weak Assertions & Temp-File Hygiene:**
  - In `tests/ipc_test.odin` (`test_ipc_fuzz_no_crash`): remove the trailing no-op `testing.expect(t, true)`, assert that the unmutated serialized payload reads back with `ok == true`, assert that all strict truncations (`cut < len(orig)`) return `ok == false`, and reuse a single temp file path across iterations instead of creating ~1,900+ temp files.
  - In `tests/compute_test.odin` (`test_compute_filter_large`): verify all surviving elements across the entire filtered result array rather than only indices `0` and `1`.
  - In `tests_cpp/arrow_cpp_test.odin` (`test_arrow_cpp_filter_count_matches` and `test_arrow_cpp_filter_large`): verify filtered element values and validity bits in addition to `our_result.length == cpp_count`.
  - Assert `err == .None` / `ok == true` on `builder_finish`, `string_builder_finish`, and `buffer_make` in all new and refactored tests.

### 3. Complete Remaining Missing Test Coverage
- **Uncovered Public `skadi/` Procedures (5 remaining after branch backports + full `compute_arithmetic` ops):**
  - `table_column_at`: test valid indices (`0 ..< num_columns`) and out-of-bounds indices (`-1`, `num_columns`) returning `nil, false`.
  - `binary_builder_reset`, `large_string_builder_reset`, `large_binary_builder_reset`: test build -> finish -> reset -> reuse with nulls and non-nulls under `mem.Tracking_Allocator`.
  - `type_is_variable_length`: test all 16 `DataType` variants (`true` for `String_Type`, `Binary_Type`, `Large_String_Type`, `Large_Binary_Type`; `false` for all 12 others).
  - `compute_arithmetic`: direct unit tests across all 4 `Arithmetic_Op` variants (`.Add`, `.Sub`, `.Mul`, `.Div`), complementing the `.Div` unsigned null-divisor backport.
- **RLE & Dictionary Encoding Edge Cases (`skadi/rle.odin`, `skadi/dict.odin`):**
  - Test `rle_encode`, `rle_decode`, `rle_sum`, `rle_min_max` on empty (`length == 0`), all-null, nullable numeric arrays (`rle_sum` / `rle_min_max` ignoring null runs), and `NaN` run coalescing.
  - Test `dict_encode`, `dict_decode`, `dict_sum`, `dict_min_max`, `dict_value_counts` on empty (`length == 0`), all-null, and nullable numeric `Dict_Array`.
- **Sorting, Arithmetic & Cast Edge Cases (`skadi/compute.odin`):**
  - Test `compute_sort_indices` on sliced (`offset > 0`) `String_Type` arrays with nulls, and `f32`/`f64` arrays with `-0.0`, `+0.0`, `NaN`, and nulls.
  - Test `compute_div` on `f32`/`f64` (including nulls and zero divisors) and non-null signed `min(T) / -1` overflow guard (`i8`, `i16`, `i32`, `i64`).
  - Test `compute_cast` for narrowing integer casts (`i64 -> i16`, `i32 -> i8`), float-to-int truncation (`f64 -> i64`, `f32 -> i32`), and signed/unsigned cross-casts (`u32 <-> i64`) on sliced (`offset > 0`) nullable arrays.
- **Parallel Compute Kernels (`skadi/compute_parallel.odin`):**
  - Test `compute_sum_parallel`, `compute_min_parallel`, `compute_max_parallel`, `compute_mean_parallel`, `compute_min_max_parallel` on `f64` and `i64` with non-zero slice `offset > 0` (`offset % 8 == 0` and `offset % 8 != 0`) and nulls above `PARALLEL_MIN_LENGTH`.
  - Test `compute_filter_parallel` on `f64`, `Binary_Type`, `Large_String_Type`, `Large_Binary_Type`, and sliced (`offset > 0`) arrays.
- **Arrow C++ Interop & Parquet/CSV CLI & Error Paths (`tests_cpp/`, `examples/`):**
  - In `tests_cpp/arrow_cpp_test.odin`: add `i64`, `u64`, `f32`, `bool`, `Binary_Type`, sliced (`offset > 0`) array parity, and Arrow IPC round-trip parity against Apache Arrow C++.
  - Add CLI argument/flag parsing (`-m` memory limit flag and invalid path/argument error exits) tests for `examples/parquet_to_csv` and `examples/csv_to_parquet`.
  - In `tests/parquet_internals_test.odin`: add direct unit tests for `p2c.parse_footer` rejecting bad `PAR1` magic / truncated footers and `col_stream_init` / `col_stream_load_page` rejecting unsupported compression codecs (`codec != 0`).

## Non-Functional Requirements
- **Strict Compiler Compliance:** All packages must pass `make check` (`-vet -strict-style -disallow-do -warnings-as-errors`) with 0 warnings/errors. Notably, no C-style `? :` ternaries may be introduced.
- **Memory Leak Freedom:** All new and backported tests must clean up allocations and pass `mem.Tracking_Allocator` checks.
- **Deterministic & Fast Execution:** No unseeded randomness or excessive filesystem churn.

## Acceptance Criteria
- [ ] All 15 compatible MR-chain tests are backported and passing on `tests/`.
- [ ] `specs/dsl_test.odin` and `specs/driver_arrow_test.odin` are split into focused domain files (`*_core_test.odin`, `*_ipc_test.odin`, `*_parquet_csv_test.odin`).
- [ ] All 7 previously unreferenced public `skadi/` procedures have direct test coverage.
- [ ] All identified weak assertions (`test_ipc_fuzz_no_crash`, `test_compute_filter_large`, `tests_cpp` filters) and missing edge-case branches (RLE/Dict nulls & NaNs, sliced string/float sorts, float/`min(T)/-1` div, narrowing/float casts, parallel varlen/sliced kernels, Parquet bad magic/codec) are covered.
- [ ] `make check`, `make test`, and `make test-cpp` pass with 0 warnings and 0 failures.

## Out of Scope
- Backporting the 38 MR-chain tests that depend on unmerged features (`Buffer_Pool` hit/miss telemetry & 256KB bucketing, `Hardware_Config`, `bitmap_copy_bits`, `dict_slice`/`dict_group_sum`, `string_builder_reserve_data`, `compute_take_parallel`, `morsel_*`, `Sleipnir` actor pipeline, `benchmarks/odin/stats`, or `PTYPE_INT64`/`DOUBLE`/`FLOAT`/`BOOLEAN` Parquet CLI decoding).
