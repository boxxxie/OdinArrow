# Specification: Performance Optimization (Memory Bandwidth, SIMD & I/O Vectorization)

## Overview
Drives major performance breakthroughs across Skadi's compute kernels, memory allocators, dictionary encoders, and CSV/Parquet streaming converters by eliminating redundant memory passes (pre-zeroing, intermediate staging, and extra copies), widening SIMD execution across all numeric types, adopting branchless mask compression, implementing morsel-driven work stealing, and vectorizing hot CSV/Parquet byte loops.

---

## Functional Requirements

### 1. Memory Bandwidth & Allocation Elimination
- **Uninitialized Buffer Allocation (`buffer_make_uninit`)**:
  - Implement `buffer_make_uninit` in [`skadi/buffer.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/buffer.odin) to allocate 64-byte aligned memory without writing zeros.
  - Replace zeroing `buffer_make` with `buffer_make_uninit` in kernels that immediately overwrite all slots: `_filter_typed`, `_selection_take_typed`, `dict_decode`, and `rle_decode`.
- **Two-Phase Direct-Scatter Parallel Filter**:
  - Refactor `compute_filter_parallel` in [`skadi/compute_parallel.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compute_parallel.odin):
    - Phase 1: Worker threads count passing elements in their respective chunks.
    - Phase 2: Compute prefix sums on thread counts to determine exact scatter offsets, allocate a single unified output buffer, and let workers scatter directly into the destination.
    - Eliminate intermediate per-thread dynamic array allocations and serial concatenation in `_concat_fixed_width`.
- **Pre-Sized Variable-Length Gathers**:
  - In `_take_string`, `_filter_string`, and `str_dict_decode` ([`skadi/compute.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compute.odin), [`skadi/dict.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/dict.odin)), sum byte lengths directly from slice offsets in an initial pass.
  - Allocate the string offset and value buffers exactly once upfront, eliminating repeated row-by-row reallocations and capacity checks in `String_Builder`.
- **Zero-Copy Finish for Large and Binary Builders**:
  - Update `Binary_Builder`, `Large_String_Builder`, and `Large_Binary_Builder` in [`skadi/var_length.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/var_length.odin) to transfer ownership of raw buffers into the resulting `Array` in `O(1)` time without copying `[dynamic]` arrays.

---

### 2. SIMD, Branchless Bitmaps, & Sort Kernels
- **Branchless Dense Mask Compression**:
  - In `_compress_dense` and `_filter_typed`, eliminate bit-by-bit branching in the 8-bit loop.
  - Introduce a `@(rodata)` `[256][8]u8` index lookup table (LUT) to emit indices unconditionally, removing branch mispredictions on intermediate (20% to 80%) selectivity filters.
- **Word-Wise 64-Bit Bitmap Operations**:
  - Vectorize validity bitmap construction in `_arith_impl` ([`skadi/compute.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compute.odin)) and chunk merging in `_copy_bits` ([`skadi/bitmap.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/bitmap.odin)) using bitwise `u64` AND, `bitmap_popcount`, and shift-OR operations instead of 1-bit-at-a-time loops.
- **Broader SIMD Type Coverage**:
  - Expand SIMD coverage in [`skadi/compute_simd.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compute_simd.odin) and [`skadi/compare.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compare.odin) beyond `f64` and `i32` to cover `i8`, `i16`, `i64`, `u8`..`u64`, and `f32`.
  - Use `#simd` comparison kernels combined with `simd_extract_msbs` (or `intrinsics.x86_pmovmskb`) to generate bitmasks directly in vector registers.
- **Single-Histogram Native Radix Sort**:
  - In `_radix_sort_indices` ([`skadi/compute.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compute.odin)), maintain native `[]T` key slices rather than widening all keys to `[]u64`.
  - Accumulate all `size_of(T)` digit histograms in a single initial pass, cutting memory passes in half for 32-bit and 64-bit keys.
- **Prefix-Assisted String Sort**:
  - In `_sort_indices_string` ([`skadi/compute.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/compute.odin)), extract 8-byte big-endian string prefixes into a temporary `struct { prefix: u64, index: i32 }` array.
  - Resolve the vast majority of string comparisons directly in CPU L1/L2 cache using 64-bit integer comparisons without dereferencing offset pointers or cold string bytes.

---

### 3. Concurrency & Dictionary Encoding
- **Morsel-Driven Dynamic Work Stealing**:
  - Replace static block assignment in `_pool_run` ([`skadi/thread_pool.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/thread_pool.odin)) with atomic morsel stealing.
  - Partition work into fine-grained morsels (e.g., `4 * core_count` tasks), allowing fast cores to dynamically steal remaining work and preventing straggler stalls on skewed null distributions or uneven string sizes.
- **Open-Addressed Fast-Path Dictionary Encoding**:
  - In `str_dict_encode` and `dict_encode` ([`skadi/dict.odin`](file:///home/pauli/projects/odin/OdinArrow/skadi/dict.odin)):
    - Add a 1-slot last-value cache to instantly deduplicate identical consecutive runs without hashing.
    - Replace Odin generic `map` with a flat open-addressed hash table caching `(hash, offset, len, code)` entries for linear probing and minimal cache misses.

---

### 4. CSV, Parquet, & IPC Streaming I/O
- **Raw Byte and SIMD Scanning in CSV Output**:
  - In `out_csv_field` ([`examples/parquet_to_csv/main.odin`](file:///home/pauli/projects/odin/OdinArrow/examples/parquet_to_csv/main.odin)), replace `for c in s` (which decodes UTF-8 runes on every character) with raw byte scanning `0..<len(s)` or `#simd[16]u8` delimiter matching.
- **Pre-Escaped Dictionary Strings in Parquet Reader**:
  - In [`examples/parquet_to_csv/parquet_reader.odin`](file:///home/pauli/projects/odin/OdinArrow/examples/parquet_to_csv/parquet_reader.odin), pre-quote and escape dictionary strings once at page load time.
  - Emit dictionary-encoded rows to CSV via direct `memcpy` of pre-escaped strings rather than inspecting and quoting strings per row.
- **SIMD CSV Delimiter Scanning & Zero-Copy Fields**:
  - In `csv_read_field_into` ([`examples/csv_to_parquet/csv_reader.odin`](file:///home/pauli/projects/odin/OdinArrow/examples/csv_to_parquet/csv_reader.odin)), use `#simd[16]u8` masks for comma and newline detection, slicing unquoted fields directly from the stream buffer `cs.buf` to eliminate redundant intermediate staging buffers.
- **Vectorized RLE Bit-Unpacking**:
  - In `decode_rle_into` ([`examples/parquet_to_csv/parquet_reader.odin`](file:///home/pauli/projects/odin/OdinArrow/examples/parquet_to_csv/parquet_reader.odin)), implement 8-value SWAR/SIMD unpackers for bit widths 1 to 16, replacing per-element scalar shift and mask operations.
- **Buffered System Writes for IPC and Parquet**:
  - Replace individual `os.write` calls for small header/padding bytes in `_ipc_write_message` and column staging in `pw_write_column` with a 64 KiB write buffer, batching I/O syscalls.

---

## Non-Functional Requirements
- **Performance Targets**:
  - Filter throughput improvement: `>= 1.5x` across all selectivities.
  - Numeric aggregation throughput on non-`f64` types (`i32`, `i64`, `f32`): `>= 2.0x` speedup via broader SIMD coverage.
  - CSV-to-Parquet and Parquet-to-CSV throughput: `>= 2.0x` speedup.
  - Radix sort and string sort: `>= 1.8x` speedup.
- **Memory Footprint**:
  - Zero redundant allocations during parallel filtering and string gathering.
  - Memory write bandwidth reduction of `30%` to `50%` on dense filter and take kernels.
- **Safety & Invariants**:
  - 100% adherence to Apache Arrow columnar memory format specifications (64-byte alignment, valid null bitmaps).
  - Clean compilation under `odin check . -vet-strict-style -disallow-do` with zero warnings.

---

## Acceptance Criteria
- [ ] `buffer_make_uninit` successfully allocates 64-byte aligned memory without clearing memory to zero.
- [ ] `compute_filter_parallel` performs direct scattering without invoking `_concat_fixed_width`.
- [ ] `_compress_dense` uses branchless LUT without branching inside the 8-bit loop.
- [ ] `compute_compare` and `compute_simd` execute vectorized `#simd` code for `i8`..`i64` and `f32`.
- [ ] `_radix_sort_indices` computes histograms in a single pass over native `T` keys.
- [ ] String sorting utilizes `(u64_prefix, i32_idx)` pairs to avoid string buffer chasing on common prefixes.
- [ ] Parquet-to-CSV export avoids UTF-8 rune decoding and leverages pre-escaped dictionary strings.
- [ ] CSV reader uses `#simd[16]u8` delimiter scanning and slices fields without multi-stage copies.
- [ ] All existing 147+ tests continue to pass cleanly with zero memory leaks.
