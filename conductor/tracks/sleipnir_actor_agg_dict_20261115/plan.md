# Implementation Plan: Sleipnir Actor Super-Morsel Fused Multi-Aggregates & Dictionary Group-By

## Phase 1: Fused Multi-Aggregate Actor Pipeline (`skadi/pipeline/sleipnir_pipeline.odin`, `tests/sleipnir_pipeline_test.odin`)
Extends the Sleipnir super-morsel pipeline to execute `sum`, `count`, `min`, and `max` under a predicate in one parallel actor pass.

- [x] Task: Add Unit Tests for `pipeline_agg_where_f64` (`tests/sleipnir_pipeline_test.odin`)
    - [x] Verify exact parity with `compute_agg_where` across `<`, `<=`, `>`, `>=`, `==`, `!=`, zero-match predicates, sliced inputs, and nullable inputs
- [x] Task: Implement `pipeline_agg_where_f64` (`skadi/pipeline/sleipnir_pipeline.odin`)
    - [x] Add fused super-morsel work/subtotal payloads for `sum`/`count`/`min`/`max`
    - [x] Step L1d sub-morsels inside worker actors and merge `min`/`max`/`sum`/`count` via `Sharded_SPSC_Mailbox`
    - [x] Verify Phase 1 tests pass with 0 leaks

---

## Phase 2: Worker-Private Histogram Actor Pipeline for Dictionary Group-By (`skadi/pipeline/sleipnir_pipeline.odin`, `skadi/dict.odin`, `tests/sleipnir_pipeline_test.odin`)
Adds parallel actor execution for `str_dict_value_counts` and `str_dict_group_sum` using contention-free worker-private tables.

- [x] Task: Add Unit Tests for Dictionary Actor Group-By (`tests/sleipnir_pipeline_test.odin`, `tests/dict_test.odin`)
    - [x] Verify exact counts, null counts, and grouped sums across small/medium cardinalities, sliced arrays, and nullable values
- [x] Task: Implement `pipeline_dict_value_counts` & `pipeline_dict_group_sum` (`skadi/pipeline/sleipnir_pipeline.odin`)
    - [x] Allocate/reuse per-worker scratch count/sum buffers sized to dictionary cardinality
    - [x] Reduce per-worker partial histograms into final counts/sums via `Sharded_SPSC_Mailbox`
    - [x] Verify Phase 2 tests pass with 0 leaks

---

## Phase 3: 1v1 Benchmark Wiring & Verification (`benchmarks/odin/bench_main.odin`, `benchmarks/compare_1v1.py`, `benchmarks/RESULTS.md`)
Benchmarks `agg_where_10m_f64_actor` and `dict_vc_1m_str_actor` against Odin ST and Arrow C++.

- [x] Task: Register Benchmarks & Verify Full Suite (`benchmarks/odin/bench_main.odin`, `benchmarks/compare_1v1.py`, `benchmarks/RESULTS.md`)
    - [x] Add `agg_where_10m_f64_actor` and `dict_vc_1m_str_actor` benchmark entries
    - [x] Run `odin check` (`-vet -strict-style -disallow-do -warnings-as-errors`) on `skadi`, `skadi/pipeline`, `benchmarks/odin`, and run `odin test tests`
    - [x] Run `python3 benchmarks/compare_1v1.py --compare-last` and update `benchmarks/RESULTS.md`
