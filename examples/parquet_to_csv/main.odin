package parquet_to_csv

import "base:intrinsics"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:time"
import oa "../../skadi"

// ── output buffer ─────────────────────────────────────────────────────────────

Out :: struct {
	fd:        ^os.File,
	buf:       []u8,
	pos:       int,
	write_err: os.Error,
}

out_make :: proc(fd: ^os.File) -> Out {
	return Out{fd = fd, buf = make([]u8, 1 << 20)}
}

out_destroy :: proc(o: ^Out) { delete(o.buf) }

out_flush :: proc(o: ^Out) {
	if o.pos == 0 || o.write_err != nil {
		o.pos = 0
		return
	}
	written := 0
	for written < o.pos {
		n, err := os.write(o.fd, o.buf[written:o.pos])
		if err != nil {
			o.write_err = err
			break
		}
		if n <= 0 {
			o.write_err = io.Error.Short_Write
			break
		}
		written += n
	}
	o.pos = 0
}

out_bytes :: proc(o: ^Out, b: []u8) {
	if len(b) == 0 || o.write_err != nil { return }
	src := b
	for len(src) > 0 {
		avail := len(o.buf) - o.pos
		n := min(avail, len(src))
		copy(o.buf[o.pos:], src[:n])
		o.pos += n
		src = src[n:]
		if o.pos == len(o.buf) {
			out_flush(o)
			if o.write_err != nil { return }
		}
	}
}

out_str :: proc(o: ^Out, s: string) { out_bytes(o, transmute([]u8)s) }

// out_csv_field writes s as a CSV field, quoting per RFC 4180 when needed.
out_csv_field :: proc(o: ^Out, s: string) {
	b := transmute([]u8)s
	n := len(b)
	needs_quoting := false
	i := 0
	if n >= 16 {
		vq :: #simd[16]u8{'"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"', '"'}
		vc :: #simd[16]u8{',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ',', ','}
		vl :: #simd[16]u8{'\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n', '\n'}
		vr :: #simd[16]u8{'\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r', '\r'}
		for i + 16 <= n {
			v := intrinsics.unaligned_load((^#simd[16]u8)(&b[i]))
			m := intrinsics.simd_lanes_eq(v, vq) |
			     intrinsics.simd_lanes_eq(v, vc) |
			     intrinsics.simd_lanes_eq(v, vl) |
			     intrinsics.simd_lanes_eq(v, vr)
			if intrinsics.simd_extract_msbs(m) != {} {
				needs_quoting = true
				break
			}
			i += 16
		}
	}
	if !needs_quoting {
		for ; i < n; i += 1 {
			c := b[i]
			if c == '"' || c == ',' || c == '\n' || c == '\r' {
				needs_quoting = true
				break
			}
		}
	}
	if !needs_quoting {
		out_str(o, s)
		return
	}
	out_str(o, "\"")
	start := 0
	for k := 0; k < n; k += 1 {
		if b[k] == '"' {
			out_str(o, s[start:k+1])
			out_str(o, "\"")
			start = k + 1
		}
	}
	out_str(o, s[start:])
	out_str(o, "\"")
}

out_i32 :: proc(o: ^Out, v: i32) {
	tmp: [16]u8
	s := strconv.write_int(tmp[:], i64(v), 10)
	out_str(o, s)
}

out_i64 :: proc(o: ^Out, v: i64) {
	tmp: [24]u8
	s := strconv.write_int(tmp[:], v, 10)
	out_str(o, s)
}

out_f32 :: proc(o: ^Out, v: f32) {
	tmp: [64]u8
	s := strconv.write_float(tmp[:], f64(v), 'g', -1, 32)
	if len(s) > 0 && s[0] == '+' { s = s[1:] }
	out_str(o, s)
}

out_f64 :: proc(o: ^Out, v: f64) {
	tmp: [64]u8
	s := strconv.write_float(tmp[:], v, 'g', -1, 64)
	if len(s) > 0 && s[0] == '+' { s = s[1:] }
	out_str(o, s)
}

out_bool :: proc(o: ^Out, v: bool) {
	out_str(o, "true" if v else "false")
}

// ── main ──────────────────────────────────────────────────────────────────────

parse_cli_args :: proc(args: []string) -> (max_mb: int, in_path: string, out_path: string, ok: bool) {
	max_mb = 200
	out_path = "-"
	has_out := false
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "-m" {
			if i + 1 >= len(args) { return 0, "", "", false }
			v, v_ok := strconv.parse_int(args[i + 1])
			if !v_ok || v <= 0 || i64(v) > max(i64) / (1024 * 1024) { return 0, "", "", false }
			max_mb = v
			i += 2
			continue
		}
		if len(arg) > 0 && arg[0] == '-' {
			// Allow standalone "-" as the stdout output path only once in_path is set.
			if arg == "-" && in_path != "" && !has_out {
				out_path = "-"
				has_out = true
				i += 1
				continue
			}
			return 0, "", "", false
		}
		if in_path == "" {
			in_path = arg
		} else if !has_out {
			out_path = arg
			has_out = true
		} else {
			return 0, "", "", false
		}
		i += 1
	}
	if in_path == "" {
		return 0, "", "", false
	}
	return max_mb, in_path, out_path, true
}

main :: proc() {
	max_mb, in_path, out_path, args_ok := parse_cli_args(os.args[1:])
	if !args_ok {
		fmt.eprintln("usage: parquet_to_csv_odin [-m MB] <input.parquet> [output.csv]")
		fmt.eprintln("  -m MB   memory limit in MB (default: 200)")
		os.exit(1)
	}

	mem_limit := i64(max_mb) * 1024 * 1024
	t0 := time.now()

	num_rows, chunk_rows, conv_err := parquet_to_csv_stream(in_path, out_path, mem_limit)
	switch &e in conv_err {
	case nil:
	case Parquet_To_CSV_Open_Input_Error:
		fmt.eprintfln("error: cannot open %s: %v", in_path, e.err)
		os.exit(1)
	case Parquet_To_CSV_Bad_Footer_Error:
		fmt.eprintln("error: bad parquet footer")
		os.exit(1)
	case Parquet_To_CSV_Stream_Init_Error:
		col_name := string(e.name_buf[:e.name_len])
		if len(col_name) > 0 {
			fmt.eprintfln("error: failed to open stream for column %s", col_name)
		} else {
			fmt.eprintln("error: failed to open column stream")
		}
		os.exit(1)
	case Parquet_To_CSV_Open_Output_Error:
		fmt.eprintfln("error: cannot open %s: %v", out_path, e.err)
		os.exit(1)
	case Parquet_To_CSV_Write_Output_Error:
		fmt.eprintfln("error: write failed on %s: %v", out_path, e.err)
		os.exit(1)
	case Parquet_To_CSV_Unsupported_Column_Error:
		col_name := string(e.name_buf[:e.name_len])
		fmt.eprintfln("error: unsupported physical type %d for column %s", e.ptype, col_name)
		os.exit(1)
	case Parquet_To_CSV_Corrupt_Page_Error:
		col_name := string(e.name_buf[:e.name_len])
		if len(col_name) > 0 {
			fmt.eprintfln("error: corrupt or truncated page data in column %s", col_name)
		} else {
			fmt.eprintln("error: corrupt or truncated page data")
		}
		os.exit(1)
	}

	total_ns := time.duration_nanoseconds(time.since(t0))
	fmt.eprintfln("rows:       %d", num_rows)
	fmt.eprintfln("chunk_rows: %d", chunk_rows)
	fmt.eprintfln("mem_limit:  %dMB", max_mb)
	fmt.eprintfln("total_ms:   %.1f", f64(total_ns) / 1e6)
}

Parquet_To_CSV_Open_Input_Error :: struct {
	err: os.Error,
}

Parquet_To_CSV_Bad_Footer_Error :: struct {}

Parquet_To_CSV_Stream_Init_Error :: struct {
	name_buf: [256]u8,
	name_len: int,
}

Parquet_To_CSV_Open_Output_Error :: struct {
	err: os.Error,
}

Parquet_To_CSV_Write_Output_Error :: struct {
	err: os.Error,
}

Parquet_To_CSV_Unsupported_Column_Error :: struct {
	name_buf: [256]u8,
	name_len: int,
	ptype:    i32,
}

Parquet_To_CSV_Corrupt_Page_Error :: struct {
	name_buf: [256]u8,
	name_len: int,
}

Parquet_To_CSV_Error :: union {
	Parquet_To_CSV_Open_Input_Error,
	Parquet_To_CSV_Bad_Footer_Error,
	Parquet_To_CSV_Stream_Init_Error,
	Parquet_To_CSV_Open_Output_Error,
	Parquet_To_CSV_Write_Output_Error,
	Parquet_To_CSV_Unsupported_Column_Error,
	Parquet_To_CSV_Corrupt_Page_Error,
}

parquet_to_csv_stream :: proc(
	in_path:            string,
	out_path:           string,
	mem_limit:          i64,
	chunk_rows_override := 0,
) -> (num_rows: i64, chunk_rows: int, err: Parquet_To_CSV_Error) {
	// Open file once and share handle across footer read and all column streams
	file, file_err := os.open(in_path)
	if file_err != nil {
		return 0, 0, Parquet_To_CSV_Open_Input_Error{err = file_err}
	}
	defer os.close(file)

	file_size, sz_err := os.file_size(file)
	if sz_err != nil {
		return 0, 0, Parquet_To_CSV_Bad_Footer_Error{}
	}

	metas: []Column_Chunk_Meta
	footer_ok: bool
	num_rows, metas, footer_ok = parse_footer_from_file(file)
	defer {
		for &m in metas {
			delete(transmute([]u8)m.name)
			delete(m.extra_rg_data_offsets)
			delete(m.extra_rg_num_values)
			delete(m.extra_rg_dict_offsets)
			delete(m.extra_rg_has_dict)
		}
		delete(metas)
	}
	if !footer_ok || num_rows < 0 {
		return 0, 0, Parquet_To_CSV_Bad_Footer_Error{}
	}

	n_cols := len(metas)
	Col_Out_Kind :: enum u8 {
		Str,
		I32,
		I64,
		F32,
		F64,
		Bool,
	}
	col_kinds := make([]Col_Out_Kind, n_cols)
	defer delete(col_kinds)
	for i in 0 ..< n_cols {
		pt := metas[i].ptype
		switch pt {
		case PTYPE_BOOLEAN:    col_kinds[i] = .Bool
		case PTYPE_INT32:      col_kinds[i] = .I32
		case PTYPE_INT64:      col_kinds[i] = .I64
		case PTYPE_FLOAT:      col_kinds[i] = .F32
		case PTYPE_DOUBLE:     col_kinds[i] = .F64
		case PTYPE_BYTE_ARRAY: col_kinds[i] = .Str
		case:
			u_err: Parquet_To_CSV_Unsupported_Column_Error
			n_copy := min(len(metas[i].name), len(u_err.name_buf))
			copy(u_err.name_buf[:n_copy], metas[i].name[:n_copy])
			u_err.name_len = n_copy
			u_err.ptype = pt
			return 0, 0, u_err
		}
	}

	// Compute chunk_rows from memory budget.
	// Budget = 1 MB output buf + n_cols * 1 MB page bufs + chunk column arrays.
	overhead := i64(1 << 20) + i64(n_cols) * i64(1 << 20)
	avail    := mem_limit - overhead
	if avail < 8 * 1024 * 1024 { avail = 8 * 1024 * 1024 }

	bytes_per_row := i64(0)
	for i in 0..<n_cols {
		m := metas[i]
		if m.ptype == PTYPE_INT64 || m.ptype == PTYPE_DOUBLE {
			bytes_per_row += 8
		} else if m.ptype == PTYPE_INT32 || m.ptype == PTYPE_FLOAT {
			bytes_per_row += 4
		} else if m.ptype == PTYPE_BOOLEAN {
			bytes_per_row += 1
		} else if m.has_dict {
			bytes_per_row += 16 // just the string header; dict stays loaded
		} else {
			// PLAIN BYTE_ARRAY: string header + estimated value bytes
			avg := i64(80) // conservative default
			if m.num_values > 0 { avg = m.uncomp_size / m.num_values }
			bytes_per_row += 16 + avg
		}
	}
	if bytes_per_row == 0 { bytes_per_row = 80 }

	chunk_rows = int(avail / bytes_per_row)
	if num_rows > 0 && chunk_rows > int(num_rows) {
		chunk_rows = int(num_rows)
	}
	if chunk_rows_override > 0 {
		chunk_rows = chunk_rows_override
		if num_rows > 0 && chunk_rows > int(num_rows) {
			chunk_rows = int(num_rows)
		}
	}
	if chunk_rows < 1 {
		chunk_rows = 1
	}

	// Open per-column streaming readers sharing `file`
	streams := make([]Col_Stream, n_cols)
	initialized := 0
	defer {
		for j in 0 ..< initialized {
			col_stream_destroy(&streams[j])
		}
		delete(streams)
	}
	for j in 0 ..< n_cols {
		s, s_ok := col_stream_init_shared(file, file_size, metas[j])
		if !s_ok {
			init_err: Parquet_To_CSV_Stream_Init_Error
			n_copy := min(len(metas[j].name), len(init_err.name_buf))
			copy(init_err.name_buf[:n_copy], metas[j].name[:n_copy])
			init_err.name_len = n_copy
			return 0, 0, init_err
		}
		streams[j] = s
		initialized += 1
	}

	// Skadi arrays for the current chunk; one per column, freed after each chunk.
	chunk_arrays := make([]oa.Array, n_cols)
	defer delete(chunk_arrays)

	// Open output — declare the file handle at the same scope level as the Out
	// buffer to avoid lifetime issues with ^os.File inside nested blocks.
	opened_file: ^os.File
	using_file := out_path != "-"
	if using_file {
		f, open_err := os.open(out_path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
		if open_err != nil {
			return 0, 0, Parquet_To_CSV_Open_Output_Error{err = open_err}
		}
		opened_file = f
	}
	write_ok := false
	defer if using_file && opened_file != nil {
		os.close(opened_file)
		if !write_ok {
			_ = os.remove(out_path)
		}
	}

	out_file := opened_file if using_file else os.stdout

	o := out_make(out_file)
	defer out_destroy(&o)

	// CSV header
	for j in 0..<n_cols {
		if j > 0 { out_str(&o, ",") }
		out_csv_field(&o, metas[j].name)
	}
	out_str(&o, "\n")

	// Process in chunks
	rows_done := 0
	total     := int(num_rows)
	for rows_done < total {
		n := min(chunk_rows, total - rows_done)

		for j in 0..<n_cols {
			switch col_kinds[j] {
			case .I32:  chunk_arrays[j] = col_stream_to_i32_array(&streams[j], n)
			case .I64:  chunk_arrays[j] = col_stream_to_i64_array(&streams[j], n)
			case .F32:  chunk_arrays[j] = col_stream_to_f32_array(&streams[j], n)
			case .F64:  chunk_arrays[j] = col_stream_to_f64_array(&streams[j], n)
			case .Bool: chunk_arrays[j] = col_stream_to_bool_array(&streams[j], n)
			case .Str:  chunk_arrays[j] = col_stream_to_string_array(&streams[j], n)
			}
			if chunk_arrays[j].length != n {
				for k in 0..=j {
					oa.array_free(&chunk_arrays[k])
				}
				page_err: Parquet_To_CSV_Corrupt_Page_Error
				n_copy := min(len(metas[j].name), len(page_err.name_buf))
				copy(page_err.name_buf[:n_copy], metas[j].name[:n_copy])
				page_err.name_len = n_copy
				return 0, 0, page_err
			}
		}

		for r in 0..<n {
			for j in 0..<n_cols {
				if j > 0 { out_str(&o, ",") }
				if oa.array_is_null(&chunk_arrays[j], r) {
					// write empty field for null values
				} else {
					switch col_kinds[j] {
					case .I32:  out_i32(&o, oa.array_get(&chunk_arrays[j], r, i32))
					case .I64:  out_i64(&o, oa.array_get(&chunk_arrays[j], r, i64))
					case .F32:  out_f32(&o, oa.array_get(&chunk_arrays[j], r, f32))
					case .F64:  out_f64(&o, oa.array_get(&chunk_arrays[j], r, f64))
					case .Bool: out_bool(&o, oa.array_get(&chunk_arrays[j], r, bool))
					case .Str:  out_csv_field(&o, oa.array_get_string(&chunk_arrays[j], r))
					}
				}
			}
			out_str(&o, "\n")
		}

		for j in 0 ..< n_cols {
			oa.array_free(&chunk_arrays[j])
		}
		if o.write_err != nil {
			return 0, 0, Parquet_To_CSV_Write_Output_Error{err = o.write_err}
		}
		rows_done += n
	}
	out_flush(&o)
	if o.write_err != nil {
		return 0, 0, Parquet_To_CSV_Write_Output_Error{err = o.write_err}
	}
	write_ok = true
	return num_rows, chunk_rows, nil
}
