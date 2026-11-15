# Specification: Sleipnir Actor MSB-Bucket Parallel Radix, String & Umbra Sort

## Overview
While single-threaded `sort_indices_1m_i32` (`14.85 ms`), `sort_indices_100k_str` (`2.18 ms`), and `umbra_sort_100k_str` (`2.12 ms`) lead Arrow C++ single-threaded (`40.99 ms`, `9.68 ms`, `9.80 ms`), Skadi currently has no multi-threaded counterparts for numeric radix sort, Arrow string sort, or Umbra string sort.

Using Sleipnir actors (`deps/sleipnir/actor` + `skadi/pipeline/sleipnir_pipeline.odin`) provides a race-free parallel sorting architecture without shared histogram locks, multi-barrier synchronization, or concurrent cache-line false sharing:
- **MSB Bucket Partitioning:** Partitioning input indices by their Most Significant Byte (`256` ordered buckets) creates strictly disjoint output ranges `out_indices[bucket_offset[b] : bucket_offset[b+1]]`.
- **Disjoint Actor Ownership:** Each `Sort_Bucket_Work` envelope dispatched through `actor.Envelope_Pool` grants a worker actor exclusive ownership of its bucket's scratch and destination slice. Workers run the existing proven single-threaded sort kernel locally, emit widened `i64` indices directly into their disjoint output slice, and return completion receipts via `Sharded_SPSC_Mailbox` with zero cross-worker merge passes.

---

## Functional Requirements

### 1. Actor MSB-Bucket Parallel `i32`/`u32` Radix Sort (`skadi/pipeline/sleipnir_pipeline.odin`, `skadi/compute.odin`)
- Partition `n` valid indices by their MSB (`byte 3` of sign-flipped `u32` for `i32`, or top byte for `u32` / primitive keys) into `256` disjoint bucket ranges `bucket_offsets[0..256]` stored in a compact `[]u32` bucket buffer (and route null indices directly to the trailing null-last tail).
- Group non-empty MSB buckets into coarse `Sort_Bucket_Work` envelopes dispatched via `actor.send_batch_from_pool`.
- Inside each worker actor, sort assigned buckets locally using the remaining 3 LSD radix passes (`bytes 0..2`) with worker-private scratch buffers, writing final widened `i64` indices directly into `out_buf[bucket_offsets[b] : bucket_offsets[b+1]]`, and push `Sort_Bucket_Done` to `Sharded_SPSC_Mailbox`.
- Handle skewed distributions (e.g., all keys in a single MSB bucket) gracefully by falling back or sub-partitioning on the next byte without starvation.
- Preserve strict sort stability (`_verify_radix_sort_stability`) and null-last semantics.

### 2. Actor MSB-Bucket Parallel Umbra & Arrow String Sort (`skadi/umbra.odin`, `skadi/pipeline/sleipnir_pipeline.odin`)
- Partition `Umbra_Array` and `String_Type` valid indices by their leading byte (top byte of `Umbra_Array.prefix_key` / first byte of string, separating empty strings first and nulls last) into `256` ordered buckets.
- Dispatch non-empty bucket groups as `Sort_Bucket_Work` envelopes to Sleipnir worker actors.
- Execute `_umbra_sort_range` (using `_umbra_compare_tie` fast paths) for `Umbra_Array` buckets and MSD radix / insertion sort for `String_Type` buckets directly into the disjoint output slice, preserving stability and null-last ordering.

### 3. Benchmark & Verification Wiring (`benchmarks/odin/bench_main.odin`, `benchmarks/compare_1v1.py`, `benchmarks/RESULTS.md`)
- Register `sort_indices_1m_i32_actor`, `umbra_sort_100k_str_actor`, and `sort_indices_100k_str_actor` in `benchmarks/odin/bench_main.odin` and wire them into `benchmarks/compare_1v1.py`.
- Target `~4–5 ms` on `sort_indices_1m_i32_actor` (`~8–10x` vs Arrow C++ ST) and strong multi-core scaling on string sorting.

---

## Non-Functional Requirements
- **Zero Data Races & Zero Merge Passes:** Workers only write to disjoint output slices owned by their assigned MSB bucket range.
- **Steady-State Pool Discipline:** Use pre-warmed `actor.Envelope_Pool` envelopes and reusable worker scratch buffers without per-bucket heap allocations inside worker receive callbacks.
- **Compiler & Test Hygiene:** Pass `odin check` on `skadi`, `skadi/pipeline`, and `benchmarks/odin` with `-vet -strict-style -disallow-do -warnings-as-errors`, and pass `odin test tests` with `0` memory leaks.

---

## Acceptance Criteria
- [x] Actor parallel `i32`/`u32` radix sort produces identical indices to `compute_sort_indices` across uniform, skewed, constant, duplicate, negative, and nullable inputs, preserving stability (`_verify_radix_sort_stability`).
- [x] Actor parallel Umbra and Arrow string sort produce exact parity with `umbra_sort_indices` and `compute_sort_indices` across short (`<= 12` bytes), long (`> 12` bytes), shared-prefix, empty, duplicate, and nullable strings.
- [x] `sort_indices_1m_i32_actor`, `umbra_sort_100k_str_actor`, and `sort_indices_100k_str_actor` are wired in `benchmarks/odin/bench_main.odin` / `benchmarks/compare_1v1.py` and recorded in `benchmarks/RESULTS.md`.
- [x] All compiler checks and unit tests pass with zero warnings and zero memory leaks.

---

## Out of Scope
- Distributed multi-node sorting or external disk spill sorting.
