# Specification: Sleipnir Actor & Sharded SPSC Cache-Resident Morsel Pipeline

## Overview
While single-operator reductions (`sum_10m_f64_mt`) are bound by physical DDR4 memory bandwidth (`~35–43 GB/s`), multi-stage analytical pipelines (`Scan/Predicate 1 -> Predicate 2 -> Projection -> Aggregation` and streaming multi-batch IPC/Parquet pipelines) suffer when executed bulk-synchronously or behind `_Compute_Pool`'s global `p.submit` mutex:
1. Full-column intermediate vectors spill out of L2/L3 cache to DRAM between stages.
2. `_Compute_Pool` only permits one active parallel job across the entire process (`p.submit` mutex).

This track integrates `sleipnir` (`package actor` from `/home/pauli/projects/odin/sleipnir`) as an optional/vendored actor pipeline layer (`skadi/pipeline/` or `examples/` + `benchmarks/`) that streams L2-cache-sized morsels (`16K–32K` rows) through lock-free `Envelope_Pool` slabs and `Sharded_SPSC_Mailbox` / work-stealing `Scheduler` actors.

---

## Functional Requirements

### 1. Zero-Dependency Core + Sleipnir Package Integration & `-disallow-do` Compliance
- Keep `skadi/` (`package skadi`) zero-dependency by placing or linking `sleipnir/actor` under an isolated package directory (e.g., `deps/sleipnir/actor` or `-collection:actor=../sleipnir/actor`) used by the pipeline module (`skadi/pipeline` or `benchmarks/odin`).
- Resolve all **22 `do` statements** in `sleipnir/actor` (`pool.odin` lines 119, 172, 193; `actor.odin` lines 281, 299, 356, 369, 410, 421, 511, 655, 857, 898, 940, 941, 1123, 1136, 1171, 1182, 1444, 1478, 1481) into `{ ... }` blocks so `odin check ... -no-entry-point -vet -strict-style -disallow-do` passes with 0 errors.
- Exclude `deps/**` in `.gdumpignore` (if bundled inside the repo) and document the `sleipnir` integration in `conductor/tech-stack.md`.

### 2. Pooled Morsel Envelopes & Multi-Stage Actor Pipeline
- Define a cache-sized `Morsel_Envelope` (`16,384` rows max, or configurable via `Hardware_Config.morsel_target_bytes`) backed by `actor.Envelope_Pool` so morsel selection indices (`[]u16` local offsets `0..<65536` to halve index traffic vs `i32`) are recycled without heap allocation or GC.
- Implement a push-based multi-stage actor pipeline:
  - **Stage 1 (`Filter / Scan Workers`):** Evaluates Predicate 1 on a morsel (`[from:to]`), populates the envelope's compact selection vector, and forwards surviving morsels (or refines Predicate 2 inline/staged).
  - **Stage 2 (`Refine / Project / Compute Workers`):** Refines secondary predicates or computes derived expressions over the L2-hot morsel.
  - **Stage 3 (`Aggregator Actor`):** Accumulates per-morsel partial sums, min/max, and counts via Vyukov MPSC (`Chain=K` batched splicing) or `Sharded_SPSC_Mailbox` and replies on completion.

### 3. Persistent Scheduler Lifecycle, Thread-Safe Telemetry & 1v1 Benchmark Evaluation
- Initialize `actor.Scheduler` and pre-warmed `actor.Envelope_Pool` slabs **outside** per-trial timed regions (`bench_accum_start` / `bench_accum_stop`), matching `_Compute_Pool` and `Buffer_Pool`, so trials measure steady-state morsel execution (`0` per-trial heap allocations) rather than OS thread spawn/teardown overhead.
- Ensure `Counting_Allocator_Data` / `Bench_Alloc_State` (`benchmarks/odin/stats/bench_stats.odin`) is safe under multi-threaded actor benchmarks (atomic increments for `alloc_count`, `resize_count`, `bytes_allocated`, `trial_live_bytes`, and CAS update for `trial_peak_live_bytes`, or keeping worker envelope slabs on the backing heap allocator).
- Support concurrent multi-`Record_Batch` / IPC chunk ingestion where multiple batches flow through the actor pipeline simultaneously without blocking on a single global mutex.
- Register pipeline benchmarks in `benchmarks/odin/bench_main.odin` comparing:
  1. Pass-by-pass bulk selection (`sel_2pred_sum_10m_f64`)
  2. Sleipnir actor / sharded SPSC morsel pipeline
  3. Apache Arrow C++

---

## Non-Functional Requirements
- **Zero Per-Morsel Heap Allocations in Steady State**: All morsel messages must be served from pre-warmed `actor.Envelope_Pool` slabs (`0.0 MB` steady-state heap allocation).
- **Compiler & Test Hygiene**: Must compile cleanly with `-vet -strict-style -disallow-do` and pass leak-checked tests.

---

## Acceptance Criteria
- [ ] `odin check deps/sleipnir/actor -no-entry-point -vet -strict-style -disallow-do` (or upstream `../sleipnir/actor`) passes with 0 errors.
- [ ] `sleipnir` actor pipeline executes multi-predicate filter + aggregate and streaming `Record_Batch` workloads with exact numerical parity against single-threaded reference kernels.
- [ ] Steady-state execution performs `0` heap allocations per morsel via `actor.Envelope_Pool` (with persistent `Scheduler` + slabs initialized outside timed trials).
- [ ] Multi-threaded `Counting_Allocator` telemetry remains race-free when actors allocate/free across worker threads.
- [ ] Benchmark comparison in `benchmarks/compare_1v1.py` quantifies throughput (`GB/s`), allocation reduction (`Alloc MB`), and latency vs bulk pass-by-pass execution and Arrow C++.
- [ ] All unit and integration tests pass with zero memory leaks.

---

## Out of Scope
- Replacing `_Compute_Pool` for simple single-pass array reductions (`compute_sum_parallel`, `compute_min_max_parallel`) where a single barrier is already optimal.
