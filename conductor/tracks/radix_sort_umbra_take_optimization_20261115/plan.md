# Implementation Plan: Packed `u32` Radix Sort, Umbra Tie-Break & `Take` Gather Optimization

## Phase 1: Narrow `u32` Index LSD Radix Sort & Direct Final-Pass Widening (`skadi/compute.odin`)
Cuts radix scatter memory traffic and removes the trailing `8 MB` `mem.copy` in `_radix_sort_indices`.

- [x] Task: Add Radix Sort Edge-Case & Stability Tests (`tests/core_regressions_test.odin`)
    - [x] Verify `compute_sort_indices` stability, negative/signed min-max values, constant columns (all radix passes skipped), single-active-pass columns, and all signed/unsigned types (`i8..i64`, `u8..u64`)
    - [x] Confirm baseline tests pass and add constant/single-pass regression cases
- [x] Task: Optimize `_radix_sort_indices` with `u32` Indices & Direct Final-Pass `i64` Emission (`skadi/compute.odin`)
    - [x] Replace `[]i64` intermediate index arrays with `[]u32` when `n <= int(max(i32))`
    - [x] Identify `last_pass` ahead of the radix loop and write `i64(si[i])` directly into `data_buf.data` during `last_pass` (or emit `0..n` directly if all passes are skipped), removing the final `8 MB` `mem.copy`
    - [x] Benchmark `sort_indices_1m_i32` via `python3 benchmarks/compare_1v1.py`
- [x] Task: Conductor - User Manual Verification 'Phase 1: Narrow u32 Index Radix Sort' (Protocol in workflow.md)

---

## Phase 2: Umbra 8-Byte Secondary Tie-Break & Offset Fast Path (`skadi/umbra.odin`)
Eliminates redundant `0..3` prefix re-comparisons and byte-by-byte slice scans in `_umbra_compare_tie` for strings longer than 12 bytes.

- [x] Task: Add Umbra Long-Prefix Tie-Break & Stability Tests (`tests/umbra_test.odin`)
    - [x] Test `umbra_compare` and `umbra_sort_indices` on strings `> 12` bytes sharing 4-byte, 8-byte, 12-byte, and 16-byte prefixes, mixed `<= 12` vs `> 12` ties, equal strings, and duplicate strings
    - [x] Verify exact lexicographic parity against `compute_sort_indices` on equivalent `String_Type` arrays
- [x] Task: Implement Big-Endian `u64` Secondary Compare & Identical-Offset Fast Path (`skadi/umbra.odin`)
    - [x] In `_umbra_compare_tie`, handle `si.length > 12` / `sj.length > 12` by comparing big-endian `u64` words at `a.data[off + 4]` (for bytes `4..11`) before comparing remaining tails `[12:]` (skipping bytes `0..3` since prefixes already match)
    - [x] Fast-path identical side-buffer offsets (`off_i == off_j`)
    - [x] Benchmark `umbra_sort_100k_str` via `python3 benchmarks/compare_1v1.py`
- [x] Task: Conductor - User Manual Verification 'Phase 2: Umbra 8-Byte Tie-Break' (Protocol in workflow.md)

---

## Phase 3: `compute_take` Prefetch Tuning, `Int32_Type` Indices & 1v1 Verification (`skadi/compute.odin`, `skadi/selection.odin`, `benchmarks/RESULTS.md`)
Improves `take_1m_i32` latency and supports zero-widening 32-bit index gathers.

- [x] Task: Add Unit Tests for `Int32_Type` Index `compute_take` & `compute_take_selection` (`tests/core_regressions_test.odin`)
    - [x] Test `compute_take` with `Int32_Type` indices (including sliced arrays, null values, and null indices) and `compute_take_selection`
    - [x] Verify tests pass after implementation
- [x] Task: Tune `_take_primitive` Prefetch & Add `Int32_Type` Index / `compute_take_selection` Support (`skadi/compute.odin`, `skadi/compute_parallel.odin`, `skadi/selection.odin`)
    - [x] Tune prefetch distance/hints in `_take_primitive` (`skadi/compute.odin`) and `compute_take_parallel` (`skadi/compute_parallel.odin`) (`_TAKE_PREFETCH_DIST :: 12`, `_TAKE_PREFETCH_LOCALITY :: 0`)
    - [x] Support `Int32_Type` alongside `Int64_Type` in `compute_take` / `compute_take_parallel` and add `compute_take_selection` wrapper in `skadi/selection.odin`
- [x] Task: Verify Compilers, Unit Tests & Full 1v1 Benchmark Suite (`benchmarks/RESULTS.md`)
    - [x] Run `odin check skadi -no-entry-point -vet -strict-style -disallow-do -warnings-as-errors` and `odin check benchmarks/odin -vet -strict-style -disallow-do -warnings-as-errors`
    - [x] Run `odin test tests -out:bin/test_runner -vet -strict-style -disallow-do` (100% pass, 0 leaks)
    - [x] Run `python3 benchmarks/compare_1v1.py --from-jsonl --update-readme` and record updated results in `benchmarks/RESULTS.md`
- [x] Task: Conductor - User Manual Verification 'Phase 3: compute_take Tuning & Full Verification' (Protocol in workflow.md)
