// Streaming RFC 4180 CSV reader.
package csv_to_parquet

import "base:intrinsics"
import "core:io"
import "core:os"
import oa "../../skadi"

CSV_Stream :: struct {
	file:      ^os.File,
	buf:       []u8,      // raw read buffer (owned)
	buf_len:   int,       // valid bytes in buf
	buf_pos:   int,       // parse cursor in buf
	eof:       bool,
	read_err:  os.Error,  // non-nil on os.read failure (excluding io.Error.EOF)
	row_err:   bool,      // set true on ragged/malformed row or quote syntax error
	col_names: []string,  // column headers (heap-allocated, freed on destroy)
	n_cols:    int,
}

// csv_stream_open opens path, reads the header row, and returns a ready reader.
csv_stream_open :: proc(path: string, buf_size: int, open_err: ^os.Error = nil) -> (CSV_Stream, bool) {
	fd, err := os.open(path)
	if err != nil {
		if open_err != nil {
			open_err^ = err
		}
		return {}, false
	}
	cs: CSV_Stream
	cs.file    = fd
	cs.buf     = make([]u8, buf_size)

	csv_refill(&cs)

	names: [dynamic]string
	field_tmp := make([dynamic]u8, 0, 256)
	defer delete(field_tmp)
	for {
		clear(&field_tmp)
		field, eor, eof := csv_read_field_view(&cs, &field_tmp)
		if eof && len(field) == 0 && len(names) == 0 { break }
		// Make a stable heap copy of the name.
		name_buf := make([]u8, len(field))
		copy(name_buf, field)
		append(&names, string(name_buf))
		if eor { break }
	}

	if cs.read_err != nil {
		if open_err != nil {
			open_err^ = cs.read_err
		}
		for s in names { delete(transmute([]u8)s) }
		delete(names)
		delete(cs.buf)
		os.close(fd)
		return {}, false
	}

	if cs.row_err || len(names) == 0 || (len(names) == 1 && len(names[0]) == 0) {
		for s in names { delete(transmute([]u8)s) }
		delete(names)
		delete(cs.buf)
		os.close(fd)
		return {}, false
	}
	cs.col_names = names[:]
	cs.n_cols    = len(names)
	return cs, true
}

csv_stream_destroy :: proc(cs: ^CSV_Stream) {
	if cs.file != nil { os.close(cs.file) }
	delete(cs.buf)
	for s in cs.col_names { delete(transmute([]u8)s) }
	delete(cs.col_names)
}

csv_stream_at_eof :: proc(cs: ^CSV_Stream) -> bool {
	return cs.eof && cs.buf_pos >= cs.buf_len
}

// csv_refill compacts unprocessed bytes to the front of the buffer and reads more.
csv_refill :: proc(cs: ^CSV_Stream) {
	remaining := cs.buf_len - cs.buf_pos
	if remaining > 0 {
		copy(cs.buf[:remaining], cs.buf[cs.buf_pos:cs.buf_len])
	}
	cs.buf_len = remaining
	cs.buf_pos = 0
	n, err := os.read(cs.file, cs.buf[cs.buf_len:])
	if err != nil && err != io.Error.EOF {
		cs.read_err = err
		cs.eof = true
		return
	}
	cs.buf_len += n
	if n == 0 || err == io.Error.EOF { cs.eof = true }
}

// csv_read_field_view reads the next CSV field, returning a view into `cs.buf`
// when an unquoted field fits in the current buffer window, or using `dst`
// when unescaping quotes or spanning a buffer refill.
// Returns (field, end_of_row, end_of_file).
csv_read_field_view :: proc(cs: ^CSV_Stream, dst: ^[dynamic]u8) -> (field: string, eor: bool, eof: bool) {
	// Ensure some data is available.
	if cs.buf_pos >= cs.buf_len {
		if cs.eof { return "", true, true }
		csv_refill(cs)
		if cs.buf_pos >= cs.buf_len { return "", true, true }
	}

	if cs.buf[cs.buf_pos] == '"' {
		// ── Quoted field ──────────────────────────────────────────────────────
		cs.buf_pos += 1 // skip opening quote
		closed := false
		qloop: for {
			for cs.buf_pos < cs.buf_len {
				ch := cs.buf[cs.buf_pos]
				if ch == '"' {
					cs.buf_pos += 1
					if cs.buf_pos >= cs.buf_len && !cs.eof {
						csv_refill(cs)
					}
					if cs.buf_pos < cs.buf_len && cs.buf[cs.buf_pos] == '"' {
						// Escaped double-quote
						append(dst, '"')
						cs.buf_pos += 1
					} else {
						// Closing quote
						closed = true
						break qloop
					}
				} else {
					append(dst, ch)
					cs.buf_pos += 1
				}
			}
			// May have hit end of buffer mid-field; refill and continue.
			if cs.buf_pos >= cs.buf_len {
				if cs.eof { break qloop }
				csv_refill(cs)
			}
		}
		if !closed {
			cs.row_err = true
			return string(dst[:]), true, false
		}
		eor = csv_consume_sep(cs)
		return string(dst[:]), eor, false
	}

	// ── Unquoted field ────────────────────────────────────────────────────────
	vc :: #simd[16]u8{',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ','}
	vl :: #simd[16]u8{'\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n'}
	vr :: #simd[16]u8{'\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r'}
	for {
		start := cs.buf_pos
		found_sep := false
		for cs.buf_pos + 16 <= cs.buf_len {
			v := intrinsics.unaligned_load((^#simd[16]u8)(&cs.buf[cs.buf_pos]))
			m := intrinsics.simd_lanes_eq(v, vc) |
			     intrinsics.simd_lanes_eq(v, vl) |
			     intrinsics.simd_lanes_eq(v, vr)
			mask := transmute(u16)intrinsics.simd_extract_msbs(m)
			if mask != 0 {
				cs.buf_pos += int(intrinsics.count_trailing_zeros(mask))
				found_sep = true
				break
			}
			cs.buf_pos += 16
		}
		if !found_sep {
			for cs.buf_pos < cs.buf_len {
				ch := cs.buf[cs.buf_pos]
				if ch == ',' || ch == '\n' || ch == '\r' {
					found_sep = true
					break
				}
				cs.buf_pos += 1
			}
		}

		if found_sep {
			end := cs.buf_pos
			ch := cs.buf[end]
			if len(dst^) == 0 && (ch != '\r' || end + 1 < cs.buf_len || cs.eof) {
				eor = csv_consume_sep(cs)
				return string(cs.buf[start:end]), eor, false
			}
			append(dst, ..cs.buf[start:end])
			eor = csv_consume_sep(cs)
			return string(dst[:]), eor, false
		}

		append(dst, ..cs.buf[start:cs.buf_pos])
		// End of buffer; refill and continue scanning.
		if cs.eof {
			return string(dst[:]), true, len(dst^) == 0
		}
		csv_refill(cs)
	}
}

// csv_consume_sep advances past a comma or newline.  Returns true if row ended.
csv_consume_sep :: proc(cs: ^CSV_Stream) -> (eor: bool) {
	if cs.buf_pos >= cs.buf_len {
		if cs.eof { return true }
		csv_refill(cs)
	}
	if cs.buf_pos >= cs.buf_len { return true }

	ch := cs.buf[cs.buf_pos]
	if ch == ',' {
		cs.buf_pos += 1
		return false
	}
	if ch == '\r' {
		cs.buf_pos += 1
		if cs.buf_pos >= cs.buf_len && !cs.eof {
			csv_refill(cs)
		}
		if cs.buf_pos < cs.buf_len && cs.buf[cs.buf_pos] == '\n' {
			cs.buf_pos += 1
		}
		return true
	}
	if ch == '\n' {
		cs.buf_pos += 1
		return true
	}
	cs.row_err = true
	return true
}

// csv_stream_read_chunk reads up to max_rows rows and returns one Skadi
// String_Type Array per column.  Returns nil arrays and n=0 at EOF.
// The caller owns the returned slice and each Array; free with:
//   for ci in 0..<csv.n_cols { oa.array_free(&arrays[ci]) }
//   delete(arrays)
csv_stream_read_chunk :: proc(cs: ^CSV_Stream, max_rows: int) -> (arrays: []oa.Array, n: int) {
	if cs.row_err || cs.read_err != nil || csv_stream_at_eof(cs) { return nil, 0 }

	builders := make([]oa.String_Builder, cs.n_cols)
	for ci in 0..<cs.n_cols {
		builders[ci] = oa.string_builder_make(max_rows)
	}

	field_tmp := make([dynamic]u8, 0, 4096)
	defer delete(field_tmp)

	for n < max_rows && !csv_stream_at_eof(cs) && !cs.row_err && cs.read_err == nil {
		ok := true
		eor := false
		for ci in 0..<cs.n_cols {
			clear(&field_tmp)
			field: string
			var_eof: bool
			field, eor, var_eof = csv_read_field_view(cs, &field_tmp)
			if cs.row_err || cs.read_err != nil {
				ok = false
				break
			}
			if var_eof && eor && ci == 0 && len(field) == 0 { ok = false; break }
			oa.string_builder_append(&builders[ci], field)
			if eor && ci + 1 < cs.n_cols {
				cs.row_err = true
				ok = false
				break
			}
		}
		if !ok { break }
		if !eor {
			cs.row_err = true
			break
		}
		n += 1
	}

	if cs.row_err || cs.read_err != nil || n == 0 {
		for ci in 0..<cs.n_cols { oa.string_builder_destroy(&builders[ci]) }
		delete(builders)
		return nil, 0
	}

	arrays = make([]oa.Array, cs.n_cols)
	for ci in 0..<cs.n_cols {
		arr, finish_err := oa.string_builder_finish(&builders[ci])
		assert(finish_err == nil, "csv_stream_read_chunk: string_builder_finish failed")
		arrays[ci] = arr
		oa.string_builder_destroy(&builders[ci])
	}
	delete(builders)
	return
}
