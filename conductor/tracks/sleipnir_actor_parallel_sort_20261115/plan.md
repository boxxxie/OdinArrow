# Implementation Plan: Sleipnir Actor MSB-Bucket Parallel Radix, String & Umbra Sort

## Phase 1: Actor MSB-Bucket Parallel `i32`/`u32` Radix Sort (`skadi/pipeline/sleipnir_pipeline.odin`, `skadi/compute.odin`, `tests/sleipnir_pipeline_test.odin`)
Partitions numeric keys by MSB (`byte 3`) into 256 disjoint `u32` buckets and runs 3-pass local LSD radix sort inside Sleipnir worker actors.

- [x] Task: Add Unit Tests for Actor Radix Sort (`tests/sleipnir_pipeline_test.odin`)
    - [x] Verify stability (`_verify_radix_sort_stability` semantics), negative/signed extrema, duplicates, constant columns, skewed single-bucket keys, and null-last parity against `compute_sort_indices`
- [x] Task: Expose Local LSD Sub-Pass Helper & Implement Actor MSB-Bucket Radix Sort (`skadi/compute.odin`, `skadi/pipeline/sleipnir_pipeline.odin`)
    - [x] Extract/export helper for 3-pass `u32` LSD radix sort over a contiguous `[]u32` bucket into `[]i64` destination
    - [x] Add `Sort_Bucket_Work` / `Sort_Bucket_Done` pool and `pipeline_sort_indices_i32` / `pipeline_sort_indices_u32` in `skadi/pipeline/sleipnir_pipeline.odin`
    - [x] Verify Phase 1 unit tests pass with 0 leaks

---

## Phase 2: Actor MSB-Bucket Parallel Umbra & Arrow String Sort (`skadi/umbra.odin`, `skadi/pipeline/sleipnir_pipeline.odin`, `tests/umbra_test.odin`)
Partitions strings by leading byte into 256 disjoint buckets and sorts each bucket locally on Sleipnir worker actors.

- [x] Task: Add Unit Tests for Actor String & Umbra Sort (`tests/umbra_test.odin`, `tests/sleipnir_pipeline_test.odin`)
    - [x] Test parity against `umbra_sort_indices` and `compute_sort_indices` on mixed `<= 12` / `> 12` byte strings, shared prefixes, empty strings, duplicates, embedded NULs, and nulls
- [x] Task: Implement `pipeline_umbra_sort_indices` & `pipeline_sort_indices_str` (`skadi/umbra.odin`, `skadi/pipeline/sleipnir_pipeline.odin`)
    - [x] Expose bucket-range sort entry points (`umbra_sort_range_into` / `string_sort_range_into`) as needed
    - [x] Dispatch non-empty leading-byte buckets to worker actors and verify Phase 2 tests pass with 0 leaks

---

## Phase 3: 1v1 Benchmark Wiring & Verification (`benchmarks/odin/bench_main.odin`, `benchmarks/compare_1v1.py`, `benchmarks/RESULTS.md`)
Benchmarks actor sort scaling vs Odin ST and Arrow C++ ST.

- [x] Task: Wire Benchmarks & Verify Full Suite (`benchmarks/odin/bench_main.odin`, `benchmarks/compare_1v1.py`, `benchmarks/RESULTS.md`)
    - [x] Register `sort_indices_1m_i32_actor`, `umbra_sort_100k_str_actor`, and `sort_indices_100k_str_actor`
    - [x] Run `odin check` (`-vet -strict-style -disallow-do -warnings-as-errors`) across `skadi`, `skadi/pipeline`, `benchmarks/odin`, and run `odin test tests`
    - [x] Run `python3 benchmarks/compare_1v1.py --compare-last` and update `benchmarks/RESULTS.md`
