# Implementation Plan: Hardware-Aware Execution Config & Cache-Adaptive Morsel Sizing

## Phase 1: Runtime Hardware Topology & Cache Discovery (`skadi/hardware_config.odin`)
Detects physical vs logical CPU cores (multi-socket aware) and L1d/L2/L3 cache sizes (filtering sysfs cache `level` + `type`) with deterministic overrides for testing.

- [x] Task: Write Unit Tests for `Hardware_Config` Detection & Overrides (`tests/hardware_config_test.odin`)
    - [x] Test sysfs size string parsing (`"32K"`, `"256K"`, `"6144K"`, `"6M"`), cache `level` + `type` matching (`Data` vs `Instruction` vs `Unified`), `(physical_package_id, core_id)` deduplication, default fallbacks, and `hardware_config_set` / `hardware_config_reset`
    - [x] Verify tests fail before implementation (Red Phase)
- [x] Task: Implement `skadi/hardware_config.odin`
    - [x] Implement zero-allocation sysfs reader for `/sys/devices/system/cpu/cpu0/cache/index*/{level,type,size}` and `/sys/devices/system/cpu/cpu*/topology/{physical_package_id,core_id}`
    - [x] Implement `hardware_config_get()`, `hardware_config_set()`, and `hardware_config_reset()` with `sync.Once` lazy initialization
    - [x] Display detected hardware profile in `benchmarks/odin/bench_main.odin` header output
- [x] Task: Conductor - User Manual Verification 'Phase 1: Runtime Hardware Topology & Cache Discovery' (Protocol in workflow.md)

---

## Phase 2: Pool Wakeup Hygiene, Byte-Budgeted Morsel Sizing & Physical-Core Thread Dispatch (`skadi/thread_pool.odin`, `skadi/compute_parallel.odin`)
Prevents spurious SMT thread wakeups in `_Compute_Pool` and adapts parallel kernel thread counts and morsel sizes to the detected cache hierarchy and per-row byte width.

- [x] Task: Write Unit Tests for Adaptive `_resolve_threads`, `_compute_morsels` & Pool Dispatch (`tests/compute_parallel_test.odin`)
    - [x] Test that `bytes_per_row` (`1`, `4`, `8`, `16`, `24`) and custom `Hardware_Config` L2/L3 sizes produce expected thread counts and 64-element-aligned morsel sizes
    - [x] Verify existing `compute_sum_parallel`, `compute_min_max_parallel`, `compute_filter_parallel`, and `compute_take_parallel` tests pass with `physical_cores` default
- [x] Task: Update `skadi/thread_pool.odin` & `skadi/compute_parallel.odin` to Use `Hardware_Config`
    - [x] Eliminate spurious wakeup of unused `w.id >= active_w` SMT worker threads in `skadi/thread_pool.odin` (per-worker signaling or physical-core pool sizing)
    - [x] Update `_resolve_threads` and `_compute_morsels` to take explicit `bytes_per_row` and default `num_threads == 0` to `hardware_config_get().physical_cores`
    - [x] Pass accurate `bytes_per_row` from `compute_sum_parallel`, `compute_min_max_parallel`, `compute_filter_parallel`, and `compute_take_parallel` (and any binary/cast parallel kernels)
    - [x] Benchmark `_mt` kernels via `python3 benchmarks/compare_1v1.py --groups compute --compare-last`
- [x] Task: Conductor - User Manual Verification 'Phase 2: Pool Wakeup Hygiene & Byte-Budgeted Morsel Sizing' (Protocol in workflow.md)

---

## Phase 3: L2-Resident Morsel Execution for Multi-Predicate Queries (`skadi/selection.odin`, `skadi/compare.odin`)
Executes multi-step selection pipelines in L2-sized morsels using a single reusable cache-resident index buffer instead of materializing full-column selection vectors in DRAM.

- [x] Task: Write Unit Tests for L2-Morsel Selection Pipeline (`tests/core_regressions_test.odin` or `tests/selection_test.odin`)
    - [x] Verify morsel-chunked multi-predicate selection (`select_compare -> refine_compare -> sum/min_max`) matches full-array results across all numeric types, null bitmaps, sliced offsets, and synthetic `Hardware_Config` morsel sizes
- [x] Task: Implement Cache-Resident Morsel Selection Execution (`skadi/compare.odin`, `skadi/selection.odin`)
    - [x] Implement reusable `Selection_Morsel_Scratch` / morsel-chunked multi-predicate execution sized to `hardware_config_get().morsel_target_bytes`
    - [x] Add parallel morsel-chunked variant (`_mt`) where each worker thread owns a single `~64 KB` L2-resident selection scratch buffer
    - [x] Benchmark `sel_2pred_sum_10m_f64` with `python3 benchmarks/compare_1v1.py --compare-last` and update `benchmarks/RESULTS.md`
- [x] Task: Conductor - User Manual Verification 'Phase 3: L2-Resident Morsel Execution for Multi-Predicate Queries' (Protocol in workflow.md)
