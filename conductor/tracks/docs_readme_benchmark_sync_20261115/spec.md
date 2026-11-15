# Specification: Sync `README.md` & `RESULTS.md` Narrative with Latest Kernels, Encodings & 1v1 Benchmarks

## Overview
After completing the performance, hardware-adaptive morsel, Sleipnir actor pipeline, radix sort, Umbra, and IPC optimizations, `README.md` still displays outdated single-threaded timings (e.g., `Sort indices 1M i32` at `32.42 ms` instead of `14.85 ms`, `Take` at `8.97 ms` instead of `7.36 ms`) and lacks documentation of newer subsystems (`Umbra_Array`, `RLE_Array`, `Dict_Array`, `skadi/hardware_config.odin`, `skadi/pipeline/sleipnir_pipeline.odin`, and the `make bench-1v1` statistical comparison harness).

Additionally, the top narrative sections in `benchmarks/RESULTS.md` still cite older trial numbers from earlier iterations rather than the latest `BENCHMARK_1V1` table at the bottom.

---

## Functional Requirements

### 1. Update `README.md` Capabilities, Project Layout & Benchmark Summary
- Sync `README.md` benchmark numbers with the final `benchmarks/RESULTS.md` 1v1 measurements (`--from-jsonl --update-readme` or aligned summary table).
- Document `Umbra_Array`, `RLE_Array`, `Dict_Array`, `Selection`, hardware cache-adaptive configuration (`skadi/hardware_config.odin`), the Sleipnir actor pipeline (`skadi/pipeline/`), and `make bench-1v1` in `Highlights`, `Capabilities`, and `Project layout`.

### 2. Reconcile `benchmarks/RESULTS.md` Narrative
- Align the top-half analysis sections (`benchmarks/RESULTS.md`) with the current `BENCHMARK_1V1` table, hardware environment (Arrow C++ `25.0.1`, `-microarch:native`), and actor benchmark results.

### 3. Documentation & Formatting Guardrails
- Follow Markdown & GitHub MathJax formatting rules strictly: always use inline code spans (e.g., `` `duration_ns / 1e6` ``, `` `0 B` ``, `` `O(1)` ``) rather than `$...$` or `$$...$$` LaTeX math blocks for identifiers, units, and formulas.
- Ensure every referenced file path and symbol name matches verified files and outputs in the repository.

---

## Non-Functional Requirements
- Zero broken internal links in `README.md` and `benchmarks/RESULTS.md`.
- Every cited benchmark metric must come directly from `benchmarks/odin.jsonl`, `benchmarks/cpp.jsonl`, or `benchmarks/compare_1v1.py` output.

---

## Acceptance Criteria
- [ ] `README.md` reflects current benchmark timings, new encoding/pipeline modules, and `make bench-1v1` reproduction instructions.
- [ ] `benchmarks/RESULTS.md` narrative sections contain no stale contradictory timings relative to `BENCHMARK_1V1`.
- [ ] No `$...$` or `$$...$$` math blocks contain underscored identifiers in `README.md` or `benchmarks/RESULTS.md`.
- [ ] `examples/quickstart` and `make test` still build and pass cleanly.

---

## Out of Scope
- Adding new compute kernels or altering benchmark workload definitions.
