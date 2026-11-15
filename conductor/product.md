# Product Guide: Skadi

## Vision
Skadi is a native [Apache Arrow](https://arrow.apache.org/) implementation in the [Odin](https://odin-lang.org/) programming language, providing columnar in-memory data structures, high-performance compute kernels, and Arrow IPC (Feather v2) serialization with zero-overhead abstractions and explicit memory management.

## Target Users
- **Odin systems & data engineers** building high-performance analytical tools, ETL pipelines, or CLI utilities in Odin.
- **Polyglot data teams** needing zero-copy or direct binary interoperability with **PyArrow** and **Apache Arrow C++**.

## Core Capabilities
- **Columnar Memory & Buffers:** 64-byte-aligned buffers, packed validity bitmaps, zero-copy slicing, Arrow C Data Interface buffer layout, and a recycling `Buffer_Pool`.
- **Tagged-Union Type System:** No-vtable Arrow types (`Bool`, `Int8`–`Int64`, `UInt8`–`UInt64`, `Float32`/`Float64`, `Utf8`/`Binary`, `LargeUtf8`/`LargeBinary`, `Null`), dictionary encoding, and RLE.
- **Builders:** Raw-buffer, zero-copy `finish()`, lazy validity bitmaps, and Umbra-style string storage.
- **Compute Kernels:** `sum`, `min`/`max`, `mean`, `count`, `filter`, `take`, `cast`, element-wise arithmetic, comparisons, fused kernels (`sum-where`, `filter`), and stable `sort_indices` (LSD radix sort), with SIMD and multi-threaded `*_parallel` variants.
- **Arrow IPC (Feather v2):** File (random batch access) and stream (sequential) formats, memory-mapped zero-copy reads, hand-rolled FlatBuffers encoder/decoder, and bidirectional PyArrow / Arrow C++ interop.

## Non-Goals / Constraints
- Explicit, deterministic memory management (no GC or hidden allocations).
- Zero external runtime dependencies for the core Odin library (C++ / PyArrow are only used for FFI benchmarks and cross-validation tests).
