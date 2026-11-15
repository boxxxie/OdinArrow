# Implementation Plan: Parquet & CSV CLI Streaming Tools Hardening

## Phase 1: Thrift Compact Protocol Decoder Hardening
Hardens Thrift metadata parsing and resolves map header decoding order.

- [x] Task: Thrift Parser Unit Tests (`50e9288`)
    - [x] Add unit test parsing empty Thrift map headers and verifying correct byte consumption (`tests/parquet_internals_test.odin`: `test_thrift_skip_empty_and_non_empty_map`)
    - [x] Add unit test with truncated Thrift payload asserting error propagation without bounds panic (`tests/parquet_internals_test.odin`: `test_thrift_and_page_header_reject_truncated_and_allow_empty_dict`)
    - [x] Verify tests fail as expected (Red Phase)
- [x] Task: Implement Thrift Decoder Fixes (`49b2e7f`)
    - [x] Update `examples/parquet_to_csv/thrift.odin`: read varint size before type byte in `thrift_skip` for maps
    - [x] Add bounds checks to all read and skip procedures, setting `t.err` on unexpected EOF (`thrift.odin` `Thrift.err` propagated in `parse_page_header` and `parse_footer_struct`)
    - [x] Verify all Thrift unit tests pass cleanly
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Thrift Compact Protocol Decoder Hardening' (Protocol in workflow.md)

---

## Phase 2: Parquet Reader Definition Levels, Bit-Unpacking & Multi-RG Dictionaries
Enables full support for nullable columns, large dictionaries, and multi-row-group Parquet files.

- [x] Task: Parquet Decoding Tests (`50e9288`)
    - [x] Add test converting Parquet file with nullable columns, verifying CSV null placements (`tests/parquet_internals_test.odin`, `specs/workflows_spec_test.odin`)
    - [x] Add test with dictionary bit width $\ge 10$ (> 512 distinct values), asserting high bits are preserved (`tests/parquet_internals_test.odin`: `test_parquet_rle_bit_unpack_wide_dictionaries`)
    - [x] Add test with multiple row groups using independent dictionaries (`specs/workflows_spec_test.odin`: `spec_parquet_multi_row_group_dictionary_and_nullable_to_csv`)
    - [x] Verify current reader fails or corrupts data (Red Phase)
- [x] Task: Implement Parquet Reader Fixes (`49b2e7f`, `e942b04`, `791df3e`)
    - [x] Update `examples/parquet_to_csv/parquet_reader.odin`: decode definition levels into validity bitmaps
    - [x] Update `decode_rle_into`: expand bit-unpacking logic to read full words for bit widths >= 10 (plus zero-run/truncated-run hardening)
    - [x] Track per-row-group `dict_offset` and support fallback to PLAIN encoding (RG-level and page-level PLAIN fallback)
    - [x] Update `examples/parquet_to_csv/main.odin`: quote headers, add `INT64`/`FLOAT`/`DOUBLE`/`BOOLEAN` column support, propagate `out_flush` short-write errors
    - [x] Verify test suite passes (`tests/parquet_internals_test.odin`: `test_parquet_int64_double_boolean_to_csv`)
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Parquet Reader Definition Levels, Bit-Unpacking & Multi-RG Dictionaries' (Protocol in workflow.md)

---

## Phase 3: CSV Streaming Reader Buffer Refill & Row Boundary Validation
Eliminates CSV column desynchronization on buffer boundaries and handles ragged rows.

- [x] Task: CSV Reader Boundary Tests (`50e9288`)
    - [x] Add test parsing CSV where `\r\n` is split across 4 KiB buffer boundary (`specs/workflows_spec_test.odin`: `spec_csv_parquet_boundary_streaming`)
    - [x] Add test parsing CSV where escaped quote `""` lands on buffer boundary (`specs/workflows_spec_test.odin`: `spec_csv_parquet_boundary_streaming`)
    - [x] Add test with malformed row width verifying clean error detection (`tests/parquet_internals_test.odin`: `test_csv_ragged_rows_rejected_no_leak`)
    - [x] Verify tests fail or desynchronize columns (Red Phase)
- [x] Task: Implement CSV Reader Fixes (`49b2e7f`)
    - [x] Update `examples/csv_to_parquet/csv_reader.odin`: call `csv_refill` in `csv_consume_sep` and `csv_read_field_into` on trailing split characters
    - [x] Validate `eor` in `csv_stream_read_chunk` and reject mismatched row lengths (`test_csv_ragged_rows_rejected_no_leak`)
    - [x] Clean up buffer allocations on empty or invalid CSV files (`test_csv_empty_file_no_leak` & `test_csv_newline_only_header_rejected_no_leak`)
    - [x] Verify CSV parsing tests pass
- [ ] Task: Conductor - User Manual Verification 'Phase 3: CSV Streaming Reader Buffer Refill & Row Boundary Validation' (Protocol in workflow.md)

---

## Phase 4: Parquet Writer Page Bounds, I/O Error Checking & FFI Bridge Fixes
Guards against 2 GiB page overflows, checks I/O return codes, and cleans up FFI strings.

- [~] Task: Parquet Writer and FFI Tests
    - [ ] Add fault-injection unit test checking `os.write` disk-full failure handling in parquet and IPC writers (`page_overflow` and `write_err`/`Short_Write` guards implemented in `parquet_writer.odin` and `skadi/ipc.odin`)
    - [ ] Add unit test validating `cstring` error conversion in FFI wrappers (`benchmarks/*_ffi/main.odin` use `cstring(&errbuf[0])`)
    - [x] Verify strict compiler checks pass across all FFI and CLI targets
- [x] Task: Implement Writer Bounds and FFI String Fixes
    - [x] Update `examples/csv_to_parquet/parquet_writer.odin`: guard page size `<= max(i32)` (`page_overflow`)
    - [x] Check `os.write` return lengths and propagate disk errors in writer routines (`skadi/ipc.odin` `_ipc_write_all`, `examples/parquet_to_csv/main.odin` `out_flush`, and `examples/csv_to_parquet/parquet_writer.odin` `pw_flush`/`pw_write_bytes`)
    - [x] Update FFI wrappers to print `cstring(&errbuf[0])` and handle OS fallbacks (`benchmarks/csv_to_parquet_ffi/main.odin`, `benchmarks/parquet_to_csv_ffi/main.odin`)
    - [x] Run `odin check` on all programs with `-vet -strict-style -disallow-do` (all 4 `examples/* & benchmarks/*` pass)
- [ ] Task: Conductor - User Manual Verification 'Phase 4: Parquet Writer Page Bounds, I/O Error Checking & FFI Bridge Fixes' (Protocol in workflow.md)
