# Specification: Vectored I/O (`writev`) Zero-Copy Arrow IPC File & Stream Writer

## Overview
While Skadi leads Arrow C++ on `ipc_read_mmap_10m_i32` (`0.02 ms` vs `0.10 ms`, `6.19x`) and `ipc_roundtrip_10m_i32` (`29.82 ms` vs `39.48 ms`, `1.32x`), `ipc_write_10m_i32` is currently at a statistical dead tie (`27.51 ms` vs `27.39 ms`, `1.00x~`).

Currently, `_IPC_Writer` in `skadi/ipc.odin` stages small framing headers, alignment padding bytes, and partial leading page-alignment slices via `_ipc_w_write` into a staging buffer before issuing separate `os.write` calls for large column bodies. Replacing this with POSIX vectored scatter-gather `writev` allows metadata headers, 8-byte zero-padding slices, and column buffers (`desc.data[:desc.length]`) to be submitted directly from memory without userspace staging copies and with far fewer syscalls.

---

## Functional Requirements

### 1. Vectored `_IPC_Vectored_Writer` (`skadi/ipc.odin`)
- Implement a vectored scatter-gather writer on Linux/POSIX (`core:sys/posix` or `core:sys/linux` `writev` syscall) with `IOV_MAX` batching (e.g., `1024` iovecs per syscall) and full partial-write advancement (`written < total_chunk_bytes`), plus a clean portable fallback for non-POSIX targets.
- Use a static 8-byte zero-padding buffer for 8-byte alignment padding (`meta_pad` and `body_pad`) and tiny inline staging only for scalar framing tokens (`IPC_CONTINUATION`, `meta_size`, `footer_len`, magic headers/footers), avoiding userspace `copy()` staging of column data buffers.

### 2. Zero-Copy `iovec` Emission in `ipc_write_file` & `ipc_write_stream` (`skadi/ipc.odin`)
- Wire `ipc_write_file` and `ipc_write_stream` to append `iovec` descriptors pointing directly to:
  - Header magic (`ARROW1\0\0`)
  - Encapsulated Schema & RecordBatch FlatBuffer metadata slices + 8-byte padding
  - Column `IPC_Body_Buffer` payloads (`desc.data[:desc.length]`) + 8-byte alignment padding
  - EOS marker, Footer FlatBuffer, footer length, and tail magic (`ARROW1`)
- Preserve 100% byte-identical Arrow IPC File and Stream layout, alignment, and PyArrow / Arrow C++ interoperability.

### 3. Benchmark & Verification (`tests/core_regressions_test.odin`, `benchmarks/compare_1v1.py`, `benchmarks/RESULTS.md`)
- Verify byte-level round-trip equivalence across primitive, nullable, sliced, empty, `Utf8`, `LargeUtf8`, `Binary`, and multi-batch IPC files and streams.
- Benchmark `ipc_write_10m_i32` (`27.51 ms` baseline) and `ipc_roundtrip_10m_i32` (`29.82 ms` baseline) via `benchmarks/compare_1v1.py --groups ipc`.

---

## Non-Functional Requirements
- **Zero Extra Column Copies:** Body buffers must be referenced directly via `iovec` pointers rather than copied into an intermediate staging buffer.
- **Partial-Write & `EINTR` Safety:** Handle `EINTR` and short `writev` returns cleanly without truncating or corrupting file offsets.
- **Compiler & Test Hygiene:** Pass `odin check` (`-vet -strict-style -disallow-do -warnings-as-errors`) and `odin test tests` with `0` memory leaks.

---

## Acceptance Criteria
- [x] `ipc_write_file` and `ipc_write_stream` emit files byte-compatible with the existing IPC reader, Arrow C++, and PyArrow across single-batch and multi-batch datasets (including partial `writev` handling).
- [x] Vectored writer handles payloads exceeding `IOV_MAX` iovecs (e.g., wide tables / many batches) cleanly across batched `writev` calls.
- [x] `ipc_write_10m_i32` and `ipc_roundtrip_10m_i32` are benchmarked via `benchmarks/compare_1v1.py --groups ipc` and recorded in `benchmarks/RESULTS.md`.
- [x] All compiler checks and unit tests pass with zero warnings and zero memory leaks.

---

## Out of Scope
- Asynchronous `io_uring` file submission or IPC compression (`LZ4_FRAME` / `ZSTD`).
