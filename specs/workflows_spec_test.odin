package skadi_specs

import "core:math"
import "core:testing"

// Pattern A + B: Conjunctive selection & fused aggregation with nulls and slices
@(test)
spec_nullable_sliced_conjunctive_query :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	// Prefix/suffix rows outside [1:7) must never leak into sliced kernels
	given_column(&w, "raw_price", []Maybe(f64){999.0, 10.0, nil, 45.0, 80.0, 60.0, nil, 999.0})
	given_column(&w, "raw_tier",  []Maybe(f64){  9.0,  2.0, 2.0,  1.0,  2.0,  nil, 2.0,   9.0})

	given_sliced_column(&w, "price", "raw_price", 1, 7) // [10, nil, 45, 80, 60, nil]
	given_sliced_column(&w, "tier",  "raw_tier",  1, 7) // [ 2,   2,  1,  2, nil,  2]

	upon_selecting(&w, "high_price", "price", .Ge, 45.0)
	upon_refining_selection(&w, "qualified", "high_price", "tier", .Eq, 2.0)
	upon_fused_aggregating(&w, "tier2_stats", "price", "tier", .Eq, 2.0)

	// Surviving row in both price >= 45 AND tier == 2 is index 3 (price = 80.0)
	then_selection_equals(&w, "qualified", []int{3})
	then_selection_aggregates_equal(&w, "price", "qualified", selected_rows = 1, valid_count = 1, sum = 80.0, min_val = 80.0, max_val = 80.0)

	// For tier == 2 (indices 0, 1, 3, 5), non-null prices are 10.0 and 80.0
	then_aggregates_equal(&w, "tier2_stats", count = 2, sum = 90.0, min_val = 10.0, max_val = 80.0)

	upon_fused_aggregating(&w, "no_match_stats", "price", "tier", .Gt, 100.0)
	then_aggregates_equal(&w, "no_match_stats", count = 0, sum = 0.0, min_val = 0.0, max_val = 0.0)
}

// Decision Matrix: All 6 comparison operators on nullable data with per-row line attribution
@(test)
spec_comparison_operator_matrix_with_nulls :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	given_column(&w, "v", []Maybe(i32){-10, nil, 0, 10, 20, nil})

	rows := []Compare_Row{
		cmp_row(.Gt, 0,  []int{3, 4}),
		cmp_row(.Ge, 0,  []int{2, 3, 4}),
		cmp_row(.Lt, 0,  []int{0}),
		cmp_row(.Le, 0,  []int{0, 2}),
		cmp_row(.Eq, 10, []int{3}),
		cmp_row(.Ne, 10, []int{0, 2, 4}), // nulls must never pass .Ne
	}

	for row in rows {
		upon_selecting(&w, "s", "v", row.op, row.scalar, loc = row.loc)
		then_selection_equals(&w, "s", row.expected, loc = row.loc)
	}
}

// Red-First Spec 1: Integer division with null divisor must propagate null, not SIGFPE
@(test)
spec_integer_division_propagates_null_divisor :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	// Include min(i32) / -1 in a masked-out null slot to test signed overflow handling
	// in compute_div: hardware idiv traps on min(i32) / -1 (SIGFPE).
	given_column(&w, "num", []Maybe(i32){100, min(i32), 50, nil, 42})
	given_masked_column(&w, "den", raw = []i32{10, -1, 0, 5, 0}, valid = []bool{true, false, false, true, false})

	given_sliced_column(&w, "num_s", "num", 0, 4)
	given_sliced_column(&w, "den_s", "den", 0, 4)

	upon_dividing(&w, "quot", "num_s", "den_s")
	then_column_i32_equals(&w, "quot", []Maybe(i32){10, nil, nil, nil})
}

// Red-First Spec 2: Multi-batch IPC zero-copy views survive freeing batch 0 first
@(test)
spec_ipc_multi_batch_independent_lifetimes :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	given_column(&w, "id_a", []Maybe(i32){1, nil, 3})
	given_column(&w, "nm_a", []Maybe(string){"ada", nil, "grace"})
	given_batch(&w, "b0", []string{"id:id_a", "name:nm_a"})

	given_column(&w, "id_b", []Maybe(i32){4, 5})
	given_column(&w, "nm_b", []Maybe(string){"alan", "barbara"})
	given_batch(&w, "b1", []string{"id:id_b", "name:nm_b"})

	upon_ipc_file_roundtrip(&w, "loaded", []string{"b0", "b1"}, use_mmap = true)
	upon_releasing_batch_in_set(&w, "loaded", 0)

	then_batch_set_count(&w, "loaded", expected_batches = 2)
	then_batch_column_equals(&w, "loaded", 1, "id",   []Maybe(i32){4, 5})
	then_batch_column_equals(&w, "loaded", 1, "name", []Maybe(string){"alan", "barbara"})

	upon_ipc_stream_roundtrip(&w, "loaded_stream", []string{"b0", "b1"})
	upon_releasing_batch_in_set(&w, "loaded_stream", 0)

	then_batch_set_count(&w, "loaded_stream", expected_batches = 2)
	then_batch_column_equals(&w, "loaded_stream", 1, "id",   []Maybe(i32){4, 5})
	then_batch_column_equals(&w, "loaded_stream", 1, "name", []Maybe(string){"alan", "barbara"})
}

// Red-First Spec 3: CSV -> Parquet -> CSV survives tiny read buffers splitting \r\n and ""
@(test)
spec_csv_parquet_boundary_streaming :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	csv_in := "id,\"note,text\"\r\n1,\"say \"\"hi\"\"\"\r\n2,\"line1\nline2\"\r\n3,plain\r\n"
	expected_lf := "id,\"note,text\"\n1,\"say \"\"hi\"\"\"\n2,\"line1\nline2\"\n3,plain\n"

	given_csv_input(&w, "raw_csv", csv_in)
	upon_csv_parquet_csv_roundtrip(&w, "roundtripped_csv", "raw_csv", read_buf_bytes = 16, max_rows_per_rg = 2)
	then_csv_text_equals(&w, "roundtripped_csv", expected_lf)
}

// Exact 64-bit integer predicates (> 2^53) in select, refinement, and fused aggregation
@(test)
spec_exact_i64_selection_refinement_and_fused_aggregation :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	// 2^53 = 9_007_199_254_740_992: f64 collides BASE and BASE + 1, whereas exact i64 distinguishes them.
	BASE :: i64(9_007_199_254_740_992)

	given_column(&w, "raw_id",    []Maybe(i64){BASE + 99, BASE, BASE + 1, nil, BASE + 2, BASE + 1, BASE + 3, BASE - 99})
	given_column(&w, "raw_score", []Maybe(i64){999, 10, 20, 30, 40, nil, 50, 999})
	given_column(&w, "raw_val",   []Maybe(i64){999, 100, 200, 300, 400, 500, nil, 999})

	given_sliced_column(&w, "id",    "raw_id",    1, 7) // [BASE, BASE+1, nil, BASE+2, BASE+1, BASE+3]
	given_sliced_column(&w, "score", "raw_score", 1, 7) // [10,   20,     30,  40,     nil,    50]
	given_sliced_column(&w, "val",   "raw_val",   1, 7) // [100,  200,    300, 400,    500,    nil]

	upon_selecting_i64(&w, "id_ge", "id", .Ge, BASE + 1)
	then_selection_equals(&w, "id_ge", []int{1, 3, 4, 5})

	upon_refining_selection_i64(&w, "qualified", "id_ge", "score", .Ge, 20)
	then_selection_equals(&w, "qualified", []int{1, 3, 5})

	upon_fused_aggregating_i64(&w, "exact_hit", "val", "id", .Eq, BASE + 1)
	then_aggregates_equal(&w, "exact_hit", count = 2, sum = 700.0, min_val = 200.0, max_val = 500.0)

	upon_fused_aggregating_i64(&w, "null_val_hit", "val", "id", .Eq, BASE + 3)
	then_aggregates_equal(&w, "null_val_hit", count = 0, sum = 0.0, min_val = 0.0, max_val = 0.0)
}

// Decision Matrix: Cross-type scalar comparisons across exact i64, exact u64, and f64 boundary scalars
// (`compute_compare*` yields a dense Bool selection mask where null input rows evaluate to false)
@(test)
spec_cross_type_scalar_comparison_matrix :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	BASE_I64 :: i64(9_007_199_254_740_992)
	BASE_U64 :: u64(9_007_199_254_740_992)

	given_column(&w, "c_i64", []Maybe(i64){min(i64), BASE_I64, BASE_I64 + 1, nil, max(i64) - 1, max(i64)})
	given_column(&w, "c_u64", []Maybe(u64){0, BASE_U64, BASE_U64 + 1, nil, max(u64) - 1, max(u64)})
	given_column(&w, "c_u8",  []Maybe(u8){0, 10, nil, 255})
	given_column(&w, "c_i32", []Maybe(i32){-5, 0, nil, 10})
	given_column(&w, "c_f64", []Maybe(f64){-2.5, 0.0, nil, 3.5})

	rows := []Scalar_Cmp_Row{
		scalar_i64_row("c_i64", .Eq, BASE_I64 + 1, []bool{false, false, true, false, false, false}),
		scalar_i64_row("c_i64", .Gt, BASE_I64,     []bool{false, false, true, false, true, true}),
		scalar_i64_row("c_i64", .Le, min(i64),     []bool{true, false, false, false, false, false}),

		scalar_u64_row("c_u64", .Eq, BASE_U64 + 1, []bool{false, false, true, false, false, false}),
		scalar_u64_row("c_u64", .Ge, max(u64) - 1, []bool{false, false, false, false, true, true}),
		scalar_u64_row("c_u64", .Lt, 1,            []bool{true, false, false, false, false, false}),

		scalar_f64_row("c_u8",  .Gt, 255.0,        []bool{false, false, false, false}),
		scalar_f64_row("c_u8",  .Gt, -1.0,         []bool{true, true, false, true}),
		scalar_u64_row("c_u8",  .Le, 10,           []bool{true, true, false, false}),

		scalar_f64_row("c_i32", .Gt, 0.5,          []bool{false, false, false, true}),
		scalar_i64_row("c_i32", .Ge, 0,            []bool{false, true, false, true}),

		scalar_i64_row("c_f64", .Lt, 0,            []bool{true, false, false, false}),
		scalar_f64_row("c_f64", .Eq, -2.5,         []bool{true, false, false, false}),

		scalar_f64_row("c_i64", .Eq, f64(BASE_I64),   []bool{false, true, false, false, false, false}),
		scalar_f64_row("c_i64", .Gt, f64(BASE_I64),   []bool{false, false, true, false, true, true}),
		scalar_f64_row("c_i64", .Eq, 0.5,             []bool{false, false, false, false, false, false}),
		scalar_f64_row("c_i64", .Lt, 0.5,             []bool{true, false, false, false, false, false}),
		scalar_f64_row("c_i64", .Ge, 0.5,             []bool{false, true, true, false, true, true}),
		scalar_f64_row("c_i64", .Eq, math.nan_f64(),  []bool{false, false, false, false, false, false}),
		scalar_f64_row("c_i64", .Lt, math.nan_f64(),  []bool{false, false, false, false, false, false}),
		scalar_f64_row("c_i64", .Gt, math.nan_f64(),  []bool{false, false, false, false, false, false}),
		scalar_f64_row("c_i64", .Ne, math.nan_f64(),  []bool{true, true, true, false, true, true}),
		scalar_f64_row("c_i64", .Lt, 1e30,            []bool{true, true, true, false, true, true}),
		scalar_f64_row("c_i64", .Ge, 1e30,            []bool{false, false, false, false, false, false}),
		scalar_f64_row("c_i64", .Gt, -1e30,           []bool{true, true, true, false, true, true}),
		scalar_f64_row("c_i64", .Le, -1e30,           []bool{false, false, false, false, false, false}),
		scalar_f64_row("c_u64", .Gt, f64(BASE_U64),   []bool{false, false, true, false, true, true}),
		scalar_f64_row("c_u64", .Eq, -1.0,            []bool{false, false, false, false, false, false}),
		scalar_f64_row("c_u64", .Lt, -1.0,            []bool{false, false, false, false, false, false}),
		scalar_f64_row("c_u64", .Gt, -1.0,            []bool{true, true, true, false, true, true}),
		scalar_f64_row("c_u64", .Ge, -1.0,            []bool{true, true, true, false, true, true}),
		scalar_f64_row("c_u64", .Lt, 1e30,            []bool{true, true, true, false, true, true}),
	}

	for row in rows {
		upon_comparing_row(&w, "mask", row)
		then_mask_equals(&w, "mask", row.expected, loc = row.loc)
	}
}

// Parquet dictionary decoding: bit_width == 0 single-entry dict, RLE def levels, and dict->plain RG transition
@(test)
spec_parquet_multi_row_group_dictionary_and_nullable_to_csv :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	id_rgs := []Parquet_RG_I32_Spec{
		// RG0: Nullable multi-entry INT32 dictionary
		{
			encoding = .Dictionary,
			nullable = true,
			dict     = []i32{100, 200},
			values   = []Maybe(i32){100, 200, 100},
		},
		// RG1: Nullable single-entry INT32 dictionary (bit_width == 0) with null row
		{
			encoding = .Dictionary,
			nullable = true,
			dict     = []i32{777},
			values   = []Maybe(i32){777, nil},
		},
		// RG2: Transition from dictionary to nullable PLAIN encoding across row groups
		{
			encoding = .Plain,
			nullable = true,
			values   = []Maybe(i32){301, nil, 303},
		},
	}

	str_rgs := []Parquet_RG_Str_Spec{
		// RG0: Nullable BYTE_ARRAY dictionary with CSV comma escaping
		{
			encoding = .Dictionary,
			nullable = true,
			dict     = []string{"alpha", "beta", "comma,val"},
			values   = []Maybe(string){"alpha", nil, "comma,val"},
		},
		// RG1: Nullable single-entry BYTE_ARRAY dictionary (bit_width == 0)
		{
			encoding = .Dictionary,
			nullable = true,
			dict     = []string{"solo"},
			values   = []Maybe(string){nil, "solo"},
		},
		// RG2: Transition to nullable PLAIN BYTE_ARRAY with CSV quote escaping
		{
			encoding = .Plain,
			nullable = true,
			values   = []Maybe(string){"gamma", "quote\"it", nil},
		},
	}

	given_parquet_two_col_fixture(&w, "multi_rg", "id", "tag", id_rgs, str_rgs)
	upon_parquet_to_csv(&w, "out_csv", "multi_rg", max_rows_per_chunk = 2)

	expected_csv :=
		"id,tag\n" +
		"100,alpha\n" +
		"200,\n" +
		"100,\"comma,val\"\n" +
		"777,\n" +
		",solo\n" +
		"301,gamma\n" +
		",\"quote\"\"it\"\n" +
		"303,\n"

	then_csv_text_equals(&w, "out_csv", expected_csv)
}

// Null_Type array slice, copy, and compute_count verification
@(test)
spec_null_type_column_slice_copy_and_count :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	given_null_column(&w, "nulls", 6)
	then_null_column_equals(&w, "nulls", expected_len = 6)
	then_column_count_equals(&w, "nulls", expected_total = 6, expected_valid = 0)

	given_sliced_column(&w, "null_slice", "nulls", 1, 5)
	then_null_column_equals(&w, "null_slice", expected_len = 4)
	then_column_count_equals(&w, "null_slice", expected_total = 4, expected_valid = 0)

	upon_copying_column(&w, "null_copy", "null_slice")
	then_null_column_equals(&w, "null_copy", expected_len = 4)
	then_column_count_equals(&w, "null_copy", expected_total = 4, expected_valid = 0)
}

// Mask-driven selection, single-column and record-batch take, and selection/where aggregations
@(test)
spec_mask_selection_column_and_record_batch_take :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	given_column(&w, "id",    []Maybe(i32){1, nil, 3, 4, nil, 6})
	given_column(&w, "score", []Maybe(f64){10.0, 20.0, nil, 40.0, 50.0, 60.0})
	given_column(&w, "bonus", []f64{1.5, 2.5, 3.5, 4.5, 5.5, 6.5})
	given_column(&w, "tag",   []Maybe(string){"a", "b", "c", nil, "e", "f"})
	given_column(&w, "mask",  []Maybe(bool){true, false, true, true, nil, false})
	given_batch(&w, "src_batch", []string{"id", "score", "bonus", "tag"})

	upon_selecting_mask(&w, "sel", "mask")
	then_selection_equals(&w, "sel", []int{0, 2, 3})
	then_selection_aggregates_equal(&w, "score", "sel", selected_rows = 3, valid_count = 2, sum = 50.0, min_val = 10.0, max_val = 40.0)
	then_where_aggregates_equal(&w, "score", "mask", mask_true_count = 3, valid_count = 2, sum = 50.0, mean = 25.0, min_val = 10.0, max_val = 40.0)

	upon_taking_selection(&w, "taken_score", "score", "sel")
	then_column_f64_equals(&w, "taken_score", []Maybe(f64){10.0, nil, 40.0})
	upon_taking_selection(&w, "taken_bonus", "bonus", "sel")
	then_column_f64_equals(&w, "taken_bonus", []Maybe(f64){1.5, 3.5, 4.5})

	upon_taking_batch_selection(&w, "taken_batch", "src_batch", "sel")
	then_batch_column_equals(&w, "taken_batch", "id",    []Maybe(i32){1, 3, 4})
	then_batch_column_equals(&w, "taken_batch", "score", []Maybe(f64){10.0, nil, 40.0})
	then_batch_column_equals(&w, "taken_batch", "bonus", []Maybe(f64){1.5, 3.5, 4.5})
	then_batch_column_equals(&w, "taken_batch", "tag",   []Maybe(string){"a", "c", nil})
}

// String dictionary value counts and grouped sum with nulls and sliced offsets
@(test)
spec_string_dictionary_value_counts_and_group_sum :: proc(t: ^testing.T) {
	w: Spec_World
	world_init(&w, t)
	defer world_destroy(&w)

	given_column(&w, "raw_keys",    []Maybe(string){"skip", "red", "green", "red", nil, "blue", "green", "red", "skip"})
	given_column(&w, "raw_weights", []Maybe(f64){999.0, 1.5, 2.0, 3.5, 100.0, nil, 4.0, 5.0, 999.0})

	given_sliced_column(&w, "keys",    "raw_keys",    1, 8)
	given_sliced_column(&w, "weights", "raw_weights", 1, 8)

	upon_encoding_string_dict(&w, "color_dict", "keys")
	then_string_dict_value_counts_equal(&w, "color_dict", []string{"red", "green", "blue"}, []i64{3, 2, 1})
	then_string_dict_group_sums_equal(&w, "color_dict", "weights", []string{"red", "green", "blue"}, []f64{10.0, 6.0, 0.0})
}
