# Implementation Plan: Sleipnir Actor & Sharded SPSC Cache-Resident Morsel Pipeline

## Phase 1: Sleipnir Collection Setup, `-disallow-do` Compliance & Tech Stack Documentation
Configures access to `sleipnir` (`package actor`), resolves `-disallow-do` syntax incompatibilities, and preserves `Skadi`'s zero-dependency core library.

- [x] Task: Configure `sleipnir` Package Collection, Fix `-disallow-do` & Update `conductor/tech-stack.md`
    - [x] Replace all 22 single-line `do` statements in `sleipnir/actor` (`pool.odin` lines 119, 172, 193; `actor.odin` lines 281, 299, 356, 369, 410, 421, 511, 655, 857, 898, 940, 941, 1123, 1136, 1171, 1182, 1444, 1478, 1481) with `{ ... }` blocks (in `deps/sleipnir/actor` and/or upstream `/home/pauli/projects/odin/sleipnir/actor`)
    - [x] Document `sleipnir` (`package actor`) in `conductor/tech-stack.md` and exclude `deps/**` in `.gdumpignore` if bundled locally
    - [x] Configure `Makefile` / collection flags (`-collection:actor=...`) and verify `odin check <actor_path> -no-entry-point -vet -strict-style -disallow-do` passes with 0 errors
- [x] Task: Conductor - User Manual Verification 'Phase 1: Sleipnir Collection Setup' (Protocol in workflow.md)

---

## Phase 2: Cache-Resident Morsel Actor Pipeline (`Morsel_Envelope` + `Envelope_Pool`)
Implements the pooled morsel pipeline using `sleipnir` work-stealing actors and `Sharded_SPSC_Mailbox` / MPSC batching.

- [x] Task: Write Unit Tests for Sleipnir Morsel Pipeline (`tests/sleipnir_pipeline_test.odin`)
    - [x] Test multi-stage morsel filter -> refine -> aggregate across `10M`-row arrays, null bitmaps, edge-case lengths, and multi-batch `Record_Batch` streams
    - [x] Verify persistent scheduler + pre-warmed `Envelope_Pool` reuse produces exact results and zero memory leaks after `actor.scoped_scheduler` / `actor.destroy`
    - [x] Verify tests fail before implementation (Red Phase)
- [x] Task: Implement Pooled Morsel Pipeline (`skadi/pipeline/` or `skadi/sleipnir_pipeline.odin`)
    - [x] Define L2-sized `Morsel_Work` and `Morsel_Subtotal` messages pooled via `actor.Envelope_Pool` (`u16` local morsel offsets `0..<65536` to halve index memory traffic vs `i32`)
    - [x] Implement worker actor behaviors for morsel predicate evaluation, secondary refinement, and subtotal aggregation
    - [x] Support batched message splicing (`Chain=K`) and `Sharded_SPSC_Mailbox` fast path alongside persistent `actor.Scheduler` lifecycle management
- [x] Task: Conductor - User Manual Verification 'Phase 2: Cache-Resident Morsel Actor Pipeline' (Protocol in workflow.md)

---

## Phase 3: Thread-Safe Allocation Telemetry & 1v1 Benchmark Evaluation
Ensures race-free allocation telemetry under multi-threaded actor runs and benchmarks the Sleipnir morsel pipeline against bulk-synchronous selection vectors and Apache Arrow C++.

- [x] Task: Harden `Counting_Allocator` for Multi-Threaded Actors (`benchmarks/odin/stats/bench_stats.odin`, `tests/bench_stats_test.odin`)
    - [x] Update `_counting_allocator_proc` in `benchmarks/odin/stats/bench_stats.odin` to update `Bench_Alloc_State` atomically (and CAS `trial_peak_live_bytes`) so multi-threaded actor allocations cannot race
    - [x] Add multi-threaded `Counting_Allocator` unit test in `tests/bench_stats_test.odin`
- [x] Task: Add Sleipnir Pipeline Benchmarks to `benchmarks/odin/bench_main.odin`
    - [x] Initialize persistent `actor.Scheduler` and pre-warmed `actor.Envelope_Pool` slabs outside the timed `bench_accum_start`/`stop` loop so trials measure steady-state execution (`0` per-morsel heap allocs)
    - [x] Register `sel_2pred_sum_10m_f64_actor` (and multi-batch streaming pipeline benchmark) in `benchmarks/odin/bench_main.odin`
    - [x] Run `python3 benchmarks/compare_1v1.py --compare-last` and update `benchmarks/RESULTS.md` with throughput (`GB/s`), allocation telemetry (`Allocs`, `Alloc MB`), and speedup analysis
- [x] Task: Conductor - User Manual Verification 'Phase 3: Thread-Safe Telemetry & 1v1 Benchmark Evaluation' (Protocol in workflow.md)
