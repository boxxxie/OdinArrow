# Implementation Plan: Statistical JSONL Benchmark Suite & 1v1 Comparator

## Phase 1: Odin Statistical Benchmark Harness (`benchmarks/odin/`)
Implements the `xitdb`-style statistical harness in Odin with grouped execution, warmup passes, quantile/variance calculation, and rank-preserving JSONL output.

- [x] Task: Design & Implement Statistical Harness (`benchmarks/odin/harness.odin` & `benchmarks/odin/stats/bench_stats.odin`)
    - [x] Add unit tests in `tests/bench_stats_test.odin` covering percentile/IQR/stddev math, Git commit resolution, CLI flag parsing, and selective JSONL rank merging
    - [x] Implement CLI argument parser (`--runs`, `--warmup`, `--n`, `--commit`, `--run-id`, `--append`, `--no-history`, `--output`, `--history`, `--groups`, `--filter`, `--lang`, `--legacy`) and `.git/HEAD` / `packed-refs` SHA resolver
    - [x] Implement `run_group`, `print_result`, `flush_group_results`, and statistical calculations (`median`, `mean`, `stddev`, `variance`, `cv_pct`, `iqr`, `p95`, `p99`, `ops_per_sec`) preserving sub-nanosecond precision
    - [x] Implement JSONL serialization to `benchmarks/odin.jsonl` (with rank-preserving selective merge) and append-only `benchmarks/history.jsonl`
- [x] Task: Port Core Benchmarks & Add ST/MT Compute Variants (`benchmarks/odin/bench_main.odin`)
    - [x] Register benchmark groups: `builders` (`array_build_10m_i32`), `compute` (`_st` and `_mt` for `sum_10m_f64`, `sum_10m_f64_nulls`, `sum_10m_i32`, `min_max_10m_i32`, `filter_10m_i32`), `strings` (`string_build_1m`, `string_scan_1m`), and `ipc` (`ipc_roundtrip_10m_i32`), plus extended parity groups (`fusion`, `encoding`, `nulls`, `simd`, `parquet_csv`)
    - [x] Verify zero leaks across repeated warmup and trial iterations and clean compilation under `-vet -strict-style -disallow-do` and `-o:speed -microarch:native`
- [x] Task: Conductor - User Manual Verification 'Phase 1: Odin Statistical Benchmark Harness' (Protocol in workflow.md)

---

## Phase 2: Arrow C++ Statistical Benchmark Harness (`benchmarks/cpp/`)
Upgrades the standalone Apache Arrow C++ benchmark binary to match the Odin harness CLI, warmup/trial accumulation, statistics, and JSONL schema.

- [x] Task: Upgrade Arrow C++ Harness (`benchmarks/cpp/bench_arrow_main.cpp`)
    - [x] Implement CLI parsing matching the Odin harness (`--runs`, `--warmup`, `--n`, `--commit`, `--run-id`, `--append`, `--no-history`, `--output`, `--history`, `--groups`, `--filter`, `--lang`, `--legacy`) and Git commit resolution
    - [x] Implement `run_group` / `BenchContext::record` warmup + trial collection, quantile/variance math, and aligned benchmark names (`builders`, `compute`, `strings`, `ipc`, `fusion`, `encoding`, `nulls`, `simd`)
    - [x] Implement rank-preserving `benchmarks/cpp.jsonl` writer and `benchmarks/history.jsonl` appender matching Odin's JSONL schema
- [x] Task: Build & Verify Arrow C++ JSONL Output
    - [x] Compile `bin/bench_arrow_cpp` via `make bin/bench_arrow_cpp` (`pkg-config` Arrow detection with PyArrow fallback) and verify full and selective (`--groups`, `--filter`) JSONL output
- [x] Task: Conductor - User Manual Verification 'Phase 2: Arrow C++ Statistical Benchmark Harness' (Protocol in workflow.md)

---

## Phase 3: Multi-Run Comparator, Regression Analyzer & Makefile Integration
Brings in the Python statistical aggregator/comparator for Odin ST vs Arrow C++ ST (+ Odin MT scaling) and commit-vs-commit regression detection.

- [x] Task: Implement `benchmarks/compare_1v1.py`
    - [x] Write Python unit tests (`benchmarks/test_compare_1v1.py`) verifying multi-run `samples_ns` pooling, quantile/variance stats, Welch's *z*-score calculation, ST/MT pairing, and `--compare-commits` / `--list-commits` / `--inspect`
    - [x] Implement runner orchestration (Odin `-o:speed -microarch:native` and `bin/bench_arrow_cpp`), `--from-jsonl`, `--pool`, and `--lang {odin,cpp,both}` filtering
    - [x] Implement 1v1 comparison table (Odin ST vs Arrow C++ ST with Welch's *z* significance, plus Odin MT column/summary) and commit regression analyzer (`--compare-commits`, `--list-commits`, `--inspect`)
- [x] Task: Integrate `Makefile` Targets & Verify End-to-End Flow
    - [x] Update `Makefile` with `bench-1v1` target and update `benchmarks/compare.sh` to pass `--legacy --no-history`
    - [x] Run end-to-end verification (`make bench-1v1`, `--from-jsonl`, `--list-commits`, `--inspect`, `python3 -m unittest benchmarks/test_compare_1v1.py`, and `odin test tests/`)
- [x] Task: Conductor - User Manual Verification 'Phase 3: Multi-Run Comparator, Regression Analyzer & Makefile Integration' (Protocol in workflow.md)

---

## Phase 4: Allocation Telemetry, Memory Bandwidth (`GB/s`) & Session Diffing
Extends the harness and comparator with actual per-trial allocation/pool tracking, effective memory bandwidth (`GB/s`), session-to-session comparison (`--compare-runs`, `--compare-last`), inline `Δ Prev`, and automated `benchmarks/RESULTS.md` syncing.

- [x] Task: Add Odin `Counting_Allocator`, `Buffer_Pool` Hit/Miss Counters & `mem.free_with_size` (`skadi/buffer.odin`, `skadi/buffer_pool.odin`, `benchmarks/odin/`)
    - [x] Update `buffer_free` (`skadi/buffer.odin`) to call `mem.free_with_size` and add `hits` / `misses` counters to `Buffer_Pool` (`skadi/buffer_pool.odin`) with unit tests in `tests/buffer_pool_test.odin`
    - [x] Implement `Bench_Alloc_State`, `Counting_Allocator_Data`, `counting_allocator`, and `gb_per_sec` in `benchmarks/odin/stats/bench_stats.odin` with unit tests in `tests/bench_stats_test.odin`
    - [x] Sample allocation & `Buffer_Pool` hit/miss deltas per trial in `benchmarks/odin/harness.odin` and wire `counting_allocator` into `benchmarks/odin/bench_main.odin`
- [x] Task: Add Arrow C++ `MemoryPool` Telemetry & `gb_per_sec` (`benchmarks/cpp/bench_arrow_main.cpp`)
    - [x] Sample `arrow::default_memory_pool()` (`num_allocations()`, `total_bytes_allocated()`, `bytes_allocated()`) around each trial and emit allocation + `gb_per_sec` JSONL fields
- [x] Task: Extend `benchmarks/compare_1v1.py` with `GB/s`, Allocation Columns, `--compare-last` / `--compare-runs` & `--update-readme`
    - [x] Add `gb_per_sec`, `resolve_previous_odin_records`, `Δ Prev`, `Odin GB/s`, `C++ GB/s`, `Allocs (Odin/C++)`, `Alloc MB (Odin/C++)`, `--list-runs`, `--compare-runs`, `--compare-last`, and `--update-readme`
    - [x] Add unit tests in `benchmarks/test_compare_1v1.py` and verify full 1v1 suite execution (`python3 benchmarks/compare_1v1.py --update-readme`) updating `benchmarks/RESULTS.md`
- [x] Task: Conductor - User Manual Verification 'Phase 4: Allocation Telemetry, Bandwidth & Session Diffing' (Protocol in workflow.md)
