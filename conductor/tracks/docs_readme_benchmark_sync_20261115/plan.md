# Implementation Plan: Sync `README.md` & `RESULTS.md` Narrative with Latest Kernels, Encodings & 1v1 Benchmarks

## Phase 1: Update `README.md` (`README.md`)
Updates highlights, benchmarks, capabilities, and repository layout to match the implemented codebase.

- [x] Task: Refresh `README.md` Benchmark Table & Command Docs (`README.md`)
    - [x] Sync benchmark numbers with final `benchmarks/RESULTS.md` / `compare_1v1.py` output
    - [x] Document `make bench-1v1`, `Umbra_Array`, `RLE_Array`, `Dict_Array`, `skadi/hardware_config.odin`, and `skadi/pipeline/`
    - [x] Verify no underscored identifiers appear in `$...$` or `$$...$$` blocks

---

## Phase 2: Reconcile `benchmarks/RESULTS.md` & Validate (`benchmarks/RESULTS.md`)
Updates top-half narrative sections and verifies examples and docs links.

- [x] Task: Align `benchmarks/RESULTS.md` Narrative & Regenerate Summary (`benchmarks/RESULTS.md`)
    - [x] Reconcile environment header, legacy prose numbers, and actor pipeline takeaways with `BENCHMARK_1V1`
    - [x] Run `odin run examples/quickstart -out:/tmp/quickstart` and `make test` to verify documented commands work verbatim
