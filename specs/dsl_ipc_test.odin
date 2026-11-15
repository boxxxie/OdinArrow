package skadi_specs

import "core:bytes"
import "core:fmt"
import "core:strings"
import "core:testing"
import oa "../skadi"

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
			got := oa.array_get_large_binary(col, i) if large else oa.array_get_binary(col, i)
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
