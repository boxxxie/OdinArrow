# Endeavor — surpassing the reference implementation

A review of Skadi with two goals: (1) harden the parts that parse untrusted
input, and (2) lay out performance work — both Arrow-compatible and
compatibility-breaking — that makes Skadi faster than Apache Arrow's
own C++ kernels on the operations that matter.

Each item notes **impact**, **effort**, and whether it **breaks Arrow
compatibility**. File/function references point at the current codebase in
`skadi/` and `skadi/pipeline/`.

---

## A. Security — the IPC reader is an untrusted-input parser

`ipc_read_file` / `ipc_read_stream` (`skadi/ipc.odin`) decode attacker-controllable
bytes: FlatBuffer table/vtable offsets, vector counts, and Arrow buffer
offsets/lengths. Building with `-no-bounds-check` (or relying on multi-pointer
string slicing) previously exposed out-of-bounds reads or arbitrary memory
disclosure.

### A1. Unvalidated FlatBuffer offsets -> OOB read / panic — ✅ *done*
The metadata read primitives (`_rd_i32/i16/i64/u32` + `_rd_u8`) are
bounds-safe: an out-of-range position (from attacker offsets, including a
negative `vt = tbl - soff`) returns 0 instead of reading out of bounds — free,
since they only touch the small FlatBuffer metadata. Remaining direct byte
indexes and slices in schema/field/record-batch parsers are guarded by an
overflow-safe `_fits(data, pos, size)` (written `pos <= len - size`), and
footer block bounds are tightened.

### A2. Unvalidated vector counts -> resource exhaustion / OOB — ✅ *done*
`n_nodes` / `n_bufs` are bounded against remaining metadata
(`nv + 4 + n_nodes*16 <= len(meta)`) before loops run, so bogus counts return
"malformed" instead of walking off the buffer. Footer `n_blocks` and
fields-vector counts are guarded similarly.

### A3. Integer overflow bypasses the body bounds check — ✅ *done*
Size/offset arithmetic that could overflow (`(col_len+1)*off_w`, `n_nodes*16`,
`n_fields*4`, block bounds) is rewritten in division/subtraction form so a
hostile count/length cannot wrap past a bounds check. Per-column buffer-size
validation ensures the validity bitmap covers `col_len` bits and fixed-width/bool
data holds `col_len` elements. Covered by `test_ipc_fuzz_no_crash` in
`tests/ipc_test.odin` (1,500 random mutations + every truncation length read
without crashing or leaking).

### A4. Offset buffers are never validated -> memory disclosure — ✅ *done*
`array_get_string` slices `buffers[2].data[start:end]` through a multi-pointer,
so crafted non-monotonic or out-of-range offsets previously leaked arbitrary
memory. Fixed: `_ipc_offsets_valid` verifies variable-length offset buffers
(`offsets[0] == 0`, monotonic, `<= data_buffer_len`) before returning a column,
gated by `validate` on `ipc_read_file`/`ipc_read_stream` (default ON;
`validate=false` for self-produced files). Covered by `test_ipc_rejects_bad_offsets`.

### A5. `mmap` lifetime, truncation & overwrite safety — ✅ *done*
A memory-mapped file truncated underneath by another process faults (`SIGBUS`)
on access of vanished pages. `use_mmap` on `ipc_read_file`/`ipc_read_stream`
defaults to `true` (zero-copy via POSIX `mmap` in `skadi/ipc_mmap_unix.odin`,
assuming a stable file); `use_mmap=false` reads into a private heap buffer via
`os.read_entire_file` so concurrent truncation cannot fault. Zero-copy batches
share an atomically refcounted `Record_Batch._ipc_backing` (`_IPC_Backing` with
`release`), unmapping only when the last batch is freed. On the write path,
`ipc_write_file` / `ipc_write_stream` intentionally omit `.Trunc` on open so
overwriting existing regular files reuses page-cache pages, using
`_ipc_truncate_if_regular` to shrink shorter outputs without failing on pipes,
sockets, or `/dev/null`, and chunking `writev` under `max(i32)` bytes for Darwin
safety.

> **Status: the entire A-section is done.** The IPC reader and writer are
> hardened against malformed, truncated, or adversarially mutated inputs and
> verified by unit, fuzz, and ATDD matrix specs.

---

## B. Performance — compatible (keep full Arrow interop)

### B1. Target-scoped AVX2 + explicit `#simd` widening — ✅ *done*
Early builds with `-microarch:native` regressed `sum_10m_i32` (`2.0 ms -> 4.9 ms`
on i7-7700HQ) due to poor `i32 -> i64` sign-extend/accumulate codegen. Rewriting
`_sum_sint_simd` and `_sum_uint_simd` in `skadi/compute_simd.odin` with explicit
`#simd[4]T -> #simd[4]i64/u64` widening and scoping AVX2 to the vector loops via
`@(enable_target_feature = _SIMD_TARGET_FEATURE)` (`"avx2"` on `amd64`, without
`#force_inline`) eliminated the regression. On Ryzen 7 7735U (`-o:speed -microarch:native`),
`sum_10m_i32` now runs in **2.45 ms ST / 1.45 ms MT** vs **3.29 ms** in Arrow
C++ `25.0.1` (**1.34× ST / 2.26× MT**).

### B2. Null-aware bulk aggregation — ✅ *done*
The null path in `skadi/compute.odin` walks the validity bitmap a **byte at a
time** (`_sum_typed`, `_min_typed`, `_max_typed`, `_min_max_typed`): an all-valid
byte (`0xFF`) coalesces into a run and dispatches to the SIMD kernels
(`_sum_run`, `_min_run`, `_max_run`, `_min_max_run`), all-null bytes (`0x00`) are
skipped, and only mixed bytes bit-test elements. Parallel chunk boundaries align
to multiples of 64 rows so the bulk path remains active in every worker.

**Measured:**
- Cache-resident null-sum (i7-7700HQ, 1.6 MB): **245 us -> 75 us/call (3.3×)**.
- `sum_10m_f64_nulls` (Ryzen 7 7735U, 1% nulls): **5.22 ms ST / 2.55 ms MT** vs
  **8.20 ms** in Arrow C++ `25.0.1` (**1.57× ST / 3.22× MT**, `0` allocs).

### B3. Widen SIMD coverage — ✅ *done*
`skadi/compute_simd.odin` now provides target-scoped SIMD kernels across all
numeric widths:
- `_sum_f64_simd` (4-way `#simd[4]f64`) and `_sum_f32_simd` (`#simd[4]f32 -> #simd[4]f64`).
- `_sum_sint_simd` and `_sum_uint_simd` covering `i8`/`i16`/`i32` and `u8`/`u16`/`u32`.
- 4-way unrolled `f64` accumulators for `i64`/`u64` (avoiding FP chain stalls).
- Generic `_min_typed_simd`, `_max_typed_simd`, and `_min_max_typed_simd`
  (`#simd[K]T`, `K :: 32 / size_of(T)`) across every integer and float type.

### B4. Selectivity-hybrid `filter` & prefetched `take` — ✅ *done*
- **`compute_filter` (`skadi/compute.odin`)** uses a selectivity-hybrid strategy on
  unaligned/null-free masks: sparse masks (`out_count * 4 < n`) run a 64-bit
  **`tzcnt`** loop visiting only set bits (`filter_10m_i32_sparse`: **0.45 ms ST**
  vs **1.49 ms** Arrow C++ `25.0.1`, **3.28×**); dense masks walk bytes via the
  256-entry `_BYTE_INDICES_LUT` (`filter_10m_i32` 50% pass: **5.25 ms ST /
  2.47 ms MT** vs **40.02 ms** Arrow C++, **7.63× ST / 16.17× MT**).
  `compute_filter_parallel` handles both fixed-width and variable-length
  (`String_Type`/`Binary_Type`, **0.65 ms MT** vs **4.82 ms** C++, **7.44×**).
- **`compute_take` & `compute_take_parallel`** use a validity-free fast path with
  explicit software prefetching (`intrinsics.prefetch_read_data` at distance 12)
  and unconditional release-mode bounds enforcement (`take_1m_i32`: **7.36 ms ST /
  2.01 ms MT** vs **9.02 ms** Arrow C++, **1.22× ST / 4.49× MT**).

### B5. Persistent thread pool, `Hardware_Config` & Sleipnir actors — ✅ *done*
- **`skadi/thread_pool.odin`:** Process-lifetime parked worker pool woken via
  condition-variable broadcast using raw heap allocations so the singleton never
  trips test tracking allocators (`PARALLEL_MIN_LENGTH = 262_144`).
- **`skadi/hardware_config.odin`:** Runtime sysfs discovery (up to 1,024 CPUs +
  `core:sys/info` fallback) of `L1d`/`L2`/`L3` cache sizes with lock-free atomic
  fast-path reads for adaptive morsel sizing.
- **`skadi/pipeline/sleipnir_pipeline.odin` (`deps/sleipnir/actor/`):** Lock-free
  work-stealing actors using pooled MPSC work batches (`Envelope_Pool`) and
  per-core `Sharded_SPSC_Mailbox` coordination for zero-alloc parallel reductions,
  dictionary histograms, and race-free MSB-bucket sorting.

### B6. Inlining, prefetch & vectored IPC — ✅ *done*
- Hot builder paths (`builder_append`, `builder_append_null`,
  `string_builder_append`, `string_builder_reserve_data`) are `#force_inline` on
  raw `[^]T` / `[^]u8` buffers with uninitialized data allocations and
  `Buffer_Pool` recycling (`array_build_10m_i32`: **13.78 ms** vs **33.24 ms**,
  **2.41×**; `string_build_1m`: **3.49 ms** vs **4.66 ms**, **1.34×**).
- `compute_take` / `selection_take` use `intrinsics.prefetch_read_data`.
- `ipc_write_file` / `ipc_write_stream` use scatter-gather `writev`
  (`_IPC_Vectored_Writer`), cutting `ipc_write_10m_i32` to **12.53 ms** vs
  **36.42 ms** (**2.91×**) and `ipc_roundtrip_10m_i32` to **13.07 ms** vs
  **46.97 ms** (**3.59×**, `0.0 MB` vs `38.1 MB` payload copies).

---

## C. Performance — at the expense of compatibility (the path to "superior")

These live outside the standard Arrow buffer layout or behind explicit boundaries,
using DuckDB / Velox / Umbra techniques to move fewer bytes and avoid pointer
chasing.

### C1. German-style ("Umbra") short-string inlining — ✅ *done*
Implemented (`skadi/umbra.odin`): fixed 16-byte `Umbra_String` slot
`{ length: u32, data: [12]u8 }` — inline for `length <= 12`, 4-byte prefix +
`i64` side-buffer offset otherwise — with `Umbra_Builder`, `umbra_get`,
`umbra_compare`, `umbra_count_eq`, 4-pass LSD prefix-radix + merge-sort
`umbra_sort_indices`, and `umbra_sort_range_into` for parallel buckets.

**Measured (100K random strings, `umbra_sort_100k_str` vs Arrow C++ `25.0.1`):**
- `umbra_sort_indices` (ST): **2.58 ms** vs **9.80 ms** C++ (**3.80×**).
- `pipeline_umbra_sort_indices` (Sleipnir actor MT): **0.27 ms** (**36.40×** vs
  C++, **9.57×** MT scale).

*Still open under C1:* SIMD prefix range filters and join-key hashing on inline slots.

### C2. Selection vectors & L1d `u16` morsels — ✅ *done*
Implemented (`skadi/selection.odin`, `skadi/compare.odin`): `Selection`
(surviving `i32` row indices), `compute_select`, comptime-`$OP`-monomorphised
`compute_compare*`, `compute_select_compare*`, `selection_refine_compare*`,
`compute_sum_selection`, `compute_min_max_selection`, `selection_take` (`Int8..64`,
`UInt8..64`, `Float32/64`, `String_Type`), and `record_batch_take`.

For L1d cache residency, `morsel_select_compare_f64_u16` and
`morsel_refine_compare_f64_u16` keep surviving row indices in `u16` sub-morsels
(`MORSEL_MAX_ROWS`), feeding `compute_sel_2pred_sum`,
`compute_sel_2pred_sum_parallel`, and Sleipnir actor `pipeline_sel_2pred_sum_f64`.

**Measured (`sel_2pred_sum_10m_f64` vs Arrow C++ `25.0.1`, `0` vs `4` allocs / `25.4 MB`):**
- Single-threaded: **13.93 ms** vs **21.92 ms** C++ (**1.57×**).
- Sleipnir actor (`pipeline_sel_2pred_sum_f64`): **5.76 ms** (**3.80×** vs C++).
- Thread-pool parallel (`compute_sel_2pred_sum_parallel`): **4.38 ms** (**5.00×** vs C++).

*Still open:* `selection_take` support for `Bool_Type`, `Binary_Type`, and `Large_*` types.

### C3. Operator fusion & Sleipnir super-morsels — ✅ *done (hand-fused + comptime monomorphisation)*
- **Single-pass mask fusion (`skadi/compute_fused.odin`):** `compute_sum_where`
  (**6.17 ms ST** vs **39.02 ms** Arrow C++ `25.0.1`, **6.32×**, `0` vs `38.1 MB`
  allocs), `compute_min_where`, `compute_max_where`, `compute_min_max_where`,
  `compute_mean_where`, `compute_count_where`.
- **Compile-time `$OP` fusion (`skadi/fusion.odin`, `skadi/compare.odin`, `skadi/pipeline/sleipnir_pipeline.odin`):**
  `compute_agg_where_compare` computes `sum, count, min, max` in one pass under
  a predicate with `0` mask/intermediate allocations (**10.32 ms ST** vs **39.39 ms**
  C++, **3.82×**). In parallel, `pipeline_agg_where_f64` drives 4-way unrolled
  `morsel_agg_f64_u16` across Sleipnir super-morsels in **4.46 ms** (**8.82×**
  vs C++, `0` allocs).

*Still open:* multi-predicate + heterogeneous predicate/value column fusion inside `fusion.odin` and a declarative expression planner.

### C4. Encoding-aware kernels (RLE & dictionary) — ✅ *done*
- **Run-end encoding (`skadi/rle.odin`):** `RLE_Array(T)` (with `run_ends`,
  `values`, and optional `run_valid` bitmask for null runs), coalescing
  `RLE_Builder(T)` (`rle_append`, `rle_append_null`, `NaN` run coalescing),
  `rle_encode`/`rle_decode`, `rle_is_null`, `rle_get`/`rle_try_get`, and
  `O(runs)` `rle_sum` / `rle_min_max`.
  - **Measured (`rle_sum_10m_f64`, 10K runs):** **0.01 ms (~12 us)** vs **6.43 ms**
    Arrow C++ `25.0.1` (**532.62×**, ~117 KB vs 76.3 MB, `0` allocs).
- **Dictionary encoding (`skadi/dict.odin` + `skadi/pipeline/sleipnir_pipeline.odin`):**
  `Str_Dict_Array` and generic `Dict_Array(T)` (`DICT_NULL_CODE :: -1` for nulls,
  `NaN`-deduplicating `dict_encode`, `str_dict_slice`/`dict_slice`, `O(n_dict)`
  `dict_min_max`, `dict_sum`, `*_value_counts`, `*_group_sum`), plus zero-alloc
  Sleipnir actor variants (`pipeline_dict_value_counts`, `pipeline_dict_group_sum`,
  `pipeline_dict_sum`).
  - **Measured (`dict_vc_1m_str`, 100 distinct):** **0.79 ms ST** (**7.73×** vs
    Arrow C++ `6.09 ms`) and **0.16 ms** Sleipnir actor (**37.95×** vs C++).

*Still open under C4:* multi-key hash group-by.

### C5. Drop the optional validity bitmap for declared non-null columns — *medium*
Runtime null checks are already skipped whenever `arr.buffers[0].data == nil`,
so kernels pay zero overhead on non-null arrays today; a schema-enforced
non-nullable static invariant could further simplify builder dispatch.

### C6. Native, FlatBuffer-free container format — *medium*
Keep Arrow IPC as the interchange wire format; a fixed-offset native Skadi-to-Skadi
format remains a future option if FlatBuffers encoding overhead ever dominates
small-batch workloads.

---

## Summary Status

- ✅ **A1–A5** (IPC bounds, integer overflow, offset validation, `mmap`/overwrite/Darwin safety) — **done**
- ✅ **B1–B6** (target-scoped AVX2/SIMD across numeric widths, byte-coalesced null reductions, `tzcnt`/LUT filter, prefetched take, persistent thread pool + `Hardware_Config` + Sleipnir actors, `#force_inline` builders + vectored `writev`) — **done**
- ✅ **C1–C4** (Umbra strings, `Selection` + L1d `u16` morsels, operator fusion + super-morsels, RLE with null runs + numeric/string dictionary + actor histograms) — **done**

**Result:** Across all **26 canonical 1v1 workloads** in `benchmarks/RESULTS.md`,
Skadi beats Apache Arrow C++ `25.0.1` (`-O3`) single-threaded (`1.05×`–`532.62×`)
and scales to `2.26×`–`37.95×` with thread pools and Sleipnir actors.
