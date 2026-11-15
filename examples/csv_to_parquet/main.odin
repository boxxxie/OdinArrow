package csv_to_parquet

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import oa "../../skadi"

parse_cli_args :: proc(args: []string) -> (max_mb: int, in_path: string, out_path: string, ok: bool) {
	max_mb = 200
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "-m" {
			if i + 1 >= len(args) { return 0, "", "", false }
			v, v_ok := strconv.parse_int(args[i + 1])
			if !v_ok || v <= 0 { return 0, "", "", false }
			max_mb = v
			i += 2
			continue
		}
		if len(arg) > 0 && arg[0] == '-' {
			return 0, "", "", false
		}
		if in_path == "" {
			in_path = arg
		} else if out_path == "" {
			out_path = arg
		} else {
			return 0, "", "", false
		}
		i += 1
	}
	if in_path == "" || out_path == "" {
		return 0, "", "", false
	}
	return max_mb, in_path, out_path, true
}

main :: proc() {
	max_mb, in_path, out_path, args_ok := parse_cli_args(os.args[1:])
	if !args_ok {
		fmt.eprintln("usage: csv_to_parquet_odin [-m MB] <input.csv> <output.parquet>")
		fmt.eprintln("  -m MB   memory limit in MB (default: 200)")
		os.exit(1)
	}

	mem_limit := i64(max_mb) * 1024 * 1024
	t0 := time.now()

	total_rows, total_chunks, conv_err := csv_to_parquet_stream(in_path, out_path, mem_limit)
	switch e in conv_err {
	case nil:
	case CSV_To_Parquet_Open_CSV_Error:
		fmt.eprintfln("error: cannot open CSV %s: %v", in_path, e.err)
		os.exit(1)
	case CSV_To_Parquet_Invalid_CSV_Error:
		fmt.eprintfln("error: invalid CSV in %s: %s", in_path, e.message)
		os.exit(1)
	case CSV_To_Parquet_Create_Output_Error:
		fmt.eprintfln("error: cannot create %s: %v", out_path, e.err)
		os.exit(1)
	case CSV_To_Parquet_Write_Output_Error:
		fmt.eprintfln("error: write failed on %s: %v", out_path, e.err)
		os.exit(1)
	case CSV_To_Parquet_Page_Overflow_Error:
		fmt.eprintfln("error: Parquet page size exceeds 2 GiB limit on %s", out_path)
		os.exit(1)
	}

	total_ns := time.duration_nanoseconds(time.since(t0))
	fmt.eprintfln("rows:        %d", total_rows)
	fmt.eprintfln("row_groups:  %d", total_chunks)
	fmt.eprintfln("mem_limit:   %dMB", max_mb)
	fmt.eprintfln("total_ms:    %.1f", f64(total_ns) / 1e6)
}

CSV_To_Parquet_Open_CSV_Error :: struct {
	err: os.Error,
}

CSV_To_Parquet_Invalid_CSV_Error :: struct {
	message: string,
}

CSV_To_Parquet_Create_Output_Error :: struct {
	err: os.Error,
}

CSV_To_Parquet_Write_Output_Error :: struct {
	err: os.Error,
}

CSV_To_Parquet_Page_Overflow_Error :: struct {}

CSV_To_Parquet_Error :: union {
	CSV_To_Parquet_Open_CSV_Error,
	CSV_To_Parquet_Invalid_CSV_Error,
	CSV_To_Parquet_Create_Output_Error,
	CSV_To_Parquet_Write_Output_Error,
	CSV_To_Parquet_Page_Overflow_Error,
}

csv_to_parquet_stream :: proc(
	in_path:          string,
	out_path:         string,
	mem_limit:        i64,
	buf_size_override := 0,
	max_rows_override := 0,
) -> (total_rows: int, total_chunks: int, err: CSV_To_Parquet_Error) {
	// Read buffer: 10% of memory limit, clamped to [4 MB, 64 MB].
	buf_size := int(mem_limit / 10)
	if buf_size < 4 * 1024 * 1024 {
		buf_size = 4 * 1024 * 1024
	}
	if buf_size > 64 * 1024 * 1024 {
		buf_size = 64 * 1024 * 1024
	}
	if buf_size_override > 0 {
		buf_size = buf_size_override
	}

	open_err: os.Error
	csv, csv_ok := csv_stream_open(in_path, buf_size, &open_err)
	if !csv_ok {
		if open_err != nil {
			return 0, 0, CSV_To_Parquet_Open_CSV_Error{err = open_err}
		}
		return 0, 0, CSV_To_Parquet_Invalid_CSV_Error{message = "empty or invalid CSV header"}
	}
	defer csv_stream_destroy(&csv)

	n_cols := csv.n_cols

	out_file, out_err := os.open(out_path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if out_err != nil {
		return 0, 0, CSV_To_Parquet_Create_Output_Error{err = out_err}
	}
	write_ok := false
	defer {
		if !write_ok {
			_ = os.truncate(out_file, 0)
		}
		os.close(out_file)
	}

	pw := pw_open(out_file, csv.col_names)
	defer pw_destroy(&pw)

	overhead := i64(buf_size) + 32 * 1024 * 1024
	col_buf_cap := mem_limit - overhead
	if col_buf_cap < 8 * 1024 * 1024 {
		col_buf_cap = 8 * 1024 * 1024
	}

	per_row_est := n_cols * 200
	if per_row_est < 1 {
		per_row_est = 200
	}

	max_rows := int(col_buf_cap) / per_row_est
	if max_rows < 1 {
		max_rows = 1
	}
	if max_rows_override > 0 {
		max_rows = max_rows_override
	}

	for {
		arrays, n := csv_stream_read_chunk(&csv, max_rows)
		if csv.row_err {
			return 0, 0, CSV_To_Parquet_Invalid_CSV_Error{message = "row column count mismatch"}
		}
		if n == 0 {
			break
		}

		pw_write_row_group(&pw, arrays)

		for ci in 0 ..< n_cols {
			oa.array_free(&arrays[ci])
		}
		delete(arrays)

		if pw.page_overflow {
			return 0, 0, CSV_To_Parquet_Page_Overflow_Error{}
		}
		if pw.write_err != nil {
			return 0, 0, CSV_To_Parquet_Write_Output_Error{err = pw.write_err}
		}

		total_rows += n
		total_chunks += 1
	}

	pw_finish(&pw)
	if pw.write_err != nil {
		return 0, 0, CSV_To_Parquet_Write_Output_Error{err = pw.write_err}
	}
	write_ok = true
	return total_rows, total_chunks, nil
}
