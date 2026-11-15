# Product Guidelines: Skadi

## Engineering & API Principles
- **Explicit Memory Ownership:** Every allocation, buffer, builder, array, schema, and record batch must have clear ownership semantics, explicit `allocator := context.allocator` parameters where appropriate, and deterministic `*_destroy` / `*_free` procedures.
- **Zero-Overhead & Zero-Copy First:** Prefer tagged unions over vtables, raw aligned buffers, and zero-copy views/slices over defensive copies.
- **Strict Static Hygiene:** All Odin packages must pass `odin check` with `-vet -strict-style -disallow-do -warnings-as-errors` (as configured in `ols.json` and `Makefile`).
- **Idiomatic Odin Package Conventions:** Follow standard Odin library organization, file naming, package naming, and error-return idioms (`(T, bool)` or explicit error enums).

## Documentation & Testing Standards
- **Concise Technical Prose:** Keep READMEs, doc comments, and benchmark reports direct, factual, and reproducible.
- **Arrow Spec Fidelity & Interop:** Validate binary/IPC compatibility against Apache Arrow C++ and PyArrow, and document any deviations or supported subsets clearly.
- **Performance Accountability:** Benchmark changes against single-threaded Apache Arrow C++ and PyArrow using reproducible scripts and median-of-N timings.
