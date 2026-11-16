# Skadi — Apache Arrow Capability Gap Review

> Updated: 2026-11-16  
> Reference: [Apache Arrow](https://arrow.apache.org/) (format spec, C++ / PyArrow libraries, v25.0.1)  
> Subject: **Skadi** (`skadi/` `package skadi` and `skadi/pipeline/` `package pipeline`) as it exists in this repository

This document compares Skadi against the **Apache Arrow project** as a whole — the columnar format specification, the reference C++ libraries, and the ecosystem built around them (PyArrow, Parquet integration, Flight, Dataset, etc.). It is not a performance review; see [`benchmarks/RESULTS.md`](../benchmarks/RESULTS.md) for that.

### Status legend

| Symbol | Meaning |
|---|---|
| ✅ | Implemented in Skadi core/pipeline (`skadi/`, `skadi/pipeline/`) |
| 🔶 | Partial / companion encoding / CLI example (`examples/`, FFI) |
| ❌ | Not implemented |

---

## 1. Executive summary

Skadi is a **focused, high-performance implementation of Arrow's core in-memory columnar model** for flat (non-nested) data: 64-byte aligned buffers, packed validity bitmaps, all 16 flat `DataType` variants (`Null_Type`, `Bool_Type`, `Int8..64`, `UInt8..64`, `Float32/64`, `String_Type`/`Binary_Type` `i32`, `Large_String_Type`/`Large_Binary_Type` `i64`), builders, schema/record-batch/table abstractions, target-scoped AVX2/SIMD + thread-pooled + Sleipnir actor compute/selection/fusion kernels, companion compressed encodings (`Umbra_Array`, `RLE_Array(T)`, `Dict_Array(T)` / `Str_Dict_Array`), and Arrow IPC file + stream I/O with vectored `writev` writes and memory-mapped zero-copy reads.

It **does not** replicate the breadth of the Apache Arrow **software ecosystem**. Measured against PyArrow / Arrow C++, the largest gaps are:

1. **Data types** — no nested (`List`, `Struct`, `Union`, `Map`), temporal (`Date`, `Time`, `Timestamp`), `Float16`, or `Decimal` types; dictionary and RLE exist as companion types (`skadi/dict.odin`, `skadi/rle.odin`) rather than Arrow IPC union variants
2. **Compute** — ~35+ specialized compute, comparison, selection, fusion, encoding, and actor pipeline procs vs **100+ dynamically registered Arrow functions**, no general multi-join/window query planner
3. **I/O** — no library-level CSV/JSON/Parquet; uncompressed subset Parquet/CSV CLI tools live in `examples/` (with Arrow C++ FFI baselines in `benchmarks/`)
4. **Infrastructure** — no Dataset API, filesystem abstraction, Flight/ADBC, Acero query engine, Gandiva, or GPU support
5. **Interop** — wire-compatible IPC and binary-compatible raw buffer layout (`tests_cpp/`) with PyArrow and Arrow C++, but no formal `ArrowSchema`/`ArrowArray` C Data Interface export/import procs

Where Skadi **does** compete (and beats Arrow C++ `25.0.1` across all 26 canonical 1v1 benchmarks) is the **narrow analytical core**: building flat/encoded columns, fused & selection-vector scans, sorting, and IPC round-trips.

---

## 2. Columnar format & type system

Apache Arrow defines a rich logical and physical type system ([Columnar format spec](https://arrow.apache.org/docs/format/Columnar.html)). Skadi implements a **flat subset** plus companion cache-optimized encodings.

### 2.1 Logical / physical types

| Arrow type | Skadi | Notes |
|---|---|---|
| Null | ✅ | `Null_Type` in `Array`, `compute_count`, IPC schema/batch |
| Boolean | ✅ | Bit-packed values buffer |
| Int8 / Int16 / Int32 / Int64 | ✅ | |
| UInt8 / UInt16 / UInt32 / UInt64 | ✅ | |
| Float16 | ❌ | Not in `DataType` union |
| Float32 / Float64 | ✅ | |
| Decimal128 / Decimal256 | ❌ | No fixed-precision decimal |
| Date32 / Date64 | ❌ | |
| Time32 / Time64 | ❌ | |
| Timestamp (with timezone) | ❌ | |
| Duration / Interval | ❌ | |
| Binary / String (Utf8) | ✅ | `i32` offsets |
| LargeBinary / LargeString | ✅ | `i64` offsets; builders + IPC |
| FixedSizeBinary | ❌ | |
| List / LargeList | ❌ | `Array.children` field exists but unused |
| FixedSizeList | ❌ | |
| ListView / LargeListView | ❌ | Newer spec layouts |
| Struct | ❌ | |
| Union (sparse / dense) | ❌ | |
| Map | ❌ | |
| Dictionary (encoded) | 🔶 | `Dict_Array(T)` & `Str_Dict_Array` (`skadi/dict.odin`) + Parquet dict pages; not in Arrow IPC |
| RunEndEncoded | 🔶 | `RLE_Array(T)` (`skadi/rle.odin`) with run-level validity; not in Arrow IPC |
| Umbra / German Strings (16-byte inline/prefix) | 🔶 | `Umbra_Array` (`skadi/umbra.odin`); standalone fast-compare layout |
| Extension types | ❌ | User-defined logical types with storage type + metadata |

### 2.2 Layout & invariants

| Capability | Skadi | Apache Arrow |
|---|---|---|
| 64-byte buffer alignment | ✅ | ✅ |
| Validity bitmaps (optional when no nulls) | ✅ | ✅ |
| Zero-copy slice (offset + length) | ✅ | ✅ |
| Lazy / cached null count | ✅ | ✅ |
| Variadic buffer counts (nested) | ❌ | ✅ |
| Endianness conversion | ❌ (LE assumed) | ✅ |
| Buffer compression in-memory | ❌ | 🔶 (optional in some paths) |

---

## 3. Memory management

| Capability | Skadi | Apache Arrow (C++) |
|---|---|---|
| Explicit aligned allocation (`buffer_make` / `buffer_make_uninit`) | ✅ | ✅ (`arrow::Buffer`) |
| Zero-copy buffer views (`buffer_slice`) | ✅ | ✅ |
| Reusable allocation pool | ✅ `Buffer_Pool` (power-of-two/256 KB buckets, 25% slack reuse, 128 MB LRU cap) | ✅ `arrow::MemoryPool` |
| Reference-counted shared buffers | 🔶 `Record_Batch._ipc_backing` atomic refcounting | ✅ `shared_ptr<Buffer>` |
| Memory accounting / statistics | 🔶 `Buffer_Pool` `hits`/`misses`/`free_large_bytes`, `mem.Tracking_Allocator` | ✅ pool stats, debugger hooks |
| Memory-mapped file backing | ✅ IPC read (Unix `mmap` + copy fallback) | ✅ |
| Vectored scatter-gather IPC writes (`writev`) | ✅ `_IPC_Vectored_Writer` | ✅ |
| GPU / device memory | ❌ | ✅ (CUDA, etc.) |
| Thread-safe pool | ❌ (single-thread per builder/thread; documented) | ✅ |

Skadi's ownership model is **explicit and deterministic** (`allocator` per buffer, non-owning slices with `allocator = {}`, and refcounted `_IPC_Backing` for zero-copy `mmap` batches). Arrow C++ uses reference counting everywhere via `shared_ptr`.

---

## 4. Core data structures

| Structure | Skadi | Apache Arrow |
|---|---|---|
| `Array` | ✅ | ✅ `arrow::Array` |
| `Selection` + L1d `u16` morsels | ✅ (`skadi/selection.odin`, `skadi/compare.odin`) | 🔶 internal ExecBatch selection |
| `Chunked_Array` | 🔶 (`skadi/table.odin`: `get` / `is_null`) | ✅ full API, compute on chunks |
| `Record_Batch` | ✅ | ✅ |
| `Table` | 🔶 stacks batches with schema validation, borrows chunks | ✅ owns schema, column chunks, metadata |
| `Schema` / `Field` | ✅ | ✅ + field metadata, dictionaries |
| `Scalar` | ❌ | ✅ typed single values for compute |
| `Datum` (Array \| Scalar \| Chunked \| …) | ❌ | ✅ unified compute input |
| `Tensor` / `SparseTensor` | ❌ | ✅ |

**Skadi gaps in tabular API:**

- No field or schema **custom metadata** (key/value)
- No **dictionary** on `Field` (dictionaries live in `Str_Dict_Array` / `Dict_Array(T)`)
- No `Table` → `Record_Batch` iterator, slice, filter, or join
- `Chunked_Array` has `get` / `is_null` only — no slice, concat, or compute

---

## 5. Builders & array construction

| Builder | Skadi | Apache Arrow |
|---|---|---|
| Primitive (`bool`, all int/float widths) | ✅ zero-copy `finish()`, lazy bitmap | ✅ `NumericBuilder`, etc. |
| String / Binary (`i32` offsets) | ✅ raw-buffer builder + `reserve_data` | ✅ |
| Large String / Binary (`i64` offsets) | ✅ raw-buffer builder + `reserve_data` | ✅ |
| Null array | 🔶 constructed via `Array{type = Null_Type{}, ...}`; no dedicated builder struct | ✅ `NullBuilder` |
| Umbra strings | ✅ `Umbra_Builder` (`skadi/umbra.odin`) | ❌ |
| RunEndEncoded | 🔶 `RLE_Builder(T)` / `rle_encode` | ✅ |
| Dictionary | 🔶 `dict_encode` / `str_dict_encode` | ✅ |
| FixedSizeBinary / Decimal / Temporal | ❌ | ✅ |
| List / Struct / Union | ❌ | ✅ nested builders |
| Typed `ArrayBuilder` hierarchy | ❌ (generic `Primitive_Builder($T)` & `_Var_Builder`) | ✅ per-type classes |
| `Buffer_Pool` integration | ✅ | ✅ default pool |

---

## 6. Compute engine

Apache Arrow Compute ([C++ docs](https://arrow.apache.org/docs/cpp/compute.html)) exposes a **function registry** with 100+ kernels invokable via `CallFunction(name, args)`. Skadi provides direct, monomorphised Odin procs with zero dynamic dispatch overhead.

### 6.1 What Skadi implements

| Kernel / Family | Serial | SIMD | Parallel (`thread_pool`) | Sleipnir Actor (`skadi/pipeline`) |
|---|---|---|---|---|
| `compute_sum` | ✅ | ✅ `f32`, `f64`, `i8..32`, `u8..32` | ✅ | — |
| `compute_min` / `compute_max` / `compute_min_max` | ✅ | ✅ all numeric widths | ✅ | — |
| `compute_mean` | ✅ | via sum | ✅ | — |
| `compute_count` | ✅ (incl. `Null_Type`) | — | ❌ | — |
| `compute_filter` | ✅ (`tzcnt` + 256-entry LUT) | — | ✅ (fixed + `String`/`Binary`) | — |
| `compute_take` | ✅ (prefetched) | — | ✅ (prefetched) | — |
| `compute_cast` (numeric) | ✅ | — | ❌ | — |
| `compute_arithmetic` (`add`/`sub`/`mul`/`div`) | ✅ | — | ❌ | — |
| `compute_compare*` (`==`, `!=`, `<`, `<=`, `>`, `>=`) | ✅ (comptime `$OP`) | auto-vec | — | — |
| `Selection` (`compute_select*`, `selection_refine*`, `selection_take`) | ✅ (`tzcnt`/LUT + `u16` morsels) | — | ✅ (`compute_sel_2pred_sum_parallel`) | ✅ (`pipeline_sel_2pred_sum_f64`) |
| Fused `*_where` (`compute_sum_where`, `compute_agg_where_compare*`) | ✅ | — | — | ✅ (`pipeline_agg_where_f64`) |
| `compute_sort_indices` (stable, nulls-last) | ✅ (LSD radix + prefix radix) | — | — | ✅ (`pipeline_sort_indices`) |
| `RLE_Array(T)` (`rle_sum`, `rle_min_max`, `rle_encode`/`decode`) | ✅ (`O(runs)`) | — | — | — |
| `Dict_Array(T)` / `Str_Dict_Array` (`value_counts`, `group_sum`, `min_max`, `sum`) | ✅ (`O(n_dict)` min/max) | — | — | ✅ (`pipeline_dict_*`) |
| `Umbra_Array` (`umbra_compare`, `umbra_count_eq`, `umbra_sort_indices`) | ✅ (prefix radix + merge) | — | — | ✅ (`pipeline_umbra_sort_indices`) |

### 6.2 Major compute categories compared with Arrow

#### Aggregations (scalar & grouped reduce)

| Arrow function (examples) | Skadi |
|---|---|
| `sum`, `min`, `max`, `min_max`, `mean`, `count` | ✅ |
| `all`, `any` | ❌ |
| `count_distinct`, `count_all` | ❌ |
| `first`, `last`, `first_last`, `product` | ❌ |
| `stddev`, `variance`, `skew`, `kurtosis` | ❌ |
| `quantile`, `tdigest`, `approximate_median`, `mode` | ❌ |
| Grouped / hash aggregations | 🔶 `str_dict_group_sum`, `dict_group_sum`, `pipeline_dict_group_sum` (single dictionary key) |

#### Element-wise & logical

| Category | Examples | Skadi |
|---|---|---|
| Comparisons | `equal`, `less`, `not_equal`, `less_equal`, `greater`, `greater_equal` | ✅ (`compute_compare`, `compute_compare_i64`, `compute_compare_u64`) |
| Boolean logic | `and`, `or`, `not`, `xor`, Kleene | ❌ (chained predicates via `selection_refine_compare*`) |
| Null predicates | `is_null`, `is_valid`, `fill_null` | ❌ (per-element via `array_is_null` / `array_is_valid`) |
| Bitwise / Math / Rounding | `bit_wise_and`, `sin`, `log`, `round`, `floor`, `ceil` | ❌ |

#### Selection & ordering

| Arrow function | Skadi |
|---|---|
| `sort_indices` | ✅ (`compute_sort_indices`, `pipeline_sort_indices`, `umbra_sort_indices`) |
| `array_sort` | ❌ (compose via `compute_take`) |
| `partition_nth`, `select_k_unstable`, `indices_nonzero` | ❌ |

#### String & binary

| Arrow function | Skadi |
|---|---|
| `utf8_length` (total length scan) | 🔶 `string_view_sum_lengths` (`skadi/var_length.odin`) |
| `binary_length`, `utf8_trim`, `replace`, `match`, `split`, `join`, `binary_concat` | ❌ |

#### Temporal, Hash/Set, Structural & Query Engine

| Category / Function | Skadi |
|---|---|
| Temporal extract, cast, arithmetic | ❌ (no temporal types) |
| `value_counts` | 🔶 `dict_value_counts`, `str_dict_value_counts`, `pipeline_dict_value_counts` |
| `unique`, `is_in`, `hash` | ❌ |
| `run_end_encode`, `run_end_decode` | ✅ (`rle_encode`, `rle_decode` in `skadi/rle.odin`) |
| `make_struct`, `struct_field`, `list_flatten` | ❌ |
| Hash join / asof join / Window functions / Acero / Gandiva / GPU | ❌ |

#### Compute infrastructure

| Feature | Skadi | Apache Arrow |
|---|---|---|
| Function registry + `CallFunction` | ❌ | ✅ |
| Kernel dispatch by exact type | ✅ `switch` + comptime generics | ✅ auto |
| Implicit numeric promotion / `Scalar` broadcasting | ❌ | ✅ |
| Options (`ScalarAggregateOptions`, …) | ❌ | ✅ |
| Compute on `ChunkedArray` / `RecordBatch` / `Table` | ❌ (`pipeline_record_batch_stream_sum` only) | ✅ |
| **Gandiva** (LLVM JIT expressions) | ❌ (comptime Odin monomorphisation for `fusion.odin`) | ✅ (C++) |

---

## 7. IPC & serialization

| Capability | Skadi | Apache Arrow |
|---|---|---|
| IPC **file** format (Feather v2) | ✅ read + write | ✅ |
| IPC **stream** format | ✅ read + write | ✅ |
| Encapsulated message framing | ✅ | ✅ |
| Self-contained FlatBuffers encoder/decoder | ✅ (bounds- & overflow-hardened) | ✅ |
| Vectored `writev` zero-copy writes | ✅ (Darwin `max(i32)` chunking + overwrite-safe truncate) | ✅ |
| Zero-copy read (`mmap`) + copy fallback | ✅ Unix `mmap` (`use_mmap=true`), heap copy (`use_mmap=false`) | ✅ |
| Offset & metadata validation (`validate=true`) | ✅ | ✅ |
| Zero-copy refcounted `Record_Batch._ipc_backing` | ✅ | ✅ |
| Supported IPC types (flat) | ✅ all 16 flat types incl. `Null_Type` and `Large_*` | ✅ |
| Nested types / Dictionary batches / IPC body compression (LZ4, ZSTD) | ❌ | ✅ |
| Custom schema / field metadata & extension metadata | ❌ | ✅ |
| Tensor / SparseTensor IPC & C Stream / Device interfaces | ❌ | ✅ |

**Interop status:** Files and streams produced by Skadi for supported flat types are readable by PyArrow and Arrow C++, and vice versa (verified in `tests/`, `specs/`, `tests_cpp/`, and GitHub Actions CI).

---

## 8. File format I/O (beyond IPC)

Skadi separates **library (`skadi/`)** from **CLI examples (`examples/`)** and **FFI comparison runners (`benchmarks/`)**.

| Format | Skadi library | Skadi `examples/` | Apache Arrow |
|---|---|---|---|
| Arrow IPC / Feather | ✅ | `examples/quickstart` | ✅ |
| **Parquet** read | ❌ | 🔶 native subset (`examples/parquet_to_csv`) | ✅ full |
| **Parquet** write | ❌ | 🔶 native subset (`examples/csv_to_parquet`) | ✅ full |
| Parquet via FFI | — | 🔶 `benchmarks/*_ffi` (Arrow C++ shim) | ✅ |
| **CSV** read/write | ❌ | 🔶 streaming RFC 4180 CSV parser/writer | ✅ `arrow::csv` |
| **JSON / ORC / Avro / NDJSON** | ❌ | ❌ | ✅ / 🔶 |

### 8.1 Native Odin Parquet subset (`examples/` only)

| Parquet feature | Native Odin | Apache Arrow Parquet |
|---|---|---|
| PLAIN encoding | ✅ | ✅ |
| Dictionary pages | 🔶 read only (multi-page) | ✅ |
| RLE / bit-packed definition & dictionary levels | 🔶 read only | ✅ |
| Page compression (SNAPPY, ZSTD, GZIP, …) | ❌ (rejected cleanly) | ✅ |
| Statistics / column indexes / Bloom filters | ❌ | ✅ |
| Nested / repeated fields / Schema evolution / Encryption | ❌ | ✅ |
| Physical types | 🔶 `BYTE_ARRAY` + `INT32` write; `BOOLEAN`, `INT32`, `INT64`, `FLOAT`, `DOUBLE`, `BYTE_ARRAY` read | ✅ |

---

## 9. Dataset, Filesystem, Network & Query Engine

| Component | Skadi | Apache Arrow |
|---|---|---|
| `Dataset` / Hive partitioning / `Scanner` | ❌ | ✅ |
| Unified `FileSystem` (S3 / GCS / Azure / HDFS) | ❌ (local `core:os` + POSIX `mmap` only) | ✅ |
| **Arrow Flight** / **Flight SQL** / **ADBC** | ❌ | ✅ |
| **Acero** / **Gandiva** / **Substrait** / GPU | ❌ | ✅ |

---

## 10. Interoperability & language ecosystem

| Interface | Skadi | Apache Arrow |
|---|---|---|
| **C Data Interface** (`ArrowArray` / `ArrowSchema`) | 🔶 binary-compatible raw buffers; no export/import procs | ✅ spec + helpers |
| **C Stream Interface** | ❌ | ✅ |
| PyArrow / Python | ✅ via IPC files/streams | ✅ native binding |
| Arrow C++ FFI validation (`tests_cpp/`) | ✅ 14 parity tests (`i32`, `i64`, `u64`, `f32`, `f64`, `bool`, `String`, `Binary`, slices, IPC) | — |
| Multi-language bindings (R, Java, Go, Rust, JS, …) | ❌ (Odin only) | ✅ |

---

## 11. Metadata, extension types & schema evolution

| Feature | Skadi | Apache Arrow |
|---|---|---|
| Field nullable flag | ✅ | ✅ |
| Field / schema custom metadata (KV) | ❌ | ✅ |
| Dictionary type on `Field` | ❌ | ✅ |
| Extension types & schema evolution | ❌ | ✅ / 🔶 |

---

## 12. Tooling, testing & packaging

| Area | Skadi | Apache Arrow |
|---|---|---|
| Unit & regression tests | ✅ **224 tests** across 17 files (`tests/` via `make test`) | ✅ extensive |
| 4-layer ATDD specs & property tests | ✅ **22 specs** (`specs/` via `make test-specs`) + 6 Python tests | — |
| C++ interop & layout parity tests | ✅ **14 tests** (`tests_cpp/` via `make test-cpp`) | — |
| Statistical 1v1 benchmark suite vs C++ `25.0.1` | ✅ **26 workloads / 32 rows** (`make bench-1v1`) | ✅ (conbench) |
| CI (GitHub Actions) | ✅ [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) (Linux + macOS) | ✅ |
| Repo layout & IDE tooling | ✅ idiomatic `skadi/` + `skadi/pipeline/` + `ols.json` | ✅ |
| Documentation | ✅ `README.md`, `CHANGELOG.md`, `docs/`, `benchmarks/RESULTS.md` | ✅ arrow.apache.org |

---

## 13. Side-by-side scope map

```
Apache Arrow ecosystem                          Skadi coverage
─────────────────────────────────────────────────────────────────────
Columnar format (16 flat types + companions)    █████░░░░░  ~45%
In-memory Array / Batch / Table (flat)          ████████░░  ~85%
Builders (flat + large + Umbra/RLE/Dict)        █████████░  ~90%
Compute (flat, SIMD, selection, fusion, actors) ████░░░░░░  ~35%
IPC file + stream (flat, mmap + writev)         ████████░░  ~80%
Parquet (native CLI subset in examples/)        ██░░░░░░░░  ~15%
CSV I/O (streaming CLI in examples/)            ██░░░░░░░░  ~20%
Dataset / Scanner / Cloud FileSystem            ░░░░░░░░░░   0%
Flight / Flight SQL / ADBC                      ░░░░░░░░░░   0%
Acero / Gandiva / GPU                           ░░░░░░░░░░   0%
Multi-language bindings                         ░░░░░░░░░░   0%  (Odin only)
```

---

## 14. What Skadi covers well (parity or faster for flat analytics)

- Columnar memory layout and Arrow buffer conventions (`tests_cpp/` verified)
- Zero-copy slice, `mmap` IPC read, vectored `writev` IPC write, zero-copy builder `finish()`, and `Buffer_Pool` recycling
- All 16 flat Arrow types including `Null_Type` and `Large_String`/`Large_Binary`
- Companion encodings (`Umbra_Array`, `RLE_Array(T)`, `Dict_Array(T)`, `Str_Dict_Array`)
- Core compute, monomorphised comparisons, lazy `Selection` + L1d `u16` morsels, operator fusion, persistent thread pool, and Sleipnir actor pipelines — beating Arrow C++ `25.0.1` across all 26 1v1 workloads

---

## 15. Prioritised remaining gaps (if aiming at broader Arrow parity)

### Tier 1 — Format completeness

| Priority | Gap | Effort |
|---|---|---|
| P1 | Temporal types (`Date32`, `Date64`, `Timestamp`) + IPC + cast | M |
| P1 | Arrow IPC dictionary batches + `Field` dictionary metadata | L |
| P2 | `Struct` + `List` nested types (arrays, builders, IPC, compute) | L |
| P2 | IPC body compression (ZSTD/LZ4) | M |
| P3 | Field/schema custom metadata & extension types | M |

### Tier 2 — Compute & I/O breadth

| Priority | Gap | Effort |
|---|---|---|
| P1 | Arrow C Data Interface export/import procs (`ArrowSchema` / `ArrowArray`) | M |
| P2 | Parquet page decompression (Snappy/ZSTD) & reusable library module | L |
| P2 | `unique`, `is_in`, null-handling kernels (`is_null`, `fill_null`), `selection_take` for remaining types | M |
| P3 | Multi-key grouped aggregations & multi-column fusion planner | L |

### Explicit non-goals

- GPU / CUDA kernels
- Gandiva LLVM JIT
- Full Acero / SQL engine / Arrow Flight RPC
- Multi-language bindings beyond Odin

---

## 16. References

- [Apache Arrow columnar format](https://arrow.apache.org/docs/format/Columnar.html)  
- [Arrow IPC format](https://arrow.apache.org/docs/format/Columnar.html#ipc-streaming-format)  
- [Arrow C++ compute functions](https://arrow.apache.org/docs/cpp/compute.html)  
- [Arrow C Data Interface](https://arrow.apache.org/docs/format/CDataInterface.html)  
- Skadi: [`README.md`](../README.md), [`Cursor.md`](Cursor.md), [`Endeavor.md`](Endeavor.md), [`benchmarks/RESULTS.md`](../benchmarks/RESULTS.md)

---

*This review reflects the repository state at update time (**224 unit tests + 22 ATDD specs + 6 Python comparator tests + 14 C++ FFI tests**).*
