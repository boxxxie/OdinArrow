# Implementation Plan: Performance Optimization (Memory Bandwidth, SIMD & I/O Vectorization)

## Phase 1: Memory Bandwidth & Allocation Elimination
Eliminates redundant pre-zeroing passes, intermediate array staging, and per-row reallocations.

- [x] Task: Implement `buffer_make_uninit`
    - [x] Write unit test verifying `buffer_make_uninit` returns 64-byte aligned buffers without zeroing overhead (`tests/buffer_test.odin`: `test_buffer_make_uninit_alignment_and_lifecycle`)
    - [x] Add `buffer_make_uninit` to `skadi/buffer.odin`
    - [x] Replace zeroing `buffer_make` with `buffer_make_uninit` in `_filter_typed`, `_selection_take_typed`, `dict_decode`, and `rle_decode`
    - [x] Verify test suite passes with zero regressions
- [x] Task: Two-Phase Direct-Scatter Parallel Filter
    - [x] Verify parallel filter throughput and allocations (`tests/compute_parallel_test.odin` + `filter_10m_i32_mt` benchmark: 3.84 ms)
    - [x] Implement Phase 1 survivor counting per thread in `compute_filter_parallel` (`_filter_count_job`)
    - [x] Compute prefix sums to determine destination offsets and allocate a single unified output buffer
    - [x] Implement Phase 2 direct worker scattering (`_filter_scatter_job`) and remove `_concat_fixed_width`
    - [x] Verify parallel filter tests pass
- [x] Task: Pre-Sized Variable-Length Gathers
    - [x] Update `_selection_take_string`, `_filter_varlen`, and `str_dict_decode` to pre-calculate total byte lengths from offsets upfront
    - [x] Pre-allocate offset and value buffers in a single allocation pass (`_varlen_alloc_buffers`), bypassing row-by-row `String_Builder` growth
    - [x] Verify string filtering and take tests pass
- [x] Task: Zero-Copy Large and Binary Builders
    - [x] Update `String_Builder`, `Binary_Builder`, `Large_String_Builder`, and `Large_Binary_Builder` in `skadi/var_length.odin` to embed `_Var_Builder($Offset)`
    - [x] Transfer raw buffer pointers directly into the finished `Array` in `O(1)` time without copying `[dynamic]` arrays
    - [x] Verify builder tests pass with tracking allocator leak checks
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Memory Bandwidth & Allocation Elimination' (Protocol in workflow.md)

---

## Phase 2: SIMD, Branchless Bitmaps & Sort Kernels
Accelerates core computational loops with branchless tables, 64-bit word operations, and expanded SIMD coverage.

- [x] Task: Branchless Dense Mask Compression
    - [x] Add `@(rodata) _BYTE_INDICES_LUT: [256][8]u8` index lookup table in `skadi/selection.odin`
    - [x] Refactor `_compress_dense` (`skadi/selection.odin`) and `_filter_typed` (`skadi/compute.odin`) to emit indices unconditionally via LUT lookup
    - [x] Benchmark filter throughput (`filter_10m_i32_st` 5.96 ms, `filter_10m_i32_mt` 3.84 ms vs Arrow C++ 36.35 ms)
- [x] Task: Word-Wise 64-Bit Bitmap Operations
    - [x] Refactor validity bitmap construction in `_arith_impl` (`skadi/compute.odin`) to perform `u64` bitwise AND + `bitmap_popcount`
    - [x] Implement `bitmap_copy_bits` (`skadi/bitmap.odin`) using 64-bit aligned copy and unaligned shift-OR merges (`tests/buffer_test.odin`: `test_bitmap_copy_bits`)
    - [x] Verify arithmetic and bitmap unit tests pass
- [x] Task: Broaden SIMD Coverage for All Numeric Types
    - [x] Implement `#simd` aggregation kernels for `i8..u64`, `f32`, and `f64` in `skadi/compute_simd.odin` (`_sum_typed_simd`, `_min_typed_simd`, `_max_typed_simd`, `_min_max_typed_simd`)
    - [x] Integrate `intrinsics.simd_extract_msbs` via `_simd_cmp_bits` to generate comparison bitmasks directly in vector registers (`skadi/compare.odin`)
    - [x] Wire new SIMD kernels into `_compare_mono` and typed dispatchers
    - [x] Verify numeric compute tests pass
- [x] Task: Single-Histogram Native Radix Sort
    - [x] Update `_radix_sort_indices` in `skadi/compute.odin` to sort native `[]$U` keys without widening to `[]u64`
    - [x] Compute all `size_of(T)` digit histograms in a single initial pass
    - [x] Verify radix sort stability and performance on integer and float arrays
- [x] Task: Prefix-Assisted String Sort
    - [x] In `_sort_indices_string`, stage `_Str_Sort_Entry { prefix: u64, idx: i32, slen: i32 }` pairs extracted using `intrinsics.byte_swap`
    - [x] Resolve string ordering via 64-bit prefix comparison in L1 cache, deferring to string buffer only on matching prefixes
    - [x] Verify string sorting test suite passes
- [ ] Task: Conductor - User Manual Verification 'Phase 2: SIMD, Branchless Bitmaps & Sort Kernels' (Protocol in workflow.md)

---

## Phase 3: Morsel Concurrency & Fast Dictionary Encoding
Eliminates thread stragglers and minimizes hash table lookups during dictionary encoding.

- [x] Task: Morsel-Driven Work Stealing in Thread Pool
    - [x] Refactor `_Compute_Pool` in `skadi/thread_pool.odin` to support atomic morsel chunk indexing (`next_idx`, `active_workers`)
    - [x] Update `_pool_run` and `skadi/compute_parallel.odin` (`_compute_morsels`, `4 * nt` slices) so worker threads and caller atomically claim morsels
    - [x] Verify parallel operations pass across `tests/compute_parallel_test.odin`
- [x] Task: Open-Addressed Dictionary Hash Table & Run Cache
    - [x] Add 1-slot last-value cache (`has_last`) to `str_dict_encode` and `dict_encode` in `skadi/dict.odin`
    - [x] Implement flat open-addressed hash table (`_Dict_Slot`) with linear probing in `context.temp_allocator`
    - [x] Verify dictionary encoding tests pass cleanly with 0 leaks (`tests/dict_test.odin`)
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Morsel Concurrency & Fast Dictionary Encoding' (Protocol in workflow.md)

---

## Phase 4: CSV, Parquet & IPC Streaming I/O Vectorization
Vectorizes hot byte scanning loops and buffers syscall writes across streaming converters.

- [x] Task: Raw Byte & SIMD Scanning in CSV Output
    - [x] In `out_csv_field` (`examples/parquet_to_csv/main.odin`), replace rune decoding with raw byte + `#simd[16]u8` lane scanning for quotes, commas, and newlines
    - [x] Verify CSV export tests pass
- [x] Task: Pre-Escaped Dictionary Strings in Parquet Reader
    - [x] In `examples/parquet_to_csv/parquet_reader.odin`, pre-quote dictionary strings during dictionary page decoding
    - [x] Stream pre-escaped dictionary entries to CSV output directly
    - [x] Verify Parquet-to-CSV tests pass
- [x] Task: SIMD Delimiter Scanning & Zero-Copy Fields in CSV Reader
    - [x] Implement `#simd[16]u8` delimiter matching in `csv_read_field_into` (`examples/csv_to_parquet/csv_reader.odin`)
    - [x] Slice unquoted fields directly from `cs.buf`, bypassing intermediate copies
    - [x] Verify CSV parsing tests pass
- [x] Task: Vectorized SWAR/SIMD RLE Bit-Unpacker
    - [x] In `decode_rle_into` (`examples/parquet_to_csv/parquet_reader.odin`), implement fast unpackers
    - [x] Verify Parquet definition level and dictionary index decoding pass
- [x] Task: 64 KiB Buffered I/O Writes
    - [x] Implement 64 KiB write buffering in `skadi/ipc.odin` (`_IPC_Writer`) and `examples/csv_to_parquet/parquet_writer.odin`
    - [x] Verify file roundtrips pass
- [ ] Task: Conductor - User Manual Verification 'Phase 4: CSV, Parquet & IPC Streaming I/O Vectorization' (Protocol in workflow.md)

---

## Phase 5: Benchmark Verification & Regression Suite
Validates throughput improvements and ensures zero memory leaks across all test suites.

- [x] Task: Run Head-to-Head Benchmarks Against Arrow C++
    - [x] Execute `make bench-1v1` (`benchmarks/compare_1v1.py`, full 10M/1M statistical suite) against Arrow C++ `25.0.1`
    - [x] Measure speedup factors across Odin ST, Odin MT, and Arrow C++ ST (`sum_10m_f64` 1.35x ST / 2.70x MT, `filter_10m_i32` 6.10x ST / 9.47x MT, `ipc_roundtrip_10m_i32` 1.18x)
    - [x] Document verified results in `benchmarks/RESULTS.md`
- [x] Task: Strict Style, Memory Leak & Compiler Validation
    - [x] Run `odin check skadi -no-entry-point -vet -strict-style -disallow-do -warnings-as-errors` with 0 warnings
    - [x] Run `odin check examples/parquet_to_csv -vet -strict-style -disallow-do` and `examples/csv_to_parquet`
    - [x] Run `odin test tests -vet -strict-style -disallow-do` (`171/171`) and `odin test specs -vet -strict-style -disallow-do` (`21/21`) with tracking allocator leak verification
- [ ] Task: Conductor - User Manual Verification 'Phase 5: Benchmark Verification & Regression Suite' (Protocol in workflow.md)
