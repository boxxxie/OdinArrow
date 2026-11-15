# Specification: Parquet & CSV CLI Streaming Tools Hardening

## Overview
Remediates Thrift wire protocol corruption, definition-level decoding crashes, bit-unpacking truncation, delimiter split bugs across buffer boundaries, resource exhaustion, and unhandled I/O errors in `parquet_to_csv_odin`, `csv_to_parquet_odin`, and accompanying FFI utilities.

## Functional Requirements

### 1. Thrift Compact Protocol Decoder Hardening (`examples/parquet_to_csv/thrift.odin`)
- In `thrift_skip` for `THRIFT_MAP`, read the varint element count before reading the key/value type byte, strictly adhering to Thrift Compact Protocol specifications. If the map size is 0, do not consume a type byte.
- Add bounds checking across all primitive, varint, binary, and list reading procedures. Track and propagate `t.err` to prevent panics and out-of-bounds slicing on corrupted or truncated Parquet metadata.

### 2. Streaming Parquet Reader Robustness (`examples/parquet_to_csv/parquet_reader.odin`, `main.odin`)
- **Nullable (OPTIONAL) Columns**: Decode definition-level RLE/bit-packed streams rather than skipping them, extracting valid vs null row positions so values align with row numbers and do not read past allocated page buffers.
- **Multi-Row-Group & Fallback Dictionaries**: Retain per-row-group `dict_offset` and `has_dict` metadata. Prevent decoding row groups 1..N against row group 0's dictionary, and properly support pages falling back to `PLAIN` encoding (`ph.encoding == 0`).
- **Wide Bit-Unpacking**: In `decode_rle_into`, widen bit-packed decoding from 16 bits to 32/64 bits to support dictionary bit widths $\ge 10$ (dictionaries $> 512$ entries) without dropping high bits.
- **CLI & I/O Hygiene**: Add support for `INT64`, `FLOAT`, `DOUBLE`, and `BOOLEAN` in CSV emission; escape and quote CSV header names; avoid file descriptor exhaustion by reusing open file handles sequentially.

### 3. Streaming CSV Reader & Parquet Writer (`examples/csv_to_parquet/`)
- **Buffer-Boundary Refill**: In `csv_reader.odin`, call `csv_refill` when `\r` (for `\r\n`) or the opening quote `"` (for escaped `""`) falls on the last byte of `cs.buf`, preventing column desynchronization.
- **Row Boundary Validation**: Check `eor` (end of row) in `csv_stream_read_chunk` to detect and handle ragged or malformed rows.
- **Memory & Resource Cleanup**: Free `cs.buf` on header read errors or empty files; eliminate unused header arena allocations.
- **Page Size Limits**: Guard against $> 2\text{ GiB}$ column pages in `pw_write_column`.
- **I/O Error Checking**: Verify `os.write` return lengths and handle write errors/disk full conditions in both Parquet writer and IPC serialization.

### 4. FFI CLI Bridge Fixes (`benchmarks/*_ffi/main.odin`)
- Replace `string(errbuf[:])` with `cstring(&errbuf[0])` to prevent printing up to 1024 trailing NUL bytes on error.
- Provide explicit error messages when executed on unsupported operating systems.

## Non-Functional Requirements
- **Streaming Throughput**: Maintain streaming memory usage ($O(1)$ memory relative to file size) during large Parquet and CSV conversions.
- **Standards Conformance**: Strict compliance with Apache Parquet 2.0+ Thrift metadata and RFC 4180 CSV specifications.

## Acceptance Criteria
- [ ] Parquet files with OPTIONAL (nullable) columns convert to CSV with null values correctly positioned.
- [ ] Parquet files with multiple row groups and dictionaries $> 512$ entries decode with 100% value fidelity.
- [ ] CSV files with `\r\n` or `""` straddling 4 KiB buffer boundaries parse without column shifting or delimiter corruption.
- [ ] All CLI programs compile cleanly with `odin check examples/... & benchmarks/... -vet-strict-style -disallow-do`.
