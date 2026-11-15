# Specification: Sleipnir Actor Super-Morsel Fused Multi-Aggregates & Dictionary Group-By

## Overview
Currently, the Sleipnir super-morsel actor pipeline (`skadi/pipeline/sleipnir_pipeline.odin`) only accelerates two-predicate filtered sums (`pipeline_sel_2pred_sum_f64` / `pipeline_record_batch_stream_sum`, achieving `5.76 ms` / `41.6 GB/s` with `0` heap allocations). Two other high-value analytical operators still run single-threaded only:
1. Fused multi-aggregate filtering (`agg_where_10m_f64`: `sum`, `count`, `min`, `max` under a predicate in one pass).
2. Dictionary-encoded group-by aggregations (`str_dict_value_counts`, `str_dict_group_sum`, and `Dict_Array(T)` reductions).

Extending `Morsel_Pipeline` (or a sibling typed actor pipeline using the same `SUPER_MORSEL_MULTIPLIER` + `Envelope_Pool` + `Sharded_SPSC_Mailbox` architecture) enables lock-free parallel execution with `0` atomic contention via worker-private partial states and worker-private L1d-resident histogram tables.

---

## Functional Requirements

### 1. Fused Multi-Aggregate Actor Pipeline (`pipeline_agg_where_f64`)
- Execute fused `sum + count + min + max` over `col_val` where `col_pred <op> threshold` using super-morsel work envelopes stepped across L1d sub-morsels (`<= MORSEL_MAX_ROWS`).
- Support both null-free `Float64_Type` fast paths and nullable fallback paths, matching `compute_agg_where` (`skadi/compute_fused.odin`) bit-for-bit on `count`, `min`, `max`, and within floating-point associativity tolerance on `sum`.
- Return partial `Agg_Result` structs via `Sharded_SPSC_Mailbox` and merge final `min`, `max`, `sum`, and `count` on the coordinator with `0` steady-state heap allocations.

### 2. Worker-Private Histogram Actor Pipeline for Dictionary Group-By (`pipeline_dict_value_counts`, `pipeline_dict_group_sum`)
- Support `String_Dict_Array` and numeric `Dict_Array(T)` inputs by dispatching super-morsels of `codes` (and corresponding `values` for `group_sum`) to Sleipnir worker actors.
- Pre-allocate worker-private L1d-resident count/sum tables (`n_dict` entries, dynamically sized or pooled before trials) so workers never contend on shared atomic counters.
- Emit worker-private partial histograms (or range-sliced summaries) via `Sharded_SPSC_Mailbox` for coordinator reduction, including null-code tracking.

### 3. Benchmark & Verification Wiring (`benchmarks/odin/bench_main.odin`, `benchmarks/compare_1v1.py`, `benchmarks/RESULTS.md`)
- Register `agg_where_10m_f64_actor` and `dict_vc_1m_str_actor` in `benchmarks/odin/bench_main.odin` and wire into `benchmarks/compare_1v1.py`.

---

## Non-Functional Requirements
- **Zero Atomic Histogram Contention:** Dictionary workers accumulate strictly into thread/actor-local tables before final coordinator merge.
- **Zero Steady-State Allocations:** Pre-warmed envelope pools and reusable worker tables yield `0` heap allocations inside timed benchmark loops.
- **Compiler & Test Hygiene:** Pass `odin check` (`-vet -strict-style -disallow-do -warnings-as-errors`) and `odin test tests` with `0` memory leaks.

---

## Acceptance Criteria
- [ ] `pipeline_agg_where_f64` matches `compute_agg_where` across all `Compare_Op` variants, empty matches, all-null inputs, and sliced arrays.
- [ ] `pipeline_dict_value_counts` and `pipeline_dict_group_sum` match `str_dict_value_counts` and `str_dict_group_sum` exactly across varying dictionary cardinalities and nullable codes/values.
- [ ] `agg_where_10m_f64_actor` and `dict_vc_1m_str_actor` are wired in `benchmarks/odin/bench_main.odin` / `benchmarks/compare_1v1.py` and recorded in `benchmarks/RESULTS.md`.
- [ ] All compiler checks and unit tests pass with zero warnings and zero memory leaks.

---

## Out of Scope
- General hash-join or unbounded high-cardinality open-addressing hash tables inside worker actors.
