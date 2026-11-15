# Specification: Statistical JSONL Benchmark Suite & 1v1 Comparator (xitdb-style)

## Overview
Adopt the statistical JSONL benchmark harness and multi-run regression analyzer pattern from `xitdb` into `Skadi`, covering **Skadi** ([`benchmarks/odin/`](file:///home/pauli/projects/odin/OdinArrow/benchmarks/odin) -> `benchmarks/odin.jsonl`) and **Apache Arrow C++** ([`benchmarks/cpp/`](file:///home/pauli/projects/odin/OdinArrow/benchmarks/cpp) -> `benchmarks/cpp.jsonl`), with an append-only multi-commit history (`benchmarks/history.jsonl`) and a Python comparator (`benchmarks/compare_1v1.py`).

Both Single-Threaded (`_st`) and Multi-Threaded (`_mt`) Odin compute kernels are benchmarked explicitly so Odin ST compares apples-to-apples against Arrow C++ ST while Odin MT tracks parallel scaling.

---

## Functional Requirements

### 1. Odin Statistical Benchmark Harness (`benchmarks/odin/`)
- **Grouped Benchmark Registry**:
  - Port core benchmarks into selectable groups: `builders`, `compute`, `strings`, `ipc`, plus extended parity groups (`fusion`, `encoding`, `nulls`, `simd`, `parquet_csv`).
  - Support extensible group registration (`run_group`) for adding future groups.
- **CLI Contract**:
  - Support `--runs N` (default `5`), `--warmup N` (default `1`), `--commit SHA` (auto-resolved from `.git/HEAD` / `.git/packed-refs`), `--run-id ID`, `--append`, `--no-history`, `--output PATH` (default `benchmarks/odin.jsonl`), `--history PATH` (default `benchmarks/history.jsonl`), `--groups LIST`, `--filter SUBSTR`, `--lang NAME`, and `--legacy`.
- **Statistical Computation, Allocation Telemetry & JSONL Output**:
  - Execute warmup passes before measured trials (`Bench_Accum`) with `free_all(context.temp_allocator)` between trials and proper array/builder cleanup outside timed regions.
  - Wrap `g_alloc` / `context.allocator` in `Counting_Allocator` (`Bench_Alloc_State`) and track `Buffer_Pool.hits` / `Buffer_Pool.misses` per trial to record `allocs_per_run`, `resizes_per_run`, `alloc_bytes_per_run`, `peak_live_bytes`, `pool_hits`, and `pool_misses`.
  - Compute `total_ms` (median ms), `median_ns`, `mean_ns`, `stddev_ns`, `variance_ns2`, `cv_pct`, `min_ns`, `max_ns`, `iqr_ns`, `p95_ns`, `p99_ns`, `ops_per_sec` (elements/sec), `gb_per_sec` (`bytes_used / (median_ns * ops)`), and `bytes_used`.
  - Preserve full-precision `samples_ns` so sub-nanosecond-per-element SIMD kernels never suffer integer rounding to `0 ns/op`.
  - Support selective execution (`--groups` / `--filter`) updating only matching `rank` slots in `benchmarks/odin.jsonl` while preserving untouched ranks, and append every record to `benchmarks/history.jsonl` unless `--no-history` is specified.

### 2. Arrow C++ Statistical Benchmark Harness (`benchmarks/cpp/bench_arrow_main.cpp`)
- **CLI & Group Parity**:
  - Accept the same CLI flags (`--runs`, `--warmup`, `--n`, `--commit`, `--run-id`, `--append`, `--no-history`, `--output`, `--history`, `--groups`, `--filter`, `--lang`, `--legacy`).
  - Group workloads identically (`builders`, `compute`, `strings`, `ipc`, plus `fusion`, `encoding`, `nulls`, `simd`) with warmup + measured trials.
- **MemoryPool Telemetry & JSONL Parity**:
  - Sample `arrow::default_memory_pool()` (`num_allocations()`, `total_bytes_allocated()`, `bytes_allocated()`) around each measured trial to emit `allocs_per_run`, `alloc_bytes_per_run`, `peak_live_bytes`, and `gb_per_sec` alongside statistical timing metrics.
  - Write compatible JSONL records to `benchmarks/cpp.jsonl` (with rank-preserving selective updates) and `benchmarks/history.jsonl`.

### 3. Multi-Run Aggregator, Session Diffing & Regression Analyzer (`benchmarks/compare_1v1.py`)
- **Execution & Loading**:
  - Build and invoke the Odin (`-o:speed -microarch:native`) and Arrow C++ (`-O3`) benchmark binaries sharing a unified `run_id`, or analyze existing snapshots via `--from-jsonl`.
  - Forward `--runs`, `--warmup`, `--n`, `--commit`, `--run-id`, `--append`, `--no-history`, `--groups`, `--filter`, and `--lang {odin,cpp,both}` to runners.
- **Multi-Run Pooling, Telemetry & Significance Testing**:
  - Pool raw `samples_ns` across multiple run sessions matching `(commit, lang, name)` and recompute unified variance statistics (`mean`, `median`, `stddev`, `variance`, `cv_pct`, `iqr`, `p95`, `p99`, `ops_per_sec`, `gb_per_sec`) plus pooled allocation telemetry.
  - Render 1v1 comparison tables (Odin ST vs Arrow C++ ST) with Welch's *z*-test significance (`*` for `z >= 1.96`, `~` otherwise), plus `Δ Prev`, `Odin GB/s`, `C++ GB/s`, `Allocs (Odin/C++)`, `Alloc MB (Odin/C++)`, and Odin MT throughput / scaling columns.
  - Support `--markdown` and `--update-readme` to keep `benchmarks/RESULTS.md` synchronized cleanly.
- **History, Session & Commit Regression Tooling**:
  - `--list-commits`: list all commits, run IDs, languages, and pooled sample counts in `benchmarks/history.jsonl`.
  - `--list-runs`: list sessions (`run_id`) chronologically from `benchmarks/history.jsonl`.
  - `--inspect PATTERN`: inspect per-run distributions, quantiles, and raw samples for matching benchmarks.
  - `--compare-commits SHA_A SHA_B`: compare benchmark distributions between two Git commit SHAs using Welch's *z*-test to flag statistically significant speedups or regressions.
  - `--compare-runs RUN_A RUN_B` & `--compare-last`: diff individual benchmark sessions (even on the same uncommitted HEAD SHA) using Welch's *z*-test.

### 4. Build Integration (`Makefile`)
- Add a `bench-1v1` target invoking `benchmarks/compare_1v1.py` and keep existing `bench-odin`, `bench-arrow-cpp`, `bench-python`, and `bench-compare` targets functional.

---

## Non-Functional Requirements
- **Compiler Hygiene**: All Odin benchmark files must compile cleanly with `-vet -strict-style -disallow-do` (and `-o:speed -microarch:native`).
- **Memory Safety**: Zero memory leaks across repeated warmup and trial runs (`Buffer_Pool` reuse, `mem.free_with_size`, and explicit frees).
- **Sub-Nanosecond Precision**: Per-element latency and `samples_ns` must preserve fractional precision for multi-million-element SIMD kernels.

---

## Acceptance Criteria
- [x] `odin run benchmarks/odin -o:speed -microarch:native` runs warmup + 5 trials, prints a statistical summary table, and writes valid JSONL with timing & allocation telemetry to `benchmarks/odin.jsonl` and `benchmarks/history.jsonl`.
- [x] `bin/bench_arrow_cpp` accepts matching CLI flags and writes valid JSONL with timing & `MemoryPool` telemetry to `benchmarks/cpp.jsonl` and `benchmarks/history.jsonl`.
- [x] Selective `--groups` and `--filter` runs update only matched ranks and preserve untouched ranks in `odin.jsonl` / `cpp.jsonl`.
- [x] `python3 benchmarks/compare_1v1.py` runs both suites, pools samples, prints 1v1 statistical comparisons (`Δ Prev`, `GB/s`, `Allocs`, `Alloc MB`, MT scaling, Welch's *z*), updates `benchmarks/RESULTS.md`, and passes `--compare-commits`, `--compare-runs`, `--compare-last`, `--list-commits`, `--list-runs`, and `--inspect` checks.
- [x] All existing tests (`odin test tests -collection:skadi=skadi -vet-strict-style -disallow-do`) continue to pass.

---

## Out of Scope
- PyArrow JSONL emission and Parquet/CSV CLI JSONL integration (deferred to a follow-up track).
- Code-change-to-benchmark `--plan` / `--affected` diff mapping and per-benchmark code slice generation (`--generate-slices`).
