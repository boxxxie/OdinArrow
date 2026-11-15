# Implementation Plan: String Builder, String Scan & Selection Vector Allocation Optimization

## Phase 1: `_Var_Builder` Single-Pass Allocation, `free_with_size` Hygiene & `Buffer_Pool` Large-Allocation Tuning
Eliminates the redundant `8 MB` initial data buffer allocation in `_vb_make` when capacity is known or followed by `*_reserve_data`, aligns builder frees with `free_with_size`, and prevents `2x` power-of-two inflation on `> 4 MB` pooled buffers.

- [x] Task: Add Unit Tests for `initial_data_cap`, `free_with_size` Accounting & Large Pool Bucketing (`tests/strings_test.odin`, `tests/buffer_pool_test.odin`)
    - [x] Write tests in `tests/strings_test.odin` verifying `string_builder_make(cap, alloc, initial_data_cap)` allocates `3` buffers when `initial_data_cap > 0` and `0` discarded data buffers when `initial_data_cap == 0` precedes `string_builder_reserve_data`
    - [x] Write tests in `tests/buffer_pool_test.odin` verifying sub-power-of-two bucketing for `> 4 MB` blocks reuses blocks across identical trials with lower memory waste than `2^n`
    - [x] Verify tests fail before implementation (Red Phase)
- [x] Task: Implement `initial_data_cap` & `free_with_size` in `skadi/var_length.odin` / `skadi/builders.odin` and Tune `skadi/buffer_pool.odin`
    - [x] Add `initial_data_cap: int = -1` parameter to `string_builder_make`, `binary_builder_make`, `large_string_builder_make`, `large_binary_builder_make`, and `_vb_make` in `skadi/var_length.odin`
    - [x] Update `_vb_destroy`, `_vb_finish`, `_vb_grow_data` (`skadi/var_length.odin`) and `builder_destroy` / `builder_finish` (`skadi/builders.odin`) to call `mem.free_with_size`
    - [x] Tune `_pool_get` / `_bucket_size` in `skadi/buffer_pool.odin` for blocks `> 4 MB`
    - [x] Update `string_build_1m` and `sort_indices_100k_str` in `benchmarks/odin/bench_main.odin` and verify `allocs_per_run` drops from `4` to `3`
- [x] Task: Conductor - User Manual Verification 'Phase 1: _Var_Builder Single-Pass Allocation & Pool Tuning' (Protocol in workflow.md)

---

## Phase 2: Zero-Overhead String View Reader & Word-Wise `string_scan_1m`
Closes the `0.75x` performance gap on `string_scan_1m` against Apache Arrow C++ by optimizing inline accessors, hoisting raw string array pointers, and scanning validity bits 64 bits at a time.

- [x] Task: Add Unit Tests for `String_Array_View` / `array_string_view` (`tests/strings_test.odin`)
    - [x] Write unit tests covering `String_Array_View` / `array_string_view` and word-wise string iteration on sliced and unsliced `String_Type` arrays with `nil` bitmaps, mixed nulls, and non-64-aligned tail lengths
    - [x] Verify tests fail before implementation (Red Phase)
- [x] Task: Optimize `array_get_string` & Implement `array_string_view` (`skadi/var_length.odin`) + Update `string_scan_1m` (`benchmarks/odin/bench_main.odin`)
    - [x] Mark `array_get_string`, `array_get_binary`, `array_get_large_string`, `array_get_large_binary` in `skadi/var_length.odin` as `#force_inline proc "contextless"`, gate bounds `assert` behind `when ODIN_DEBUG`, and remove the redundant `if start == end` branch
    - [x] Implement `String_Array_View` / `array_string_view(arr: ^Array)` and a 64-bit word-wise (`u64`) validity scan helper in `skadi/var_length.odin`
    - [x] Update `string_scan_1m` in `benchmarks/odin/bench_main.odin`, benchmark via `python3 benchmarks/compare_1v1.py --groups strings --compare-last`, and verify `>= 1.0x` vs Arrow C++
- [x] Task: Conductor - User Manual Verification 'Phase 2: Zero-Overhead String View Reader' (Protocol in workflow.md)

---

## Phase 3: Fused Selection Build & In-Place Refinement (`skadi/compare.odin`, `skadi/selection.odin`)
Eliminates the `1.25 MB` heap `Bool` mask allocation and second `~20 MB` index buffer allocation in `sel_2pred_sum_10m_f64`.

- [x] Task: Add Unit Tests for Stack-Chunked `compute_select_compare` & `selection_refine_compare_inplace` (`tests/core_regressions_test.odin` or `tests/selection_test.odin`)
    - [x] Write unit tests verifying `selection_refine_compare_inplace` and fused `compute_select_compare` produce exact parity across all numeric types, null bitmaps, sliced arrays, and constant predicate plans (`All_True` / `All_False`) with `<= 1` index allocation and zero mask allocations
    - [x] Verify tests fail before implementation (Red Phase)
- [x] Task: Implement Fused Stack-Chunked `compute_select_compare` & `selection_refine_compare_inplace` (`skadi/compare.odin`, `skadi/selection.odin`)
    - [x] Replace the heap `compute_compare` + `_filter_count_bits` + `_compress_dense` 3-pass pipeline in `skadi/compare.odin` with a stack `[512]u8` L1-chunked SIMD compare + compress pass
    - [x] Implement `selection_refine_compare_inplace` and `selection_refine_compare_i64_inplace` in `skadi/compare.odin` reusing `sel.indices` (`k <= j` in `_refine_compare_mono`)
    - [x] Update `sel_2pred_sum_10m_f64` in `benchmarks/odin/bench_main.odin`, run `python3 benchmarks/compare_1v1.py --update-readme`, and verify statistically significant gains via `--compare-last`
- [x] Task: Conductor - User Manual Verification 'Phase 3: Fused Selection Build & In-Place Refinement' (Protocol in workflow.md)
