# Skadi

[![CI](https://github.com/boxxxie/skadi/actions/workflows/ci.yml/badge.svg)](https://github.com/boxxxie/skadi/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/version-0.2.0-blue.svg)](CHANGELOG.md)
[![Odin](https://img.shields.io/badge/Odin-lang-3882D2.svg)](https://odin-lang.org/)
[![License: Zlib](https://img.shields.io/badge/License-Zlib-lightgrey.svg)](LICENSE)
[![Arrow IPC](https://img.shields.io/badge/Arrow%20IPC-Feather%20v2-orange.svg)](https://arrow.apache.org/docs/format/Columnar.html#serialization-and-interprocess-communication-ipc)

A native [Apache Arrow](https://arrow.apache.org/) implementation in the
[Odin](https://odin-lang.org/) language — columnar in-memory format, compute
kernels, and the Arrow IPC format (Feather v2), with zero-overhead abstractions
and explicit memory management.

Files written by Skadi are readable directly by **PyArrow** and **Apache Arrow
C++**, and vice-versa.

We aim to be faster than the original - with our appreciation of what the Apache
Arrow project has accomplished.

## Highlights

- **Columnar memory** — 64-byte-aligned buffers, packed validity bitmaps,
  zero-copy slicing, the Arrow C Data Interface buffer layout.
- **Type system & compressed encodings** — a tagged union of Arrow types (no
  vtables): `Bool`, `Int8…64`, `UInt8…64`, `Float32/64`, `Utf8`/`Binary`
  (`i32` offsets), `LargeUtf8`/`LargeBinary` (`i64` offsets), `Null` — plus
  encoding-aware arrays: [`Umbra_Array`](skadi/umbra.odin) (16-byte German strings
  with inline/prefix fast paths), [`RLE_Array(T)`](skadi/rle.odin) (run-end
  encoding), and [`Dict_Array(T)` / `Str_Dict_Array`](skadi/dict.odin) (dictionary
  encoding).
- **Builders** — raw-buffer, zero-copy `finish()`, pre-reserved capacity
  (`string_builder_reserve_data`), lazy validity bitmaps, release-mode 2 GiB `i32`
  offset overflow checks, plus a reusable [`Buffer_Pool`](skadi/buffer_pool.odin)
  with power-of-two/256 KB bucketing, 25% large-block slack reuse, hit/miss
  telemetry, and a 128 MB LRU cap for `>4 MB` blocks.
- **Compute kernels, fusion & selection vectors** — `sum`, `min`/`max`, `mean`,
  `count`, selectivity-hybrid `filter` (256-entry byte-mask LUT / `tzcnt`),
  software-prefetched `take` (with release-mode bounds guards), `cast`,
  element-wise arithmetic, comparisons, and `sort_indices` (packed `u32` LSD
  radix sort for integers, prefix radix + tie-break merge sort for
  strings/Umbra); target-scoped AVX2/SIMD reductions across numeric widths;
  fused operators (`compute_sum_where`, `compute_agg_where_compare`) and lazy
  [`Selection`](skadi/selection.odin) vectors with L1d-resident `u16` morsel
  kernels ([`skadi/hardware_config.odin`](skadi/hardware_config.odin)).
- **Parallel & Sleipnir actor execution** — work-stealing `*_parallel` kernels
  ([`skadi/thread_pool.odin`](skadi/thread_pool.odin)), including
  `compute_filter_parallel` (fixed-width + variable-length strings/binary),
  `compute_take_parallel`, and `compute_sel_2pred_sum_parallel`, plus the
  cache-resident **Sleipnir actor & sharded SPSC morsel pipeline**
  ([`skadi/pipeline/sleipnir_pipeline.odin`](skadi/pipeline/sleipnir_pipeline.odin))
  for super-morsel fused aggregations (`pipeline_agg_where_f64`,
  `pipeline_sel_2pred_sum_f64`), dictionary histograms (`pipeline_dict_value_counts`,
  `pipeline_dict_group_sum`, `pipeline_dict_sum`), and MSB-bucket parallel
  radix/string/Umbra sorting (`pipeline_sort_indices`, `pipeline_umbra_sort_indices`).
- **Arrow IPC** — file (random batch access) and stream (sequential) formats,
  **vectored `writev` zero-copy writes** (with Darwin `max(i32)` chunking and
  overwrite-safe regular-file truncation), **memory-mapped (`mmap`) zero-copy
  reads** (`use_mmap=false` copy fallback), refcounted `Record_Batch._ipc_backing`
  lifetime, FlatBuffers/offset validation (`validate=true`), hand-rolled
  FlatBuffers encoder/decoder, and bidirectional PyArrow / Arrow C++ interop.

## Quick example

```odin
package main

import oa "skadi"
import "core:fmt"

main :: proc() {
    // Build a Float64 array (with one null).
    b := oa.builder_make(f64, 1024)
    for i in 0..<1000 { oa.builder_append(&b, f64(i)) }
    oa.builder_append_null(&b)
    arr, _ := oa.builder_finish(&b)      // zero-copy: buffers move into the Array
    oa.builder_destroy(&b)

    // Compute over it.
    total, valid := oa.compute_sum(&arr)
    fmt.printfln("sum=%.0f over %d non-null values", total, valid)

    // Wrap it in a schema + record batch and write a (pyarrow-readable) IPC file.
    schema, _ := oa.schema_make([]oa.Field{ oa.field_make("v", oa.Float64_Type{}) })
    defer oa.schema_free(&schema)
    batch, _ := oa.record_batch_make(&schema, []oa.Array{arr})  // batch now owns arr's buffers
    defer oa.record_batch_free(&batch)
    oa.ipc_write_file("data.arrow", &schema, []oa.Record_Batch{batch})

    // Read it back (zero-copy: columns are views into the mmap'd file).
    sc, batches, ok := oa.ipc_read_file("data.arrow")
    fmt.println("read ok:", ok, "batches:", len(batches))
    oa.schema_free(sc); free(sc)
    for bx in batches { bc := bx; oa.record_batch_free(&bc) }
    delete(batches)
}
```

Reading the same file in Python:

```python
import pyarrow.ipc as ipc
table = ipc.open_file("data.arrow").read_all()
```

## Benchmarks

Skadi vs **Apache Arrow C++ `25.0.1`** (`-O3`, the LLVM-compiled library
PyArrow wraps, called directly) across 26 canonical 1v1 workloads — **both
single-threaded (`Odin ST` vs `Arrow C++ ST`)** for an apples-to-apples per-core
comparison, alongside **multi-threaded / Sleipnir actor scaling (`Odin MT`)**.
Measured on an AMD Ryzen 7 7735U (8C/16T) with `--runs 5 --warmup 1` (median of
5 trials, Odin `-o:speed -microarch:native`, recycling memory pools on both
sides). Speedup `> 1×` means Skadi is faster.

| Benchmark                                                     | Odin ST (ms) | Arrow C++ ST (ms) |   ST Speedup | Odin MT (ms)       | MT vs C++            |
| ------------------------------------------------------------- | -----------: | ----------------: | -----------: | -----------------: | -------------------: |
| `array_build_10m_i32` (Build 10M `i32`, 1% nulls)             |        13.78 |             33.24 |    **2.41×** |                  - |                    - |
| `string_build_1m` (Build 1M strings, 2% nulls)                |         3.49 |              4.66 |    **1.34×** |                  - |                    - |
| `sum_10m_f64` (Sum 10M `f64`)                                 |         4.00 |              6.50 |    **1.63×** |               2.24 |            **2.91×** |
| `sum_10m_f64_nulls` (Sum 10M `f64`, 1% nulls)                 |         5.22 |              8.20 |    **1.57×** |               2.55 |            **3.22×** |
| `sum_10m_i32` (Sum 10M `i32`)                                 |         2.45 |              3.29 |    **1.34×** |               1.45 |            **2.26×** |
| `min_max_10m_i32` (Min+Max 10M `i32`)                         |         2.19 |              2.37 |    **1.09×** |               1.04 |            **2.29×** |
| `filter_10m_i32` (Filter 10M `i32`, 50% pass)                 |         5.25 |             40.02 |    **7.63×** |               2.47 |           **16.17×** |
| `filter_10m_i32_sparse` (Filter 10M `i32`, 1% pass)           |         0.45 |              1.49 |    **3.28×** |                  - |                    - |
| `filter_1m_string` (Filter 1M strings, 50% pass)              |         3.74 |              4.82 |    **1.29×** |               0.65 |            **7.44×** |
| `take_1m_i32` (Take 10M `i32`, 1M indices)                    |         7.36 |              9.02 |    **1.22×** |               2.01 |            **4.49×** |
| `sort_indices_1m_i32` (Sort indices 1M `i32`)                 |        22.49 |             40.99 |    **1.82×** |               4.98 |            **8.23×** |
| `sort_indices_100k_str` (Sort indices 100K strings)           |         2.58 |              9.68 |    **3.76×** |               0.33 |           **28.90×** |
| `cast_10m_i32_f64` (Cast 10M `i32` → `f64`)                   |         3.79 |              7.93 |    **2.09×** |                  - |                    - |
| `arith_add_10m_f64` (Add 10M `f64`)                           |         6.84 |             11.97 |    **1.75×** |                  - |                    - |
| `compare_gt_10m_i32` (Compare 10M `i32 > k`)                  |         2.08 |              5.89 |    **2.84×** |                  - |                    - |
| `compare_gt_10m_f64` (Compare 10M `f64 > k`)                  |         4.32 |              7.57 |    **1.75×** |                  - |                    - |
| `string_scan_1m` (Scan 1M strings)                            |         1.08 |              1.14 |    **1.05×** |                  - |                    - |
| `sum_where_10m_f64` (Sum-where 10M `f64`, 50%)                |         6.17 |             39.02 |    **6.32×** |                  - |                    - |
| `agg_where_10m_f64` (Fused `sum,count,min,max` 10M `f64`)     |        10.32 |             39.39 |    **3.82×** |               4.46 |            **8.82×** |
| `sel_2pred_sum_10m_f64` (2-pred selection + sum 10M `f64`)    |        13.93 |             21.92 |    **1.57×** | 4.38 (5.76 actor)  | **5.00×** (3.80× actor) |
| `dict_vc_1m_str` (Value counts 1M str, 100 distinct)          |         0.79 |              6.09 |    **7.73×** |               0.16 |           **37.95×** |
| `rle_sum_10m_f64` (RLE sum 10M `f64`, 10K runs)               |         0.01 |              6.43 |  **532.62×** |                  - |                    - |
| `umbra_sort_100k_str` (Umbra sort 100K strings)               |         2.58 |              9.80 |    **3.80×** |               0.27 |           **36.40×** |
| `ipc_roundtrip_10m_i32` (IPC roundtrip 10M `i32` w+r)         |        13.07 |             46.97 |    **3.59×** |                  - |                    - |
| `ipc_write_10m_i32` (IPC vectored write 10M `i32`)            |        12.53 |             36.42 |    **2.91×** |                  - |                    - |
| `ipc_read_mmap_10m_i32` (IPC `mmap` read 10M `i32`)           |         0.02 |              0.16 |    **7.17×** |                  - |                    - |

**Every benchmark beats Arrow C++ single-threaded and scales further with
multi-threading and the Sleipnir actor pipeline.** Key architectural drivers:
- **Fused kernels & L1d `u16` morsels**: `sum_where`, `agg_where`, and
  `Selection` pipelines evaluate predicates and aggregates inside L1d-sized
  morsels ([`skadi/hardware_config.odin`](skadi/hardware_config.odin)) with `0`
  intermediate heap allocations (`0` vs `1`–`4` allocs / up to `39.3 MB` in C++).
- **Encoding-aware arrays**: [`RLE_Array`](skadi/rle.odin) sums 10M rows over 10K
  runs in `0.01 ms` (`532.62×`), [`Dict_Array` / `Str_Dict_Array`](skadi/dict.odin)
  computes 1M-row value counts in `0.79 ms` ST / `0.16 ms` actor MT (`37.95×` vs
  C++), and [`Umbra_Array`](skadi/umbra.odin) eliminates pointer-chasing in string
  sorting (`0.27 ms` actor MT, `36.40×` vs C++).
- **Packed `u32` radix & MSB-bucket actor sort**: `sort_indices` packs keys and
  indices into 8-byte entries for LSD radix sorting (`1.82×` ST) and fans MSB
  buckets across Sleipnir actors (`4.98 ms`, `8.23×` vs C++); string/Umbra actor
  sorts reach `28.90×`–`36.40×`.
- **Vectored `writev` + `mmap` IPC**: Zero-copy vectored writes (`12.53 ms`,
  `2.91×`) and lazy `mmap` reads (`0.02 ms`, `7.17×`) cut IPC heap buffer copies
  to `0.0 MB` (vs `38.1 MB` in Arrow C++).

Full statistical results (Welch's z-tests, CV%, bandwidth `GB/s`, allocation
telemetry, and 3-way PyArrow comparisons) live in
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md).

Reproduce:
- `make bench-1v1` — build and run the statistical 1v1 suite (Odin vs Arrow C++),
  saving `benchmarks/odin.jsonl`, `benchmarks/cpp.jsonl`, and `benchmarks/history.jsonl`
  (or `python3 benchmarks/compare_1v1.py --from-jsonl` to print from saved JSONL).
- `bash benchmarks/bench_odin_c.sh` — single-threaded Odin vs Arrow C++ table.
- `bash benchmarks/compare.sh` — 3-way Skadi / PyArrow / Arrow C++ comparison
  (requires `pyarrow`).

## Building & testing

Requires the [Odin compiler](https://odin-lang.org/docs/install/).

```sh
make test                              # 224 unit/regression tests + 22 ATDD specs + 6 Python comparator tests
make test-specs                        # 22 4-layer ATDD specs + 6 Python comparator tests
make check                             # strict static analysis across all 13 Odin targets (-vet -strict-style -disallow-do -warnings-as-errors)
make test-cpp                          # 14 Arrow C++ FFI layout & IPC parity tests (requires Arrow C++)
make parquet-odin csv-to-parquet-odin  # build native streaming Parquet <-> CSV CLI tools into bin/
odin run examples/quickstart -out:/tmp/quickstart   # run the runnable demo
odin build skadi -build-mode:static -out:libskadi.a       # build the package
```

To use it in your own project, import the `skadi` directory as the `skadi`
package (either via a relative path or `-collection:skadi=...`). A complete, runnable tour of the API lives in
[`examples/quickstart`](examples/quickstart/main.odin); running it prints:

```
== Skadi quickstart ==

-- primitives + compute --
  length=10  null_count=1
  sum=42 (over 9 non-null)  min=0  max=9  mean=4.67
  even values: [0, 2, 4, 6, 8]

-- strings --
  4 strings, 17 total bytes; arr[1]="arrow"

-- sort_indices + take --
  sorted: [10, 20, 30, 40, 50]

-- Arrow IPC file round-trip --
  wrote /tmp/odinarrow_quickstart.arrow (readable by pyarrow.ipc.open_file)
  read back 3 row(s):
    id=1 name="ada"
    id=2 name="alan"
    id=3 name="grace"
```

## Capabilities

| Area                                                                 | Status       |
| -------------------------------------------------------------------- | ------------ |
| Aligned buffers, bitmaps (popcount), zero-copy slice                 | ✅           |
| Primitive + variable-length arrays & builders                        | ✅           |
| LargeString / LargeBinary (`i64` offsets)                            | ✅           |
| Schema, RecordBatch, Table / ChunkedArray                            | ✅           |
| Compute kernels (SIMD, packed `u32` radix sort, threaded)            | ✅           |
| Selection vectors & fused multi-aggregate operators                  | ✅           |
| Compressed encodings (`Umbra_Array`, `RLE_Array`, `Dict_Array`)      | ✅           |
| Hardware cache-adaptive config (`skadi/hardware_config.odin`)          | ✅           |
| Sleipnir actor & sharded SPSC morsel pipeline (`skadi/pipeline/`)      | ✅           |
| IPC file & stream formats (pyarrow-compatible)                       | ✅           |
| Vectored `writev` zero-copy IPC writes + `mmap` zero-copy reads      | ✅           |
| Reusable buffer-pool allocator                                       | ✅           |
| 4-layer ATDD specs & property suite (`specs/`, `make test-specs`)    | ✅           |
| GitHub Actions CI (Linux + macOS, PyArrow + Arrow C++ FFI)           | ✅           |
| Streaming CSV ↔ Parquet subset CLI tools (`examples/`)               | ✅ (examples) |
| Statistical 1v1 JSONL benchmark suite (`make bench-1v1`)             | ✅           |
| Full Parquet spec, Flight RPC, GPU kernels                           | out of scope |


## Project layout

```
skadi/                   the skadi package (buffers, types, arrays, builders,
                         compute, selection, fusion, umbra, rle, dict, ipc,
                         buffer_pool, hardware_config.odin, ...)
skadi/pipeline/          Sleipnir actor & sharded SPSC morsel pipeline
                         (sleipnir_pipeline.odin)
deps/sleipnir/actor/     Sleipnir lock-free actor & SPSC/MPSC runtime
docs/                    Cursor.md, Endeavor.md, Review.md — architecture review,
                         security/performance notes, and Arrow capability gap matrix
tests/                   unit & regression test suite (224 tests, `make test`)
specs/                   4-layer ATDD executable specifications (22 specs, `make test-specs`)
tests_cpp/               Arrow C++ FFI layout & IPC parity tests (14 tests, `make test-cpp`)
examples/quickstart/     a runnable tour of the API
examples/csv_to_parquet/ native CSV -> Parquet CLI example
examples/parquet_to_csv/ native Parquet -> CSV CLI example
benchmarks/              odin / python / cpp / FFI runners + compare_1v1.py (`make bench-1v1`)
                         + compare.sh + RESULTS.md
```

## License

Zlib License — see [LICENSE](LICENSE).
