package skadi_specs

import "core:testing"

given_parquet_two_col_fixture :: proc(
	w:            ^Spec_World,
	name:         string,
	id_col_name:  string,
	str_col_name: string,
	id_rgs:       []Parquet_RG_I32_Spec,
	str_rgs:      []Parquet_RG_Str_Spec,
	loc           := #caller_location,
) {
	driver_build_parquet_two_col_fixture(w, name, id_col_name, str_col_name, id_rgs, str_rgs, loc)
}

given_csv_input :: proc(w: ^Spec_World, name, content: string) {
	driver_put_csv_text(w, name, content)
}

upon_csv_parquet_csv_roundtrip :: proc(
	w:               ^Spec_World,
	dst_name:        string,
	src_name:        string,
	read_buf_bytes:  int,
	max_rows_per_rg: int,
	loc              := #caller_location,
) {
	src, ok := w.csv_texts[src_name]
	testing.expectf(w.t, ok, "missing CSV input %q", src_name, loc = loc)
	if !ok {
		return
	}
	got, rt_ok := driver_csv_parquet_roundtrip(w, src, read_buf_bytes, max_rows_per_rg, loc)
	if rt_ok {
		driver_put_csv_text(w, dst_name, got)
	}
}

upon_parquet_to_csv :: proc(
	w:                  ^Spec_World,
	dst_csv_name:       string,
	pq_blob_name:       string,
	max_rows_per_chunk: int = 1024,
	loc                 := #caller_location,
) {
	driver_parquet_blob_to_csv(w, dst_csv_name, pq_blob_name, max_rows_per_chunk, loc)
}

then_csv_text_equals :: proc(w: ^Spec_World, name, expected: string, loc := #caller_location) {
	got, ok := w.csv_texts[name]
	testing.expectf(w.t, ok, "missing CSV output %q", name, loc = loc)
	if ok {
		testing.expect_value(w.t, got, expected, loc = loc)
	}
}
