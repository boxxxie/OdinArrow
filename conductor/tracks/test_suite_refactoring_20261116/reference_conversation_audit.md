# Reference: Test Suite Audit & Downstream MR-Chain Test Discovery

- **Source Conversation:** [Test Suite Audit & MR-Chain Test Discovery](conversation://a23115f9-4792-4da2-a30b-ee2c4f9f5eeb)
- **Baseline Branch State:** `master` at `f5ee1b1` (after fast-forwarding `fix/core-and-cli-hardening` `44a1cc7` and `test/atdd-specs` `f5ee1b1`)
- **Date:** 2026-11-16

---

## Part 1: Baseline `master` (`f5ee1b1`) Test Suite Audit

### Verified Baseline Metrics
| Suite / Check | Command | Observed Result (`f5ee1b1`) | Scope |
|---|---|---|---|
| Static analysis (`-vet -strict-style -disallow-do -warnings-as-errors`) | `make check` | Passed (11 targets, 0 warnings/errors) | `skadi`, `tests`, `specs`, `tests_cpp`, `examples/*`, `benchmarks/*` |
| Unit & regression suite | `odin test tests` | Passed (157 tests, 111.6 ms) | Core containers, SIMD/parallel compute, IPC fuzz/bounds, Parquet/CSV internals |
| 4-layer ATDD & property specs | `odin test specs` | Passed (22 tests, 16.1 ms) | Workflows, 16-type IPC matrix, seeded oracle properties |
| Arrow C++ FFI parity | `make test-cpp` | Passed (10 tests, 11.1 ms) | Linux-only in `.github/workflows/ci.yml#L52-L65` (excluded from `make test`) |

### Verified Strengths & Parity
- **4-layer ATDD separation (`specs/`):** Layer 1 (`specs/workflows_spec_test.odin`) stays free of allocator/wire plumbing; `Spec_World` isolates per-test state via atomic temp-file counters (`g_temp_seq`); Layer 2 (`specs/dsl_test.odin`) and Layer 3 (`specs/driver_arrow_test.odin`) forward `loc = loc` consistently on assertions.
- **1:1 migration parity:** Legacy tests removed in `25c2ead` (`tests/compare_test.odin`, `tests/fusion_test.odin`, `tests/selection_test.odin`, and two `dict_test.odin` tests) are covered—with stricter null and slice variants—in `specs/workflows_spec_test.odin` and `specs/properties_compute_spec_test.odin`.
- **Deterministic property specs:** `specs/properties_spec_test.odin` and `specs/properties_compute_spec_test.odin` use stack-local `Spec_Rng` seeds, free temp allocations per iteration, and validate sliced/nullable behavior against scalar oracles.
- **Memory-safety & bounds tests:** `tests/core_regressions_test.odin`, `tests/ipc_test.odin`, and `tests/parquet_internals_test.odin` pair adversarial/malformed inputs with `mem.Tracking_Allocator` leak checks.

### Audit Findings & Gaps on `master`

#### 1. Weak or Incomplete Assertions & File Churn
- **No-op assertion & temp-file churn in IPC fuzzer (`tests/ipc_test.odin#L87-L130`, `test_ipc_fuzz_no_crash`):**
  - Ends with `testing.expect(t, true)`. Verifies no crashes/leaks across 1,500 mutations and all truncations, but never asserts that unmutated `orig` reads back with `ok == true` or that strict truncations (`cut < len(orig)`) return `ok == false`.
  - Writes ~1,900+ temp files to disk per run (`1500` mutations + `len(orig) + 1` truncations).
- **Length-only Arrow C++ FFI filter checks (`tests_cpp/arrow_cpp_test.odin#L161-L213`):**
  - `test_arrow_cpp_filter_count_matches` and `test_arrow_cpp_filter_large` only verify `i64(our_result.length) == cpp_count`; filtered element values and validity bits are unchecked.
- **Spot-checked large filter (`tests/compute_test.odin#L311-L330`, `test_compute_filter_large`):**
  - Checks `result.length` and indices `0` and `1` only; mid-array and tail values are unchecked.
- **Discarded setup errors in `tests/`:**
  - Numerous unit tests ignore `err` on `builder_finish` / `buffer_make` (`arr, _ := oa.builder_finish(&b)`), unlike `specs/` which asserts `err == nil`.

#### 2. Unreferenced Public `skadi/` Procedures (7 of 155)
1. `table_column_at` (`skadi/table.odin#L100`) — only name-based `table_column` is tested.
2. `binary_builder_reset` (`skadi/var_length.odin#L196`)
3. `large_string_builder_reset` (`skadi/var_length.odin#L277`)
4. `large_binary_builder_reset` (`skadi/var_length.odin#L338`)
5. `buffer_make_uninit` (`skadi/buffer.odin#L37`)
6. `type_is_variable_length` (`skadi/types.odin#L62`)
7. `compute_arithmetic` (`skadi/compute.odin#L883`) — exercised only via `compute_add`/`sub`/`mul`/`div` wrappers.

#### 3. Missing Edge-Case & Branch Coverage
- **RLE & Numeric Dict nulls / NaNs / empty (`skadi/rle.odin`, `skadi/dict.odin`):**
  - `rle_encode`, `rle_decode`, `rle_sum`, `rle_min_max`: untested on null runs (`a.null_count > 0` in `rle_decode`), all-null/empty arrays, and `NaN` run coalescing (`rle_append` / `rle_min_max`).
  - `dict_encode`, `dict_decode`, `dict_sum`, `dict_min_max`, `dict_value_counts`: untested on numeric `Dict_Array` with nulls, all-nulls, empty arrays, or `NaN` (`has_nan` deduplication in `dict_encode` and `d.null_count > 0` in `dict_decode`).
- **Sorting edge cases (`skadi/compute.odin#L1037-L1226`):**
  - `compute_sort_indices` on `String_Type` only tests 4 non-null unsliced strings (`tests/compute_test.odin#L550-L568`); nulls and sliced (`offset > 0`) string arrays in `_sort_indices_string` lack tests.
  - Integer widths beyond `i32`/`u64` (`i8`, `i16`, `i64`, `u8`, `u16`, `u32`), float `f32`, and `NaN`/`-0.0` float ordering lack tests.
- **Arithmetic & Cast gaps (`skadi/compute.odin#L765-L1030`):**
  - `compute_div` lacks `f32`/`f64` tests and non-null signed `min(T) / -1` overflow protection checks (`spec_integer_division_propagates_null_divisor` places `min(i32) / -1` in a null slot).
  - `compute_cast` mostly tests `i32 -> f64`; narrowing integer casts, float-to-int truncation, and signed/unsigned cross-casts need coverage.
- **Parallel kernels (`skadi/compute_parallel.odin`):**
  - `compute_sum_parallel`, `compute_min_parallel`, `compute_max_parallel`, `compute_mean_parallel`, `compute_min_max_parallel` only test `i32`; `compute_filter_parallel` only tests `i32` and `bool` (not `f64`, `String_Type`, `Binary_Type`, `Large_String_Type`, `Large_Binary_Type`, or sliced `offset > 0` inputs).
- **Arrow C++ / PyArrow Interop (`tests_cpp/arrow_cpp_test.odin`, `.github/workflows/ci.yml#L52-L65`):**
  - Only covers `i32`/`f64` sum, `i32` min/max, `i32` filter count, and `string` length sum at `offset == 0`. Missing: `i64`, `u64`, `f32`, `bool`, `binary`, sliced (`offset > 0`) arrays, and Arrow IPC interop in `tests_cpp`.
- **Parquet / CSV CLI & Error Paths (`examples/parquet_to_csv/parquet_reader.odin`, `examples/csv_to_parquet/main.odin`):**
  - `main()` CLI argument/flag parsing (`-m`) and exit codes have no automated tests.
  - `parquet_reader` rejection of bad `PAR1` magic / truncated footers (`parse_footer`) and unsupported compression codecs (e.g., Snappy/GZIP, `codec != 0`) is not unit-tested.

#### 4. Maintainability Notes
- `specs/driver_arrow_test.odin` (1,135 lines) and `specs/dsl_test.odin` (1,082 lines) bundle core array/compute, IPC, and Parquet fixture builders into two large files; splitting by domain keeps Layer 2/3 navigable.

---

## Part 2: Downstream MR-Chain Test Discovery (53 Tests Across 6 Commits)

Commits inspected above `master` (`f5ee1b1`):
1. `56fbd38` (`perf/core-simd-and-ipc`): `perf(core): optimize SIMD kernels, encodings, radix sort, and vectored IPC`
2. `9adeae8` (`feat/sleipnir-pipeline`): `feat(pipeline): add Sleipnir actor and sharded SPSC morsel pipeline`
3. `04c983d` (`perf/parquet-csv-vectorization` ancestor): `perf(programs): vectorize Parquet and CSV streaming CLI readers and writers`
4. `855cc76` (`perf/parquet-csv-vectorization`): `test(parquet): fix strict-style ternaries and cover SIMD, float, dict, and RLE paths`
5. `ca4dfd6` (`feat/benchmarks-ci-docs` ancestor): `feat(benchmarks): add statistical JSONL harness and 1v1 Arrow C++ comparator`
6. `9ad608a` (`feat/atdd` / `feat/benchmarks-ci-docs` ancestor): `test: add Sleipnir pipeline, benchmark stats, and kernel unit tests`

### Group A: Moveable As-Is (11 Tests)

| Commit | Source Test File | Test Name | Verification & Value on `master` |
|---|---|---|---|
| `56fbd38` | `tests/buffer_test.odin` | `test_buffer_make_uninit_alignment_and_lifecycle` | Covers unreferenced `buffer_make_uninit` |
| `56fbd38` | `tests/dict_test.odin` | `test_dict_nan_dedup_and_null_decode` | Covers `f64` NaN dedup & null decode round-trip |
| `56fbd38` | `tests/rle_test.odin` | `test_rle_encode_decode_preserves_nulls` | Covers null-preserving RLE encode/decode round-trip |
| `56fbd38` | `tests/compute_test.odin` | `test_compute_sort_indices_temp_allocator_no_leak` | Covers temp-allocator cleanup in repeated sorts (`25` iters, `N :: 2048`) |
| `9ad608a` | `tests/core_regressions_test.odin` | `test_compute_div_unsigned_null_divisor` | Covers unreferenced `compute_arithmetic` with `u64` null divisors |
| `9ad608a` | `tests/core_regressions_test.odin` | `test_compute_sum_simd_integers_and_null_mix` | Covers `compute_sum` on `i32`, `u16`, and mixed-null `f64` (`103`, `75`, `150`) |
| `9ad608a` | `tests/core_regressions_test.odin` | `test_radix_sort_string_and_umbra_ties` | Covers `_sort_indices_string` nulls-last/embedded-NUL/ties + Umbra ties |
| `9ad608a` | `tests/core_regressions_test.odin` | `test_compare_and_refine_f64_avx2` | Covers `compute_compare`, `compute_compare_i64`, `selection_refine_compare`, `compute_sum_selection` (`n :: 103`; rename suffix `_and_i64` for `master`) |
| `9ad608a` | `tests/core_regressions_test.odin` | `test_radix_sort_u32_edge_cases` (+ `_verify_radix_sort_stability`) | Covers `_radix_sort_indices` pass-skipping (0/1/2 passes) and stability across `i8..u64` |
| `855cc76` | `tests/parquet_internals_test.odin` | `test_decode_rle_into_bit_widths_and_tails` | Covers `p2c.decode_rle_into` (`examples/parquet_to_csv/parquet_reader.odin#L328-L379`) at bit widths `1`, `5`, `11` |
| `855cc76` | `tests/parquet_internals_test.odin` | `test_csv_and_out_simd_16byte_boundaries` | Covers `c2p.csv_to_parquet_stream(..., buf_size_override = 16)` + `p2c.parquet_to_csv_stream` refill/quote boundaries |

### Group B: Moveable with Minor Extraction / Adaptation (4 Tests)

1. **`test_umbra_long_tie_break_offsets_and_mixed_lengths`** (`9adeae8`, `tests/umbra_test.odin`):
   - **Adaptation:** Omit `import pipeline "../skadi/pipeline"` (only used by `test_umbra_actor_parallel_sort_parity`), and ensure no C-style `? :` ternaries are present.
2. **`test_compute_filter_parallel_varlen`** (`9ad608a`, `tests/core_regressions_test.odin`):
   - **Adaptation:** Remove the two `oa.string_builder_reserve_data(...)` calls and replace `(i & 1) == 0 ? "even_item" : "odd"` with `"even_item" if (i & 1) == 0 else "odd"`.
   - **Why it works on `master`:** `skadi/compute_parallel.odin#L202-L210` already dispatches `String_Type` in `compute_filter_parallel`.
3. **`test_ipc_wide_multibatch_mixed_sliced_and_overwrite_truncation`** + `_verify_mixed_batches` (from Parts 2 & 3 of `test_ipc_vectored_write_wide_multibatch_and_partial_iovec` in `9ad608a`, `tests/core_regressions_test.odin`):
   - **Adaptation:** Drop Part 1 (`oa._IPC_IOVec` / `oa._ipc_advance_iovecs`), keep Parts 2 & 3, and replace C-style `? :` ternaries (`bi == 0 ? 100 : 500`, `(orig % 3) == 0 ? ...`, etc.) with Odin `if ... else`. Also ensure `tests/core_regressions_test.odin` does not import `../benchmarks/odin/stats`.
   - **Coverage added:** 360-column 2-batch round-trip, mixed 8-type (`Null`, `Bool`, `Large_String`, `Binary`, `Large_Binary`) multi-batch sliced `[5:22]` + empty-batch round-trips (`use_mmap` true/false), and overwrite file truncation check.
4. **`test_builder_lazy_bitmap_and_reset`** (extracted from `test_builder_lazy_bitmap_and_reserve_data` in `9ad608a`, `tests/core_regressions_test.odin`):
   - **Adaptation:** Keep only the `Primitive_Builder` block (`null -> zero-tail check -> builder_reset -> dense omits buffers[0] -> null-at-tail`), omitting `string_builder_reserve_data` / `binary_builder_reserve_data` blocks.
   - **Why it works on `master`:** `skadi/builders.odin#L14-L88` already implements lazy validity bitmaps and omits `buffers[0]` on dense `builder_finish`.

**Rebasing Note for Downstream MRs:** When the downstream MR branches later rebase onto `master` after this track lands, the MR-only parts (`_IPC_IOVec` test, `string_builder_reserve_data` assertions, `compute_take_parallel`, etc.) should be kept cleanly without duplicating the tests already moved onto `master`.

### Group C: Strictly MR-Only Tests (38 Tests — Do Not Move to `master`)

- **`56fbd38` (`perf/core-simd-and-ipc`, 8 tests):**
  - `tests/buffer_pool_test.odin`: `test_buffer_pool_hit_miss_telemetry`, `test_buffer_pool_large_256kb_bucketing` (`Buffer_Pool` lacks `.hits`/`.misses` and 256KB rounding in `skadi/buffer_pool.odin#L17-L21`); `test_buffer_pool_alignment_bucketing` (`mem.alloc(128, 1)` on `master` aligns to `align_of(_Pool_Header)` (16B) and can randomly land on 64B and fail `p64 != p8`; `master` already tests this deterministically in `test_buffer_pool_resize_and_alignment`).
  - `tests/buffer_test.odin`: `test_bitmap_copy_bits` (`bitmap_copy_bits` absent on `master`).
  - `tests/compute_test.odin`: `test_compute_arithmetic_type_mismatch_error` (expects `mem.Allocator_Error.Invalid_Argument`, whereas `master` `skadi/compute.odin#L884-L885` asserts).
  - `tests/dict_test.odin`: `test_dict_slice_and_group_sum` (`str_dict_slice`, `dict_slice`, `dict_group_sum` absent on `master`).
  - `tests/hardware_config_test.odin`: `test_parse_cache_size_bytes`, `test_hardware_config_host_and_override` (`hardware_config.odin` absent on `master`).
- **`9adeae8` (`feat/sleipnir-pipeline`, 1 test):**
  - `tests/umbra_test.odin`: `test_umbra_actor_parallel_sort_parity` (`pipeline.Morsel_Pipeline` absent on `master`).
- **`04c983d` + `855cc76` (`perf/parquet-csv-vectorization`, 4 tests):**
  - `tests/parquet_internals_test.odin`:
    - `test_csv_ragged_rows_rejected_no_leak` (`examples/csv_to_parquet/csv_reader.odin#L198-L218` on `master` pads short ragged rows with `""` and skips extra columns).
    - `test_parquet_int64_double_boolean_to_csv`, `test_parquet_float_dict_nullable_bool_and_precision` (`examples/parquet_to_csv/main.odin#L310-L338` on `master` only decodes `PTYPE_INT32` + string columns).
    - `test_parquet_unsupported_ptype_and_bad_boolean_dict` (`Parquet_To_CSV_Unsupported_Column_Error` absent on `master`, and `examples/parquet_to_csv/parquet_reader.odin#L506-L525` does not reject `PTYPE_BOOLEAN` dictionary pages).
- **`ca4dfd6` (`feat/benchmarks-ci-docs` ancestor, 6 tests):**
  - `benchmarks/test_compare_1v1.py`: 6 Python unit tests for `benchmarks/compare_1v1.py` (harness absent on `master`).
- **`9ad608a` (`feat/atdd` / `feat/benchmarks-ci-docs` ancestor, 19 tests):**
  - `tests/bench_stats_test.odin`: 6 tests for `benchmarks/odin/stats`.
  - `tests/sleipnir_pipeline_test.odin`: 7 tests for `skadi/pipeline` (`deps/sleipnir/actor`).
  - `tests/strings_test.odin`: `test_string_builder_initial_data_cap_exact_allocs` (3-arg `string_builder_make` + `benchmarks/odin/stats`), `test_string_array_view_and_sum_lengths` (`array_string_view`).
  - `tests/core_regressions_test.odin`: `test_compute_take_parallel`, `test_compute_take_i32_indices_and_selection` (`compute_take_parallel`, `compute_take_selection`, `Int32_Type` indices in `compute_take`), `test_select_compare_stack_chunk_and_refine_inplace`, `test_morsel_u16_kernels_and_sel2pred_fastpath` (`selection_refine_compare_inplace`, `compute_sel_2pred_sum`, `morsel_*`, `benchmarks/odin/stats`).
