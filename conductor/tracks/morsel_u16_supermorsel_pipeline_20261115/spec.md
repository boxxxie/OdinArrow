# Specification: L1d `u16` Morsel Fast-Path & Sleipnir Super-Morsel Coarsening

## Overview
Benchmark telemetry in `benchmarks/RESULTS.md` and `benchmarks/odin.jsonl` highlights two remaining cache-hierarchy and scheduling bottlenecks across the multi-predicate selection pipelines:
1. **`compute_sel_2pred_sum` (`15.73 ms` ST) & `compute_sel_2pred_sum_parallel` (`4.34 ms` MT) L1d Spill & Type-Switch Overhead:**
   In [`skadi/compare.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compare.odin#L981-L1107), `_sel2pred_range` still runs the generic `i32` `Selection` path (`[_SEL2_MAX_MORSEL]i32` = `64 KB` stack workspace, which exceeds the `32 KB` L1d cache detected on this host) and evaluates `array_slice` + `arr.type` union switches three times per morsel (`3,663` type dispatches across `10M` rows). Meanwhile, [`skadi/pipeline/sleipnir_pipeline.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/pipeline/sleipnir_pipeline.odin#L70-L215) already uses compact `u16` local morsel offsets (`[16_384]u16` = `32 KB`, fitting inside L1d) and AVX2-specialized `f64` kernels (`morsel_select_compare_f64_u16`, `morsel_refine_compare_f64_u16`, `morsel_sum_f64_u16`).
2. **`sel_2pred_sum_10m_f64_actor` Fine-Grained MPSC/SPSC Dispatch Overhead (`8.17 ms` median vs `4.34 ms` MT fork-join, `20.5%` CV):**
   In [`skadi/pipeline/sleipnir_pipeline.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/pipeline/sleipnir_pipeline.odin#L439-L486), `_dispatch_columns` emits `1,221` separate `8,192`-row `Morsel_Work` messages for `10M` rows. Even with `32`-envelope batching and pooled slabs, fine-grained MPSC pushing and `Sharded_SPSC_Mailbox` return messages introduce `~3.8 ms` of scheduling jitter relative to static fork-join (`min` sample already hits `4.81 ms`).

Unifying the shared L1d-resident `u16` morsel kernels in `skadi/compare.odin` and coarsening Sleipnir actor dispatch into `65,536`-row super-morsels (`8` L1d/L2 sub-morsels processed internally per actor invocation) targets a `20–30%` win on `sel_2pred_sum_10m_f64` / `_mt` and a `~1.6x` improvement on `sel_2pred_sum_10m_f64_actor`.

---

## Functional Requirements

### 1. Shared L1d `u16` Morsel Kernels (`skadi/compare.odin`, `skadi/pipeline/sleipnir_pipeline.odin`)
- Move/expose `morsel_select_compare_f64_u16`, `morsel_refine_compare_f64_u16`, and `morsel_sum_f64_u16` in `package skadi` (`skadi/compare.odin`), using `u16` local morsel offsets (`0..<16_384`, `32 KB` total stack scratch) and `@(enable_target_feature = "avx2")` SIMD comparison extraction.
- Update `_sel2pred_range` (used by both `compute_sel_2pred_sum` and `compute_sel_2pred_sum_parallel` in `skadi/compare.odin`) to check for the null-free `Float64_Type` fast path once per range (`col_a` and `col_b` both `Float64_Type`, `buffers[0].data == nil`, `step <= _SEL2_MAX_MORSEL`) and execute the shared `u16` L1d kernels directly without per-morsel `array_slice` or union type switches.
- Keep the existing `i32` `Selection` path inside `_sel2pred_range` as the fallback for nullable or non-`f64` columns.
- Update `skadi/pipeline/sleipnir_pipeline.odin` to call `oa.morsel_select_compare_f64_u16`, `oa.morsel_refine_compare_f64_u16`, and `oa.morsel_sum_f64_u16` directly instead of duplicating those helpers in `package pipeline`.

### 2. Super-Morsel Coarsening in Sleipnir Pipeline (`skadi/pipeline/sleipnir_pipeline.odin`)
- Introduce `SUPER_MORSEL_MULTIPLIER :: 8` (up to `65,536` rows per `Morsel_Work` envelope) and add `sub_morsel_rows: int` (`<= MORSEL_MAX_ROWS`, `16_384`) to `Morsel_Work`.
- Update `_dispatch_columns` in `skadi/pipeline/sleipnir_pipeline.odin` to derive `sub_morsel_rows` from `Hardware_Config.morsel_target_bytes` (`clamp((hw.morsel_target_bytes / bpr + 63) &~ 63, 4096, MORSEL_MAX_ROWS)`) and dispatch `super_morsel_rows := sub_morsel_rows * SUPER_MORSEL_MULTIPLIER` ranges (`~153` envelopes for `10M` rows instead of `1,221`), preserving `0` steady-state heap allocations.
- Update `_worker_receive` in `skadi/pipeline/sleipnir_pipeline.odin` to iterate over `[row_start, row_start + row_len)` in `sub_morsel_rows` L1d/L2 steps (both fast `u16` path and fallback `i32` path), accumulating local partial `sum` and `valid_count` before emitting a single `Morsel_Subtotal` per super-morsel via `actor.sharded_spsc_push`.
- Preserve full multi-batch streaming semantics in `pipeline_record_batch_stream_sum` (including batches smaller than `super_morsel_rows`).

### 3. Tests & 1v1 Benchmark Verification
- Add unit tests in `tests/core_regressions_test.odin` and `tests/sleipnir_pipeline_test.odin` verifying exact parity across sub-morsel boundaries, non-aligned tail lengths, nullable/non-`f64` fallback, sliced arrays, and multi-batch `Record_Batch` streams.
- Run `python3 benchmarks/compare_1v1.py --groups fusion --compare-last` and update `benchmarks/RESULTS.md` with the observed `sel_2pred_sum_10m_f64`, `sel_2pred_sum_10m_f64_mt`, and `sel_2pred_sum_10m_f64_actor` metrics.

---

## Non-Functional Requirements
- **Zero Heap Allocations in Steady State**: Both `compute_sel_2pred_sum*` and `Morsel_Pipeline` must maintain `0` allocations (`0.0 MB`) per trial.
- **Compiler & Test Hygiene**: Zero warnings/errors under `odin check skadi`, `skadi/pipeline`, `benchmarks/odin` with `-vet -strict-style -disallow-do -warnings-as-errors`, and `0` memory leaks in `odin test tests`.

---

## Acceptance Criteria
- [x] `morsel_select_compare_f64_u16`, `morsel_refine_compare_f64_u16`, and `morsel_sum_f64_u16` live in `skadi/compare.odin` with zero duplicated logic between `skadi/compare.odin` and `skadi/pipeline/sleipnir_pipeline.odin`.
- [x] `compute_sel_2pred_sum` and `compute_sel_2pred_sum_parallel` use the `32 KB` L1d `u16` workspace on null-free `Float64_Type` inputs and measurably improve `sel_2pred_sum_10m_f64` / `sel_2pred_sum_10m_f64_mt` with `0` heap allocations.
- [x] `Morsel_Pipeline` dispatches super-morsels (`SUPER_MORSEL_MULTIPLIER == 8`) while iterating L1d/L2 `sub_morsel_rows` inside workers, reducing `sel_2pred_sum_10m_f64_actor` median latency and variance (`CV%`) with `0` steady-state allocations.
- [x] All unit tests in `tests/` pass with zero memory leaks and `compare_1v1.py` confirms statistically verified gains in `benchmarks/RESULTS.md`.

---

## Out of Scope
- Packing/narrowing integer radix sort indices, Umbra 8-byte tie-breaking, or `compute_take` prefetch tuning (covered in Track `radix_sort_umbra_take_optimization_20261115`).
- Changing single-pass memory-bandwidth-bound reductions (`sum_10m_f64`, `min_max_10m_i32`).
