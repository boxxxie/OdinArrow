# Implementation Plan: L1d `u16` Morsel Fast-Path & Sleipnir Super-Morsel Coarsening

## Phase 1: Shared L1d `u16` Morsel Fast-Path (`skadi/compare.odin`, `skadi/pipeline/sleipnir_pipeline.odin`)
Moves the `u16` L1d-resident `f64` morsel selection/refine/sum kernels into `skadi/compare.odin` so both `compute_sel_2pred_sum*` and `Morsel_Pipeline` share one implementation, cutting workspace footprint from `64 KB` (`i32`) to `32 KB` (`u16`) and eliminating per-morsel union switches.

- [x] Task: Add Unit Tests for `u16` Morsel Helpers & Fast-Path Parity (`tests/core_regressions_test.odin`)
    - [x] Add tests exercising `morsel_select_compare_f64_u16`, `morsel_refine_compare_f64_u16`, and `morsel_sum_f64_u16` across all `Compare_Op` variants, sliced offsets (`arr.offset > 0`), tail lengths not divisible by 4, and `0`-match predicates
    - [x] Verify `compute_sel_2pred_sum` and `compute_sel_2pred_sum_parallel` match naive scalar reference totals on both null-free `f64` fast path and nullable / `i32` fallback paths
    - [x] Verify tests pass after implementation
- [x] Task: Export `u16` Morsel Kernels in `skadi/compare.odin` & Wire into `_sel2pred_range` (`skadi/compare.odin`, `skadi/pipeline/sleipnir_pipeline.odin`)
    - [x] Export `morsel_select_compare_f64_u16`, `morsel_refine_compare_f64_u16`, and `morsel_sum_f64_u16` in `skadi/compare.odin`
    - [x] Update `_sel2pred_range` (and callers `compute_sel_2pred_sum` / `_sel2pred_job` / `compute_sel_2pred_sum_parallel`) to execute the `[16_384]u16` (`32 KB`) fast path on null-free `Float64_Type` columns, falling back to `i32` `Selection` when nullable or non-`f64`
    - [x] Replace duplicate kernel definitions in `skadi/pipeline/sleipnir_pipeline.odin` with calls to `oa.morsel_*_f64_u16`
- [x] Task: Conductor - User Manual Verification 'Phase 1: Shared L1d u16 Morsel Fast-Path' (Protocol in workflow.md)

---

## Phase 2: Sleipnir Super-Morsel Coarsening (`skadi/pipeline/sleipnir_pipeline.odin`)
Reduces MPSC envelope and `Sharded_SPSC_Mailbox` round-trip overhead by `8x` (`~153` super-morsels instead of `1,221` for `10M` rows) while iterating L1d/L2 sub-morsels internally inside each worker actor.

- [x] Task: Add Super-Morsel & Sub-Batch Streaming Tests (`tests/sleipnir_pipeline_test.odin`)
    - [x] Add tests covering super-morsel splitting (`row_len > MORSEL_MAX_ROWS`), non-aligned trailing super-morsels, multi-batch `Record_Batch` streams smaller and larger than `super_morsel_rows`, and nullable fallback inside super-morsels
    - [x] Verify tests pass after implementation
- [x] Task: Implement Super-Morsel Dispatch & Worker Sub-Morsel Loop (`skadi/pipeline/sleipnir_pipeline.odin`)
    - [x] Define `SUPER_MORSEL_MULTIPLIER :: 8` and add `sub_morsel_rows: int` to `Morsel_Work`
    - [x] Update `_dispatch_columns` to pack `super_morsel_rows := sub_morsel_rows * SUPER_MORSEL_MULTIPLIER` ranges into `Morsel_Work` envelopes
    - [x] Update `_worker_receive` to step across `sub_morsel_rows` chunks (`<= MORSEL_MAX_ROWS`) using its `u16` scratch (or `[MORSEL_MAX_ROWS]i32` fallback) and accumulate into a single `Morsel_Subtotal` push per super-morsel
- [x] Task: Conductor - User Manual Verification 'Phase 2: Sleipnir Super-Morsel Coarsening' (Protocol in workflow.md)

---

## Phase 3: Verification, 1v1 Benchmarks & Results Update
Verifies compiler compliance, zero memory leaks, and statistically significant benchmark gains across `sel_2pred_sum_10m_f64`, `_mt`, and `_actor`.

- [x] Task: Verify Compilers, Tests & 1v1 Benchmarks (`benchmarks/RESULTS.md`)
    - [x] Run `odin check skadi -no-entry-point -vet -strict-style -disallow-do -warnings-as-errors`, `odin check skadi/pipeline -no-entry-point -vet -strict-style -disallow-do -warnings-as-errors`, and `odin check benchmarks/odin -vet -strict-style -disallow-do -warnings-as-errors`
    - [x] Run `odin test tests -out:bin/test_runner -vet -strict-style -disallow-do` and confirm 100% pass with 0 memory leaks
    - [x] Run `python3 benchmarks/compare_1v1.py --groups fusion --compare-last` and update `benchmarks/RESULTS.md` (`--from-jsonl --update-readme`) with updated timings and CV%
- [x] Task: Conductor - User Manual Verification 'Phase 3: Verification & 1v1 Benchmarks' (Protocol in workflow.md)
