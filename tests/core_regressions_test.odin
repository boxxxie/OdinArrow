package skadi_tests

import "core:mem"
import "core:testing"
import oa "../skadi"

// Red-First: Buffer_Pool must honour 64-byte alignment even after recycling a 1-byte-aligned block of equal size
@(private="file")
Test_Backing_Data :: struct {
	backing: mem.Allocator,
	allocs:  map[rawptr]rawptr,
}

@(private="file")
test_pool_backing_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	data := cast(^Test_Backing_Data)allocator_data
	if alignment <= 8 && (mode == .Alloc || mode == .Alloc_Non_Zeroed) {
		raw, err := mem.alloc_bytes(size + 64, 64, data.backing, loc)
		if err != .None {
			return nil, err
		}
		// +49 forces an odd base pointer; _pool_get must still align _Pool_Header while leaving user non-64B-aligned.
		shifted := rawptr(uintptr(raw_data(raw)) + 49)
		data.allocs[shifted] = raw_data(raw)
		return (cast([^]byte)shifted)[:size], .None
	}
	if (mode == .Resize || mode == .Resize_Non_Zeroed) && old_memory in data.allocs {
		return nil, .Mode_Not_Implemented
	}
	if mode == .Free && old_memory in data.allocs {
		orig := data.allocs[old_memory]
		delete_key(&data.allocs, old_memory)
		mem.free(orig, data.backing, loc)
		return nil, .None
	}
	return data.backing.procedure(data.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
test_buffer_pool_resize_and_alignment :: proc(t: ^testing.T) {
	t_data: Test_Backing_Data
	t_data.backing = context.allocator
	t_data.allocs = make(map[rawptr]rawptr)
	defer {
		for _, v in t_data.allocs {
			mem.free(v, t_data.backing)
		}
		delete(t_data.allocs)
	}
	custom_backing := mem.Allocator{procedure = test_pool_backing_proc, data = &t_data}

	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool, custom_backing)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	// Exercise _pool_resize: grow (128 -> 256), shrink in-place (256 -> 32), free via resize-to-0
	raw, err1 := mem.alloc(128, 8, alloc)
	testing.expect_value(t, err1, nil)
	if err1 != nil || raw == nil { return }
	(cast([^]u8)raw)[0] = 0x5A

	grown, err2 := mem.resize(raw, 128, 256, 8, alloc)
	testing.expect_value(t, err2, nil)
	if err2 != nil || grown == nil { return }
	testing.expect_value(t, (cast([^]u8)grown)[0], u8(0x5A))
	testing.expect_value(t, (cast([^]u8)grown)[200], u8(0))

	shrunk, err3 := mem.resize(grown, 256, 32, 8, alloc)
	testing.expect_value(t, err3, nil)
	if err3 != nil || shrunk == nil { return }
	testing.expect_value(t, (cast([^]u8)shrunk)[0], u8(0x5A))
	_, _ = mem.resize(shrunk, 32, 0, 8, alloc)

	// Seed free_list with an 8-byte-aligned (non-64B-aligned) allocation, then request 64-byte ARROW_ALIGNMENT
	unaligned, u_err := mem.alloc(oa.ARROW_ALIGNMENT, 1, alloc)
	testing.expect_value(t, u_err, nil)
	testing.expect(t, uintptr(unaligned) % oa.ARROW_ALIGNMENT != 0, "seeded block must not be 64-byte aligned")
	mem.free(unaligned, alloc)

	buf, b_err := oa.buffer_make(oa.ARROW_ALIGNMENT, alloc)
	defer oa.buffer_free(&buf)
	testing.expect_value(t, b_err, nil)
	testing.expect(
		t,
		uintptr(buf.data) % oa.ARROW_ALIGNMENT == 0,
		"recycled pool block must satisfy 64-byte Arrow alignment",
	)
}

// Red-First: null -> finish -> reset -> null must allocate a bitmap >= bitmap_byte_count (64B), not 8B
@(test)
test_builder_null_finish_reset_null_bitmap_capacity :: proc(t: ^testing.T) {
	b := oa.builder_make(i32, 16)
	defer oa.builder_destroy(&b)

	oa.builder_append_null(&b)
	oa.builder_append(&b, 10)
	a1, _ := oa.builder_finish(&b)
	defer oa.array_free(&a1)

	oa.builder_reset(&b)
	oa.builder_append_null(&b)
	oa.builder_append(&b, 20)
	a2, _ := oa.builder_finish(&b)
	defer oa.array_free(&a2)

	testing.expect(
		t,
		a2.buffers[0].capacity >= a2.buffers[0].size,
		"validity bitmap capacity must be >= declared Buffer.size (64 bytes)",
	)

	// Triggers _validity_copy over bitmap_byte_count(a2.length) bytes
	casted, c_err := oa.compute_cast(&a2, oa.Int64_Type{})
	defer oa.array_free(&casted)
	testing.expect_value(t, c_err, nil)
	testing.expect(t, oa.array_is_null(&casted, 0))
	testing.expect_value(t, oa.array_get(&casted, 1, i64), i64(20))

	// Same lifecycle on String_Builder
	sb := oa.string_builder_make(16)
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_append_null(&sb)
	sa1, _ := oa.string_builder_finish(&sb)
	defer oa.array_free(&sa1)

	oa.string_builder_reset(&sb)
	oa.string_builder_append_null(&sb)
	oa.string_builder_append(&sb, "ok")
	sa2, _ := oa.string_builder_finish(&sb)
	defer oa.array_free(&sa2)

	testing.expect(
		t,
		sa2.buffers[0].capacity >= sa2.buffers[0].size,
		"string validity bitmap capacity must be >= declared Buffer.size",
	)
}

// Red-First: builder_finish documents that the builder is left empty and reusable on the next append
@(test)
test_builder_append_after_finish_without_reset :: proc(t: ^testing.T) {
	// 1. Primitive builder (T == i32)
	b := oa.builder_make(i32, 32)
	defer oa.builder_destroy(&b)
	for i in 0..<24 {
		oa.builder_append(&b, i32(i))
	}
	a1, _ := oa.builder_finish(&b)
	defer oa.array_free(&a1)

	oa.builder_append(&b, 77)
	oa.builder_append(&b, 88)
	a2, _ := oa.builder_finish(&b)
	defer oa.array_free(&a2)

	testing.expect_value(t, a2.length, 2)
	if a2.length == 2 {
		testing.expect_value(t, oa.array_get(&a2, 0, i32), i32(77))
		testing.expect_value(t, oa.array_get(&a2, 1, i32), i32(88))
	}

	// 2. Bool builder (when T == bool branch in builder_finish)
	bb := oa.builder_make(bool, 32)
	defer oa.builder_destroy(&bb)
	for i in 0..<20 {
		oa.builder_append(&bb, i % 2 == 0)
	}
	ba1, _ := oa.builder_finish(&bb)
	defer oa.array_free(&ba1)

	oa.builder_append(&bb, true)
	oa.builder_append(&bb, false)
	ba2, _ := oa.builder_finish(&bb)
	defer oa.array_free(&ba2)

	testing.expect_value(t, ba2.length, 2)
	if ba2.length == 2 {
		testing.expect_value(t, oa.array_get(&ba2, 0, bool), true)
		testing.expect_value(t, oa.array_get(&ba2, 1, bool), false)
	}

	// 3. String_Builder (var_length string_builder_finish)
	sb := oa.string_builder_make(32)
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_append(&sb, "hello")
	oa.string_builder_append(&sb, "world")
	sa1, _ := oa.string_builder_finish(&sb)
	defer oa.array_free(&sa1)

	oa.string_builder_append(&sb, "first")
	oa.string_builder_append(&sb, "second")
	sa2, _ := oa.string_builder_finish(&sb)
	defer oa.array_free(&sa2)

	testing.expect_value(t, sa2.length, 2)
	if sa2.length == 2 {
		testing.expect_value(t, oa.array_get_string(&sa2, 0), "first")
		testing.expect_value(t, oa.array_get_string(&sa2, 1), "second")
	}
}

@(test)
test_umbra_embedded_nul_prefix_tie :: proc(t: ^testing.T) {
	b := oa.umbra_builder_make(4)
	defer oa.umbra_builder_destroy(&b)

	// All four share the exact same 4-byte zero-padded prefix: {'a', 'b', 0, 0}
	oa.umbra_append(&b, "ab")
	oa.umbra_append(&b, "ab\x00")
	oa.umbra_append(&b, "ab\x00\x00z")
	oa.umbra_append(&b, "ab\x00\x00a")
	ua := oa.umbra_builder_finish(&b)
	defer oa.umbra_free(&ua)

	testing.expect(t, oa.umbra_compare(&ua, 0, 1) < 0, `"ab" < "ab\x00"`)
	testing.expect(t, oa.umbra_compare(&ua, 3, 2) < 0, `"ab\x00\x00a" < "ab\x00\x00z"`)
	testing.expect_value(t, oa.umbra_count_eq(&ua, "ab\x00"), 1)
	testing.expect_value(t, oa.umbra_count_eq(&ua, "ab"), 1)
}

@(test)
test_record_batch_make_rejects_type_mismatch :: proc(t: ^testing.T) {
	fields := []oa.Field{oa.field_make("int_col", oa.Int32_Type{})}
	sc, s_err := oa.schema_make(fields)
	testing.expect_value(t, s_err, nil)
	defer oa.schema_free(&sc)

	b_f64 := oa.builder_make(f64, 2)
	defer oa.builder_destroy(&b_f64)
	oa.builder_append(&b_f64, 1.0)
	oa.builder_append(&b_f64, 2.0)
	col_f64, _ := oa.builder_finish(&b_f64)

	rb, ok := oa.record_batch_make(&sc, []oa.Array{col_f64})
	if ok {
		oa.record_batch_free(&rb)
	} else {
		oa.array_free(&col_f64)
	}
	testing.expect(t, !ok, "record_batch_make must reject type mismatch between schema field (Int32) and array (Float64)")
}

@(test)
test_table_from_record_batches_rejects_mismatched_schema :: proc(t: ^testing.T) {
	f_i32 := []oa.Field{oa.field_make("val", oa.Int32_Type{})}
	sc_i32, _ := oa.schema_make(f_i32)
	defer oa.schema_free(&sc_i32)

	f_f64 := []oa.Field{oa.field_make("val", oa.Float64_Type{})}
	sc_f64, _ := oa.schema_make(f_f64)
	defer oa.schema_free(&sc_f64)

	b1 := oa.builder_make(i32, 2)
	defer oa.builder_destroy(&b1)
	oa.builder_append(&b1, 10)
	oa.builder_append(&b1, 20)
	c1, _ := oa.builder_finish(&b1)

	rb1, _ := oa.record_batch_make(&sc_i32, []oa.Array{c1})
	defer oa.record_batch_free(&rb1)

	b2 := oa.builder_make(f64, 2)
	defer oa.builder_destroy(&b2)
	oa.builder_append(&b2, 1.5)
	oa.builder_append(&b2, 2.5)
	c2, _ := oa.builder_finish(&b2)

	rb2, _ := oa.record_batch_make(&sc_f64, []oa.Array{c2})
	defer oa.record_batch_free(&rb2)

	tbl, ok := oa.table_from_record_batches([]oa.Record_Batch{rb1, rb2})
	if ok {
		oa.table_free(&tbl)
	}
	testing.expect(t, !ok, "table_from_record_batches must reject batches with differing column types")
}

@(test)
test_buffer_resize_rejects_slice_view_or_zero_allocator :: proc(t: ^testing.T) {
	// 1. buffer_slice produces a non-owning Buffer view with allocator.procedure == nil
	buf, _ := oa.buffer_make(128)
	defer oa.buffer_free(&buf)

	view := oa.buffer_slice(&buf, 16, 64)
	testing.expect(t, view.allocator.procedure == nil, "view must have nil allocator procedure")

	r_err := oa.buffer_resize(&view, 256)
	testing.expect(t, r_err != nil, "buffer_resize on slice view must fail")

	// 2. zero Buffer{}
	zero_buf := oa.Buffer{}
	z_err := oa.buffer_resize(&zero_buf, 64)
	testing.expect(t, z_err != nil, "buffer_resize on zero Buffer must fail")
}

@(test)
test_null_type_recount_nulls :: proc(t: ^testing.T) {
	arr := oa.Array{type = oa.Null_Type{}, length = 7, null_count = -1}
	testing.expect_value(t, oa.array_recount_nulls(&arr), 7)
	testing.expect_value(t, arr.null_count, 7)

	sl := oa.array_slice(arr, 2, 6)
	testing.expect_value(t, oa.array_recount_nulls(&sl), 4)
	testing.expect_value(t, sl.null_count, 4)
}

@(test)
test_record_batch_and_table_nil_schema_and_column_len_guards :: proc(t: ^testing.T) {
	// 1. record_batch_make with nil schema must return ok = false
	rb_nil, ok_nil := oa.record_batch_make(nil, nil)
	testing.expect(t, !ok_nil)
	oa.record_batch_free(&rb_nil)
	testing.expect(t, oa.record_batch_column(&rb_nil, "a") == nil)

	// 2. table_from_record_batches with nil schema or mismatched column slice lengths
	f := []oa.Field{oa.field_make("a", oa.Int32_Type{})}
	sc, _ := oa.schema_make(f)
	defer oa.schema_free(&sc)

	b := oa.builder_make(i32, 1)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, 7)
	c, _ := oa.builder_finish(&b)
	rb_valid, _ := oa.record_batch_make(&sc, []oa.Array{c})
	defer oa.record_batch_free(&rb_valid)

	// First batch has nil schema
	bad_nil_0 := oa.Record_Batch{schema = nil}
	tbl0, ok0 := oa.table_from_record_batches([]oa.Record_Batch{bad_nil_0})
	if ok0 { oa.table_free(&tbl0) }
	testing.expect(t, !ok0)

	// Second batch has nil schema
	tbl1, ok1 := oa.table_from_record_batches([]oa.Record_Batch{rb_valid, bad_nil_0})
	if ok1 { oa.table_free(&tbl1) }
	testing.expect(t, !ok1)

	// Batch has matching schema pointer but truncated columns slice
	bad_cols := oa.Record_Batch{schema = &sc, columns = nil, length = 0}
	tbl2, ok2 := oa.table_from_record_batches([]oa.Record_Batch{bad_cols})
	if ok2 { oa.table_free(&tbl2) }
	testing.expect(t, !ok2)

	tbl3, ok3 := oa.table_from_record_batches([]oa.Record_Batch{rb_valid, bad_cols})
	if ok3 { oa.table_free(&tbl3) }
	testing.expect(t, !ok3)
}
