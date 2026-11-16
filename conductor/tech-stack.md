# Tech Stack: Skadi

## Core Language & Toolchain
- **Language**: [Odin](https://odin-lang.org/) (compiler version: `dev-2026-09:a2fb372b7`)
- **Backend**: LLVM 18+
- **Compiler Flags**:
  - Development / Testing: `make test` (`odin test tests -out:bin/test_runner -vet -strict-style -disallow-do -warnings-as-errors`)
  - Release / Optimized: `odin build skadi -collection:skadi=skadi -o:speed -microarch:native`
- **Build Harness**: `Makefile`, `roundtrip_test.sh`

## Standards & Wire Protocols
- **Apache Arrow Columnar Format**: Arrow C Data Interface memory layout, 64-byte aligned buffers, bit-packed validity bitmaps.
- **Arrow IPC (Feather v2)**: FlatBuffers metadata representation for Schema and RecordBatch; File and Streaming IPC wire protocols.
- **Apache Parquet**: Native CLI subset (`examples/`) supports Thrift Compact Protocol footers, uncompressed pages, RLE / bit-packed definition levels, and multi-page dictionary decoding; compressed Parquet (Snappy / Zstandard) runs through the Arrow C++ FFI shim (`benchmarks/`).
- **RFC 4180 CSV**: High-throughput streaming CSV parser with SIMD delimiter scanning and strict RFC 4180 quote validation.

## Core Packages & Dependencies
- `core:mem`: Memory allocators, tracking allocator (`mem.Tracking_Allocator`), aligned allocations (`mem.alloc_aligned`).
- `core:intrinsics`: Platform intrinsics for unaligned SIMD loads (`intrinsics.unaligned_load`), bit counting, and non-temporal streaming stores.
- `core:simd`: Explicit vector intrinsics for AVX2 / AVX-512 / NEON numeric compute loops.
- `core:sync`: Thread synchronization primitives, atomics, and worker thread pool for parallel compute execution.
- `core:os`: Zero-copy file descriptors, cross-platform memory mapping (`mmap`), file I/O.
- `core:testing`: Test runner and failure verification assertions.

## Directory Structure
- `skadi/`: Core Skadi library (25 files: array, bitmap, buffer, buffer_pool, builders, compute, compare, dict, fusion, hardware_config, ipc, record_batch, rle, schema, selection, table, thread_pool, types, umbra, var_length).
- `skadi/pipeline/`: Optional Sleipnir actor-driven morsel execution pipeline (`sleipnir_pipeline.odin`), isolating vendored actor dependencies from the zero-dependency core library.
- `deps/sleipnir/actor/`: Lock-free work-stealing actor runtime (`Envelope_Pool`, `mpsc_push_chain`, `Sharded_SPSC_Mailbox`).
- `examples/`:
  - `quickstart`: Runnable API + PyArrow IPC round-trip tour.
  - `parquet_to_csv`: Native Odin streaming Parquet-to-CSV CLI (`bin/parquet_to_csv_odin`).
  - `csv_to_parquet`: Native Odin streaming CSV-to-Parquet CLI (`bin/csv_to_parquet_odin`).
- `tests/`: Unit and regression test suite (224 tests across 17 files).
- `specs/`: 4-layer ATDD executable specifications (22 specs across domain-modularized DSL and driver files).
- `tests_cpp/`: Cross-language interop and IPC parity tests against Apache Arrow C++ (14 tests).
- `benchmarks/`: Statistical JSONL 1v1 benchmarks against Arrow C++ `25.0.1`, PyArrow runners, and `parquet_to_csv_ffi` / `csv_to_parquet_ffi` FFI comparison tools.
