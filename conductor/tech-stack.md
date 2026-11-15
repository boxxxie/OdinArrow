# Tech Stack: Skadi

## Core Language & Toolchain
- **Language:** [Odin](https://odin-lang.org/) (`-vet -strict-style -disallow-do -warnings-as-errors`)
- **Language Server / Formatter:** `ols` (`ols.json` with `enable_format: true`, `checker_args` matching `Makefile`)
- **Build & Task Runner:** GNU Make (`Makefile`)

## Core Architecture & Dependencies
- **Core Library (`skadi/`, `package skadi`):** Pure Odin standard library (`core:*` — `core:mem`, `core:simd`, `core:sync`, `core:sys/posix`, `core:os`, etc.), zero external runtime dependencies.
- **Testing:** Built-in `odin test` (`tests/` `*_test.odin` unit tests, `tests_cpp/` FFI interop tests).

## Interoperability & Benchmarking (Dev / Test / Optional FFI)
- **C++ / Arrow C++:** `g++` (`-std=c++20 -O3`) linking `libarrow` / `libparquet` (via `pkg-config` or bundled `pyarrow` libraries) for `lib/libarrow_capi.so` and C++ benchmarks.
- **Python:** Python 3 + `pyarrow` for cross-validation (`roundtrip_test.sh`) and 3-way benchmarks (`benchmarks/`).
