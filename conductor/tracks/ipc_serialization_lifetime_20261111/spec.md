# Specification: Arrow IPC Sliced Serialization & Refcounted Lifetime

## Overview
Resolves critical IPC data corruption when serializing sliced arrays, prevents use-after-free crashes across multi-batch zero-copy readers via refcounted backing buffers, enforces IPC file tail magic verification, and eliminates duplicate schema memory leaks.

## Functional Requirements

### 1. Sliced Array IPC Serialization (`skadi/ipc.odin`)
- Ensure `_ipc_encode_record_batch` respects `col.offset` when serializing:
  - Validity bitmaps: bit-shift validity bits so the serialized bitmap starts at bit 0 representing `col.offset`.
  - Bool buffers: bit-shift data bitmap to start at bit 0 for sliced boolean columns.
  - Fixed-width numeric buffers: serialize slice `data[col.offset * width .. (col.offset + col.length) * width]`.
  - String & binary offset buffers: re-base offsets to 0 (`out_offsets[i] = raw_offsets[offset + i] - raw_offsets[offset]`) and accurately serialize only the sliced variable-length value bytes.

### 2. Multi-Batch Refcounted Zero-Copy Lifetime (`skadi/record_batch.odin`, `skadi/ipc.odin`)
- Implement a thread-safe refcounted backing structure (`Shared_Backing`) for memory-mapped files and stream allocations.
- Each `Record_Batch` returned by `ipc_read_file` or `ipc_read_stream` holds a pointer to the `Shared_Backing` and increments its reference count.
- Freeing `batches[0]` must not unmap or free the underlying memory while `batches[1..N]` remain alive.
- The backing memory is freed or unmapped only when the final referencing `Record_Batch` is destroyed via `record_batch_free`.

### 3. IPC Tail Magic & Schema Leak Fixes (`skadi/ipc.odin`)
- In `ipc_read_file`, verify the trailing 6-byte magic marker (`IPC_MAGIC_TAIL` == `"ARROW1"`). Reject files with missing or malformed tail markers.
- In `ipc_read_stream`, when encountering subsequent `_IPC_HEADER_SCHEMA` messages, free the existing `schema.fields` and cloned string allocations before overwriting them to prevent memory leaks.
- In `_ipc_decode_record_batch`, eliminate redundant allocation and deallocation of `cols_copy` by moving `columns` directly into `Record_Batch`.

## Non-Functional Requirements
- **Interoperability**: Sliced IPC files and streams must roundtrip cleanly through PyArrow and Apache Arrow C++ without errors.
- **Zero-Copy**: Multi-batch IPC file reads must retain true zero-copy performance without buffer duplication.
- **Memory Safety**: No memory leaks or double frees verified across multi-batch IPC life cycles.

## Acceptance Criteria
- [ ] Sliced record batches (numeric and string columns) serialized to IPC files can be read back and verify identical values and nulls.
- [ ] In a multi-batch IPC file, freeing `batches[0]` before accessing `batches[1..N]` does not segfault and data in remaining batches remains valid.
- [ ] `ipc_read_file` rejects files truncated before or missing `IPC_MAGIC_TAIL`.
- [ ] `ipc_read_stream` handles streams with updated/duplicate schemas without memory leaks.
- [ ] All tests pass under `odin test tests -collection:skadi=skadi`.
