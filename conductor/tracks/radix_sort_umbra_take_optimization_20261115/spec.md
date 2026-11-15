# Specification: Packed `u32` Radix Sort, Umbra Tie-Break & `Take` Gather Optimization

## Overview
While Skadi's streaming reductions and pre-sized builders sit near the DDR4 memory-bandwidth ceiling, three compute and encoding kernels still pay avoidable data-movement and comparison overhead in [`benchmarks/RESULTS.md`](file:///home/pauli/projects/odin/OdinArrow/benchmarks/RESULTS.md#L309-L338):
1. **`sort_indices_1m_i32` (`20.01 ms` vs C++ `40.99 ms`, [`skadi/compute.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compute.odin#L1272-L1335)):**
   `_radix_sort_indices` currently stores intermediate index arrays (`idx` and `ibuf`) as `[]i64` (`8 B`/elem) alongside `keys`/`kbuf` (`4 B`/elem), performing two separate random-access scatters (`12 B`/elem) per active radix pass plus a trailing `8 MB` `mem.copy` into `data_buf.data`. Using `u32` indices during intermediate radix passes (when `n <= int(max(u32))`, `~4B` rows) and widening `u32 -> i64` directly into `data_buf.data` on the final active radix pass cuts radix scatter bandwidth by `33%` (or `50%` on index storage) and eliminates the `8 MB` copy.
2. **`umbra_sort_100k_str` (`2.69 ms` vs Arrow string `sort_indices_100k_str` `2.26 ms`, [`skadi/umbra.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/umbra.odin#L126-L298)):**
   Currently trails plain Arrow string sort on `100k` `> 12`-byte strings (`"alpha_key_000001"`). Plain `_sort_indices_string` loads an `8`-byte `u64` prefix per entry, whereas `umbra_sort_indices` only radix-sorts the `4`-byte slot prefix and falls back to `strings.compare(umbra_get(a, i), umbra_get(a, j))` inside `_umbra_compare_tie` on every merge-sort step—re-comparing bytes `0..3` and scanning slices byte-by-byte. Comparing bytes `4..11` via a single big-endian `u64` unaligned load at `a.data[off + 4]` (with an identical-offset/length fast path and suffix-only `bytes[12:]` fallback) restores Umbra's comparison advantage.
3. **`take_1m_i32` (`8.63 ms` ST vs C++ `9.02 ms`, `1.05x~`, [`skadi/compute.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compute.odin#L740-L830)):**
   Our narrowest margin over Arrow C++. Random-access gathering of `1M` `i32` elements out of `4 MB` is latency-bound; tuning software prefetch distance/locality in `_take_primitive` (and adding direct `Selection` / `Int32_Type` index gather support via `compute_take_selection` or `compute_take` accepting `Int32_Type` indices) reduces index bandwidth by `50%` on 32-bit index workflows.

---

## Functional Requirements

### 1. Narrow `u32` Index LSD Radix Sort & Direct `i64` Final-Pass Widening (`skadi/compute.odin`)
- Update `_radix_sort_indices` in `skadi/compute.odin` when `n <= int(max(i32))` (the standard Arrow 32-bit length domain; keep `i64` fallback if `n > int(max(i32))`):
  - Maintain `u32` index buffers (`idx` / `ibuf`, `4 B` per element instead of `8 B`) or packed `{key, idx}` entries for 32-bit keys (`size_of(T) <= 4`) to reduce cache pressure and TLB misses during random-access scatters.
  - Detect the **last active radix pass** from `hist` (or `all_skipped` when all elements are equal) and write `i64(si[i])` directly into the `data_buf` output buffer (`cast([^]i64)data_buf.data`) during that final pass—eliminating the post-loop `8 MB` `mem.copy` (`mem.copy` of `si` when `i64` fallback is used, or direct `i64` emission for `all_skipped`).
- Preserve exact stability (equal keys maintain ascending original index order) and exact compatibility across all signed/unsigned integer types (`i8..i64`, `u8..u64`).

### 2. Umbra 8-Byte Secondary Tie-Break & Offset Fast Path (`skadi/umbra.odin`)
- Optimize `_umbra_compare_tie` in `skadi/umbra.odin` for strings with `length > 12`:
  - Extract side-buffer `i64` offsets once (`off_i := _get_i64le(si.data[4:12])`, `off_j := _get_i64le(sj.data[4:12])`).
  - When `si.length >= 12 && sj.length >= 12` (or `min(len_i, len_j) >= 12`), compare bytes `4..11` directly via a big-endian `u64` unaligned load (`intrinsics.byte_swap(intrinsics.unaligned_load(cast(^u64)&a.data[off + 4]))` on little-endian) before falling back to byte comparison on the tail `[12:]` (or full remaining slice).
  - Add an identical-slice fast path when `off_i == off_j && si.length == sj.length` (`return 0`), plus handle mixed `<= 12` vs `> 12` ties cleanly without re-comparing the already-equal 4-byte prefix `[0..3]`.
- Ensure `umbra_compare`, `umbra_count_eq`, and `umbra_sort_indices` preserve exact lexicographical order and tie stability.

### 3. `compute_take` Prefetch Tuning & Narrow Index Gather (`skadi/compute.odin`, `skadi/selection.odin`)
- Profile and tune prefetch lookahead distance and locality hints (`0..3`) in `_take_primitive` (`skadi/compute.odin`) and `compute_take_parallel` (`skadi/compute_parallel.odin`) for random `1M+` gathers (`take_1m_i32`).
- Support `Int32_Type` index arrays directly in `compute_take` (and/or expose `compute_take_selection` delegating cleanly to `selection_take` in `skadi/selection.odin`) so callers with 32-bit indices avoid `i32 -> i64` widening copies.
- Verify all `take_1m_i32`, `sort_indices_1m_i32`, and `umbra_sort_100k_str` gains via `benchmarks/compare_1v1.py`.

---

## Non-Functional Requirements
- **Exact Stability & Bounds Safety**: Sorting must remain strictly stable (`(val_a, orig_idx_a)` order); `ODIN_DEBUG` bounds assertions in `compute_take` must remain intact.
- **Compiler & Test Hygiene**: Must pass `odin check skadi -no-entry-point -vet -strict-style -disallow-do -warnings-as-errors` and `odin test tests -out:bin/test_runner -vet -strict-style -disallow-do` with zero leaks.

---

## Acceptance Criteria
- [x] `_radix_sort_indices` uses `u32` indices during radix passes (`n <= max(i32)`) and widens directly into `data_buf` on the final pass, measurably speeding up `sort_indices_1m_i32` with zero regressions across all integer widths (`i8..i64`, `u8..u64`).
- [x] `_umbra_compare_tie` resolves `4..11`-byte ties with big-endian `u64` loads and suffix-only fallback, bringing `umbra_sort_100k_str` at or ahead of plain Arrow `sort_indices_100k_str` (`<= 2.26 ms`).
- [x] `compute_take` / `_take_primitive` prefetch tuning and `Int32_Type` index support (plus `compute_take_selection` helper) pass full unit tests and push `take_1m_i32` cleanly ahead of Arrow C++ (`> 1.05x`).
- [x] `benchmarks/RESULTS.md` updated via `python3 benchmarks/compare_1v1.py --from-jsonl --update-readme`.

---

## Out of Scope
- Multi-threaded sorting or hash-join operators (separate future feature track).
- L1d `u16` morsel selection and Sleipnir super-morsel coarsening (covered in Track `morsel_u16_supermorsel_pipeline_20261115`).
