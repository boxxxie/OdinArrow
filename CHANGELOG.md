# Changelog

All notable changes to **Skadi** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-11-16

### Fixed

- **`Buffer_Pool` & builders (`skadi/buffer_pool.odin`, `skadi/builders.odin`, `skadi/var_length.odin`)**: Pass true allocated capacities as `old_size` to `mem.resize_non_zeroed` in `_builder_grow_data` and `_vb_grow_offsets`, honor custom `allocator` arguments in `builder_finish` / `_vb_finish`, clamp `_pool_resize` `old_size` to block capacity, add 25% slack reuse and a 128 MB LRU cap for cached `>4 MB` pool blocks, and enforce release-mode 2 GiB `i32` offset overflow checks.
- **Compute & selection safety (`skadi/compute.odin`, `skadi/compute_parallel.odin`, `skadi/selection.odin`)**: Enforce unconditional runtime bounds panics on out-of-bounds gather indices in `compute_take` / `compute_take_parallel`, and enforce 2 GiB `i32` offset overflow panics in release builds for `_filter_varlen`, `_take_varlen`, `compute_filter_parallel`, and `_selection_take_string`.
- **Arrow IPC writer (`skadi/ipc.odin`)**: Omit `.Trunc` on open so regular-file overwrites reuse page-cache pages and extents, guard `os.truncate` via `_ipc_truncate_if_regular` (shrinking shorter writes and truncating regular files to `0` on failure without failing on pipes/sockets/`/dev/null`), and chunk writes in `_IPC_Vectored_Writer` below `max(i32)` bytes for Darwin safety.
- **Sleipnir pipeline & hardware config (`skadi/pipeline/sleipnir_pipeline.odin`, `skadi/hardware_config.odin`)**: Broadcast `wake_futex` when toggling unparked sort execution (`_sort_begin_unparked`), reserve parent-loop sibling slots when splitting sort buckets (`_MAX_SORT_BUCKET_JOBS = 2048`), widen `worker_loads` to 256, make `hardware_config_get` lock-free when unoverridden, and expand sysfs CPU topology scanning to 1,024 entries with `core:sys/info` fallback.
- **Streaming CSV & Parquet CLI examples (`examples/csv_to_parquet/`, `examples/parquet_to_csv/`)**: Propagate `os.read` and `os.read_at` errors, reject unclosed quotes and trailing non-separator bytes after closing quotes in CSV parsing, validate non-negative `num_rows`, and report mid-stream corrupt Parquet pages via `Parquet_To_CSV_Corrupt_Page_Error`.
- **Cross-platform Arrow C++ FFI test check (`tests_cpp/arrow_cpp_test.odin`)**: Guard `foreign libarrow_capi` inside `when ODIN_OS == .Linux` and add non-Linux `proc "c"` stubs so `make check` passes on macOS and Windows targets.

### Dependencies

- **Sleipnir `v1.1.0` (`deps/sleipnir/actor/`)**: Synced vendored `package actor` cleanly to Sleipnir `v1.1.0` (`41aa9b8`, adding OTP supervision in `supervision.odin`, mailbox draining on teardown, worker `temp_allocator` cleanup, and `.Seq_Cst` step/tail ordering).

### Testing

- Expanded `tests/` to **230 unit & regression tests**, modularized `specs/` into domain-scoped Layer 2 DSL (`specs/dsl_*_test.odin`) and Layer 3 driver (`specs/driver_*_test.odin`) files (**22 ATDD specs**), and expanded `tests_cpp/` to **14 Arrow C++ FFI & IPC parity tests**.

## [0.2.0] - 2026-11-15

### Added

- **Sleipnir actor & sharded SPSC morsel pipeline** (`skadi/pipeline/sleipnir_pipeline.odin`, `deps/sleipnir/actor/`): Cache-resident worker actors with per-core `Sharded_SPSC_Mailbox` coordination for parallel fused reductions, dictionary histograms, and MSB-bucket sorting.
- **Hardware-aware execution configuration** (`skadi/hardware_config.odin`): Sysfs cache discovery (`L1d` / `L2` / `L3`) and adaptive `u16` / super-morsel sizing across platforms.
- **L1d `u16` morsel selection & super-morsel fused multi-aggregates**: `morsel_select_compare_f64_u16`, 4-way unrolled `morsel_agg_f64_u16`, `pipeline_agg_where_f64`, and `pipeline_sel_2pred_sum_f64` operating inside L1d-resident index morsels with `0` steady-state heap allocations.
- **Compressed & cache-optimized encodings**:
  - `Umbra_Array` (`skadi/umbra.odin`) — 16-byte German strings with inline/prefix fast paths and prefix-radix sorting.
  - `RLE_Array(T)` (`skadi/rle.odin`) — run-end encoding with direct run-level aggregation (`0.01 ms` for 10M `f64` over 10K runs).
  - `Dict_Array(T)` & `Str_Dict_Array` (`skadi/dict.odin`) — dictionary encoding with `O(n_dict)` min/max and integer-histogram `value_counts` / `group_sum`.
- **`Null_Type` support**: Full builder, array, compute, and Arrow IPC file/stream encoding and decoding for `Null_Type`.
- **4-layer ATDD executable specification suite** (`specs/`): 21 black-box specifications covering end-to-end workflows, Arrow IPC matrices, and seeded property invariants.
- **Statistical JSONL benchmark suite & 1v1 Arrow C++ comparator** (`make bench-1v1`, `benchmarks/compare_1v1.py`, `benchmarks/odin/stats/`): 26 canonical single-threaded and multi-threaded/actor workloads compared against Apache Arrow C++ `25.0.1` (`-O3`) with Welch's z-tests, CV%, bandwidth (`GB/s`), and allocation telemetry.
- **Build & editor tooling**: `ols.json` aligned with strict checker flags, plus `make check` and `make test-specs` targets and `pkg-config` Arrow C++ resolution in `Makefile`.

### Performance

- **Radix & parallel MSB-bucket sorting**: Packed 8-byte `(key_u32, idx_u32)` LSD radix sort (`1.82×` ST, `8.23×` actor MT vs Arrow C++) and prefix-radix + merge-sort string/Umbra sorting (`3.76×`–`3.80×` ST, `28.90×`–`36.40×` actor MT vs Arrow C++).
- **Dictionary actor histograms**: `pipeline_dict_value_counts` reaches `0.16 ms` on 1M strings / 100 distinct (`7.73×` ST, `37.95×` actor MT vs Arrow C++).
- **Vectored `writev` & `mmap` zero-copy Arrow IPC**: Scatter-gather `writev` IPC file/stream writes (`12.53 ms`, `2.91×` vs Arrow C++) and lazy `mmap` reads (`0.02 ms`, `7.17×` vs Arrow C++), reducing round-trip payload heap allocations to `0.0 MB` (`3.59×` vs Arrow C++).
- **Broad SIMD & zero-copy builder/kernel passes**: Pre-reserved raw-buffer `String_Builder` appends (`string_builder_reserve_data`), validity-free `take` fast path with `intrinsics.prefetch_read_data`, byte-coalesced null bitmap SIMD reductions, `Buffer_Pool` block recycling, and vectorized Parquet/CSV streaming CLI pipelines (`examples/` / `benchmarks/`).

### Fixed & Security

- **Arrow IPC bounds & lifetime hardening**: Hardened FlatBuffers metadata decoding (`skadi/ipc.odin`) against out-of-bounds offsets, negative `soffset` vtables, integer overflow, and non-monotonic string offsets; guarded SIMD reads on unaligned/tail inputs; added refcounted zero-copy `Record_Batch._ipc_backing` lifetime management.
- **Core array, builder & compute safety**: Rebased sliced `array_copy` offsets for variable-length columns, hardened `NaN` min/max comparisons, division-by-zero checks, builder reset reuse, and `RLE_Array` / `Dict_Array` invariant guards.
- **Parquet & CSV CLI hardening**: Bounded native Parquet dictionary and page allocations against file size and row counts, and fixed multi-page dictionary handling, definition levels, Thrift bool list decoding, and CSV output flushing.

## [0.1.0] - 2026-06-10

### Added

- Initial native Odin Apache Arrow implementation (`skadi/`): 64-byte aligned buffers, packed validity bitmaps with popcount, primitive and variable-length (`Utf8`, `LargeUtf8`, `Binary`, `LargeBinary`) arrays and builders, `Schema`, `Record_Batch`, `Table` / `Chunked_Array`, SIMD/threaded compute kernels, Arrow IPC file & stream formats, `Buffer_Pool`, Arrow C++ FFI compatibility tests (`tests_cpp/`), and CSV ↔ Parquet CLI example programs (`examples/` / `benchmarks/`).
