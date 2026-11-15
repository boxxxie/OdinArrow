# Implementation Plan: Test Suite Refactoring, Branch Test Backporting & Coverage Completion

> Reference: [Conversation Audit & MR Branch Discovery](./reference_conversation_audit.md)

## Phase 1: Backport 15 Compatible Tests from Downstream MR Branches
Backports the 11 as-is tests and 4 adapted/extracted tests from `56fbd38`, `9adeae8`, `855cc76`, and `9ad608a` onto a track branch from `master`, ensuring strict `-vet-style -disallow-do` compliance.

- [ ] Task: Backport `56fbd38` & `9adeae8` Core Buffer, Encoding, Sort & Umbra Tests
    - [ ] Port `test_buffer_make_uninit_alignment_and_lifecycle` from `56fbd38` into `tests/buffer_test.odin`
    - [ ] Port `test_dict_nan_dedup_and_null_decode` from `56fbd38` into `tests/dict_test.odin`
    - [ ] Port `test_rle_encode_decode_preserves_nulls` from `56fbd38` into `tests/rle_test.odin`
    - [ ] Port `test_compute_sort_indices_temp_allocator_no_leak` from `56fbd38` into `tests/compute_test.odin`
    - [ ] Port `test_umbra_long_tie_break_offsets_and_mixed_lengths` from `9adeae8` into `tests/umbra_test.odin` (without `import pipeline` and using `if ... else` instead of `? :`)
- [ ] Task: Backport `9ad608a` Core Regressions & `855cc76` Parquet/CSV Internals Tests
    - [ ] Port `test_compute_div_unsigned_null_divisor`, `test_compute_sum_simd_integers_and_null_mix`, `test_radix_sort_string_and_umbra_ties`, `test_compare_and_refine_f64_and_i64`, and `test_radix_sort_u32_edge_cases` (`+ _verify_radix_sort_stability`) from `9ad608a` into `tests/core_regressions_test.odin`
    - [ ] Port adapted `test_builder_lazy_bitmap_and_reset` (`Primitive_Builder` section), `test_compute_filter_parallel_varlen` (without `string_builder_reserve_data`), and `test_ipc_wide_multibatch_mixed_sliced_and_overwrite_truncation` (Parts 2 & 3 of `test_ipc_vectored_write_wide_multibatch_and_partial_iovec`) from `9ad608a` into `tests/core_regressions_test.odin`, replacing all C-style `? :` ternaries with Odin `if ... else`
    - [ ] Port `test_decode_rle_into_bit_widths_and_tails` and `test_csv_and_out_simd_16byte_boundaries` from `855cc76` into `tests/parquet_internals_test.odin`
    - [ ] Run `make check && make test` and confirm all backported tests compile with 0 warnings and pass
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Backport 15 Compatible Tests from Downstream MR Branches' (Protocol in workflow.md)

---

## Phase 2: Refactor ATDD Spec Layers & Harden Existing Assertions
Splits oversized ATDD Layer 2/3 files by domain and fixes weak assertions and temp-file churn.

- [ ] Task: Split Monolithic ATDD Layer 2 (`dsl_test.odin`) and Layer 3 (`driver_arrow_test.odin`) Files by Domain
    - [ ] Split `specs/dsl_test.odin` into `specs/dsl_core_test.odin`, `specs/dsl_ipc_test.odin`, and `specs/dsl_parquet_csv_test.odin`
    - [ ] Split `specs/driver_arrow_test.odin` into `specs/driver_core_test.odin`, `specs/driver_ipc_test.odin`, and `specs/driver_parquet_csv_test.odin`
    - [ ] Verify `odin check specs` and `odin test specs` pass with 0 warnings
- [ ] Task: Harden Weak Assertions & Reduce Temp-File Churn in `tests/` and `tests_cpp/`
    - [ ] Refactor `test_ipc_fuzz_no_crash` in `tests/ipc_test.odin` to reuse a single temp file path, assert `ok == true` on unmutated `orig`, assert `ok == false` on strict truncations (`cut < len(orig)`), and remove `testing.expect(t, true)`
    - [ ] Strengthen `test_compute_filter_large` in `tests/compute_test.odin` to verify all surviving elements across the entire result array
    - [ ] Strengthen `test_arrow_cpp_filter_count_matches` and `test_arrow_cpp_filter_large` in `tests_cpp/arrow_cpp_test.odin` to verify surviving element values and validity bits
    - [ ] Audit touched/refactored tests in `tests/` to assert `err == .None` / `ok == true` on `builder_finish`, `string_builder_finish`, and `buffer_make` instead of discarding with `_`
    - [ ] Run `make check && make test && make test-cpp` and confirm 0 warnings/failures
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Refactor ATDD Spec Layers & Harden Existing Assertions' (Protocol in workflow.md)

---

## Phase 3: Complete Uncovered Public APIs, Encodings, Compute & Parallel Kernels
Adds unit and property/spec coverage for all remaining `skadi/` gaps identified in the audit.

- [ ] Task: Cover Remaining Unreferenced Public `skadi/` Procedures
    - [ ] Add unit tests for `table_column_at` (in-bounds and out-of-bounds indices) in `tests/batch_test.odin`
    - [ ] Add unit tests for `binary_builder_reset`, `large_string_builder_reset`, and `large_binary_builder_reset` (with nulls, non-nulls, and leak tracking) in `tests/strings_test.odin`
    - [ ] Add exhaustive unit test for `type_is_variable_length` across all 16 `DataType` variants in `tests/types_test.odin`
    - [ ] Add direct unit tests for `compute_arithmetic` across `.Add`, `.Sub`, `.Mul`, and `.Div` in `tests/compute_test.odin`
- [ ] Task: Cover RLE & Numeric Dictionary Null, Empty, All-Null, and NaN Edge Cases
    - [ ] Add tests in `tests/rle_test.odin` for `rle_encode`, `rle_decode`, `rle_sum`, and `rle_min_max` on empty (`0`), all-null, nullable numeric arrays, and `NaN` run coalescing
    - [ ] Add tests in `tests/dict_test.odin` for `dict_encode`, `dict_decode`, `dict_sum`, `dict_min_max`, and `dict_value_counts` on empty (`0`), all-null, and nullable numeric `Dict_Array`
- [ ] Task: Cover Sorting, Arithmetic, Cast & Parallel Compute Edge Cases
    - [ ] Add tests in `tests/compute_test.odin` for `compute_sort_indices` on sliced (`offset > 0`) nullable `String_Type` arrays and `f32`/`f64` arrays with `-0.0`, `+0.0`, `NaN`, and nulls
    - [ ] Add tests in `tests/compute_test.odin` for `compute_div` on `f32`/`f64` (including nulls and zero divisors) and non-null signed `min(T) / -1` (`i8`, `i16`, `i32`, `i64`), plus `compute_cast` narrowing, float-to-int, and signed/unsigned cross-casts on sliced nullable arrays
    - [ ] Add tests in `tests/parallel_test.odin` for `compute_sum_parallel`, `compute_min_parallel`, `compute_max_parallel`, `compute_mean_parallel`, and `compute_min_max_parallel` on `f64`/`i64` with `offset > 0` and nulls, and `compute_filter_parallel` on `f64`, `Binary_Type`, `Large_String_Type`, `Large_Binary_Type`, and sliced inputs
    - [ ] Run `make check && make test` and confirm 0 warnings/failures
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Complete Uncovered Public APIs, Encodings, Compute & Parallel Kernels' (Protocol in workflow.md)

---

## Phase 4: Complete Arrow C++ FFI Parity & Parquet/CSV Error-Path Tests
Expands cross-language interop and negative Parquet reader coverage.

- [ ] Task: Expand `tests_cpp/arrow_cpp_test.odin` Type & Slice Coverage
    - [ ] Add Arrow C++ parity tests for `i64`, `u64`, `f32`, `bool`, `Binary_Type`, sliced (`offset > 0`) arrays, and Arrow IPC round-trip parity in `tests_cpp/arrow_cpp_test.odin`
    - [ ] Run `make test-cpp` and verify all interop tests pass
- [ ] Task: Add Parquet/CSV CLI Argument, Footer & Compression Codec Rejection Tests
    - [ ] Add tests covering `-m` memory-limit flag parsing and invalid path/argument CLI error handling for `examples/parquet_to_csv` and `examples/csv_to_parquet`
    - [ ] Add unit tests in `tests/parquet_internals_test.odin` for `p2c.parse_footer` rejecting invalid `PAR1` magic bytes and truncated footers
    - [ ] Add unit tests in `tests/parquet_internals_test.odin` for `p2c.col_stream_init` / `p2c.col_stream_load_page` rejecting unsupported non-uncompressed codecs (`codec != 0`)
    - [ ] Run `make check && make test && make test-cpp` and confirm 100% pass with 0 warnings
- [ ] Task: Conductor - User Manual Verification 'Phase 4: Complete Arrow C++ FFI Parity & Parquet/CSV Error-Path Tests' (Protocol in workflow.md)
