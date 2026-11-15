# Implementation Plan: Vectored I/O (`writev`) Zero-Copy Arrow IPC File & Stream Writer

## Phase 1: Vectored `_IPC_Vectored_Writer` & Unit Tests (`skadi/ipc.odin`, `tests/core_regressions_test.odin`)
Implements a batched POSIX `writev` writer with `IOV_MAX` chunking, partial-write recovery, and portable fallback.

- [x] Task: Add Vectored IPC Write & Edge-Case Tests (`tests/core_regressions_test.odin`)
    - [x] Test multi-batch, wide-schema (`> 1024` buffer segments to exercise `IOV_MAX` flushing), empty-column, nullable, and sliced-array IPC file and stream round-trips
- [x] Task: Implement `_IPC_Vectored_Writer` (`skadi/ipc.odin`)
    - [x] Add `iovec` queue with tiny inline header/token storage and static `[8]u8` zero-padding slice
    - [x] Implement batched `writev` flush handling `EINTR` and partial writes across `iovec` boundaries

---

## Phase 2: Wire `ipc_write_file` & `ipc_write_stream` & Benchmark (`skadi/ipc.odin`, `benchmarks/RESULTS.md`)
Replaces buffered staging writes in both public IPC writers and measures `ipc_write_10m_i32` and `ipc_roundtrip_10m_i32`.

- [x] Task: Convert `ipc_write_file` & `ipc_write_stream` to Vectored Submission (`skadi/ipc.odin`)
    - [x] Queue FlatBuffers metadata, padding, and `IPC_Body_Buffer` payloads directly into `_IPC_Vectored_Writer`
    - [x] Verify lifetime of temp-allocated FlatBuffers slices stays alive until `writev` flush completes
- [x] Task: Verify Compilers, Tests & IPC Benchmarks (`benchmarks/RESULTS.md`)
    - [x] Run `odin check` (`-vet -strict-style -disallow-do -warnings-as-errors`) and `odin test tests`
    - [x] Run `python3 benchmarks/compare_1v1.py --groups ipc --compare-last` and update `benchmarks/RESULTS.md`
