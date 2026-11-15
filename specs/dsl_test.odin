package skadi_specs

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import oa "../skadi"

given_column :: proc{
	given_col_i32,
	given_col_maybe_i32,
	given_col_maybe_i8,
	given_col_maybe_i16,
	given_col_i64,
	given_col_maybe_i64,
	given_col_maybe_u8,
	given_col_maybe_u16,
	given_col_maybe_u32,
	given_col_u64,
	given_col_maybe_u64,
	given_col_maybe_f32,
	given_col_f64,
	given_col_maybe_f64,
	given_col_bool,
	given_col_maybe_bool,
	given_col_str,
	given_col_maybe_str,
	given_col_binary,
	given_col_maybe_binary,
}

given_col_i32 :: proc(w: ^Spec_World, name: string, vals: []i32, loc := #caller_location) {
	driver_build_primitive(w, name, vals, loc)
}
given_col_maybe_i32 :: proc(w: ^Spec_World, name: string, vals: []Maybe(i32), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_maybe_i8 :: proc(w: ^Spec_World, name: string, vals: []Maybe(i8), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_maybe_i16 :: proc(w: ^Spec_World, name: string, vals: []Maybe(i16), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_i64 :: proc(w: ^Spec_World, name: string, vals: []i64, loc := #caller_location) {
	driver_build_primitive(w, name, vals, loc)
}
given_col_maybe_i64 :: proc(w: ^Spec_World, name: string, vals: []Maybe(i64), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_maybe_u8 :: proc(w: ^Spec_World, name: string, vals: []Maybe(u8), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_maybe_u16 :: proc(w: ^Spec_World, name: string, vals: []Maybe(u16), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_maybe_u32 :: proc(w: ^Spec_World, name: string, vals: []Maybe(u32), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_u64 :: proc(w: ^Spec_World, name: string, vals: []u64, loc := #caller_location) {
	driver_build_primitive(w, name, vals, loc)
}
given_col_maybe_u64 :: proc(w: ^Spec_World, name: string, vals: []Maybe(u64), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_maybe_f32 :: proc(w: ^Spec_World, name: string, vals: []Maybe(f32), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_f64 :: proc(w: ^Spec_World, name: string, vals: []f64, loc := #caller_location) {
	driver_build_primitive(w, name, vals, loc)
}
given_col_maybe_f64 :: proc(w: ^Spec_World, name: string, vals: []Maybe(f64), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_bool :: proc(w: ^Spec_World, name: string, vals: []bool, loc := #caller_location) {
	driver_build_primitive(w, name, vals, loc)
}
given_col_maybe_bool :: proc(w: ^Spec_World, name: string, vals: []Maybe(bool), loc := #caller_location) {
	driver_build_nullable_primitive(w, name, vals, loc)
}
given_col_str :: proc(w: ^Spec_World, name: string, vals: []string, loc := #caller_location) {
	driver_build_strings(w, name, vals, loc)
}
given_col_maybe_str :: proc(w: ^Spec_World, name: string, vals: []Maybe(string), loc := #caller_location) {
	driver_build_nullable_strings(w, name, vals, loc)
}
given_col_binary :: proc(w: ^Spec_World, name: string, vals: [][]u8, loc := #caller_location) {
	driver_build_binary(w, name, vals, loc)
}
given_col_maybe_binary :: proc(w: ^Spec_World, name: string, vals: []Maybe([]u8), loc := #caller_location) {
	driver_build_nullable_binary(w, name, vals, loc)
}
given_col_large_strings :: proc(w: ^Spec_World, name: string, vals: []string, loc := #caller_location) {
	driver_build_large_strings(w, name, vals, loc)
}
given_null_column :: proc(w: ^Spec_World, name: string, length: int, loc := #caller_location) {
	driver_build_null_column(w, name, length, loc)
}
given_large_string_column :: proc(w: ^Spec_World, name: string, vals: []Maybe(string), loc := #caller_location) {
	driver_build_nullable_large_strings(w, name, vals, loc)
}
given_large_binary_column :: proc(w: ^Spec_World, name: string, vals: []Maybe([]u8), loc := #caller_location) {
	driver_build_nullable_large_binary(w, name, vals, loc)
}
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

given_masked_column :: proc{
	given_masked_column_i32,
}
given_masked_column_i32 :: proc(w: ^Spec_World, name: string, raw: []i32, valid: []bool, loc := #caller_location) {
	driver_build_masked_i32(w, name, raw, valid, loc)
}

given_sliced_column :: proc(w: ^Spec_World, dst, src: string, from, to: int, loc := #caller_location) {
	parent, ok := w.arrays[src]
	testing.expectf(w.t, ok, "missing source column %q", src, loc = loc)
	if !ok {
		return
	}
	bounds_ok := from >= 0 && to <= parent.length && from <= to
	testing.expectf(w.t, bounds_ok, "invalid slice bounds [%d:%d) for length %d", from, to, parent.length, loc = loc)
	if !bounds_ok {
		return
	}
	driver_put_array(w, dst, oa.array_slice(parent, from, to), loc)
}

given_batch :: proc(w: ^Spec_World, batch_name: string, col_names: []string, loc := #caller_location) {
	driver_make_batch(w, batch_name, col_names, loc)
}

given_csv_input :: proc(w: ^Spec_World, name, content: string) {
	driver_put_csv_text(w, name, content)
}

upon_selecting :: proc(w: ^Spec_World, sel_name, col_name: string, op: oa.Compare_Op, scalar: f64, loc := #caller_location) {
	col, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing column %q", col_name, loc = loc)
	if !ok {
		return
	}
	driver_put_selection(w, sel_name, oa.compute_select_compare(col, op, scalar))
}

upon_selecting_i64 :: proc(w: ^Spec_World, sel_name, col_name: string, op: oa.Compare_Op, scalar: i64, loc := #caller_location) {
	col, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing column %q", col_name, loc = loc)
	if !ok {
		return
	}
	driver_put_selection(w, sel_name, oa.compute_select_compare_i64(col, op, scalar))
}

upon_refining_selection :: proc(w: ^Spec_World, dst_sel, src_sel, col_name: string, op: oa.Compare_Op, scalar: f64, loc := #caller_location) {
	sel, s_ok := &w.selections[src_sel]
	col, c_ok := &w.arrays[col_name]
	testing.expect(w.t, s_ok && c_ok, "missing selection or column", loc = loc)
	if !s_ok || !c_ok {
		return
	}
	driver_put_selection(w, dst_sel, oa.selection_refine_compare(sel, col, op, scalar))
}

upon_refining_selection_i64 :: proc(w: ^Spec_World, dst_sel, src_sel, col_name: string, op: oa.Compare_Op, scalar: i64, loc := #caller_location) {
	sel, s_ok := &w.selections[src_sel]
	col, c_ok := &w.arrays[col_name]
	testing.expect(w.t, s_ok && c_ok, "missing selection or column", loc = loc)
	if !s_ok || !c_ok {
		return
	}
	driver_put_selection(w, dst_sel, oa.selection_refine_compare_i64(sel, col, op, scalar))
}

upon_selecting_mask :: proc(w: ^Spec_World, sel_name, mask_col: string, loc := #caller_location) {
	mask, ok := &w.arrays[mask_col]
	testing.expectf(w.t, ok, "missing mask column %q", mask_col, loc = loc)
	if !ok {
		return
	}
	_, is_bool := mask.type.(oa.Bool_Type)
	testing.expectf(w.t, is_bool, "mask column %q must be Bool_Type, got %v", mask_col, mask.type, loc = loc)
	if !is_bool {
		return
	}
	driver_put_selection(w, sel_name, oa.compute_select(mask))
}

upon_taking_selection :: proc(w: ^Spec_World, dst_col, src_col, sel_name: string, loc := #caller_location) {
	src, s_ok := &w.arrays[src_col]
	sel, sel_ok := &w.selections[sel_name]
	testing.expectf(w.t, s_ok, "missing source column %q", src_col, loc = loc)
	testing.expectf(w.t, sel_ok, "missing selection %q", sel_name, loc = loc)
	if !s_ok || !sel_ok {
		return
	}
	taken, err := oa.selection_take(src, sel)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, dst_col, taken, loc)
}

upon_taking_batch_selection :: proc(w: ^Spec_World, dst_batch, src_batch, sel_name: string, loc := #caller_location) {
	rb, b_ok := &w.batches[src_batch]
	sel, sel_ok := &w.selections[sel_name]
	testing.expectf(w.t, b_ok, "missing batch %q", src_batch, loc = loc)
	testing.expectf(w.t, sel_ok, "missing selection %q", sel_name, loc = loc)
	if !b_ok || !sel_ok {
		return
	}
	out, ok := oa.record_batch_take(rb, sel)
	testing.expect(w.t, ok, "record_batch_take must succeed", loc = loc)
	if !ok {
		return
	}
	driver_put_batch(w, dst_batch, out, loc)
}

upon_encoding_string_dict :: proc(w: ^Spec_World, dict_name, col_name: string, loc := #caller_location) {
	col, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing column %q", col_name, loc = loc)
	if !ok {
		return
	}
	_, is_str := col.type.(oa.String_Type)
	testing.expectf(w.t, is_str, "string dict expects String_Type for %q, got %v", col_name, col.type, loc = loc)
	if !is_str {
		return
	}
	driver_put_str_dict(w, dict_name, oa.str_dict_encode(col))
}

upon_comparing_f64 :: proc(w: ^Spec_World, mask_name, col_name: string, op: oa.Compare_Op, scalar: f64, loc := #caller_location) {
	col, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing column %q", col_name, loc = loc)
	if !ok {
		return
	}
	mask, err := oa.compute_compare(col, op, scalar)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, mask_name, mask, loc)
}

upon_comparing_i64 :: proc(w: ^Spec_World, mask_name, col_name: string, op: oa.Compare_Op, scalar: i64, loc := #caller_location) {
	col, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing column %q", col_name, loc = loc)
	if !ok {
		return
	}
	mask, err := oa.compute_compare_i64(col, op, scalar)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, mask_name, mask, loc)
}

upon_comparing_u64 :: proc(w: ^Spec_World, mask_name, col_name: string, op: oa.Compare_Op, scalar: u64, loc := #caller_location) {
	col, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing column %q", col_name, loc = loc)
	if !ok {
		return
	}
	mask, err := oa.compute_compare_u64(col, op, scalar)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, mask_name, mask, loc)
}

upon_copying_column :: proc(w: ^Spec_World, dst_name, src_name: string, loc := #caller_location) {
	src, ok := &w.arrays[src_name]
	testing.expectf(w.t, ok, "missing source column %q", src_name, loc = loc)
	if !ok {
		return
	}
	copied, err := oa.array_copy(src)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, dst_name, copied, loc)
}

upon_dividing :: proc(w: ^Spec_World, dst, left, right: string, loc := #caller_location) {
	l, lok := &w.arrays[left]
	r, rok := &w.arrays[right]
	testing.expect(w.t, lok && rok, "missing operand column", loc = loc)
	if !lok || !rok {
		return
	}
	res, err := oa.compute_div(l, r)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, dst, res, loc)
}

upon_fused_aggregating :: proc(w: ^Spec_World, out_name, val_col, pred_col: string, op: oa.Compare_Op, scalar: f64, loc := #caller_location) {
	vals, vok := &w.arrays[val_col]
	pred, pok := &w.arrays[pred_col]
	testing.expect(w.t, vok && pok, "missing values or predicate column", loc = loc)
	if !vok || !pok {
		return
	}
	w.aggs[out_name] = oa.compute_agg_where_compare(vals, pred, op, scalar)
}

upon_fused_aggregating_i64 :: proc(w: ^Spec_World, out_name, val_col, pred_col: string, op: oa.Compare_Op, scalar: i64, loc := #caller_location) {
	vals, vok := &w.arrays[val_col]
	pred, pok := &w.arrays[pred_col]
	testing.expect(w.t, vok && pok, "missing values or predicate column", loc = loc)
	if !vok || !pok {
		return
	}
	w.aggs[out_name] = oa.compute_agg_where_compare_i64(vals, pred, op, scalar)
}

upon_ipc_file_roundtrip :: proc(w: ^Spec_World, set_name: string, batch_names: []string, use_mmap := true, loc := #caller_location) {
	driver_ipc_file_roundtrip(w, set_name, batch_names, use_mmap, loc)
}

upon_ipc_stream_roundtrip :: proc(w: ^Spec_World, set_name: string, batch_names: []string, loc := #caller_location) {
	driver_ipc_stream_roundtrip(w, set_name, batch_names, loc)
}

upon_ipc_schema_only_roundtrip :: proc(w: ^Spec_World, set_name, schema_from_batch: string, use_mmap := true, loc := #caller_location) {
	driver_ipc_schema_only_roundtrip(w, set_name, schema_from_batch, use_mmap, loc)
}

upon_releasing_batch_in_set :: proc(w: ^Spec_World, set_name: string, idx: int, loc := #caller_location) {
	driver_release_batch_in_set(w, set_name, idx, loc)
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

then_selection_equals :: proc(w: ^Spec_World, name: string, expected: []int, loc := #caller_location) {
	sel, sel_ok := w.selections[name]
	testing.expectf(w.t, sel_ok, "missing selection %q", name, loc = loc)
	if sel_ok {
		testing.expect_value(w.t, sel.length, len(expected), loc = loc)
		if sel.length == len(expected) {
			for want_idx, k in expected {
				testing.expect_value(w.t, int(sel.indices[k]), want_idx, loc = loc)
			}
		}
	}
}

then_column_i32_equals :: proc(w: ^Spec_World, col_name: string, expected: []Maybe(i32), loc := #caller_location) {
	arr, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing column %q", col_name, loc = loc)
	if !ok {
		return
	}
	_then_array_nullable_primitive_equals(w, arr, col_name, expected, loc)
}

then_column_f64_equals :: proc(w: ^Spec_World, col_name: string, expected: []Maybe(f64), loc := #caller_location) {
	arr, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing column %q", col_name, loc = loc)
	if !ok {
		return
	}
	_then_array_nullable_primitive_equals(w, arr, col_name, expected, loc)
}

then_column_str_equals :: proc(w: ^Spec_World, col_name: string, expected: []Maybe(string), loc := #caller_location) {
	arr, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing column %q", col_name, loc = loc)
	if !ok {
		return
	}
	_then_array_str_equals(w, arr, col_name, expected, false, loc)
}

then_batch_column_offset :: proc(w: ^Spec_World, batch_name, col_name: string, expected_offset: int, loc := #caller_location) {
	rb, ok := &w.batches[batch_name]
	testing.expectf(w.t, ok, "missing batch %q", batch_name, loc = loc)
	if !ok {
		return
	}
	col := oa.record_batch_column(rb, col_name)
	testing.expectf(w.t, col != nil, "missing column %q in batch %q", col_name, batch_name, loc = loc)
	if col != nil {
		testing.expect_value(w.t, col.offset, expected_offset, loc = loc)
	}
}

then_batch_set_count :: proc(w: ^Spec_World, set_name: string, expected_batches: int, loc := #caller_location) {
	set, ok := w.batch_sets[set_name]
	testing.expectf(w.t, ok, "missing batch set %q", set_name, loc = loc)
	if ok {
		testing.expect_value(w.t, len(set), expected_batches, loc = loc)
	}
}

then_batch_in_set_row_count :: proc(w: ^Spec_World, set_name: string, batch_idx, expected_rows: int, loc := #caller_location) {
	rb, ok := driver_get_batch_in_set(w, set_name, batch_idx, loc)
	if ok {
		testing.expect_value(w.t, rb.length, expected_rows, loc = loc)
	}
}

then_schema_field_names :: proc(w: ^Spec_World, set_name: string, expected_fields: []string, loc := #caller_location) {
	sc, ok := w.set_schemas[set_name]
	testing.expectf(w.t, ok && sc != nil, "missing schema for batch set %q", set_name, loc = loc)
	if !ok || sc == nil {
		return
	}
	testing.expect_value(w.t, len(sc.fields), len(expected_fields), loc = loc)
	if len(sc.fields) == len(expected_fields) {
		for entry, i in expected_fields {
			colon := strings.index_byte(entry, ':')
			if colon >= 0 {
				want_name := entry[:colon]
				want_type := entry[colon + 1:]
				testing.expect_value(w.t, sc.fields[i].name, want_name, loc = loc)
				testing.expect_value(w.t, oa.type_name(sc.fields[i].type), want_type, loc = loc)
			} else {
				testing.expect_value(w.t, sc.fields[i].name, entry, loc = loc)
			}
		}
	}
}

then_mask_equals :: proc(w: ^Spec_World, mask_name: string, expected: []bool, loc := #caller_location) {
	arr, ok := &w.arrays[mask_name]
	testing.expectf(w.t, ok, "missing mask column %q", mask_name, loc = loc)
	if !ok {
		return
	}
	_, is_bool := arr.type.(oa.Bool_Type)
	testing.expect(w.t, is_bool, "expected Bool_Type comparison mask", loc = loc)
	testing.expect(w.t, arr.buffers[0].data == nil, "comparison mask must be dense (non-nullable)", loc = loc)
	testing.expect_value(w.t, arr.length, len(expected), loc = loc)
	if arr.length != len(expected) {
		return
	}
	for want, i in expected {
		testing.expect_value(w.t, oa.array_get(arr, i, bool), want, loc = loc)
	}
}

then_column_count_equals :: proc(w: ^Spec_World, col_name: string, expected_total, expected_valid: int, loc := #caller_location) {
	arr, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing column %q", col_name, loc = loc)
	if !ok {
		return
	}
	total, valid := oa.compute_count(arr)
	testing.expect_value(w.t, total, expected_total, loc = loc)
	testing.expect_value(w.t, valid, expected_valid, loc = loc)
}

then_null_column_equals :: proc(w: ^Spec_World, col_name: string, expected_len: int, loc := #caller_location) {
	arr, ok := &w.arrays[col_name]
	testing.expectf(w.t, ok, "missing null column %q", col_name, loc = loc)
	if !ok {
		return
	}
	_, is_null_t := arr.type.(oa.Null_Type)
	testing.expect(w.t, is_null_t, "expected Null_Type", loc = loc)
	testing.expect_value(w.t, arr.length, expected_len, loc = loc)
	testing.expect_value(w.t, oa.array_null_count(arr), expected_len, loc = loc)
	for i in 0 ..< min(arr.length, expected_len) {
		testing.expectf(w.t, oa.array_is_null(arr, i), "expected null row %d", i, loc = loc)
	}
}

then_batch_column_equals :: proc{
	then_single_batch_i32_equals,
	then_single_batch_f64_equals,
	then_single_batch_str_equals,
	then_batch_in_set_i8_equals,
	then_batch_in_set_i16_equals,
	then_batch_in_set_i32_equals,
	then_batch_in_set_i64_equals,
	then_batch_in_set_u8_equals,
	then_batch_in_set_u16_equals,
	then_batch_in_set_u32_equals,
	then_batch_in_set_u64_equals,
	then_batch_in_set_f32_equals,
	then_batch_in_set_f64_equals,
	then_batch_in_set_bool_equals,
	then_batch_in_set_maybe_bool_equals,
	then_batch_in_set_str_equals,
	then_batch_in_set_binary_equals,
}

then_batch_column_at_equals :: proc{
	then_single_batch_col_at_i32_equals,
	then_single_batch_col_at_f64_equals,
	then_single_batch_col_at_str_equals,
}

@(private="file")
_driver_get_batch_column :: proc(
	w:         ^Spec_World,
	set_name:  string,
	batch_idx: int,
	col_name:  string,
	loc        := #caller_location,
) -> (^oa.Array, bool) {
	rb, ok := driver_get_batch_in_set(w, set_name, batch_idx, loc)
	if !ok {
		return nil, false
	}
	col := oa.record_batch_column(rb, col_name)
	testing.expectf(w.t, col != nil, "missing column %q", col_name, loc = loc)
	return col, col != nil
}

@(private="file")
_driver_get_single_batch_column :: proc(
	w:          ^Spec_World,
	batch_name: string,
	col_name:   string,
	loc         := #caller_location,
) -> (^oa.Array, bool) {
	rb, ok := &w.batches[batch_name]
	testing.expectf(w.t, ok, "missing batch %q", batch_name, loc = loc)
	if !ok {
		return nil, false
	}
	col := oa.record_batch_column(rb, col_name)
	testing.expectf(w.t, col != nil, "missing column %q in batch %q", col_name, batch_name, loc = loc)
	return col, col != nil
}

@(private="file")
_driver_get_single_batch_column_at :: proc(
	w:          ^Spec_World,
	batch_name: string,
	col_idx:    int,
	loc         := #caller_location,
) -> (^oa.Array, string, bool) {
	rb, ok := &w.batches[batch_name]
	testing.expectf(w.t, ok, "missing batch %q", batch_name, loc = loc)
	if !ok {
		return nil, "", false
	}
	col := oa.record_batch_column_at(rb, col_idx)
	testing.expectf(w.t, col != nil, "missing column[%d] in batch %q", col_idx, batch_name, loc = loc)
	if col == nil {
		return nil, "", false
	}
	return col, fmt.tprintf("%s[%d]", batch_name, col_idx), true
}

@(private="file")
_then_array_nullable_primitive_equals :: proc(
	w:        ^Spec_World,
	col:      ^oa.Array,
	col_name: string,
	expected: []Maybe($T),
	loc       := #caller_location,
) {
	type_ok: bool
	when T == bool {
		_, type_ok = col.type.(oa.Bool_Type)
	} else when T == i8 {
		_, type_ok = col.type.(oa.Int8_Type)
	} else when T == i16 {
		_, type_ok = col.type.(oa.Int16_Type)
	} else when T == i32 {
		_, type_ok = col.type.(oa.Int32_Type)
	} else when T == i64 {
		_, type_ok = col.type.(oa.Int64_Type)
	} else when T == u8 {
		_, type_ok = col.type.(oa.UInt8_Type)
	} else when T == u16 {
		_, type_ok = col.type.(oa.UInt16_Type)
	} else when T == u32 {
		_, type_ok = col.type.(oa.UInt32_Type)
	} else when T == u64 {
		_, type_ok = col.type.(oa.UInt64_Type)
	} else when T == f32 {
		_, type_ok = col.type.(oa.Float32_Type)
	} else when T == f64 {
		_, type_ok = col.type.(oa.Float64_Type)
	}
	testing.expectf(w.t, type_ok, "unexpected column type %v for %q", col.type, col_name, loc = loc)
	testing.expect_value(w.t, col.length, len(expected), loc = loc)
	if col.length != len(expected) {
		return
	}
	for want, i in expected {
		if v, is_val := want.?; is_val {
			testing.expectf(w.t, oa.array_is_valid(col, i), "expected valid value in %q at row %d", col_name, i, loc = loc)
			when T == f32 {
				got := oa.array_get(col, i, f32)
				testing.expectf(w.t, math.abs(got - v) <= 1e-6, "%q row %d mismatch: got %v, want %v", col_name, i, got, v, loc = loc)
			} else when T == f64 {
				got := oa.array_get(col, i, f64)
				testing.expectf(w.t, math.abs(got - v) <= 1e-9, "%q row %d mismatch: got %v, want %v", col_name, i, got, v, loc = loc)
			} else {
				got := oa.array_get(col, i, T)
				testing.expectf(w.t, got == v, "%q row %d mismatch: got %v, want %v", col_name, i, got, v, loc = loc)
			}
		} else {
			testing.expectf(w.t, oa.array_is_null(col, i), "expected null in %q at row %d", col_name, i, loc = loc)
		}
	}
}

@(private="file")
_then_batch_nullable_primitive_equals :: proc(
	w:         ^Spec_World,
	set_name:  string,
	batch_idx: int,
	col_name:  string,
	expected:  []Maybe($T),
	loc        := #caller_location,
) {
	col, ok := _driver_get_batch_column(w, set_name, batch_idx, col_name, loc)
	if !ok {
		return
	}
	qualified := fmt.tprintf("%s[%d].%s", set_name, batch_idx, col_name)
	_then_array_nullable_primitive_equals(w, col, qualified, expected, loc)
}

then_single_batch_i32_equals :: proc(w: ^Spec_World, batch_name, col_name: string, expected: []Maybe(i32), loc := #caller_location) {
	col, ok := _driver_get_single_batch_column(w, batch_name, col_name, loc)
	if ok {
		_then_array_nullable_primitive_equals(w, col, fmt.tprintf("%s.%s", batch_name, col_name), expected, loc)
	}
}

then_single_batch_f64_equals :: proc(w: ^Spec_World, batch_name, col_name: string, expected: []Maybe(f64), loc := #caller_location) {
	col, ok := _driver_get_single_batch_column(w, batch_name, col_name, loc)
	if ok {
		_then_array_nullable_primitive_equals(w, col, fmt.tprintf("%s.%s", batch_name, col_name), expected, loc)
	}
}

then_single_batch_str_equals :: proc(w: ^Spec_World, batch_name, col_name: string, expected: []Maybe(string), loc := #caller_location) {
	col, ok := _driver_get_single_batch_column(w, batch_name, col_name, loc)
	if ok {
		_then_array_str_equals(w, col, fmt.tprintf("%s.%s", batch_name, col_name), expected, false, loc)
	}
}

then_single_batch_col_at_i32_equals :: proc(w: ^Spec_World, batch_name: string, col_idx: int, expected: []Maybe(i32), loc := #caller_location) {
	col, label, ok := _driver_get_single_batch_column_at(w, batch_name, col_idx, loc)
	if ok {
		_then_array_nullable_primitive_equals(w, col, label, expected, loc)
	}
}

then_single_batch_col_at_f64_equals :: proc(w: ^Spec_World, batch_name: string, col_idx: int, expected: []Maybe(f64), loc := #caller_location) {
	col, label, ok := _driver_get_single_batch_column_at(w, batch_name, col_idx, loc)
	if ok {
		_then_array_nullable_primitive_equals(w, col, label, expected, loc)
	}
}

then_single_batch_col_at_str_equals :: proc(w: ^Spec_World, batch_name: string, col_idx: int, expected: []Maybe(string), loc := #caller_location) {
	col, label, ok := _driver_get_single_batch_column_at(w, batch_name, col_idx, loc)
	if ok {
		_then_array_str_equals(w, col, label, expected, false, loc)
	}
}

then_batch_in_set_i8_equals         :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(i8), loc := #caller_location)   { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }
then_batch_in_set_i16_equals        :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(i16), loc := #caller_location)  { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }
then_batch_in_set_i32_equals        :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(i32), loc := #caller_location)  { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }
then_batch_in_set_i64_equals        :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(i64), loc := #caller_location)  { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }
then_batch_in_set_u8_equals         :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(u8), loc := #caller_location)   { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }
then_batch_in_set_u16_equals        :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(u16), loc := #caller_location)  { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }
then_batch_in_set_u32_equals        :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(u32), loc := #caller_location)  { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }
then_batch_in_set_u64_equals        :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(u64), loc := #caller_location)  { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }
then_batch_in_set_f32_equals        :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(f32), loc := #caller_location)  { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }
then_batch_in_set_f64_equals        :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(f64), loc := #caller_location)  { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }
then_batch_in_set_maybe_bool_equals :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(bool), loc := #caller_location) { _then_batch_nullable_primitive_equals(w, set_name, batch_idx, col_name, expected, loc) }

then_batch_in_set_bool_equals :: proc(
	w:         ^Spec_World,
	set_name:  string,
	batch_idx: int,
	col_name:  string,
	expected:  []bool,
	loc        := #caller_location,
) {
	col, ok := _driver_get_batch_column(w, set_name, batch_idx, col_name, loc)
	if !ok {
		return
	}
	qualified := fmt.tprintf("%s[%d].%s", set_name, batch_idx, col_name)
	_, type_ok := col.type.(oa.Bool_Type)
	testing.expectf(w.t, type_ok, "expected Bool_Type for %q, got %v", qualified, col.type, loc = loc)
	testing.expect_value(w.t, col.length, len(expected), loc = loc)
	if col.length != len(expected) {
		return
	}
	for want, i in expected {
		testing.expectf(w.t, oa.array_is_valid(col, i), "expected valid bool in %q at row %d", qualified, i, loc = loc)
		got := oa.array_get(col, i, bool)
		testing.expectf(w.t, got == want, "%q row %d mismatch: got %v, want %v", qualified, i, got, want, loc = loc)
	}
}

@(private="file")
_then_array_str_equals :: proc(
	w:        ^Spec_World,
	col:      ^oa.Array,
	col_name: string,
	expected: []Maybe(string),
	large:    bool,
	loc       := #caller_location,
) {
	if large {
		_, is_ls := col.type.(oa.Large_String_Type)
		testing.expectf(w.t, is_ls, "expected Large_String_Type for %q, got %v", col_name, col.type, loc = loc)
	} else {
		_, is_s := col.type.(oa.String_Type)
		testing.expectf(w.t, is_s, "expected String_Type for %q, got %v", col_name, col.type, loc = loc)
	}
	testing.expect_value(w.t, col.length, len(expected), loc = loc)
	if col.length != len(expected) {
		return
	}
	for want, i in expected {
		if s, is_val := want.?; is_val {
			testing.expectf(w.t, oa.array_is_valid(col, i), "expected valid string in %q at row %d", col_name, i, loc = loc)
			got := large ? oa.array_get_large_string(col, i) : oa.array_get_string(col, i)
			testing.expectf(w.t, got == s, "%q row %d mismatch: got %q, want %q", col_name, i, got, s, loc = loc)
		} else {
			testing.expectf(w.t, oa.array_is_null(col, i), "expected null string in %q at row %d", col_name, i, loc = loc)
		}
	}
}

@(private="file")
_then_batch_str_equals :: proc(
	w:         ^Spec_World,
	set_name:  string,
	batch_idx: int,
	col_name:  string,
	expected:  []Maybe(string),
	large:     bool,
	loc        := #caller_location,
) {
	col, ok := _driver_get_batch_column(w, set_name, batch_idx, col_name, loc)
	if ok {
		qualified := fmt.tprintf("%s[%d].%s", set_name, batch_idx, col_name)
		_then_array_str_equals(w, col, qualified, expected, large, loc)
	}
}

@(private="file")
_then_batch_bin_equals :: proc(
	w:         ^Spec_World,
	set_name:  string,
	batch_idx: int,
	col_name:  string,
	expected:  []Maybe([]u8),
	large:     bool,
	loc        := #caller_location,
) {
	col, ok := _driver_get_batch_column(w, set_name, batch_idx, col_name, loc)
	if !ok {
		return
	}
	qualified := fmt.tprintf("%s[%d].%s", set_name, batch_idx, col_name)
	if large {
		_, is_lb := col.type.(oa.Large_Binary_Type)
		testing.expectf(w.t, is_lb, "expected Large_Binary_Type for %q, got %v", qualified, col.type, loc = loc)
	} else {
		_, is_b := col.type.(oa.Binary_Type)
		testing.expectf(w.t, is_b, "expected Binary_Type for %q, got %v", qualified, col.type, loc = loc)
	}
	testing.expect_value(w.t, col.length, len(expected), loc = loc)
	if col.length != len(expected) {
		return
	}
	for want, i in expected {
		if b, is_val := want.?; is_val {
			testing.expectf(w.t, oa.array_is_valid(col, i), "expected valid binary in %q at row %d", qualified, i, loc = loc)
			got := large ? oa.array_get_large_binary(col, i) : oa.array_get_binary(col, i)
			testing.expectf(w.t, bytes.equal(got, b), "%q row %d binary mismatch: got %v, want %v", qualified, i, got, b, loc = loc)
		} else {
			testing.expectf(w.t, oa.array_is_null(col, i), "expected null binary in %q at row %d", qualified, i, loc = loc)
		}
	}
}

then_batch_in_set_str_equals         :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(string), loc := #caller_location) { _then_batch_str_equals(w, set_name, batch_idx, col_name, expected, false, loc) }
then_batch_large_string_column_equals :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe(string), loc := #caller_location) { _then_batch_str_equals(w, set_name, batch_idx, col_name, expected, true, loc) }
then_batch_in_set_binary_equals      :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe([]u8), loc := #caller_location)   { _then_batch_bin_equals(w, set_name, batch_idx, col_name, expected, false, loc) }
then_batch_large_binary_column_equals :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected: []Maybe([]u8), loc := #caller_location)  { _then_batch_bin_equals(w, set_name, batch_idx, col_name, expected, true, loc) }

then_batch_null_column_equals :: proc(w: ^Spec_World, set_name: string, batch_idx: int, col_name: string, expected_len: int, loc := #caller_location) {
	col, ok := _driver_get_batch_column(w, set_name, batch_idx, col_name, loc)
	if !ok {
		return
	}
	_, is_null_t := col.type.(oa.Null_Type)
	testing.expectf(w.t, is_null_t, "expected Null_Type for %q, got %v", col_name, col.type, loc = loc)
	testing.expect_value(w.t, col.length, expected_len, loc = loc)
	testing.expect_value(w.t, oa.array_null_count(col), expected_len, loc = loc)
	for i in 0 ..< min(col.length, expected_len) {
		testing.expectf(w.t, oa.array_is_null(col, i), "expected null row %d in %q", i, col_name, loc = loc)
	}
}

then_csv_text_equals :: proc(w: ^Spec_World, name, expected: string, loc := #caller_location) {
	got, ok := w.csv_texts[name]
	testing.expectf(w.t, ok, "missing CSV output %q", name, loc = loc)
	if ok {
		testing.expect_value(w.t, got, expected, loc = loc)
	}
}

then_aggregates_equal :: proc(
	w: ^Spec_World,
	agg_name: string,
	count: int,
	sum, min_val, max_val: f64,
	loc := #caller_location,
) {
	got, ok := w.aggs[agg_name]
	testing.expectf(w.t, ok, "missing aggregate %q", agg_name, loc = loc)
	if !ok {
		return
	}
	testing.expect_value(w.t, got.count, count, loc = loc)
	if count > 0 {
		testing.expect(w.t, got.valid, "aggregate must be marked valid", loc = loc)
		testing.expectf(w.t, math.abs(got.sum - sum) <= 1e-9, "sum mismatch: got %v, want %v", got.sum, sum, loc = loc)
		testing.expectf(w.t, math.abs(got.min_val - min_val) <= 1e-9, "min mismatch: got %v, want %v", got.min_val, min_val, loc = loc)
		testing.expectf(w.t, math.abs(got.max_val - max_val) <= 1e-9, "max mismatch: got %v, want %v", got.max_val, max_val, loc = loc)
	} else {
		testing.expect(w.t, !got.valid, "empty aggregate must be invalid", loc = loc)
	}
}

then_selection_aggregates_equal :: proc(
	w:             ^Spec_World,
	col_name:      string,
	sel_name:      string,
	selected_rows: int,
	valid_count:   int,
	sum:           f64,
	min_val:       f64,
	max_val:       f64,
	loc            := #caller_location,
) {
	col, c_ok := &w.arrays[col_name]
	sel, s_ok := &w.selections[sel_name]
	testing.expectf(w.t, c_ok, "missing column %q", col_name, loc = loc)
	testing.expectf(w.t, s_ok, "missing selection %q", sel_name, loc = loc)
	if !c_ok || !s_ok {
		return
	}
	testing.expect_value(w.t, oa.compute_count_selection(sel), selected_rows, loc = loc)

	got_sum, sum_vc := oa.compute_sum_selection(col, sel)
	testing.expect_value(w.t, sum_vc, valid_count, loc = loc)
	testing.expectf(w.t, math.abs(got_sum - sum) <= 1e-9, "selection sum mismatch: got %v, want %v", got_sum, sum, loc = loc)

	got_lo, got_hi, mm_vc := oa.compute_min_max_selection(col, sel)
	testing.expect_value(w.t, mm_vc, valid_count, loc = loc)
	if valid_count > 0 {
		testing.expectf(w.t, math.abs(got_lo - min_val) <= 1e-9, "selection min mismatch: got %v, want %v", got_lo, min_val, loc = loc)
		testing.expectf(w.t, math.abs(got_hi - max_val) <= 1e-9, "selection max mismatch: got %v, want %v", got_hi, max_val, loc = loc)
	}
}

then_where_aggregates_equal :: proc(
	w:               ^Spec_World,
	col_name:        string,
	mask_name:       string,
	mask_true_count: int,
	valid_count:     int,
	sum:             f64,
	mean:            f64,
	min_val:         f64,
	max_val:         f64,
	loc              := #caller_location,
) {
	col, c_ok := &w.arrays[col_name]
	mask, m_ok := &w.arrays[mask_name]
	testing.expectf(w.t, c_ok, "missing column %q", col_name, loc = loc)
	testing.expectf(w.t, m_ok, "missing mask column %q", mask_name, loc = loc)
	if !c_ok || !m_ok {
		return
	}
	testing.expect_value(w.t, oa.compute_count_where(mask), mask_true_count, loc = loc)

	got_sum, sum_vc := oa.compute_sum_where(col, mask)
	testing.expect_value(w.t, sum_vc, valid_count, loc = loc)
	testing.expectf(w.t, math.abs(got_sum - sum) <= 1e-9, "where sum mismatch: got %v, want %v", got_sum, sum, loc = loc)

	got_mean, mean_vc := oa.compute_mean_where(col, mask)
	testing.expect_value(w.t, mean_vc, valid_count, loc = loc)
	testing.expectf(w.t, math.abs(got_mean - mean) <= 1e-9, "where mean mismatch: got %v, want %v", got_mean, mean, loc = loc)

	got_lo, got_hi, mm_vc := oa.compute_min_max_where(col, mask)
	testing.expect_value(w.t, mm_vc, valid_count, loc = loc)
	solo_lo, lo_vc := oa.compute_min_where(col, mask)
	solo_hi, hi_vc := oa.compute_max_where(col, mask)
	testing.expect_value(w.t, lo_vc, valid_count, loc = loc)
	testing.expect_value(w.t, hi_vc, valid_count, loc = loc)
	if valid_count > 0 {
		testing.expectf(w.t, math.abs(got_lo - min_val) <= 1e-9, "where min_max lo mismatch: got %v, want %v", got_lo, min_val, loc = loc)
		testing.expectf(w.t, math.abs(got_hi - max_val) <= 1e-9, "where min_max hi mismatch: got %v, want %v", got_hi, max_val, loc = loc)
		testing.expectf(w.t, math.abs(solo_lo - min_val) <= 1e-9, "where min mismatch: got %v, want %v", solo_lo, min_val, loc = loc)
		testing.expectf(w.t, math.abs(solo_hi - max_val) <= 1e-9, "where max mismatch: got %v, want %v", solo_hi, max_val, loc = loc)
	}
}

@(private="file")
_str_dict_find_code :: proc(d: ^oa.Str_Dict_Array, key: string) -> (int, bool) {
	for ci in 0 ..< oa.n_dict(d) {
		if oa.array_get_string(&d.dict, ci) == key {
			return ci, true
		}
	}
	return -1, false
}

then_string_dict_value_counts_equal :: proc(
	w:               ^Spec_World,
	dict_name:       string,
	expected_keys:   []string,
	expected_counts: []i64,
	loc              := #caller_location,
) {
	d, ok := &w.str_dicts[dict_name]
	testing.expectf(w.t, ok, "missing string dict %q", dict_name, loc = loc)
	testing.expect_value(w.t, len(expected_keys), len(expected_counts), loc = loc)
	if !ok || len(expected_keys) != len(expected_counts) {
		return
	}
	counts := oa.str_dict_value_counts(d)
	defer delete(counts)

	testing.expect_value(w.t, oa.n_dict(d), len(expected_keys), loc = loc)
	testing.expect_value(w.t, len(counts), len(expected_keys), loc = loc)
	for key, ki in expected_keys {
		ci, found := _str_dict_find_code(d, key)
		testing.expectf(w.t, found, "expected dictionary key %q not found", key, loc = loc)
		if found {
			testing.expect_value(w.t, counts[ci], expected_counts[ki], loc = loc)
		}
	}
}

then_string_dict_group_sums_equal :: proc(
	w:             ^Spec_World,
	dict_name:     string,
	weight_col:    string,
	expected_keys: []string,
	expected_sums: []f64,
	loc            := #caller_location,
) {
	d, d_ok := &w.str_dicts[dict_name]
	weights, w_ok := &w.arrays[weight_col]
	testing.expectf(w.t, d_ok, "missing string dict %q", dict_name, loc = loc)
	testing.expectf(w.t, w_ok, "missing weight column %q", weight_col, loc = loc)
	testing.expect_value(w.t, len(expected_keys), len(expected_sums), loc = loc)
	if !d_ok || !w_ok || len(expected_keys) != len(expected_sums) {
		return
	}
	sums := oa.str_dict_group_sum(d, weights)
	defer delete(sums)

	testing.expect_value(w.t, oa.n_dict(d), len(expected_keys), loc = loc)
	testing.expect_value(w.t, len(sums), len(expected_keys), loc = loc)
	for key, ki in expected_keys {
		ci, found := _str_dict_find_code(d, key)
		testing.expectf(w.t, found, "expected dictionary key %q not found", key, loc = loc)
		if found {
			testing.expectf(
				w.t,
				math.abs(sums[ci] - expected_sums[ki]) <= 1e-9,
				"group sum mismatch for %q: got %v, want %v",
				key,
				sums[ci],
				expected_sums[ki],
				loc = loc,
			)
		}
	}
}

Compare_Row :: struct {
	op:       oa.Compare_Op,
	scalar:   f64,
	expected: []int,
	loc:      runtime.Source_Code_Location,
}

cmp_row :: proc(op: oa.Compare_Op, scalar: f64, expected: []int, loc := #caller_location) -> Compare_Row {
	return Compare_Row{op = op, scalar = scalar, expected = expected, loc = loc}
}

Scalar_Cmp_Kind :: enum {
	F64,
	I64,
	U64,
}

Scalar_Cmp_Row :: struct {
	col_name:   string,
	op:         oa.Compare_Op,
	kind:       Scalar_Cmp_Kind,
	f64_scalar: f64,
	i64_scalar: i64,
	u64_scalar: u64,
	expected:   []bool,
	loc:        runtime.Source_Code_Location,
}

scalar_f64_row :: proc(col_name: string, op: oa.Compare_Op, scalar: f64, expected: []bool, loc := #caller_location) -> Scalar_Cmp_Row {
	return Scalar_Cmp_Row{col_name = col_name, op = op, kind = .F64, f64_scalar = scalar, expected = expected, loc = loc}
}

scalar_i64_row :: proc(col_name: string, op: oa.Compare_Op, scalar: i64, expected: []bool, loc := #caller_location) -> Scalar_Cmp_Row {
	return Scalar_Cmp_Row{col_name = col_name, op = op, kind = .I64, i64_scalar = scalar, expected = expected, loc = loc}
}

scalar_u64_row :: proc(col_name: string, op: oa.Compare_Op, scalar: u64, expected: []bool, loc := #caller_location) -> Scalar_Cmp_Row {
	return Scalar_Cmp_Row{col_name = col_name, op = op, kind = .U64, u64_scalar = scalar, expected = expected, loc = loc}
}

upon_comparing_row :: proc(w: ^Spec_World, mask_name: string, row: Scalar_Cmp_Row) {
	switch row.kind {
	case .F64:
		upon_comparing_f64(w, mask_name, row.col_name, row.op, row.f64_scalar, loc = row.loc)
	case .I64:
		upon_comparing_i64(w, mask_name, row.col_name, row.op, row.i64_scalar, loc = row.loc)
	case .U64:
		upon_comparing_u64(w, mask_name, row.col_name, row.op, row.u64_scalar, loc = row.loc)
	}
}
