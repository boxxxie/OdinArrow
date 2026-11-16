# Skadi Project Domain & Architecture Invariants

## 1. High-Signal Domain Invariants (Scout Focus)
- **Arrow IPC FlatBuffers & Bounds (`skadi/ipc.odin`):** Validate FlatBuffer vtable sizes (`vt_size`) with `_fits` before reading optional slots; omitted `Field.nullable` and `Int.isSigned` default to `false` per `Schema.fbs`. Use overflow-safe `_ipc_bitmap_bytes_needed` instead of `(col_len + 7) / 8`, and unaligned loads on untrusted offset views.
- **Selection Length Contract (`skadi/selection.odin`):** `Selection.indices` is often a caller/morsel scratch slice larger than `sel.length`. All `Selection` consumers must iterate `0..<sel.length`, never `len(sel.indices)`.
- **Cross-Allocator Builder Finish (`skadi/builders.odin`, `skadi/var_length.odin`):** Lazy validity bitmaps can have `b.bm_cap < (b.length + 7) / 8` after non-null appends; clamp copies to `b.bm_cap` and `0xFF`-fill trailing valid bytes before masking the final partial byte.
- **Buffer Resize Zeroing (`skadi/buffer.odin`):** Zero from `min(buf.size, old_cap)` on reallocating growth so shrunk or uninitialized tails are cleared.
- **Thrift & Parquet Bounds (`examples/parquet_to_csv/`):** Guard `pos + n` against signed `int` overflow before slicing or advancing cursors on untrusted inputs.

## 2. Project False-Positive Kill List (Do NOT Flag)
- **Two-Phase IEEE 754 NaN Min/Max Hot Loops (`_agg_where_float_mono`, `_min_max_selection_typed`):** Do NOT flag the Phase 2 `if v < lo { lo = v }; if v > hi { hi = v }` hot loop as missing NaN checks or order-dependent. Phase 1 seeds `lo`/`hi` with the first valid non-NaN value (`v == v`), and IEEE 754 `<`/`>` evaluate to `false` for any subsequent `NaN`, keeping `lo`/`hi` finite without per-row `v == v` or `seen` branches.
- **Intentional Uninitialized Hot Buffers (`= ---`, `buffer_make_uninit`, `mem.alloc_bytes_non_zeroed`):** Do NOT flag uninitialized stack morsel scratch (`ws`, `scratch_u16`, `b0..b3` in `skadi/pipeline/sleipnir_pipeline.odin`) or uninitialized value/offset builder buffers (`Buffer_Pool`) when indexed `[0..<length]` is fully overwritten before read.
- **Single-Threaded Reference Kernels vs SIMD/Actor Paths:** `morsel_*` and `pipeline_*` non-null fast paths are explicitly gated by `buffers[0].data == nil` and fall back to nullable kernels when bitmaps are present.
- **Sentinel-Padded / Non-Owned Views:** `array_slice` and `dict_slice` create non-owning buffer views with `.children = nil`; only top-level owners free buffers.

## 3. Repo Anchor Symbols
- **Core:** `Array`, `Buffer`, `Buffer_Pool`, `Primitive_Builder`, `_Var_Builder`, `Selection`, `Record_Batch`, `_IPC_Backing`, `Dict_Array`, `Umbra_Array`, `RLE_Array`
- **Pipeline:** `Morsel_Pipeline`, `Morsel_Work`, `Morsel_Subtotal`, `Hardware_Config`

## 4. Repo Test & Build Notes
- **Static check:** `make check` (`-vet -strict-style -disallow-do -warnings-as-errors` across 13 targets; see `ols.json`).
- **Tests:** `make test` (Odin unit tests, ATDD specs, Python comparator tests) and `make test-cpp` (Arrow C++ FFI parity).
- **Benchmarks:** `make bench-1v1` (`benchmarks/compare_1v1.py`) and `bash benchmarks/bench_odin_c.sh`.
