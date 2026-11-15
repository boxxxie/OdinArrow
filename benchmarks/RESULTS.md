# Skadi Benchmark Analysis

Head-to-head comparison of **Skadi** against **Apache Arrow C++ `25.0.1`**
(`-O3`, the same LLVM-compiled library PyArrow wraps, called directly through
its C/C++ API) and **PyArrow** (Python).

## Environment

| | |
|---|---|
| CPU | AMD Ryzen 7 7735U with Radeon Graphics (8 cores / 16 threads, L1d 32 KB, L2 512 KB, L3 16 MB) |
| Arrow C++ | Apache Arrow C++ `25.0.1` (`-O3`; plus PyArrow for 3-way comparisons) |
| Odin | `odin build -o:speed -microarch:native` |
| Timing & Stats | `time.tick_now` / `steady_clock`, `--runs 5 --warmup 1` (**median of 5 trials** + Welch's two-sample z-test via `make bench-1v1`) |
| Workload | 10M elements (numeric), 1M elements (strings / take / `i32` sort / dict), 100K elements (string & Umbra sort) |

Reproduce: `make bench-1v1` (or `python3 benchmarks/compare_1v1.py --from-jsonl`
to inspect saved JSONL snapshots), `bash benchmarks/bench_odin_c.sh`, or
`bash benchmarks/compare.sh` (3-way with PyArrow).

## Methodology note

The canonical 1v1 suite ([`compare_1v1.py`](compare_1v1.py), persisted in
`benchmarks/odin.jsonl`, `benchmarks/cpp.jsonl`, and `benchmarks/history.jsonl`)
reports **apples-to-apples single-threaded timings (`Odin ST` vs `Arrow C++ ST`)**
alongside **multi-threaded and Sleipnir actor scaling (`Odin MT`, `MT vs C++`,
`MT Scale`)**, memory throughput (`GB/s`), and per-run allocation telemetry
(`Allocs`, `Alloc MB`). Significance is computed with Welch's two-sample z-test
(`*` indicates `z >= 1.96`, `~` indicates within measurement noise). Both sides
use recycling memory pools (`Buffer_Pool` in Skadi, `arrow::default_memory_pool()`
in Arrow C++).

## Headline summary (commit `fa6a1e4`)

Below is a summary of the core workloads against Arrow C++ `25.0.1` ST; the
complete 32-row statistical table (including `Δ Prev`, `z`-scores, `GB/s`,
`Allocs`, `Alloc MB`, `MT Scale`, and `CV%`) is maintained in
[Statistical 1v1 Comparison](#statistical-1v1-comparison-odin-st--mt-vs-arrow-c-st).

| Benchmark | Odin ST (ms) | Odin MT (ms) | Arrow C++ ST (ms) | ST Speedup | MT vs C++ |
|---|---:|---:|---:|---:|---:|
| `array_build_10m_i32` (1% nulls) | 13.78 | - | 33.24 | **2.41×** | - |
| `string_build_1m` (2% nulls) | 3.49 | - | 4.66 | **1.34×** | - |
| `sum_10m_f64` | 4.00 | 2.24 | 6.50 | **1.63×** | **2.91×** |
| `sum_10m_f64_nulls` (1% nulls) | 5.22 | 2.55 | 8.20 | **1.57×** | **3.22×** |
| `sum_10m_i32` | 2.45 | 1.45 | 3.29 | **1.34×** | **2.26×** |
| `min_max_10m_i32` | 2.19 | 1.04 | 2.37 | **1.09×** | **2.29×** |
| `filter_10m_i32` (50% pass) | 5.25 | 2.47 | 40.02 | **7.63×** | **16.17×** |
| `take_1m_i32` | 7.36 | 2.01 | 9.02 | **1.22×** | **4.49×** |
| `sort_indices_1m_i32` | 22.49 | 4.98 (actor) | 40.99 | **1.82×** | **8.23×** |
| `sort_indices_100k_str` | 2.58 | 0.33 (actor) | 9.68 | **3.76×** | **28.90×** |
| `string_scan_1m` | 1.08 | - | 1.14 | **1.05×** | - |
| `sum_where_10m_f64` | 6.17 | - | 39.02 | **6.32×** | - |
| `agg_where_10m_f64` | 10.32 | 4.46 (actor) | 39.39 | **3.82×** | **8.82×** |
| `sel_2pred_sum_10m_f64` | 13.93 | 4.38 (5.76 actor) | 21.92 | **1.57×** | **5.00×** (3.80× actor) |
| `dict_vc_1m_str` | 0.79 | 0.16 (actor) | 6.09 | **7.73×** | **37.95×** |
| `rle_sum_10m_f64` | 0.01 | - | 6.43 | **532.62×** | - |
| `umbra_sort_100k_str` | 2.58 | 0.27 (actor) | 9.80 | **3.80×** | **36.40×** |
| `ipc_roundtrip_10m_i32` (w+r) | 13.07 | - | 46.97 | **3.59×** | - |

Ratios `> 1×` mean Skadi is faster than Arrow C++.

## Per-benchmark analysis

### Array & string builders (`array_build_10m_i32`, `string_build_1m`)
Skadi builds 10M `i32` values with 1% nulls in **13.78 ms** vs **33.24 ms**
in Arrow C++ (**2.41×**, `z = 27.2*`, `2(2p)/2` allocs / `39.3 MB`), and builds
1M strings with 2% nulls in **3.49 ms** vs **4.66 ms** (**1.34×**, `z = 3.9*`,
`3(3p)/3` allocs / `14.4 MB`). Three optimizations drive this: **zero-copy
`finish()`** (handing value, offset, and validity buffers directly to the
`Array`), **uninitialized data allocation** (skipping redundant zeroing), and
the **`Buffer_Pool`** recycling warm, pre-faulted blocks (`2p` / `3p` pool hits)
alongside raw-buffer indexed writes in `String_Builder` (`string_builder_reserve_data`).

### Reductions — `sum_10m_f64`, `sum_10m_f64_nulls`, `sum_10m_i32`, `min_max_10m_i32`
Single-threaded multi-accumulator SIMD kernels beat Arrow C++ across all four
reductions and scale cleanly on 8C/16T:
- `sum_10m_f64`: **4.00 ms ST** (`20.0 GB/s`) / **2.24 ms MT** (`35.8 GB/s`) vs
  **6.50 ms** C++ (**1.63× ST** / **2.91× MT**, `z = 16.7*`, `0` allocs).
- `sum_10m_f64_nulls` (1% nulls): **5.22 ms ST** (`15.6 GB/s`) / **2.55 ms MT**
  vs **8.20 ms** C++ (**1.57× ST** / **3.22× MT**, `z = 25.1*`, `0` allocs).
  Skadi walks the validity bitmap a byte at a time: an all-valid byte
  (`0xFF`) coalesces 8 elements into a SIMD run, all-null bytes are skipped, and
  only mixed bytes bit-test individual elements.
- `sum_10m_i32`: **2.45 ms ST** / **1.45 ms MT** vs **3.29 ms** C++
  (**1.34× ST** / **2.26× MT**, `z = 3.6*`).
- `min_max_10m_i32`: **2.19 ms ST** (`18.3 GB/s`) / **1.04 ms MT** (`38.5 GB/s`)
  vs **2.37 ms** C++ (**1.09× ST** / **2.29× MT**, `z = 1.6~` ST — both are
  at the DRAM bandwidth floor per core, with Odin scaling `2.11×` multi-threaded).

### Filter, compare, cast, add & take
- `filter_10m_i32` (50% pass): **5.25 ms ST** / **2.47 ms MT** vs **40.02 ms**
  C++ (**7.63× ST** / **16.17× MT**, `z = 11.7*`). Exact output sizing via
  popcount plus a byte-at-a-time mask loop avoids dynamic resizing.
- `filter_10m_i32_sparse` (1% pass): **0.45 ms ST** (`90.7 GB/s`) vs **1.49 ms**
  C++ (**3.28×**, `z = 18.2*`).
- `filter_1m_string` (50% pass): **3.74 ms ST** / **0.65 ms MT** vs **4.82 ms**
  C++ (**1.29× ST** / **7.44× MT**, `5.78×` MT scale).
- `compare_gt_10m_i32` (**2.08 ms** vs **5.89 ms**, **2.84×**, `z = 101.2*`),
  `compare_gt_10m_f64` (**4.32 ms** vs **7.57 ms**, **1.75×**, `z = 69.7*`),
  `cast_10m_i32_f64` (**3.79 ms** vs **7.93 ms**, **2.09×**, `z = 27.2*`), and
  `arith_add_10m_f64` (**6.84 ms** vs **11.97 ms**, **1.75×**, `23.4 GB/s`,
  `z = 16.3*`) benefit from monomorphised SIMD loops and recycled `Buffer_Pool`
  allocations (`1(1p)` pool hit).
- `take_1m_i32`: **7.36 ms ST** / **2.01 ms MT** vs **9.02 ms** C++ (**1.22× ST**
  / **4.49× MT**, `3.67×` MT scale) using a validity-free fast path and explicit
  software prefetching (`intrinsics.prefetch_read_data`).

### Radix & string sorting (`sort_indices_1m_i32`, `sort_indices_100k_str`)
`sort_indices_1m_i32` uses a packed 8-byte `(key_u32, idx_u32)` LSD radix sort
in **22.49 ms ST** vs **40.99 ms** Arrow C++ (**1.82×**, `z = 15.3*`), skipping
constant radix bytes automatically. On 8C/16T, `pipeline_sort_indices` runs a
race-free, zero-merge-pass Sleipnir actor MSB-bucket parallel radix sort in
**4.98 ms** (**8.23×** vs C++, **4.52×** MT scale). For `sort_indices_100k_str`,
Skadi packs an 8-byte string prefix for LSB radix passes + stable merge-sort
tie-breaking (`string_sort_range_into`) in **2.58 ms ST** vs **9.68 ms** C++
(**3.76×**, `z = 90.0*`), and **0.33 ms** on Sleipnir actors (**28.90×** vs C++,
**7.69×** MT scale).

### String scan — `string_scan_1m`
Skadi walks the `offsets` buffer in a tight loop summing lengths (`string_view_sum_lengths`)
in **1.08 ms ST** (`12.9 GB/s`) vs **1.14 ms** Arrow C++ ST (`12.2 GB/s`,
**1.05×**, `z = 4.8*`, `0` allocs). (In 3-way comparisons with PyArrow, Python's
`utf8_length` + `sum` kernel dispatch takes ~9.5 ms — ~9× slower.)

### Arrow IPC — vectored `writev` & `mmap` zero-copy reads
- `ipc_write_10m_i32`: **12.53 ms ST** (`0` heap allocs) vs **36.42 ms** Arrow
  C++ (**2.91×**, `z = 29.2*`). The IPC writer emits metadata and column buffers
  via scatter-gather `writev` (`_ipc_writev_all`) with zero intermediate payload
  copies.
- `ipc_read_mmap_10m_i32`: **0.02 ms ST** vs **0.16 ms** Arrow C++ (**7.17×**,
  `z = 32.0*`). The reader maps the file with `mmap` (`PROT_READ`,
  `MAP_PRIVATE`) and exposes columns as zero-copy views released via
  `Record_Batch._ipc_backing.release` (`munmap`) in `record_batch_free`, with a
  transparent read fallback on non-POSIX targets.
- `ipc_roundtrip_10m_i32` (write + read): **13.07 ms ST** vs **46.97 ms** Arrow
  C++ (**3.59×**, `z = 2.5*`, `0.0 MB` vs `38.1 MB` heap copies).

## Takeaways

- **Single-threaded parity surpassed across all 26 1v1 workloads:** Skadi
  beats Arrow C++ `25.0.1` on every single-threaded benchmark in the suite
  (`1.05×`–`532.62×`, `z >= 1.96` on 25/26 rows; `min_max_10m_i32` sits at the
  memory-bandwidth floor at `1.09×` ST and `2.29×` MT).
- **Multi-threaded & Sleipnir actor scaling:** Thread-pool `*_parallel` kernels
  and cache-resident Sleipnir actor pipelines (`skadi/pipeline/sleipnir_pipeline.odin`)
  deliver `2.26×`–`37.95×` end-to-end speedups over single-threaded Arrow C++
  with `0` steady-state heap allocations on fused and reduction hot paths.
- **vs PyArrow:** Skadi leads by `1.3×`–`20×+` across standard kernels due
  to eliminating Python interpreter and generic dispatch overhead.

## Optimizations applied

- **Vectored IPC (`writev`) + `mmap` zero-copy reads:** Zero-copy scatter-gather
  writes (`12.53 ms`, `2.91×`) and `mmap` views (`0.02 ms`, `7.17×`) cut IPC
  roundtrip payload heap allocations to `0.0 MB` (`3.59×` vs C++).
- **Zero-copy builders + `Buffer_Pool`:** `finish()` transfers ownership without
  copying, data allocations are uninitialized (`alloc_bytes_non_zeroed`), and
  `Buffer_Pool` recycles freed blocks (`2.41×` on `array_build_10m_i32`).
- **Null-aware byte-coalesced aggregation:** All-valid `0xFF` bytes dispatch to
  SIMD runs, reducing `sum_10m_f64_nulls` overhead while holding `1.57×` ST /
  `3.22×` MT over C++.
- **Packed `u32` LSD radix sort & Sleipnir MSB-bucket actors:** Cuts integer
  sorting to `22.49 ms` ST (`1.82×`) and `4.98 ms` actor MT (`8.23×`), and
  string/Umbra sorting to `0.33 ms` / `0.27 ms` (`28.90×` / `36.40×`).
- **L1d `u16` morsels, `Hardware_Config`, & Sleipnir super-morsel fusion:**
  Sysfs cache discovery (`skadi/hardware_config.odin`) and `Sharded_SPSC_Mailbox`
  worker reduction achieve `0`-alloc `4.46 ms` fused 4-aggregates (`8.82×` vs
  C++) and `0.16 ms` dictionary `value_counts` (`37.95×` vs C++).

## Encoding-aware kernels — run-end encoding (beyond Arrow's plain layout)

The aggregation experiments all converged on one lesson: the headline kernels
are **memory-bound**, so the durable win is moving fewer bytes. Run-end encoding
does exactly that — it stores a column of `length` elements as `k` runs
(`run_ends` + per-run `values`) and aggregates over the runs, never touching the
elements the encoding collapsed.

10M-element `f64` column with 1000-long runs (10K runs), single-threaded
(`rle_sum_10m_f64` vs plain `sum_10m_f64`):

| | time | size |
|---|---:|---:|
| Plain `sum_10m_f64` (Arrow C++ `25.0.1`) | 6.43 ms | 76.3 MB |
| Plain `sum_10m_f64` (Skadi)          | 4.00 ms | 76.3 MB |
| **`rle_sum` (Skadi)**                | **0.01 ms (~12 µs)** | **~117 KB** |

That is **532.62× faster** (`z = 354.0*`) than Arrow C++ `25.0.1`'s plain sum
and **~330× faster** than Skadi's own plain SIMD sum, on **~667× less memory**
(`0` heap allocs). In earlier 3-way PyArrow runs, PyArrow `pc.sum` took ~6.0 ms
because it must decode back to a dense float array first. This is a
compatibility-breaking layout (kept as a separate `RLE_Array(T)` type, not in
the Arrow `Array` union).

## Umbra short strings — comparison without the pointer chase

Arrow's `[offsets:i32][bytes:u8]` Utf8 layout takes a cache miss into the data
buffer on **every** string comparison. Umbra ("German") strings store each
element in a fixed 16-byte slot — `{ length:u32, data:[12]u8 }` — with the bytes
inline for length ≤ 12 and a 4-byte **prefix** + side-buffer offset otherwise.
The prefix lives in the slot, so most comparisons resolve in registers without
touching the data buffer at all, and `umbra_sort_indices` runs a 4-pass LSD
radix sort over the 4-byte prefix before merge-sorting equal-prefix runs.

Canonical 1v1 suite — sorting 100K random strings (`umbra_sort_100k_str`):

| | time | vs Arrow C++ ST |
|---|---:|---:|
| Arrow C++ `25.0.1` ST (`sort_indices`)        | 9.80 ms | 1.00× |
| Skadi `umbra_sort_indices` (ST)           | 2.58 ms | **3.80×** (`z = 50.5*`) |
| **Skadi `pipeline_umbra_sort_indices` (Sleipnir Actor)** | **0.27 ms** | **36.40×** (`9.57×` MT scale) |

(On larger 1M ~20-char strings in earlier 3-way PyArrow runs, Umbra sort cut
Arrow-layout sort from 518 ms and PyArrow's 415 ms down to **272 ms**.) The
cost is ~30% more memory (fixed 16-byte slots vs `offsets + bytes`) — the
classic Umbra trade. Kept as a separate `Umbra_Array` type, transcoded at an
Arrow/IPC boundary.

## Dictionary encoding — group-by as an integer histogram

For a low-cardinality column, store the distinct values once and an `i32` `code`
per element. The codes **are** the group ids, so `value_counts`/group-by is an
integer histogram over the codes — no string hashing or comparison.

Canonical 1v1 suite — `value_counts` on 1M strings with 100 distinct values
(`dict_vc_1m_str`):

| | time | vs Arrow C++ ST |
|---|---:|---:|
| Arrow C++ `25.0.1` ST (`value_counts`)        | 6.09 ms | 1.00× |
| Skadi `str_dict_value_counts` (ST)        | 0.79 ms | **7.73×** (`z = 129.4*`) |
| **Skadi `pipeline_dict_value_counts` (Sleipnir Actor)** | **0.16 ms** | **37.95×** (`4.91×` MT scale, `24.9 GB/s`) |

The Sleipnir actor path uses worker-private scratch buffers (including 4-bank
`[257]u32` stack histograms for `dict_len <= 256`) and reduces per-worker
buckets with `1` output allocation. (In earlier 10M-string PyArrow runs,
`str_dict_value_counts` ran in **6.6 ms** vs PyArrow's **190.6 ms** plain /
**62.6 ms** dictionary.) `str_dict_group_sum` and `pipeline_dict_group_sum`
extend the same histogram pattern to grouped aggregation.

A generic numeric `Dict_Array(T)` adds the same to numeric columns. Its standout
is **min/max**: every logical element is one of the dictionary values, so the
column min/max is just min/max of the (tiny) dictionary — `O(n_dict)`,
independent of length. On 10M `f64` (100 distinct), `dict_min_max` resolves in
**~0.1 µs** vs ~12.8 ms for a full plain scan.

Honest counter-example, same file: **`dict_sum` is _not_ a win (~0.80×)** — it
reads the narrower `i32` codes but the indexed lookup + accumulation is
compute/latency-bound and loses to the plain SIMD sum. It's kept for summing an
already-encoded column without decoding (`pipeline_dict_sum` also handles it
zero-alloc), not as a speedup over plain arrays.

## Fusion, selection vectors & Sleipnir super-morsel pipeline

The most direct application of "move fewer bytes": don't build the intermediate
filtered array at all.

**Operator fusion (`sum_where_10m_f64`).** `compute_sum_where(values, mask)`
computes filter+sum in a single pass with `0` heap allocations (`0/1` allocs vs
`38.1 MB` in Arrow C++): **6.17 ms ST** (`13.2 GB/s`) vs **39.02 ms** Arrow C++
`25.0.1` ST (**6.32×**, `z = 85.2*`).

**Fused 4-aggregate pass (`agg_where_10m_f64`).** Beyond hand-written
`sum_where`, `compute_agg_where_compare` computes **sum, count, min, and max in
one pass under a predicate**, monomorphised at compile time on the value type
and `$OP` — with no mask array and no filtered array. In parallel,
`pipeline_agg_where_f64` partitions across Sleipnir super-morsels using
4-way unrolled `morsel_agg_f64_u16` and reduces partials via `Sharded_SPSC_Mailbox`
with `0` steady-state heap allocations:

| | time | vs Arrow C++ ST | Allocs (Odin/C++) |
|---|---:|---:|---:|
| Arrow C++ `25.0.1` ST (mask + filter + aggs) | 39.39 ms | 1.00× | - / 2 (`39.3 MB`) |
| Skadi `compute_agg_where_compare` (ST)     | 10.32 ms | **3.82×** (`z = 74.3*`) | `0` / 2 |
| **Skadi `pipeline_agg_where_f64` (Sleipnir Actor)** | **4.46 ms** | **8.82×** (`2.31×` MT scale, `35.8 GB/s`) | **`0` / 2** |

**Selection vectors & chained predicates (`sel_2pred_sum_10m_f64`).**
`compute_select_compare` + `selection_refine_compare` evaluate conjunctive (`AND`)
predicates over a batch without materialising intermediate columns, keeping only
surviving row indices in a `Selection`. For cache-resident execution,
`morsel_select_compare_f64_u16` and `pipeline_sel_2pred_sum_f64` process
L1d-sized `u16` index morsels discovered via `Hardware_Config`
(`skadi/hardware_config.odin`):

| | time | vs Arrow C++ ST | Allocs / Alloc MB |
|---|---:|---:|---:|
| Arrow C++ `25.0.1` ST (`and` + filter + sum) | 21.92 ms | 1.00× | 4 / `25.4 MB` |
| Skadi 2-pred morsel selection + sum (ST) | 13.93 ms | **1.57×** (`z = 12.3*`) | **`0` / `0.0 MB`** |
| Skadi 2-pred Sleipnir Actor (`pipeline_sel_2pred_sum_f64`) | **5.76 ms** | **3.80×** (`2.42×` MT scale, `41.6 GB/s`) | **`0` / `0.0 MB`** |
| **Skadi 2-pred thread-pool parallel (MT)** | **4.38 ms** | **5.00×** (`3.18×` MT scale, `54.7 GB/s`) | **`0` / `0.0 MB`** |

Each added predicate narrows the surviving `u16` morsel indices instead of
re-copying unused columns — in earlier 4-conjunct runs (`WHERE c0..c3 > 50 →
SUM(pay)` on 10M rows), chained selection ran **3.66× faster** than
materialise-between (`54.8 ms` vs `200.8 ms`), and the `-o:speed -microarch:native`
build accelerates the monomorphised compare cleanly across all 16 threads.


## Statistical 1v1 Comparison (Odin ST / MT vs Arrow C++ ST)

Measured on commit `fa6a1e4` (`--runs 5 --warmup 1`, Odin `-o:speed -microarch:native`, Apache Arrow C++ `25.0.1` `-O3`) via `make bench-1v1` (`benchmarks/compare_1v1.py`, outputting `benchmarks/odin.jsonl`, `benchmarks/cpp.jsonl`, and `benchmarks/history.jsonl`). Significance is computed with two-sample Welch's z-test (`*` indicates `z >= 1.96`, `~` indicates within measurement noise); `MT Scale` reports `odin_st / odin_mt`.

<!-- BENCHMARK_1V1_START -->

| Benchmark | Group | Odin ST (ms) | Δ Prev | Arrow C++ ST (ms) | ST Speedup (z) | Odin GB/s | C++ GB/s | Allocs (Odin/C++) | Alloc MB (Odin/C++) | Odin MT (ms) | MT vs C++ | MT Scale | Odin ST CV% | C++ CV% |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `array_build_10m_i32` | builders | 13.78 | +0.5%~ | 33.24 | 2.41x (27.2*) | 3.0 | 1.2 | 2(2p)/2 | 39.3/39.3 | - | - | - | 3.3% | 4.7% |
| `sum_10m_f64` | compute | 4.00 | -5.4%~ | 6.50 | 1.63x (16.7*) | 20.0 | 12.3 | 0/0 | 0.0/0.0 | 2.24 | 2.91x | 1.79x | 7.3% | 2.2% |
| `sum_10m_f64_nulls` | compute | 5.22 | -11.3%* | 8.20 | 1.57x (25.1*) | 15.6 | 9.9 | 0/0 | 0.0/0.0 | 2.55 | 3.22x | 2.05x | 4.2% | 1.9% |
| `sum_10m_i32` | compute | 2.45 | +10.8%* | 3.29 | 1.34x (3.6*) | 16.4 | 12.2 | 0/0 | 0.0/0.0 | 1.45 | 2.26x | 1.69x | 10.7% | 10.6% |
| `min_max_10m_i32` | compute | 2.19 | +0.9%~ | 2.37 | 1.09x (1.6~) | 18.3 | 16.8 | 0/0 | 0.0/0.0 | 1.04 | 2.29x | 2.11x | 3.8% | 11.2% |
| `filter_10m_i32` | compute | 5.25 | -17.1%~ | 40.02 | 7.63x (11.7*) | 7.9 | 1.0 | 1(1p)/1 | 19.1/19.1 | 2.47 | 16.17x | 2.12x | 10.1% | 16.5% |
| `string_build_1m` | strings | 3.49 | +3.0%~ | 4.66 | 1.34x (3.9*) | 4.1 | 3.0 | 3(3p)/3 | 14.4/14.4 | - | - | - | 16.9% | 0.5% |
| `string_scan_1m` | strings | 1.08 | -1.5%~ | 1.14 | 1.05x (4.8*) | 12.9 | 12.2 | 0/0 | 0.0/0.0 | - | - | - | 0.8% | 2.6% |
| `ipc_roundtrip_10m_i32` | ipc | 13.07 | -56.2%* | 46.97 | 3.59x (2.5*) | 3.1 | 0.9 | 6/5 | 0.0/38.1 | - | - | - | 3.1% | 71.3% |
| `compare_gt_10m_i32` | compute | 2.08 | -5.0%* | 5.89 | 2.84x (101.2*) | 19.3 | 6.8 | 1(1p)/1 | 1.2/1.2 | - | - | - | 2.3% | 1.2% |
| `arith_add_10m_f64` | compute | 6.84 | +7.3%~ | 11.97 | 1.75x (16.3*) | 23.4 | 13.4 | 1(1p)/1 | 76.3/76.3 | - | - | - | 6.2% | 4.4% |
| `cast_10m_i32_f64` | compute | 3.79 | +1.5%~ | 7.93 | 2.09x (27.2*) | 10.6 | 5.0 | 1(1p)/1 | 76.3/76.3 | - | - | - | 3.9% | 3.9% |
| `take_1m_i32` | compute | 7.36 | -3.4%* | 9.02 | 1.22x (8.2*) | 1.6 | 1.3 | 1(1p)/1 | 3.8/3.8 | 2.01 | 4.49x | 3.67x | 3.2% | 4.5% |
| `sort_indices_1m_i32` | compute | 22.49 | -25.5%* | 40.99 | 1.82x (15.3*) | 0.2 | 0.1 | 1(1p)/1 | 7.6/7.6 | 4.98 | 8.23x | 4.52x | 6.9% | 5.0% |
| `filter_1m_string` | strings | 3.74 | -9.4%* | 4.82 | 1.29x (12.8*) | 3.8 | 2.9 | 3(3p)/3 | 6.5/6.6 | 0.65 | 7.44x | 5.78x | 0.7% | 4.0% |
| `sum_where_10m_f64` | fusion | 6.17 | -15.8%* | 39.02 | 6.32x (85.2*) | 13.2 | 2.1 | 0/1 | 0.0/38.1 | - | - | - | 2.6% | 2.2% |
| `agg_where_10m_f64` | fusion | 10.32 | +10.7%* | 39.39 | 3.82x (74.3*) | 15.5 | 4.1 | 0/2 | 0.0/39.3 | 4.46 | 8.82x | 2.31x | 2.3% | 2.2% |
| `sel_2pred_sum_10m_f64` | fusion | 13.93 | -17.9%* | 21.92 | 1.57x (12.3*) | 17.2 | 10.9 | 0/4 | 0.0/25.4 | 4.38 | 5.00x | 3.18x | 6.2% | 5.2% |
| `dict_vc_1m_str` | encoding | 0.79 | +2.0%~ | 6.09 | 7.73x (129.4*) | 5.1 | 0.7 | 1/3 | 0.0/0.0 | 0.16 | 37.95x | 4.91x | 7.9% | 1.1% |
| `rle_sum_10m_f64` | encoding | 0.01 | +2.3%* | 6.43 | 532.62x (354.0*) | 9.9 | 12.4 | 0/0 | 0.0/0.0 | - | - | - | 0.2% | 0.6% |
| `umbra_sort_100k_str` | encoding | 2.58 | -26.9%* | 9.80 | 3.80x (50.5*) | 1.2 | 0.2 | 1(1p)/1 | 0.8/0.8 | 0.27 | 36.40x | 9.57x | 12.0% | 0.6% |
| `ipc_write_10m_i32` | ipc | 12.53 | -54.5%* | 36.42 | 2.91x (29.2*) | 3.2 | 1.1 | 0/2 | 0.0/0.0 | - | - | - | 6.0% | 4.5% |
| `ipc_read_mmap_10m_i32` | ipc | 0.02 | +42.7%* | 0.16 | 7.17x (32.0*) | 1819.0 | 253.5 | 6/0 | 0.0/0.0 | - | - | - | 8.4% | 5.9% |
| `compare_gt_10m_f64` | compute | 4.32 | +3.5%* | 7.57 | 1.75x (69.7*) | 18.5 | 10.6 | 1(1p)/1 | 1.2/1.2 | - | - | - | 1.7% | 1.0% |
| `filter_10m_i32_sparse` | compute | 0.45 | -40.4%* | 1.49 | 3.28x (18.2*) | 90.7 | 27.6 | 1(1p)/1 | 0.4/0.4 | - | - | - | 20.8% | 4.6% |
| `sort_indices_100k_str` | strings | 2.58 | +0.3%~ | 9.68 | 3.76x (90.0*) | 0.8 | 0.2 | 1(1p)/1 | 0.8/0.8 | 0.33 | 28.90x | 7.69x | 5.7% | 0.9% |
| `sel_2pred_sum_10m_f64_actor` | fusion | 5.76 | -31.7%* | 21.92 | 3.80x (23.1*) | 41.6 | 10.9 | 0/4 | 0.0/25.4 | - | - | 2.42x | 16.3% | 5.2% |
| `sort_indices_1m_i32_actor` | compute | 4.98 | -72.2%* | 40.99 | 8.23x (14.2*) | 0.8 | 0.1 | 1(1p)/1 | 7.6/7.6 | - | - | 4.52x | 66.6% | 5.0% |
| `sort_indices_100k_str_actor` | strings | 0.33 | -95.0%* | 9.68 | 28.90x (233.7*) | 6.0 | 0.2 | 1(1p)/1 | 0.8/0.8 | - | - | 7.69x | 6.5% | 0.9% |
| `umbra_sort_100k_str_actor` | encoding | 0.27 | -96.3%* | 9.80 | 36.40x (228.8*) | 11.9 | 0.2 | 1(1p)/1 | 0.8/0.8 | - | - | 9.57x | 24.2% | 0.6% |
| `agg_where_10m_f64_actor` | fusion | 4.46 | - | 39.39 | 8.82x (76.6*) | 35.8 | 4.1 | 0/2 | 0.0/39.3 | - | - | 2.31x | 11.7% | 2.2% |
| `dict_vc_1m_str_actor` | encoding | 0.16 | - | 6.09 | 37.95x (202.1*) | 24.9 | 0.7 | 1/3 | 0.0/0.0 | - | - | 4.91x | 5.5% | 1.1% |

<!-- BENCHMARK_1V1_END -->
