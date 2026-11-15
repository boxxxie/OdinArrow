# Tech Stack: Skadi

## Core Language & Toolchain
- **Language**: [Odin](https://odin-lang.org/) (compiler version: `dev-2026-09:a2fb372b7`)
- **Backend**: LLVM 18+
- **Compiler Flags**:
  - Development / Testing: `odin test tests -collection:skadi=skadi -vet-strict-style -disallow-do`
  - Release / Optimized: `odin build src -collection:skadi=skadi -O:Speed -microarch:native`
- **Build Harness**: `Makefile`, `roundtrip_test.sh`

## Standards & Wire Protocols
- **Apache Arrow Columnar Format**: Arrow C Data Interface memory layout, 64-byte aligned buffers, bit-packed validity bitmaps.
- **Arrow IPC (Feather v2)**: FlatBuffers metadata representation for Schema, RecordBatch, and DictionaryBatch; File and Streaming IPC wire protocols.
- **Apache Parquet**: Thrift Compact Protocol footer decoder, Snappy / Zstandard compression codec decompression, RLE / bit-packed definition level streams, dictionary encoding.
- **RFC 4180 CSV**: High-throughput streaming CSV parser with delimiter refill buffering and RFC 4180 quote escaping.

## Core Packages & Dependencies
- `core:mem`: Memory allocators, tracking allocator (`mem.Tracking_Allocator`), aligned allocations (`mem.alloc_aligned`).
- `core:intrinsics`: Platform intrinsics for unaligned SIMD loads (`intrinsics.unaligned_load`), bit counting, and non-temporal streaming stores.
- `core:simd`: Explicit vector intrinsics for AVX2 / AVX-512 / NEON numeric compute loops.
- `core:sync`: Thread synchronization primitives, atomics, and worker thread pool for parallel compute execution.
- `core:os`: Zero-copy file descriptors, cross-platform memory mapping (`mmap`), file I/O.
- `core:testing`: Test runner and failure verification assertions.

## Directory Structure
- `skadi/`: Core Skadi library (array, bitmap, buffer, builders, compute, compare, dict, rle, ipc, record_batch, schema, table, hardware_config).
- `skadi/pipeline/`: Optional Sleipnir actor-driven morsel execution pipeline (`sleipnir_pipeline.odin`), isolating vendored actor dependencies from the zero-dependency core library.
- `deps/sleipnir/actor/`: Lock-free work-stealing actor runtime (`Envelope_Pool`, `mpsc_push_chain`, `Sharded_SPSC_Mailbox`).
- `examples/` / `benchmarks/`:
  - `parquet_to_csv_odin`: Native Odin streaming Parquet-to-CSV CLI.
  - `csv_to_parquet`: Native Odin streaming CSV-to-Parquet CLI.
- `benchmarks/`: Statistical JSONL benchmarks, head-to-head Arrow C++ / PyArrow runners, and `parquet_to_csv_ffi` / `csv_to_parquet_ffi` FFI comparison tools.
- `tests/`: Unit and integration test suite exercising all Skadi packages.
- `tests_cpp/`: Cross-language interop verification against Apache Arrow C++.
- `benchmarks/`: Head-to-head performance benchmarks against PyArrow and Arrow C++.
