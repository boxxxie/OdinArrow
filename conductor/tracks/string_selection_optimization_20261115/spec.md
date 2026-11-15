# Specification: String Builder, String Scan & Selection Vector Allocation Optimization

## Overview
Allocation and bandwidth telemetry in `benchmarks/compare_1v1.py` exposed three concrete bottlenecks in Skadi's single-threaded kernels compared to Apache Arrow C++:
1. **`string_build_1m` Double-Allocation (`4(4p)` allocs / `26.8 MB` vs C++ `3` allocs / `14.4 MB`):**
   In `skadi/var_length.odin`, `_vb_make` eagerly allocates an initial `init_cap * 8` (`8 MB`) data buffer before a caller's immediate `string_builder_reserve_data(&b, 11_000_000)` triggers `_vb_grow_data`, which doubles `data_cap` to `16 MB`, frees the `8 MB` block, and allocates a second `16 MB` power-of-two bucketed buffer (`8 + 16 + 4 + 0.125 = 28.125 MB` = `26.8 MiB`). Meanwhile, `_vb_destroy`, `_vb_finish`, `_vb_grow_data` in `skadi/var_length.odin` and `builder_destroy` in `skadi/builders.odin` call `mem.free` instead of `mem.free_with_size`, losing `live_bytes` / `peak_live_bytes` precision in `Counting_Allocator`.
2. **`string_scan_1m` Per-Element Overhead (`1.50 ms` vs C++ `1.13 ms`, `0.75x`):**
   The only single-threaded workload in the suite trailing Arrow C++. Per-element calls to `array_is_null(&arr, i)` ([`skadi/array.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/array.odin)) and `array_get_string(&arr, i)` ([`skadi/var_length.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/var_length.odin)) repeat `Null_Type` union tag switches, bounds assertions (active in `-o:speed` unless gated by `when ODIN_DEBUG`), redundant `if start == end` branches, and `buffers[...]` pointer indirections `1,000,000` times instead of hoisting raw `(offsets, data, null_bitmap)` pointers and scanning validity words.
3. **`sel_2pred_sum_10m_f64` 3-Pass / `39.3 MB` Allocation Bottleneck (`17.33 ms` vs C++ `25.4 MB`):**
   `compute_select_compare` ([`skadi/compare.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compare.odin#L450-L455)) allocates a `1.25 MB` `Bool` mask array via `compute_compare`, reads it a second time in `_filter_count_bits`, and reads it a third time in `_compress_dense` before writing a `~20 MB` `Selection`. Then `selection_refine_compare` allocates a second `~20 MB` index buffer even though `k <= j` always holds and refinement can happen in place (`selection_refine_compare_inplace`). Furthermore, `Buffer_Pool` power-of-two rounding (`11 MB -> 16 MB`, `20 MB -> 32 MB`) nearly doubles large-buffer memory footprints.

---

## Functional Requirements

### 1. `String_Builder` Single-Allocation Initialization & `free_with_size` Hygiene (`skadi/var_length.odin`, `skadi/builders.odin`)
- Extend `string_builder_make`, `binary_builder_make`, `large_string_builder_make`, and `large_binary_builder_make` in `skadi/var_length.odin` with optional `initial_data_cap: int = -1` passed through `_vb_make` so callers who know their approximate byte volume allocate the data buffer **once** at construction time.
- When `initial_data_cap == 0`, defer data buffer allocation until the first `_vb_grow_data` / append, eliminating wasted `8 MB` default allocations when `*_reserve_data` is called immediately after `*_make`.
- Update `_vb_destroy`, `_vb_finish`, `_vb_grow_data` in `skadi/var_length.odin` and `builder_destroy` / `builder_finish` in `skadi/builders.odin` to use `mem.free_with_size` (matching `buffer_free` in `skadi/buffer.odin`) so `Counting_Allocator` tracks `live_bytes` and `peak_live_bytes` accurately.
- Update `string_build_1m` and `sort_indices_100k_str` in `benchmarks/odin/bench_main.odin` to pass `initial_data_cap` directly, reducing `string_build_1m` allocations from `4` to `3`.

### 2. Zero-Overhead String View Reader & Word-Wise Scan (`skadi/var_length.odin`, `skadi/array.odin`)
- Mark `array_get_string`, `array_get_binary`, `array_get_large_string`, and `array_get_large_binary` in `skadi/var_length.odin` as `#force_inline proc "contextless"`, gate bounds assertions behind `when ODIN_DEBUG`, and remove redundant `if start == end { return "" }` branches.
- Add `String_Array_View` / `array_string_view(arr: ^Array)` (validating `String_Type` once up front and hoisting `offsets: [^]i32`, `data: [^]u8`, `null_bitmap: [^]u8`, `offset: int`, `length: int` without per-element `Null_Type` union tag checks).
- Provide a 64-bit word-wise (`u64`) validity bitmap traversal helper for string scans (fast-pathing `0xFFFF_FFFF_FFFF_FFFF` all-valid words and `null_bitmap == nil` runs via tight branchless `offsets[i + 1] - offsets[i]` summation).
- Achieve `>= 1.0x` parity (and ideally a speedup) against Arrow C++ `StringArray::GetView` in `string_scan_1m`.

### 3. Fused Selection Build, In-Place Refinement & Large Buffer Bucketing (`skadi/compare.odin`, `skadi/selection.odin`, `skadi/buffer_pool.odin`)
- Eliminate the 3-pass heap `Bool` mask allocation in `compute_select_compare` (`skadi/compare.odin`) by evaluating comparisons into a stack-resident L1 buffer (`[512]u8`, `4,096` bits) and compressing surviving indices directly—avoiding the `1.25 MB` mask allocation and 2 extra DRAM passes.
- Add `selection_refine_compare_inplace(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: f64)` (and `_i64`) in `skadi/compare.odin` (reusing `sel.indices` since `k <= j` always holds in `_refine_compare_mono`), eliminating the second `~20 MB` index buffer allocation in `sel_2pred_sum_10m_f64`.
- Refine `Buffer_Pool` (`skadi/buffer_pool.odin`) large-buffer bucketing (`> 4 MB`, e.g., sub-power-of-two size classes such as 1 MB / quarter-power steps instead of strict `2^n` doubling) so `11 MB`–`20 MB` buffers do not suffer nearly `2x` inflation (`11 MB -> 16 MB`, `20 MB -> 32 MB`) while preserving 100% pool hit rates across repeated trials.

---

## Non-Functional Requirements
- **Compiler Compliance**: Zero warnings/errors under `odin check skadi -no-entry-point -vet -strict-style -disallow-do -warnings-as-errors`.
- **Memory Safety**: Zero leaks in `odin test tests -out:bin/test_runner -vet -strict-style`.
- **Statistical Verification**: Verify improvements using `python3 benchmarks/compare_1v1.py --compare-last`.

---

## Acceptance Criteria
- [ ] `string_build_1m` allocates `3` buffers (`<= 16 MB` total, down from `4` buffers / `26.8 MB`) with `100%` `Buffer_Pool` hit rate after warmup.
- [ ] `string_scan_1m` reaches `>= 1.0x` speedup vs Apache Arrow C++ (down from `1.50 ms` to `<= 1.10 ms`).
- [ ] `sel_2pred_sum_10m_f64` eliminates heap mask and second selection vector allocations (`<= 1` data-dependent alloc, down from `3` allocs / `39.3 MB`), reduces allocated memory below Arrow C++ (`25.4 MB`), and improves latency.
- [ ] All unit tests in `tests/` pass with zero memory leaks.

---

## Out of Scope
- Hardware-topology auto-detection and cache-adaptive morsel sizing (covered in Track `hardware_adaptive_morsels_20261115`).
- Multi-stage actor pipelining with `sleipnir` (covered in Track `sleipnir_morsel_pipeline_20261115`).
