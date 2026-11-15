package skadi_specs

import "core:testing"

@(test)
spec_ipc_all_16_types_roundtrip_matrix :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	given_null_column(&w, "c_null", 3)
	given_column(&w, "c_bool", []Maybe(bool){true, nil, false})
	given_column(&w, "c_i8",   []Maybe(i8){i8(-128), nil, 127})
	given_column(&w, "c_i16",  []Maybe(i16){-32000, nil, 32000})
	given_column(&w, "c_i32",  []Maybe(i32){-100000, nil, 100000})
	given_column(&w, "c_i64",  []Maybe(i64){min(i64), nil, max(i64)})
	given_column(&w, "c_u8",   []Maybe(u8){0, nil, 255})
	given_column(&w, "c_u16",  []Maybe(u16){0, nil, 65535})
	given_column(&w, "c_u32",  []Maybe(u32){0, nil, 4000000000})
	given_column(&w, "c_u64",  []Maybe(u64){0, nil, max(u64)})
	given_column(&w, "c_f32",  []Maybe(f32){-1.5, nil, 3.25})
	given_column(&w, "c_f64",  []Maybe(f64){-123.456, nil, 789.0125})
	given_column(&w, "c_str",  []Maybe(string){"alpha", nil, ""})
	given_large_string_column(&w, "c_lstr", []Maybe(string){"large-a", nil, "large-c"})
	given_column(&w, "c_bin",  []Maybe([]u8){[]u8{0x01, 0x00, 0xFF}, nil, []u8{0x42}})
	given_large_binary_column(&w, "c_lbin", []Maybe([]u8){[]u8{0xDE, 0xAD}, nil, []u8{0xBE, 0xEF}})

	given_batch(&w, "all_16", []string{
		"c_null", "c_bool", "c_i8", "c_i16", "c_i32", "c_i64",
		"c_u8", "c_u16", "c_u32", "c_u64", "c_f32", "c_f64",
		"c_str", "c_lstr", "c_bin", "c_lbin",
	})

	modes := []string{"file-mmap", "file-copy", "stream"}
	for mode in modes {
		if mode == "file-mmap" {
			upon_ipc_file_roundtrip(&w, mode, []string{"all_16"}, use_mmap = true)
		} else if mode == "file-copy" {
			upon_ipc_file_roundtrip(&w, mode, []string{"all_16"}, use_mmap = false)
		} else {
			upon_ipc_stream_roundtrip(&w, mode, []string{"all_16"})
		}

		then_batch_set_count(&w, mode, expected_batches = 1)
		then_batch_in_set_row_count(&w, mode, 0, expected_rows = 3)
		then_schema_field_names(&w, mode, []string{
			"c_null:null", "c_bool:bool", "c_i8:int8", "c_i16:int16", "c_i32:int32", "c_i64:int64",
			"c_u8:uint8", "c_u16:uint16", "c_u32:uint32", "c_u64:uint64", "c_f32:float32", "c_f64:float64",
			"c_str:string", "c_lstr:large_string", "c_bin:binary", "c_lbin:large_binary",
		})
		then_batch_null_column_equals(&w, mode, 0, "c_null", expected_len = 3)
		then_batch_column_equals(&w, mode, 0, "c_bool", []Maybe(bool){true, nil, false})
		then_batch_column_equals(&w, mode, 0, "c_i8",   []Maybe(i8){i8(-128), nil, 127})
		then_batch_column_equals(&w, mode, 0, "c_i16",  []Maybe(i16){-32000, nil, 32000})
		then_batch_column_equals(&w, mode, 0, "c_i32",  []Maybe(i32){-100000, nil, 100000})
		then_batch_column_equals(&w, mode, 0, "c_i64",  []Maybe(i64){min(i64), nil, max(i64)})
		then_batch_column_equals(&w, mode, 0, "c_u8",   []Maybe(u8){0, nil, 255})
		then_batch_column_equals(&w, mode, 0, "c_u16",  []Maybe(u16){0, nil, 65535})
		then_batch_column_equals(&w, mode, 0, "c_u32",  []Maybe(u32){0, nil, 4000000000})
		then_batch_column_equals(&w, mode, 0, "c_u64",  []Maybe(u64){0, nil, max(u64)})
		then_batch_column_equals(&w, mode, 0, "c_f32",  []Maybe(f32){-1.5, nil, 3.25})
		then_batch_column_equals(&w, mode, 0, "c_f64",  []Maybe(f64){-123.456, nil, 789.0125})
		then_batch_column_equals(&w, mode, 0, "c_str",  []Maybe(string){"alpha", nil, ""})
		then_batch_large_string_column_equals(&w, mode, 0, "c_lstr", []Maybe(string){"large-a", nil, "large-c"})
		then_batch_column_equals(&w, mode, 0, "c_bin",  []Maybe([]u8){[]u8{0x01, 0x00, 0xFF}, nil, []u8{0x42}})
		then_batch_large_binary_column_equals(&w, mode, 0, "c_lbin", []Maybe([]u8){[]u8{0xDE, 0xAD}, nil, []u8{0xBE, 0xEF}})
	}
}

// Red-First target: serializing sliced columns must emit [offset .. offset+length), not [0 .. length)
@(test)
spec_ipc_sliced_batch_serializes_slice_window :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	given_column(&w, "full_id",   []Maybe(i32){10, 20, 30, nil, 50, 60})
	given_column(&w, "full_flag", []bool{false, false, true, false, true, false})
	given_column(&w, "full_name", []Maybe(string){"drop0", "drop1", "keep_a", nil, "keep_c", "drop5"})

	given_sliced_column(&w, "id",   "full_id",   2, 5)
	given_sliced_column(&w, "flag", "full_flag", 2, 5)
	given_sliced_column(&w, "name", "full_name", 2, 5)
	given_batch(&w, "sliced_rb", []string{"id", "flag", "name"})
	then_batch_column_offset(&w, "sliced_rb", "id", expected_offset = 2)

	upon_ipc_file_roundtrip(&w, "out", []string{"sliced_rb"})

	then_batch_set_count(&w, "out", expected_batches = 1)
	then_batch_column_equals(&w, "out", 0, "id",   []Maybe(i32){30, nil, 50})
	then_batch_column_equals(&w, "out", 0, "flag", []bool{true, false, true})
	then_batch_column_equals(&w, "out", 0, "name", []Maybe(string){"keep_a", nil, "keep_c"})
}

@(test)
spec_ipc_empty_and_zero_row_batches :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	given_column(&w, "empty_i32", []i32{})
	given_column(&w, "empty_str", []Maybe(string){})
	given_batch(&w, "zero_rows", []string{"empty_i32", "empty_str"})

	upon_ipc_file_roundtrip(&w, "zero_row_set", []string{"zero_rows"})
	then_batch_set_count(&w, "zero_row_set", expected_batches = 1)
	then_batch_in_set_row_count(&w, "zero_row_set", batch_idx = 0, expected_rows = 0)

	// Zero batches (schema-only IPC file)
	upon_ipc_schema_only_roundtrip(&w, "no_batches", schema_from_batch = "zero_rows")
	then_batch_set_count(&w, "no_batches", expected_batches = 0)
	then_schema_field_names(&w, "no_batches", []string{"empty_i32:int32", "empty_str:string"})
}
