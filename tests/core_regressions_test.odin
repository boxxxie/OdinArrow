package skadi_tests

import "core:bytes"
import "core:math"
import "core:mem"
import "core:os"
import "core:testing"
import bs "../benchmarks/odin/stats"
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

@(test)
test_compute_div_unsigned_null_divisor :: proc(t: ^testing.T) {
	b1 := oa.builder_make(u64, 4)
	defer oa.builder_destroy(&b1)
	for v in ([?]u64{100, 200, 300, 400}) {
		oa.builder_append(&b1, v)
	}
	lhs, l_err := oa.builder_finish(&b1)
	testing.expect_value(t, l_err, mem.Allocator_Error.None)
	defer oa.array_free(&lhs)

	b2 := oa.builder_make(u64, 4)
	defer oa.builder_destroy(&b2)
	oa.builder_append(&b2, u64(10))
	oa.builder_append_null(&b2)
	oa.builder_append(&b2, u64(3))
	oa.builder_append_null(&b2)
	rhs, r_err := oa.builder_finish(&b2)
	testing.expect_value(t, r_err, mem.Allocator_Error.None)
	defer oa.array_free(&rhs)

	out, err := oa.compute_arithmetic(&lhs, &rhs, .Div)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	defer oa.array_free(&out)

	testing.expect_value(t, out.null_count, 2)
	testing.expect(t, !oa.array_is_null(&out, 0))
	testing.expect(t, oa.array_is_null(&out, 1))
	testing.expect(t, !oa.array_is_null(&out, 2))
	testing.expect(t, oa.array_is_null(&out, 3))
	testing.expect_value(t, oa.array_get(&out, 0, u64), u64(10))
	testing.expect_value(t, oa.array_get(&out, 2, u64), u64(100))
}

@(test)
test_builder_lazy_bitmap_and_reserve_data :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	// Primitive_Builder: null -> finish -> reset -> dense -> finish -> null-at-tail -> finish
	pb := oa.builder_make(i32, 8)
	defer oa.builder_destroy(&pb)

	for i in 0..<25 {
		if i % 7 == 0 {
			oa.builder_append_null(&pb)
		} else {
			oa.builder_append(&pb, i32(i * 3))
		}
	}
	pa1, err1 := oa.builder_finish(&pb)
	testing.expect_value(t, err1, mem.Allocator_Error.None)
	defer oa.array_free(&pa1)
	testing.expect_value(t, pa1.null_count, 4)
	testing.expect_value(t, oa.bitmap_popcount(pa1.buffers[0].data, pa1.length), 21)
	// Ensure zero-tail invariant in the padding beyond length=25 (byte 3 bit 1..7 and bytes 4..63).
	testing.expect_value(t, oa.bitmap_popcount(pa1.buffers[0].data, pa1.buffers[0].size * 8), 21)

	oa.builder_reset(&pb)
	for i in 0..<19 {
		oa.builder_append(&pb, i32(i + 10))
	}
	pa2, err2 := oa.builder_finish(&pb)
	testing.expect_value(t, err2, mem.Allocator_Error.None)
	defer oa.array_free(&pa2)
	testing.expect_value(t, pa2.null_count, 0)
	testing.expect(t, pa2.buffers[0].data == nil, "dense finish must omit validity bitmap")

	oa.builder_reset(&pb)
	for i in 0..<10 {
		oa.builder_append(&pb, i32(i))
	}
	oa.builder_append_null(&pb)
	pa3, err3 := oa.builder_finish(&pb)
	testing.expect_value(t, err3, mem.Allocator_Error.None)
	defer oa.array_free(&pa3)
	testing.expect_value(t, pa3.null_count, 1)
	testing.expect_value(t, oa.bitmap_popcount(pa3.buffers[0].data, pa3.length), 10)
	testing.expect(t, oa.array_is_null(&pa3, 10))

	// String_Builder with reserve_data + lazy bitmap
	sb := oa.string_builder_make(4)
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_reserve_data(&sb, 1024)
	testing.expect(t, sb.data_cap >= 1024, "string_builder_reserve_data must grow data_cap")
	oa.string_builder_append(&sb, "alpha")
	oa.string_builder_append_null(&sb)
	oa.string_builder_append(&sb, "gamma")
	sa1, s_err1 := oa.string_builder_finish(&sb)
	testing.expect_value(t, s_err1, mem.Allocator_Error.None)
	defer oa.array_free(&sa1)
	testing.expect_value(t, sa1.null_count, 1)
	testing.expect_value(t, oa.bitmap_popcount(sa1.buffers[0].data, sa1.buffers[0].size * 8), 2)
	testing.expect_value(t, oa.array_get_string(&sa1, 0), "alpha")
	testing.expect(t, oa.array_is_null(&sa1, 1))
	testing.expect_value(t, oa.array_get_string(&sa1, 2), "gamma")

	// Binary_Builder with reserve_data
	bb := oa.binary_builder_make(4)
	defer oa.binary_builder_destroy(&bb)
	oa.binary_builder_reserve_data(&bb, 512)
	testing.expect(t, bb.data_cap >= 512, "binary_builder_reserve_data must grow data_cap")
	oa.binary_builder_append(&bb, []u8{1, 2, 3})
	oa.binary_builder_append_null(&bb)
	ba1, b_err1 := oa.binary_builder_finish(&bb)
	testing.expect_value(t, b_err1, mem.Allocator_Error.None)
	defer oa.array_free(&ba1)
	testing.expect_value(t, ba1.null_count, 1)
	testing.expect_value(t, len(oa.array_get_binary(&ba1, 0)), 3)
	testing.expect(t, oa.array_is_null(&ba1, 1))
}

@(test)
test_compute_filter_parallel_varlen :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	n := oa.PARALLEL_MIN_LENGTH + 137
	sb := oa.string_builder_make(n)
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_reserve_data(&sb, n * 8)

	mb := oa.builder_make(bool, n)
	defer oa.builder_destroy(&mb)

	for i in 0..<n {
		if i % 13 == 0 {
			oa.string_builder_append_null(&sb)
		} else if i % 2 == 0 {
			oa.string_builder_append(&sb, "hello_world")
		} else {
			oa.string_builder_append(&sb, "odin")
		}
		oa.builder_append(&mb, (i % 3) == 0)
	}
	s_arr, s_err := oa.string_builder_finish(&sb)
	testing.expect_value(t, s_err, mem.Allocator_Error.None)
	defer oa.array_free(&s_arr)

	mask, m_err := oa.builder_finish(&mb)
	testing.expect_value(t, m_err, mem.Allocator_Error.None)
	defer oa.array_free(&mask)

	serial, ser_err := oa.compute_filter(&s_arr, &mask)
	testing.expect_value(t, ser_err, mem.Allocator_Error.None)
	defer oa.array_free(&serial)

	parallel, par_err := oa.compute_filter_parallel(&s_arr, &mask, num_threads = 4)
	testing.expect_value(t, par_err, mem.Allocator_Error.None)
	defer oa.array_free(&parallel)

	testing.expect_value(t, parallel.length, serial.length)
	testing.expect_value(t, parallel.null_count, serial.null_count)
	for i in 0..<serial.length {
		if oa.array_is_null(&serial, i) {
			testing.expect(t, oa.array_is_null(&parallel, i))
		} else {
			testing.expect(t, !oa.array_is_null(&parallel, i))
			testing.expect_value(t, oa.array_get_string(&parallel, i), oa.array_get_string(&serial, i))
		}
	}

	// Dense string array (null_count == 0) parallel filter
	sb_dense := oa.string_builder_make(n)
	defer oa.string_builder_destroy(&sb_dense)
	oa.string_builder_reserve_data(&sb_dense, n * 8)
	for i in 0..<n {
		oa.string_builder_append(&sb_dense, "even_item" if (i & 1) == 0 else "odd")
	}
	s_dense, d_err := oa.string_builder_finish(&sb_dense)
	testing.expect_value(t, d_err, mem.Allocator_Error.None)
	defer oa.array_free(&s_dense)

	d_ser, ds_err := oa.compute_filter(&s_dense, &mask)
	testing.expect_value(t, ds_err, mem.Allocator_Error.None)
	defer oa.array_free(&d_ser)

	d_par, dp_err := oa.compute_filter_parallel(&s_dense, &mask, num_threads = 4)
	testing.expect_value(t, dp_err, mem.Allocator_Error.None)
	defer oa.array_free(&d_par)

	testing.expect_value(t, d_par.length, d_ser.length)
	testing.expect_value(t, d_par.null_count, 0)
	for i in 0..<d_ser.length {
		testing.expect_value(t, oa.array_get_string(&d_par, i), oa.array_get_string(&d_ser, i))
	}
}

@(test)
test_compute_sum_simd_integers_and_null_mix :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	// i32 dense (non-multiple of 16 length = 103)
	b_i32 := oa.builder_make(i32, 103)
	defer oa.builder_destroy(&b_i32)
	expected_i32 := i64(0)
	for i in 0..<103 {
		v := i32(i - 50)
		oa.builder_append(&b_i32, v)
		expected_i32 += i64(v)
	}
	a_i32, a32_err := oa.builder_finish(&b_i32)
	testing.expect_value(t, a32_err, mem.Allocator_Error.None)
	defer oa.array_free(&a_i32)
	got_i32, cnt_i32 := oa.compute_sum(&a_i32)
	testing.expect_value(t, cnt_i32, 103)
	testing.expect_value(t, got_i32, f64(expected_i32))

	// u16 dense (length = 75)
	b_u16 := oa.builder_make(u16, 75)
	defer oa.builder_destroy(&b_u16)
	expected_u16 := u64(0)
	for i in 0..<75 {
		v := u16(i * 100 + 3)
		oa.builder_append(&b_u16, v)
		expected_u16 += u64(v)
	}
	a_u16, au16_err := oa.builder_finish(&b_u16)
	testing.expect_value(t, au16_err, mem.Allocator_Error.None)
	defer oa.array_free(&a_u16)
	got_u16, cnt_u16 := oa.compute_sum(&a_u16)
	testing.expect_value(t, cnt_u16, 75)
	testing.expect_value(t, got_u16, f64(expected_u16))

	// f64 mixed nulls (every 5th element null -> hits mixed-byte branchless loop)
	b_f64 := oa.builder_make(f64, 150)
	defer oa.builder_destroy(&b_f64)
	expected_f64 := 0.0
	expected_cnt := 0
	for i in 0..<150 {
		if i % 5 == 0 {
			oa.builder_append_null(&b_f64)
		} else {
			v := f64(i) * 0.25
			oa.builder_append(&b_f64, v)
			expected_f64 += v
			expected_cnt += 1
		}
	}
	a_f64, af64_err := oa.builder_finish(&b_f64)
	testing.expect_value(t, af64_err, mem.Allocator_Error.None)
	defer oa.array_free(&a_f64)
	got_f64, cnt_f64 := oa.compute_sum(&a_f64)
	testing.expect_value(t, cnt_f64, expected_cnt)
	testing.expect(t, math.abs(got_f64 - expected_f64) <= 1e-9, "f64 mixed-null sum mismatch")
}

@(test)
test_compute_take_parallel :: proc(t: ^testing.T) {
	n :: 200_000
	m :: 75_000

	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	for i in 0..<n {
		oa.builder_append(&b, i32(i * 3 - 7))
	}
	arr, arr_err := oa.builder_finish(&b)
	testing.expect_value(t, arr_err, mem.Allocator_Error.None)
	defer oa.array_free(&arr)

	ib := oa.builder_make(i64, m)
	defer oa.builder_destroy(&ib)
	for i in 0..<m {
		oa.builder_append(&ib, i64((u64(i) * 2654435761) % u64(n)))
	}
	idx, idx_err := oa.builder_finish(&ib)
	testing.expect_value(t, idx_err, mem.Allocator_Error.None)
	defer oa.array_free(&idx)

	seq, seq_err := oa.compute_take(&arr, &idx)
	testing.expect_value(t, seq_err, mem.Allocator_Error.None)
	defer oa.array_free(&seq)

	par, par_err := oa.compute_take_parallel(&arr, &idx, 4)
	testing.expect_value(t, par_err, mem.Allocator_Error.None)
	defer oa.array_free(&par)

	testing.expect_value(t, par.length, seq.length)
	seq_data := cast([^]i32)seq.buffers[1].data
	par_data := cast([^]i32)par.buffers[1].data
	for i in 0..<m {
		testing.expect_value(t, par_data[i], seq_data[i])
	}
}

@(test)
test_radix_sort_string_and_umbra_ties :: proc(t: ^testing.T) {
	samples := [?]string{
		"pref_aaab",
		"same_12_byte_z",
		"ab\x00",
		"pref_aaaa",
		"b",
		"same_12_byte_a",
		"ab",
		"pref\x00z",
		"same_12_byte",
		"pref_aaaa",
		"a",
		"pref\x00",
		"same_12_byte_a",
	}

	// Verify Umbra_Array sort stability and embedded-NUL/tie ordering.
	ub := oa.umbra_builder_make(len(samples))
	defer oa.umbra_builder_destroy(&ub)
	for s in samples {
		oa.umbra_append(&ub, s)
	}
	ua := oa.umbra_builder_finish(&ub)
	defer oa.umbra_free(&ua)

	uidx := oa.umbra_sort_indices(&ua)
	defer oa.array_free(&uidx)
	testing.expect_value(t, uidx.length, len(samples))

	u_data := cast([^]i64)uidx.buffers[1].data
	for k in 0..<len(samples) - 1 {
		i0 := int(u_data[k])
		i1 := int(u_data[k + 1])
		s0 := oa.umbra_get(&ua, i0)
		s1 := oa.umbra_get(&ua, i1)
		cmp := oa.umbra_compare(&ua, i0, i1)
		testing.expect(t, cmp <= 0, "umbra sort not ascending")
		testing.expect(t, s0 <= s1, "umbra sort string order mismatch")
		if s0 == s1 {
			testing.expect(t, i0 < i1, "umbra sort broke stability on equal tie")
		}
	}

	// Verify String_Type compute_sort_indices with nulls, ties, and long common prefixes.
	sb := oa.string_builder_make(len(samples) + 3)
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_append_null(&sb)
	for i in 0..<len(samples) {
		if i == 6 {
			oa.string_builder_append_null(&sb)
		}
		oa.string_builder_append(&sb, samples[i])
	}
	oa.string_builder_append_null(&sb)

	sa, s_err := oa.string_builder_finish(&sb)
	testing.expect_value(t, s_err, mem.Allocator_Error.None)
	defer oa.array_free(&sa)

	sidx, si_err := oa.compute_sort_indices(&sa)
	testing.expect_value(t, si_err, mem.Allocator_Error.None)
	defer oa.array_free(&sidx)
	testing.expect_value(t, sidx.length, sa.length)

	s_data := cast([^]i64)sidx.buffers[1].data
	non_null_count := len(samples)
	for k in 0..<non_null_count - 1 {
		i0 := int(s_data[k])
		i1 := int(s_data[k + 1])
		testing.expect(t, !oa.array_is_null(&sa, i0), "unexpected null in valid prefix")
		testing.expect(t, !oa.array_is_null(&sa, i1), "unexpected null in valid prefix")
		v0 := oa.array_get_string(&sa, i0)
		v1 := oa.array_get_string(&sa, i1)
		testing.expect(t, v0 <= v1, "string radix sort not ascending")
		if v0 == v1 {
			testing.expect(t, i0 < i1, "string radix sort broke stability")
		}
	}
	// Null rows must follow non-null rows in original index order (0, 7, 15).
	testing.expect_value(t, int(s_data[non_null_count + 0]), 0)
	testing.expect_value(t, int(s_data[non_null_count + 1]), 7)
	testing.expect_value(t, int(s_data[non_null_count + 2]), len(samples) + 2)
}

@(test)
test_compare_and_refine_f64_avx2 :: proc(t: ^testing.T) {
	n :: 103
	bf := oa.builder_make(f64, n)
	defer oa.builder_destroy(&bf)
	bi := oa.builder_make(i64, n)
	defer oa.builder_destroy(&bi)
	for i in 0..<n {
		oa.builder_append(&bf, f64(i))
		oa.builder_append(&bi, i64(i))
	}
	arr_f64, err_f := oa.builder_finish(&bf)
	testing.expect_value(t, err_f, mem.Allocator_Error.None)
	defer oa.array_free(&arr_f64)

	arr_i64, err_i := oa.builder_finish(&bi)
	testing.expect_value(t, err_i, mem.Allocator_Error.None)
	defer oa.array_free(&arr_i64)

	mask_f, mf_err := oa.compute_compare(&arr_f64, .Gt, 50.0)
	testing.expect_value(t, mf_err, mem.Allocator_Error.None)
	defer oa.array_free(&mask_f)
	for i in 0..<n {
		testing.expect_value(t, oa.bitmap_get(mask_f.buffers[1].data, i), i > 50)
	}

	mask_i, mi_err := oa.compute_compare_i64(&arr_i64, .Le, 25)
	testing.expect_value(t, mi_err, mem.Allocator_Error.None)
	defer oa.array_free(&mask_i)
	for i in 0..<n {
		testing.expect_value(t, oa.bitmap_get(mask_i.buffers[1].data, i), i <= 25)
	}

	s1 := oa.compute_select_compare(&arr_f64, .Gt, 20.0)
	defer oa.selection_free(&s1)
	s2 := oa.selection_refine_compare(&s1, &arr_f64, .Lt, 80.0)
	defer oa.selection_free(&s2)
	testing.expect_value(t, s2.length, 59)

	sum, vc := oa.compute_sum_selection(&arr_f64, &s2)
	testing.expect_value(t, vc, 59)
	testing.expect_value(t, sum, f64((21 + 79) * 59 / 2))
}

@(test)
test_select_compare_stack_chunk_and_refine_inplace :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	n :: 20_000 // > 16_384 to exercise the chunked [512]u8 path
	ba := oa.builder_make(f64, n)
	defer oa.builder_destroy(&ba)
	bb := oa.builder_make(f64, n)
	defer oa.builder_destroy(&bb)
	bi := oa.builder_make(i64, n)
	defer oa.builder_destroy(&bi)

	for i in 0..<n {
		if i % 37 == 0 {
			oa.builder_append_null(&ba)
		} else if i % 97 == 0 {
			oa.builder_append(&ba, math.nan_f64())
		} else {
			oa.builder_append(&ba, f64(i % 1000))
		}
		oa.builder_append(&bb, f64((i * 7 + 3) % 1000))
		if i % 53 == 0 {
			oa.builder_append_null(&bi)
		} else {
			oa.builder_append(&bi, i64(i % 1000))
		}
	}
	a, _ := oa.builder_finish(&ba)
	defer oa.array_free(&a)
	b, _ := oa.builder_finish(&bb)
	defer oa.array_free(&b)
	ai, _ := oa.builder_finish(&bi)
	defer oa.array_free(&ai)

	state: bs.Bench_Alloc_State
	cnt := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &state,
	}
	calloc := bs.counting_allocator(&cnt)

	// Stack-chunked compare selection should perform only 1 allocation (the Selection buffer itself)
	sel := oa.compute_select_compare(&a, .Gt, 250.0, calloc)
	testing.expect_value(t, state.alloc_count, u64(1))
	oa.selection_refine_compare_inplace(&sel, &b, .Le, 700.0)
	testing.expect_value(t, state.alloc_count, u64(1))

	// Reference brute-force verification on sliced view as well
	ref_sum := f64(0)
	ref_vc := 0
	ref_idx := make([dynamic]i32, context.allocator)
	defer delete(ref_idx)
	for i in 0..<n {
		if oa.array_is_null(&a, i) { continue }
		va := oa.array_get(&a, i, f64)
		vb := oa.array_get(&b, i, f64)
		if !math.is_nan(va) && va > 250.0 && vb <= 700.0 {
			append(&ref_idx, i32(i))
			ref_sum += va
			ref_vc += 1
		}
	}
	testing.expect_value(t, sel.length, len(ref_idx))
	for i in 0..<sel.length {
		testing.expect_value(t, sel.indices[i], ref_idx[i])
	}
	oa.selection_free(&sel)
	testing.expect_value(t, state.trial_live_bytes, i64(0))

	// i64 select + inplace refine
	state = {}
	sel_i := oa.compute_select_compare_i64(&ai, .Ge, 100, calloc)
	testing.expect_value(t, state.alloc_count, u64(1))
	oa.selection_refine_compare_i64_inplace(&sel_i, &ai, .Lt, 200)
	testing.expect_value(t, state.alloc_count, u64(1))
	for j in 0..<sel_i.length {
		idx := int(sel_i.indices[j])
		v := oa.array_get(&ai, idx, i64)
		testing.expect(t, !oa.array_is_null(&ai, idx) && v >= 100 && v < 200)
	}
	oa.selection_free(&sel_i)
	testing.expect_value(t, state.trial_live_bytes, i64(0))

	// Zero-alloc fused compute_sel_2pred_sum and parallel variant
	state = {}
	sa := oa.array_slice(a, 17, n - 5)
	sb := oa.array_slice(b, 17, n - 5)
	s_sum, s_vc := oa.compute_sel_2pred_sum(&sa, .Gt, 250.0, &sb, .Le, 700.0, calloc)
	testing.expect_value(t, state.alloc_count, u64(0))

	p_sum, p_vc := oa.compute_sel_2pred_sum_parallel(&sa, .Gt, 250.0, &sb, .Le, 700.0)

	exp_sum := f64(0)
	exp_vc := 0
	for i in 0..<sa.length {
		if oa.array_is_null(&sa, i) { continue }
		va := oa.array_get(&sa, i, f64)
		vb := oa.array_get(&sb, i, f64)
		if !math.is_nan(va) && va > 250.0 && vb <= 700.0 {
			exp_sum += va
			exp_vc += 1
		}
	}
	testing.expect_value(t, s_vc, exp_vc)
	testing.expect_value(t, p_vc, exp_vc)
	testing.expect(t, math.abs(s_sum - exp_sum) <= 1e-6, "compute_sel_2pred_sum sum mismatch")
	testing.expect(t, math.abs(p_sum - exp_sum) <= 1e-6, "compute_sel_2pred_sum_parallel sum mismatch")
}

@(test)
test_morsel_u16_kernels_and_sel2pred_fastpath :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	n :: 40_005 // > 2 * 16_384 with non-aligned tail
	ba := oa.builder_make(f64, n)
	defer oa.builder_destroy(&ba)
	bb := oa.builder_make(f64, n)
	defer oa.builder_destroy(&bb)
	bi := oa.builder_make(i32, n)
	defer oa.builder_destroy(&bi)

	for i in 0..<n {
		oa.builder_append(&ba, f64((i * 13 + 5) % 200) * 0.5)
		oa.builder_append(&bb, f64((i * 7 + 11) % 200) * 0.5)
		oa.builder_append(&bi, i32((i * 13 + 5) % 200))
	}
	a, _ := oa.builder_finish(&ba)
	defer oa.array_free(&a)
	b, _ := oa.builder_finish(&bb)
	defer oa.array_free(&b)
	ai, _ := oa.builder_finish(&bi)
	defer oa.array_free(&ai)

	// Direct u16 kernel verification across all Compare_Op variants, slice offsets, and tail < 8
	sa := oa.array_slice(a, 13, n - 7)
	sb := oa.array_slice(b, 13, n - 7)
	scratch: [oa.MORSEL_MAX_ROWS]u16
	ops := [6]oa.Compare_Op{.Gt, .Ge, .Lt, .Le, .Eq, .Ne}

	for op in ops {
		rlen :: 37 // not divisible by 4 or 8
		rstart :: 21
		k1 := oa.morsel_select_compare_f64_u16(&sa, op, 40.0, rstart, rlen, scratch[:])
		k2 := oa.morsel_refine_compare_f64_u16(&sb, .Le, 60.0, rstart, scratch[:], k1)
		got_sum := oa.morsel_sum_f64_u16(&sa, rstart, scratch[:], k2)

		ref_sum := 0.0
		ref_cnt := 0
		for i in 0..<rlen {
			va := oa.array_get(&sa, rstart + i, f64)
			vb := oa.array_get(&sb, rstart + i, f64)
			m := false
			switch op {
			case .Gt: m = va >  40.0
			case .Ge: m = va >= 40.0
			case .Lt: m = va <  40.0
			case .Le: m = va <= 40.0
			case .Eq: m = va == 40.0
			case .Ne: m = va != 40.0
			}
			if m && vb <= 60.0 {
				ref_sum += va
				ref_cnt += 1
			}
		}
		testing.expect_value(t, k2, ref_cnt)
		testing.expect(t, math.abs(got_sum - ref_sum) <= 1e-6, "u16 kernel sum mismatch")
	}

	// Zero-match predicate check
	k_zero := oa.morsel_select_compare_f64_u16(&sa, .Gt, 1e9, 5, 53, scratch[:])
	testing.expect_value(t, k_zero, 0)
	testing.expect_value(t, oa.morsel_sum_f64_u16(&sa, 5, scratch[:], 0), 0.0)

	// Null-free f64 fast path in compute_sel_2pred_sum & parallel (0 heap allocations)
	state: bs.Bench_Alloc_State
	cnt := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &state,
	}
	calloc := bs.counting_allocator(&cnt)

	s_sum, s_vc := oa.compute_sel_2pred_sum(&sa, .Gt, 35.0, &sb, .Le, 70.0, calloc)
	testing.expect_value(t, state.alloc_count, u64(0))
	testing.expect_value(t, state.bytes_allocated, u64(0))

	p_sum, p_vc := oa.compute_sel_2pred_sum_parallel(&sa, .Gt, 35.0, &sb, .Le, 70.0, 4)

	exp_sum := 0.0
	exp_vc := 0
	for i in 0..<sa.length {
		va := oa.array_get(&sa, i, f64)
		vb := oa.array_get(&sb, i, f64)
		if va > 35.0 && vb <= 70.0 {
			exp_sum += va
			exp_vc += 1
		}
	}
	testing.expect_value(t, s_vc, exp_vc)
	testing.expect_value(t, p_vc, exp_vc)
	testing.expect(t, math.abs(s_sum - exp_sum) <= 1e-6, "sel_2pred_sum fastpath mismatch")
	testing.expect(t, math.abs(p_sum - exp_sum) <= 1e-6, "sel_2pred_sum_parallel fastpath mismatch")

	// Non-f64 fallback path check
	sai := oa.array_slice(ai, 13, n - 7)
	i_sum, i_vc := oa.compute_sel_2pred_sum(&sai, .Gt, 70.0, &sb, .Le, 70.0, calloc)
	testing.expect_value(t, state.alloc_count, u64(0))
	exp_i_sum := 0.0
	exp_i_vc := 0
	for i in 0..<sai.length {
		vi := f64(oa.array_get(&sai, i, i32))
		vb := oa.array_get(&sb, i, f64)
		if vi > 70.0 && vb <= 70.0 {
			exp_i_sum += vi
			exp_i_vc += 1
		}
	}
	testing.expect_value(t, i_vc, exp_i_vc)
	testing.expect(t, math.abs(i_sum - exp_i_sum) <= 1e-6, "sel_2pred_sum fallback mismatch")
}

@(private="file")
_verify_radix_sort_stability :: proc(t: ^testing.T, arr: ^oa.Array, $T: typeid, loc := #caller_location) {
	idx, err := oa.compute_sort_indices(arr)
	testing.expect_value(t, err, mem.Allocator_Error.None, loc)
	defer oa.array_free(&idx)
	testing.expect_value(t, idx.length, arr.length, loc)

	out := cast([^]i64)idx.buffers[1].data
	seen := make([]bool, arr.length)
	defer delete(seen)
	for k in 0..<arr.length {
		row := int(out[k])
		testing.expect(t, row >= 0 && row < arr.length && !seen[row], "sort index permutation invalid", loc = loc)
		seen[row] = true
		if k > 0 {
			prev_row := int(out[k - 1])
			v_prev := oa.array_get(arr, prev_row, T)
			v_cur  := oa.array_get(arr, row, T)
			testing.expect(t, v_prev <= v_cur, "sort order invalid", loc = loc)
			if v_prev == v_cur {
				testing.expect(t, prev_row < row, "sort stability violated", loc = loc)
			}
		}
	}
}

@(test)
test_radix_sort_u32_edge_cases :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	// 0 active passes (constant column)
	{
		b := oa.builder_make(i32, 128)
		defer oa.builder_destroy(&b)
		for _ in 0..<128 { oa.builder_append(&b, i32(42)) }
		arr, a_err := oa.builder_finish(&b)
		testing.expect_value(t, a_err, mem.Allocator_Error.None)
		defer oa.array_free(&arr)
		_verify_radix_sort_stability(t, &arr, i32)
	}

	// 1 active pass (only byte 1 varies)
	{
		b := oa.builder_make(i32, 200)
		defer oa.builder_destroy(&b)
		for i in 0..<200 { oa.builder_append(&b, i32(((i * 5) % 9) * 256 + 7)) }
		arr, a_err := oa.builder_finish(&b)
		testing.expect_value(t, a_err, mem.Allocator_Error.None)
		defer oa.array_free(&arr)
		_verify_radix_sort_stability(t, &arr, i32)
	}

	// 2 active passes (bytes 0 & 2 vary)
	{
		b := oa.builder_make(i32, 300)
		defer oa.builder_destroy(&b)
		for i in 0..<300 {
			val := i32(((i * 11) % 13) * 65536 + ((i * 3) % 17))
			oa.builder_append(&b, val)
		}
		arr, a_err := oa.builder_finish(&b)
		testing.expect_value(t, a_err, mem.Allocator_Error.None)
		defer oa.array_free(&arr)
		_verify_radix_sort_stability(t, &arr, i32)
	}

	// All signed and unsigned integer widths with min/max boundaries & duplicates
	verify_width :: proc(t: ^testing.T, $T: typeid, vals: []T) {
		b := oa.builder_make(T, len(vals) * 3)
		defer oa.builder_destroy(&b)
		for rep in 0..<3 {
			for v, i in vals {
				oa.builder_append(&b, vals[(i + rep * 3) % len(vals)])
				_ = v
			}
		}
		arr, a_err := oa.builder_finish(&b)
		testing.expect_value(t, a_err, mem.Allocator_Error.None)
		defer oa.array_free(&arr)
		_verify_radix_sort_stability(t, &arr, T)
	}

	verify_width(t, i8,  []i8{min(i8), -1, 0, 1, max(i8), -42, 42, 0})
	verify_width(t, i16, []i16{min(i16), -257, -1, 0, 1, 257, max(i16), -1})
	verify_width(t, i32, []i32{min(i32), -100_000, -1, 0, 1, 100_000, max(i32), 0})
	verify_width(t, i64, []i64{min(i64), -1_000_000_000_000, -1, 0, 1, 1_000_000_000_000, max(i64), 1})
	verify_width(t, u8,  []u8{0, 1, 127, 128, 255, 1})
	verify_width(t, u16, []u16{0, 1, 255, 256, 32768, 65535, 256})
	verify_width(t, u32, []u32{0, 1, 0x01020304, 0x80000000, max(u32), 0x01020304})
	verify_width(t, u64, []u64{0, 1, 0x01020304_05060708, 0x8000_0000_0000_0000, max(u64), 1})
}

@(test)
test_compute_take_i32_indices_and_selection :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	n :: 150_000
	m :: 70_000

	// Dense i32 source + sliced Int32_Type indices (parallel and serial)
	ba := oa.builder_make(i32, n)
	defer oa.builder_destroy(&ba)
	for i in 0..<n { oa.builder_append(&ba, i32(i * 5 - 100)) }
	arr, _ := oa.builder_finish(&ba)
	defer oa.array_free(&arr)

	bi32 := oa.builder_make(i32, m + 10)
	defer oa.builder_destroy(&bi32)
	for i in 0..<(m + 10) { oa.builder_append(&bi32, i32((u64(i) * 2654435761) % u64(n))) }
	idx_raw, _ := oa.builder_finish(&bi32)
	defer oa.array_free(&idx_raw)
	idx_sl := oa.array_slice(idx_raw, 7, 7 + m)

	take_seq, err_seq := oa.compute_take(&arr, &idx_sl)
	testing.expect_value(t, err_seq, mem.Allocator_Error.None)
	defer oa.array_free(&take_seq)

	take_par, err_par := oa.compute_take_parallel(&arr, &idx_sl, 4)
	testing.expect_value(t, err_par, mem.Allocator_Error.None)
	defer oa.array_free(&take_par)

	testing.expect_value(t, take_seq.length, m)
	testing.expect_value(t, take_par.length, m)
	for i in 0..<m {
		exp := oa.array_get(&arr, int(oa.array_get(&idx_sl, i, i32)), i32)
		testing.expect_value(t, oa.array_get(&take_seq, i, i32), exp)
		testing.expect_value(t, oa.array_get(&take_par, i, i32), exp)
	}

	// Nullable f64 source + nullable Int32_Type indices
	bf := oa.builder_make(f64, 20)
	defer oa.builder_destroy(&bf)
	for i in 0..<20 {
		if i % 4 == 0 { oa.builder_append_null(&bf) } else { oa.builder_append(&bf, f64(i) * 1.5) }
	}
	farr, _ := oa.builder_finish(&bf)
	defer oa.array_free(&farr)

	bni := oa.builder_make(i32, 6)
	defer oa.builder_destroy(&bni)
	oa.builder_append(&bni, i32(1))
	oa.builder_append_null(&bni)
	oa.builder_append(&bni, i32(4))
	oa.builder_append(&bni, i32(7))
	ni, _ := oa.builder_finish(&bni)
	defer oa.array_free(&ni)

	nf_out, nf_err := oa.compute_take(&farr, &ni)
	testing.expect_value(t, nf_err, mem.Allocator_Error.None)
	defer oa.array_free(&nf_out)
	testing.expect_value(t, nf_out.length, 4)
	testing.expect_value(t, nf_out.null_count, 2)
	testing.expect_value(t, oa.array_get(&nf_out, 0, f64), 1.5)
	testing.expect(t, oa.array_is_null(&nf_out, 1))
	testing.expect(t, oa.array_is_null(&nf_out, 2))
	testing.expect_value(t, oa.array_get(&nf_out, 3, f64), 10.5)

	// String_Type + Bool_Type with Int32_Type indices
	sb := oa.string_builder_make(4)
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_append(&sb, "zero")
	oa.string_builder_append_null(&sb)
	oa.string_builder_append(&sb, "two")
	oa.string_builder_append(&sb, "three")
	sarr, _ := oa.string_builder_finish(&sb)
	defer oa.array_free(&sarr)

	bb := oa.builder_make(bool, 4)
	defer oa.builder_destroy(&bb)
	oa.builder_append(&bb, true)
	oa.builder_append_null(&bb)
	oa.builder_append(&bb, false)
	oa.builder_append(&bb, true)
	barr, _ := oa.builder_finish(&bb)
	defer oa.array_free(&barr)

	bi4 := oa.builder_make(i32, 4)
	defer oa.builder_destroy(&bi4)
	oa.builder_append(&bi4, i32(3))
	oa.builder_append(&bi4, i32(1))
	oa.builder_append_null(&bi4)
	oa.builder_append(&bi4, i32(0))
	i4, _ := oa.builder_finish(&bi4)
	defer oa.array_free(&i4)

	st_out, st_err := oa.compute_take(&sarr, &i4)
	testing.expect_value(t, st_err, mem.Allocator_Error.None)
	defer oa.array_free(&st_out)
	testing.expect_value(t, oa.array_get_string(&st_out, 0), "three")
	testing.expect(t, oa.array_is_null(&st_out, 1))
	testing.expect(t, oa.array_is_null(&st_out, 2))
	testing.expect_value(t, oa.array_get_string(&st_out, 3), "zero")

	bt_out, bt_err := oa.compute_take(&barr, &i4)
	testing.expect_value(t, bt_err, mem.Allocator_Error.None)
	defer oa.array_free(&bt_out)
	testing.expect_value(t, oa.array_get(&bt_out, 0, bool), true)
	testing.expect(t, oa.array_is_null(&bt_out, 1))
	testing.expect(t, oa.array_is_null(&bt_out, 2))
	testing.expect_value(t, oa.array_get(&bt_out, 3, bool), true)

	// compute_take_selection wrapper check
	sel := oa.compute_select_compare(&arr, .Lt, -75.0)
	defer oa.selection_free(&sel)
	sel_taken, sel_err := oa.compute_take_selection(&arr, &sel)
	testing.expect_value(t, sel_err, mem.Allocator_Error.None)
	defer oa.array_free(&sel_taken)
	testing.expect_value(t, sel_taken.length, 5)
	for i in 0..<5 {
		testing.expect_value(t, oa.array_get(&sel_taken, i, i32), i32(i * 5 - 100))
	}
}

@(private="file")
_verify_mixed_batches :: proc(
	t: ^testing.T,
	batches: []oa.Record_Batch,
	loc := #caller_location,
) {
	testing.expect_value(t, len(batches), 3, loc)
	if len(batches) != 3 { return }

	// Batch 0: 17 rows sliced from [5..22)
	b0 := &batches[0]
	testing.expect_value(t, b0.length, 17, loc)
	if b0.length == 17 {
		for r in 0..<17 {
			orig := 5 + r
			is_n := (orig % 4) == 0
			for ci in 0..<len(b0.columns) {
				col := &b0.columns[ci]
				if ci == 3 {
					testing.expect(t, oa.array_is_null(col, r), "Null_Type must be null", loc = loc)
					continue
				}
				if is_n {
					testing.expect(t, oa.array_is_null(col, r), "expected null in sliced batch", loc = loc)
					continue
				}
				testing.expect(t, !oa.array_is_null(col, r), "expected valid in sliced batch", loc = loc)
				switch ci {
				case 0: testing.expect_value(t, oa.array_get(col, r, i32), i32(orig * 11 - 50), loc)
				case 1: testing.expect_value(t, oa.array_get(col, r, f64), f64(orig) * 1.25, loc)
				case 2: testing.expect_value(t, oa.array_get(col, r, bool), (orig % 2) == 1, loc)
				case 4:
					exp := "str_long_value" if (orig % 3) == 0 else "s"
					testing.expect_value(t, oa.array_get_string(col, r), exp, loc)
				case 5:
					exp := "lstr_alpha" if (orig % 2) == 0 else "lstr_beta_gamma"
					testing.expect_value(t, oa.array_get_large_string(col, r), exp, loc)
				case 6:
					exp := []u8{0x01, 0x02, u8(orig)} if (orig % 2) == 0 else []u8{0xAA, 0xBB}
					testing.expect(t, bytes.equal(oa.array_get_binary(col, r), exp), "binary mismatch", loc = loc)
				case 7:
					exp := []u8{0x10, u8(orig), 0x20, 0x30} if (orig % 2) == 0 else []u8{0xFF}
					testing.expect(t, bytes.equal(oa.array_get_large_binary(col, r), exp), "large binary mismatch", loc = loc)
				}
			}
		}
	}

	// Batch 1: 0 rows (empty)
	testing.expect_value(t, batches[1].length, 0, loc)

	// Batch 2: 9 rows
	b2 := &batches[2]
	testing.expect_value(t, b2.length, 9, loc)
	if b2.length == 9 {
		for r in 0..<9 {
			is_n := (r % 3) == 1
			for ci in 0..<len(b2.columns) {
				col := &b2.columns[ci]
				if ci == 3 || is_n {
					testing.expect(t, oa.array_is_null(col, r), "expected null in batch 2", loc = loc)
					continue
				}
				testing.expect(t, !oa.array_is_null(col, r), "expected valid in batch 2", loc = loc)
				switch ci {
				case 0: testing.expect_value(t, oa.array_get(col, r, i32), i32(r + 1000), loc)
				case 1: testing.expect_value(t, oa.array_get(col, r, f64), f64(r) + 0.5, loc)
				case 2: testing.expect_value(t, oa.array_get(col, r, bool), (r % 2) == 0, loc)
				case 4: testing.expect_value(t, oa.array_get_string(col, r), "b2_s", loc)
				case 5: testing.expect_value(t, oa.array_get_large_string(col, r), "b2_ls", loc)
				case 6: testing.expect(t, bytes.equal(oa.array_get_binary(col, r), []u8{0x5A, u8(r)}), "b2 bin mismatch", loc = loc)
				case 7: testing.expect(t, bytes.equal(oa.array_get_large_binary(col, r), []u8{0x7E, u8(r)}), "b2 lbin mismatch", loc = loc)
				}
			}
		}
	}
}

@(test)
test_ipc_vectored_write_wide_multibatch_and_partial_iovec :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	defer check_no_leaks(t, &track)
	old_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = old_alloc

	// 1. Partial writev advancement across iovec boundaries (including zero-length iovec)
	{
		b0 := []u8{1, 2, 3}
		b1 := []u8{10, 11, 12, 13, 14, 15, 16, 17}
		b2 := []u8{99}
		b3 := []u8{20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38}
		b4 := []u8{41, 42, 43, 44, 45, 46, 47}

		expected := make([dynamic]u8, 0, 38)
		defer delete(expected)
		append(&expected, ..b0)
		append(&expected, ..b1)
		append(&expected, ..b2)
		append(&expected, ..b3)
		append(&expected, ..b4)

		iovs := [6]oa._IPC_IOVec{
			{iov_base = raw_data(b0), iov_len = oa._IPC_IOVec_Len(len(b0))},
			{iov_base = raw_data(b1), iov_len = oa._IPC_IOVec_Len(len(b1))},
			{iov_base = nil, iov_len = 0},
			{iov_base = raw_data(b2), iov_len = oa._IPC_IOVec_Len(len(b2))},
			{iov_base = raw_data(b3), iov_len = oa._IPC_IOVec_Len(len(b3))},
			{iov_base = raw_data(b4), iov_len = oa._IPC_IOVec_Len(len(b4))},
		}

		rem := iovs[:]
		rem = oa._ipc_advance_iovecs(rem, 0)
		testing.expect_value(t, len(rem), 6)

		steps := [?]int{1, 4, 6, 1, 10, 16}
		collected := make([dynamic]u8, 0, 38)
		defer delete(collected)

		for step in steps {
			need := step
			for k := 0; k < len(rem) && need > 0; k += 1 {
				seg_len := int(rem[k].iov_len)
				if seg_len == 0 { continue }
				take := min(need, seg_len)
				append(&collected, ..(cast([^]u8)rem[k].iov_base)[:take])
				need -= take
			}
			testing.expect_value(t, need, 0)
			rem = oa._ipc_advance_iovecs(rem, step)
		}
		testing.expect_value(t, len(rem), 0)
		testing.expect(t, bytes.equal(collected[:], expected[:]), "partial writev iovec advancement mismatch")
	}

	// 2. Wide-schema (> 1024 iovecs to exercise IOV_MAX batching) across 2 batches in File & Stream
	{
		wide_file   := ipc_test_temp_path("vw_wide", "arrow")
		wide_stream := ipc_test_temp_path("vw_wide", "arrows")
		defer {
			_ = os.remove(wide_file);   delete(wide_file)
			_ = os.remove(wide_stream); delete(wide_stream)
		}

		NUM_COLS :: 360
		fields := make([]oa.Field, NUM_COLS)
		defer delete(fields)
		for ci in 0..<NUM_COLS {
			if (ci & 1) == 0 {
				fields[ci] = oa.field_make("ci", oa.Int32_Type{}, nullable = true)
			} else {
				fields[ci] = oa.field_make("cs", oa.String_Type{}, nullable = true)
			}
		}
		sc, s_err := oa.schema_make(fields)
		testing.expect_value(t, s_err, mem.Allocator_Error.None)
		defer oa.schema_free(&sc)

		make_wide_batch :: proc(t: ^testing.T, sc: ^oa.Schema, base: i32) -> oa.Record_Batch {
			cols := make([]oa.Array, NUM_COLS)
			defer delete(cols)
			for ci in 0..<NUM_COLS {
				if (ci & 1) == 0 {
					b := oa.builder_make(i32, 3)
					defer oa.builder_destroy(&b)
					oa.builder_append(&b, base + i32(ci))
					oa.builder_append_null(&b)
					oa.builder_append(&b, base + i32(ci) + 7)
					c_err: mem.Allocator_Error
					cols[ci], c_err = oa.builder_finish(&b)
					testing.expect_value(t, c_err, mem.Allocator_Error.None)
				} else {
					sb := oa.string_builder_make(3)
					defer oa.string_builder_destroy(&sb)
					oa.string_builder_append(&sb, "wide_a")
					oa.string_builder_append_null(&sb)
					oa.string_builder_append(&sb, "wide_c")
					c_err: mem.Allocator_Error
					cols[ci], c_err = oa.string_builder_finish(&sb)
					testing.expect_value(t, c_err, mem.Allocator_Error.None)
				}
			}
			rb, ok := oa.record_batch_make(sc, cols)
			testing.expect(t, ok, "record_batch_make must succeed")
			return rb
		}

		wb0 := make_wide_batch(t, &sc, 100)
		defer oa.record_batch_free(&wb0)
		wb1 := make_wide_batch(t, &sc, 500)
		defer oa.record_batch_free(&wb1)

		wide_batches := [2]oa.Record_Batch{wb0, wb1}
		testing.expect(t, oa.ipc_write_file(wide_file, &sc, wide_batches[:]))
		testing.expect(t, oa.ipc_write_stream(wide_stream, &sc, wide_batches[:]))

		verify_wide :: proc(t: ^testing.T, bs: []oa.Record_Batch) {
			testing.expect_value(t, len(bs), 2)
			if len(bs) != 2 { return }
			for bi in 0..<2 {
				base := i32(100 if bi == 0 else 500)
				testing.expect_value(t, bs[bi].length, 3)
				testing.expect_value(t, len(bs[bi].columns), NUM_COLS)
				for ci in 0..<NUM_COLS {
					col := &bs[bi].columns[ci]
					testing.expect(t, !oa.array_is_null(col, 0))
					testing.expect(t, oa.array_is_null(col, 1))
					testing.expect(t, !oa.array_is_null(col, 2))
					if (ci & 1) == 0 {
						testing.expect_value(t, oa.array_get(col, 0, i32), base + i32(ci))
						testing.expect_value(t, oa.array_get(col, 2, i32), base + i32(ci) + 7)
					} else {
						testing.expect_value(t, oa.array_get_string(col, 0), "wide_a")
						testing.expect_value(t, oa.array_get_string(col, 2), "wide_c")
					}
				}
			}
		}

		r_sc1, r_b1, ok1 := oa.ipc_read_file(wide_file, use_mmap = true)
		testing.expect(t, ok1)
		if ok1 {
			verify_wide(t, r_b1)
			oa.schema_free(r_sc1); free(r_sc1)
			for &b in r_b1 { oa.record_batch_free(&b) }
			delete(r_b1)
		}

		r_sc2, r_b2, ok2 := oa.ipc_read_stream(wide_stream, use_mmap = false)
		testing.expect(t, ok2)
		if ok2 {
			verify_wide(t, r_b2)
			oa.schema_free(r_sc2); free(r_sc2)
			for &b in r_b2 { oa.record_batch_free(&b) }
			delete(r_b2)
		}
	}

	// 3. Mixed-type, empty-batch, nullable, sliced-array multi-batch + overwrite truncation
	{
		mixed_file   := ipc_test_temp_path("vw_mixed", "arrow")
		mixed_stream := ipc_test_temp_path("vw_mixed", "arrows")
		fresh_file   := ipc_test_temp_path("vw_fresh", "arrow")
		fresh_stream := ipc_test_temp_path("vw_fresh", "arrows")
		defer {
			_ = os.remove(mixed_file);   delete(mixed_file)
			_ = os.remove(mixed_stream); delete(mixed_stream)
			_ = os.remove(fresh_file);   delete(fresh_file)
			_ = os.remove(fresh_stream); delete(fresh_stream)
		}

		m_fields := []oa.Field{
			oa.field_make("c_i32",  oa.Int32_Type{},        nullable = true),
			oa.field_make("c_f64",  oa.Float64_Type{},      nullable = true),
			oa.field_make("c_bool", oa.Bool_Type{},         nullable = true),
			oa.field_make("c_null", oa.Null_Type{},         nullable = true),
			oa.field_make("c_str",  oa.String_Type{},       nullable = true),
			oa.field_make("c_lstr", oa.Large_String_Type{}, nullable = true),
			oa.field_make("c_bin",  oa.Binary_Type{},       nullable = true),
			oa.field_make("c_lbin", oa.Large_Binary_Type{}, nullable = true),
		}
		m_sc, ms_err := oa.schema_make(m_fields)
		testing.expect_value(t, ms_err, mem.Allocator_Error.None)
		defer oa.schema_free(&m_sc)

		// Parent arrays for sliced batch 0 (25 rows -> sliced [5:22])
		bi := oa.builder_make(i32, 25); defer oa.builder_destroy(&bi)
		bf := oa.builder_make(f64, 25); defer oa.builder_destroy(&bf)
		bb := oa.builder_make(bool, 25); defer oa.builder_destroy(&bb)
		bs_arr := oa.string_builder_make(25); defer oa.string_builder_destroy(&bs_arr)
		bls := oa.large_string_builder_make(25); defer oa.large_string_builder_destroy(&bls)
		bbin := oa.binary_builder_make(25); defer oa.binary_builder_destroy(&bbin)
		blbin := oa.large_binary_builder_make(25); defer oa.large_binary_builder_destroy(&blbin)

		for r in 0..<25 {
			if (r % 4) == 0 {
				oa.builder_append_null(&bi)
				oa.builder_append_null(&bf)
				oa.builder_append_null(&bb)
				oa.string_builder_append_null(&bs_arr)
				oa.large_string_builder_append_null(&bls)
				oa.binary_builder_append_null(&bbin)
				oa.large_binary_builder_append_null(&blbin)
			} else {
				oa.builder_append(&bi, i32(r * 11 - 50))
				oa.builder_append(&bf, f64(r) * 1.25)
				oa.builder_append(&bb, (r % 2) == 1)
				oa.string_builder_append(&bs_arr, "str_long_value" if (r % 3) == 0 else "s")
				oa.large_string_builder_append(&bls, "lstr_alpha" if (r % 2) == 0 else "lstr_beta_gamma")
				b_val := []u8{0x01, 0x02, u8(r)} if (r % 2) == 0 else []u8{0xAA, 0xBB}
				lb_val := []u8{0x10, u8(r), 0x20, 0x30} if (r % 2) == 0 else []u8{0xFF}
				oa.binary_builder_append(&bbin, b_val)
				oa.large_binary_builder_append(&blbin, lb_val)
			}
		}
		p_i32, pi_err   := oa.builder_finish(&bi);           defer oa.array_free(&p_i32)
		p_f64, pf_err   := oa.builder_finish(&bf);           defer oa.array_free(&p_f64)
		p_bool, pb_err  := oa.builder_finish(&bb);           defer oa.array_free(&p_bool)
		p_str, ps_err   := oa.string_builder_finish(&bs_arr); defer oa.array_free(&p_str)
		p_lstr, pls_err := oa.large_string_builder_finish(&bls); defer oa.array_free(&p_lstr)
		p_bin, pbn_err  := oa.binary_builder_finish(&bbin);  defer oa.array_free(&p_bin)
		p_lbin, plb_err := oa.large_binary_builder_finish(&blbin); defer oa.array_free(&p_lbin)
		testing.expect_value(t, pi_err, mem.Allocator_Error.None)
		testing.expect_value(t, pf_err, mem.Allocator_Error.None)
		testing.expect_value(t, pb_err, mem.Allocator_Error.None)
		testing.expect_value(t, ps_err, mem.Allocator_Error.None)
		testing.expect_value(t, pls_err, mem.Allocator_Error.None)
		testing.expect_value(t, pbn_err, mem.Allocator_Error.None)
		testing.expect_value(t, plb_err, mem.Allocator_Error.None)
		p_null := oa.Array{type = oa.Null_Type{}, length = 25, null_count = 25}

		sl_cols := [8]oa.Array{
			oa.array_slice(p_i32, 5, 22),
			oa.array_slice(p_f64, 5, 22),
			oa.array_slice(p_bool, 5, 22),
			oa.array_slice(p_null, 5, 22),
			oa.array_slice(p_str, 5, 22),
			oa.array_slice(p_lstr, 5, 22),
			oa.array_slice(p_bin, 5, 22),
			oa.array_slice(p_lbin, 5, 22),
		}
		rb0, ok_rb0 := oa.record_batch_make(&m_sc, sl_cols[:])
		testing.expect(t, ok_rb0)
		defer oa.record_batch_free(&rb0)

		// Batch 1: empty (0 rows)
		e_bi := oa.builder_make(i32, 0); defer oa.builder_destroy(&e_bi); e_i32, ei_err := oa.builder_finish(&e_bi)
		e_bf := oa.builder_make(f64, 0); defer oa.builder_destroy(&e_bf); e_f64, ef_err := oa.builder_finish(&e_bf)
		e_bb := oa.builder_make(bool, 0); defer oa.builder_destroy(&e_bb); e_bool, eb_err := oa.builder_finish(&e_bb)
		e_bs := oa.string_builder_make(0); defer oa.string_builder_destroy(&e_bs); e_str, es_err := oa.string_builder_finish(&e_bs)
		e_bls := oa.large_string_builder_make(0); defer oa.large_string_builder_destroy(&e_bls); e_lstr, els_err := oa.large_string_builder_finish(&e_bls)
		e_bbin := oa.binary_builder_make(0); defer oa.binary_builder_destroy(&e_bbin); e_bin, ebn_err := oa.binary_builder_finish(&e_bbin)
		e_blbin := oa.large_binary_builder_make(0); defer oa.large_binary_builder_destroy(&e_blbin); e_lbin, elb_err := oa.large_binary_builder_finish(&e_blbin)
		testing.expect_value(t, ei_err, mem.Allocator_Error.None)
		testing.expect_value(t, ef_err, mem.Allocator_Error.None)
		testing.expect_value(t, eb_err, mem.Allocator_Error.None)
		testing.expect_value(t, es_err, mem.Allocator_Error.None)
		testing.expect_value(t, els_err, mem.Allocator_Error.None)
		testing.expect_value(t, ebn_err, mem.Allocator_Error.None)
		testing.expect_value(t, elb_err, mem.Allocator_Error.None)
		e_null := oa.Array{type = oa.Null_Type{}, length = 0, null_count = 0}
		e_cols := [8]oa.Array{e_i32, e_f64, e_bool, e_null, e_str, e_lstr, e_bin, e_lbin}
		rb1, ok_rb1 := oa.record_batch_make(&m_sc, e_cols[:])
		testing.expect(t, ok_rb1)
		defer oa.record_batch_free(&rb1)

		// Batch 2: 9 rows
		b2i := oa.builder_make(i32, 9); defer oa.builder_destroy(&b2i)
		b2f := oa.builder_make(f64, 9); defer oa.builder_destroy(&b2f)
		b2b := oa.builder_make(bool, 9); defer oa.builder_destroy(&b2b)
		b2s := oa.string_builder_make(9); defer oa.string_builder_destroy(&b2s)
		b2ls := oa.large_string_builder_make(9); defer oa.large_string_builder_destroy(&b2ls)
		b2bin := oa.binary_builder_make(9); defer oa.binary_builder_destroy(&b2bin)
		b2lbin := oa.large_binary_builder_make(9); defer oa.large_binary_builder_destroy(&b2lbin)
		for r in 0..<9 {
			if (r % 3) == 1 {
				oa.builder_append_null(&b2i)
				oa.builder_append_null(&b2f)
				oa.builder_append_null(&b2b)
				oa.string_builder_append_null(&b2s)
				oa.large_string_builder_append_null(&b2ls)
				oa.binary_builder_append_null(&b2bin)
				oa.large_binary_builder_append_null(&b2lbin)
			} else {
				oa.builder_append(&b2i, i32(r + 1000))
				oa.builder_append(&b2f, f64(r) + 0.5)
				oa.builder_append(&b2b, (r % 2) == 0)
				oa.string_builder_append(&b2s, "b2_s")
				oa.large_string_builder_append(&b2ls, "b2_ls")
				oa.binary_builder_append(&b2bin, []u8{0x5A, u8(r)})
				oa.large_binary_builder_append(&b2lbin, []u8{0x7E, u8(r)})
			}
		}
		c2_i32, c2i_err   := oa.builder_finish(&b2i)
		c2_f64, c2f_err   := oa.builder_finish(&b2f)
		c2_bool, c2b_err  := oa.builder_finish(&b2b)
		c2_str, c2s_err   := oa.string_builder_finish(&b2s)
		c2_lstr, c2ls_err := oa.large_string_builder_finish(&b2ls)
		c2_bin, c2bn_err  := oa.binary_builder_finish(&b2bin)
		c2_lbin, c2lb_err := oa.large_binary_builder_finish(&b2lbin)
		testing.expect_value(t, c2i_err, mem.Allocator_Error.None)
		testing.expect_value(t, c2f_err, mem.Allocator_Error.None)
		testing.expect_value(t, c2b_err, mem.Allocator_Error.None)
		testing.expect_value(t, c2s_err, mem.Allocator_Error.None)
		testing.expect_value(t, c2ls_err, mem.Allocator_Error.None)
		testing.expect_value(t, c2bn_err, mem.Allocator_Error.None)
		testing.expect_value(t, c2lb_err, mem.Allocator_Error.None)
		c2_null := oa.Array{type = oa.Null_Type{}, length = 9, null_count = 9}
		b2_cols := [8]oa.Array{c2_i32, c2_f64, c2_bool, c2_null, c2_str, c2_lstr, c2_bin, c2_lbin}
		rb2, ok_rb2 := oa.record_batch_make(&m_sc, b2_cols[:])
		testing.expect(t, ok_rb2)
		defer oa.record_batch_free(&rb2)

		m_batches := [3]oa.Record_Batch{rb0, rb1, rb2}
		testing.expect(t, oa.ipc_write_file(mixed_file, &m_sc, m_batches[:]))
		testing.expect(t, oa.ipc_write_stream(mixed_stream, &m_sc, m_batches[:]))

		for mmap_flag in ([2]bool{true, false}) {
			sc_f, bs_f, ok_f := oa.ipc_read_file(mixed_file, use_mmap = mmap_flag)
			testing.expect(t, ok_f)
			if ok_f {
				_verify_mixed_batches(t, bs_f)
				oa.schema_free(sc_f); free(sc_f)
				for &b in bs_f { oa.record_batch_free(&b) }
				delete(bs_f)
			}

			sc_s, bs_s, ok_s := oa.ipc_read_stream(mixed_stream, use_mmap = mmap_flag)
			testing.expect(t, ok_s)
			if ok_s {
				_verify_mixed_batches(t, bs_s)
				oa.schema_free(sc_s); free(sc_s)
				for &b in bs_s { oa.record_batch_free(&b) }
				delete(bs_s)
			}
		}

		// Overwrite existing larger files in-place with a smaller single-batch file & stream
		t_fields := []oa.Field{oa.field_make("x", oa.Int32_Type{}, nullable = false)}
		t_sc, ts_err := oa.schema_make(t_fields)
		testing.expect_value(t, ts_err, mem.Allocator_Error.None)
		defer oa.schema_free(&t_sc)
		t_b := oa.builder_make(i32, 2); defer oa.builder_destroy(&t_b)
		oa.builder_append(&t_b, i32(42))
		oa.builder_append(&t_b, i32(99))
		t_col, tc_err := oa.builder_finish(&t_b)
		testing.expect_value(t, tc_err, mem.Allocator_Error.None)
		t_rb, trb_ok := oa.record_batch_make(&t_sc, []oa.Array{t_col})
		testing.expect(t, trb_ok)
		defer oa.record_batch_free(&t_rb)
		t_batches := [1]oa.Record_Batch{t_rb}

		testing.expect(t, oa.ipc_write_file(mixed_file, &t_sc, t_batches[:]))
		testing.expect(t, oa.ipc_write_file(fresh_file, &t_sc, t_batches[:]))
		testing.expect(t, oa.ipc_write_stream(mixed_stream, &t_sc, t_batches[:]))
		testing.expect(t, oa.ipc_write_stream(fresh_stream, &t_sc, t_batches[:]))

		ov_f, ov_f_err := os.read_entire_file(mixed_file, context.allocator); defer delete(ov_f)
		fr_f, fr_f_err := os.read_entire_file(fresh_file, context.allocator); defer delete(fr_f)
		testing.expect_value(t, ov_f_err, nil)
		testing.expect_value(t, fr_f_err, nil)
		testing.expect(t, bytes.equal(ov_f, fr_f), "overwritten IPC file must match fresh file byte-for-byte")

		ov_s, ov_s_err := os.read_entire_file(mixed_stream, context.allocator); defer delete(ov_s)
		fr_s, fr_s_err := os.read_entire_file(fresh_stream, context.allocator); defer delete(fr_s)
		testing.expect_value(t, ov_s_err, nil)
		testing.expect_value(t, fr_s_err, nil)
		testing.expect(t, bytes.equal(ov_s, fr_s), "overwritten IPC stream must match fresh stream byte-for-byte")
	}
}

@(test)
test_builder_cross_allocator_bitmap_growth_no_overread :: proc(t: ^testing.T) {
	main_track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&main_track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &main_track)
	}

	alt_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&alt_track, saved_alloc)
	defer check_no_leaks(t, &alt_track)
	alt_alloc := mem.tracking_allocator(&alt_track)

	// Primitive_Builder: 1 null allocates 64-byte bitmap (512 bits), then 1024 non-null appends exceed bm_cap.
	{
		b := oa.builder_make(i32, 8)
		defer oa.builder_destroy(&b)
		oa.builder_append_null(&b)
		for i in 1..=1024 {
			oa.builder_append(&b, i32(i))
		}
		arr, err := oa.builder_finish(&b, alt_alloc)
		testing.expect_value(t, err, mem.Allocator_Error.None)
		defer oa.array_free(&arr)

		testing.expect_value(t, arr.length, 1025)
		testing.expect_value(t, arr.null_count, 1)
		testing.expect(t, oa.array_is_null(&arr, 0), "row 0 must be null")
		for i in 1..<1025 {
			testing.expectf(t, oa.array_is_valid(&arr, i), "row %d must be valid after cross-allocator finish", i)
			testing.expect_value(t, oa.array_get(&arr, i, i32), i32(i))
		}
	}

	// String_Builder (_Var_Builder): 1 null followed by 1024 non-null strings exceeding bm_cap.
	{
		sb := oa.string_builder_make(8)
		defer oa.string_builder_destroy(&sb)
		oa.string_builder_append_null(&sb)
		for i in 1..=1024 {
			oa.string_builder_append(&sb, "v" if (i & 1) == 0 else "val")
		}
		arr, err := oa.string_builder_finish(&sb, alt_alloc)
		testing.expect_value(t, err, mem.Allocator_Error.None)
		defer oa.array_free(&arr)

		testing.expect_value(t, arr.length, 1025)
		testing.expect_value(t, arr.null_count, 1)
		testing.expect(t, oa.array_is_null(&arr, 0), "string row 0 must be null")
		for i in 1..<1025 {
			testing.expectf(t, oa.array_is_valid(&arr, i), "string row %d must be valid after cross-allocator finish", i)
			want := "v" if (i & 1) == 0 else "val"
			testing.expect_value(t, oa.array_get_string(&arr, i), want)
		}
	}
}

@(test)
test_buffer_resize_realloc_zeroes_shrunk_and_uninit_tail :: proc(t: ^testing.T) {
	// 1. Shrink then grow past original capacity must zero [new_shrunk_size ..< new_size].
	buf, err := oa.buffer_make(128)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	defer oa.buffer_free(&buf)
	for i in 0..<128 {
		buf.data[i] = 0xAA
	}
	testing.expect_value(t, oa.buffer_resize(&buf, 16), mem.Allocator_Error.None)
	testing.expect_value(t, oa.buffer_resize(&buf, 256), mem.Allocator_Error.None)
	for i in 0..<16 {
		testing.expect_value(t, buf.data[i], u8(0xAA))
	}
	for i in 16..<256 {
		testing.expectf(t, buf.data[i] == 0, "stale byte at %d was not zeroed after reallocating resize", i)
	}

	// 2. Grow uninit buffer past its initial 64-byte capacity must zero [orig_size ..< new_size].
	ubuf, uerr := oa.buffer_make_uninit(16)
	testing.expect_value(t, uerr, mem.Allocator_Error.None)
	defer oa.buffer_free(&ubuf)
	for i in 0..<ubuf.capacity {
		ubuf.data[i] = 0xBB
	}
	testing.expect_value(t, oa.buffer_resize(&ubuf, 128), mem.Allocator_Error.None)
	for i in 0..<16 {
		testing.expect_value(t, ubuf.data[i], u8(0xBB))
	}
	for i in 16..<128 {
		testing.expectf(t, ubuf.data[i] == 0, "uninit tail byte at %d was not zeroed after reallocating resize", i)
	}
}

@(test)
test_dict_min_max_on_sliced_dict_array :: proc(t: ^testing.T) {
	b := oa.builder_make(i64, 6)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i64(5))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i64(100))
	oa.builder_append(&b, i64(200))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i64(1))
	src, err := oa.builder_finish(&b)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	defer oa.array_free(&src)

	d := oa.dict_encode(&src, i64)
	defer oa.dict_free(&d)

	sub := oa.dict_slice(d, 2, 4) // [100, 200]
	lo, hi, ok := oa.dict_min_max(&sub)
	testing.expect(t, ok, "non-empty non-null slice must have min/max")
	testing.expect_value(t, lo, 100.0)
	testing.expect_value(t, hi, 200.0)

	empty_sub := oa.dict_slice(d, 2, 2)
	_, _, empty_ok := oa.dict_min_max(&empty_sub)
	testing.expect(t, !empty_ok, "empty dict slice must return ok=false")

	null_sub := oa.dict_slice(d, 1, 2)
	_, _, null_ok := oa.dict_min_max(&null_sub)
	testing.expect(t, !null_ok, "all-null dict slice must return ok=false")
}

@(test)
test_ipc_preserves_non_nullable_and_unsigned_types :: proc(t: ^testing.T) {
	fpath := ipc_test_temp_path("nonnull_uint", "arrow")
	spath := ipc_test_temp_path("nonnull_uint", "arrows")
	defer {
		_ = os.remove(fpath); delete(fpath)
		_ = os.remove(spath); delete(spath)
	}

	fields := []oa.Field{
		oa.field_make("u8",  oa.UInt8_Type{},  nullable = false),
		oa.field_make("u16", oa.UInt16_Type{}, nullable = false),
		oa.field_make("u32", oa.UInt32_Type{}, nullable = false),
		oa.field_make("u64", oa.UInt64_Type{}, nullable = false),
		oa.field_make("i32", oa.Int32_Type{},  nullable = true),
	}
	sc, sc_err := oa.schema_make(fields)
	testing.expect_value(t, sc_err, mem.Allocator_Error.None)
	defer oa.schema_free(&sc)

	c0 := build_array([]u8{1, 255})
	c1 := build_array([]u16{2, 65535})
	c2 := build_array([]u32{3, 4_000_000_000})
	c3 := build_array([]u64{4, max(u64)})
	c4 := build_array([]i32{-5, 42})
	rb, rb_ok := oa.record_batch_make(&sc, []oa.Array{c0, c1, c2, c3, c4})
	testing.expect(t, rb_ok)
	defer oa.record_batch_free(&rb)

	testing.expect(t, oa.ipc_write_file(fpath, &sc, []oa.Record_Batch{rb}))
	testing.expect(t, oa.ipc_write_stream(spath, &sc, []oa.Record_Batch{rb}))

	verify_schema :: proc(t: ^testing.T, out_sc: ^oa.Schema) {
		testing.expect_value(t, len(out_sc.fields), 5)
		if len(out_sc.fields) != 5 { return }
		testing.expect_value(t, out_sc.fields[0].nullable, false)
		testing.expect_value(t, out_sc.fields[1].nullable, false)
		testing.expect_value(t, out_sc.fields[2].nullable, false)
		testing.expect_value(t, out_sc.fields[3].nullable, false)
		testing.expect_value(t, out_sc.fields[4].nullable, true)
		testing.expect_value(t, oa.type_name(out_sc.fields[0].type), "uint8")
		testing.expect_value(t, oa.type_name(out_sc.fields[1].type), "uint16")
		testing.expect_value(t, oa.type_name(out_sc.fields[2].type), "uint32")
		testing.expect_value(t, oa.type_name(out_sc.fields[3].type), "uint64")
		testing.expect_value(t, oa.type_name(out_sc.fields[4].type), "int32")
	}

	sc_f, bs_f, ok_f := oa.ipc_read_file(fpath, use_mmap = false)
	testing.expect(t, ok_f)
	if ok_f {
		verify_schema(t, sc_f)
		oa.schema_free(sc_f); free(sc_f)
		for &b in bs_f { oa.record_batch_free(&b) }
		delete(bs_f)
	}

	sc_s, bs_s, ok_s := oa.ipc_read_stream(spath, use_mmap = false)
	testing.expect(t, ok_s)
	if ok_s {
		verify_schema(t, sc_s)
		oa.schema_free(sc_s); free(sc_s)
		for &b in bs_s { oa.record_batch_free(&b) }
		delete(bs_s)
	}
}

@(test)
test_selection_sum_len_and_order_independent_nan_minmax :: proc(t: ^testing.T) {
	nan := math.nan_f64()
	arr_first := build_array([]f64{nan, 3.0, -2.0, 5.0})
	defer oa.array_free(&arr_first)
	arr_last := build_array([]f64{3.0, -2.0, 5.0, nan})
	defer oa.array_free(&arr_last)
	arr_all_nan := build_array([]f64{nan, nan})
	defer oa.array_free(&arr_all_nan)

	// 1. compute_sum_selection must iterate sel.length, not len(sel.indices).
	vals := build_array([]f64{10.0, 20.0, 1000.0, 2000.0})
	defer oa.array_free(&vals)
	idx_buf := [4]i32{0, 1, 2, 3}
	short_sel := oa.Selection{indices = idx_buf[:], length = 2}
	s_val, s_vc := oa.compute_sum_selection(&vals, &short_sel)
	testing.expect_value(t, s_val, 30.0)
	testing.expect_value(t, s_vc, 2)

	// Nullable array with len(sel.indices) > sel.length.
	nb := oa.builder_make(f64, 4)
	defer oa.builder_destroy(&nb)
	oa.builder_append(&nb, 10.0)
	oa.builder_append_null(&nb)
	oa.builder_append(&nb, 1000.0)
	oa.builder_append(&nb, 2000.0)
	nvals, n_err := oa.builder_finish(&nb)
	testing.expect_value(t, n_err, mem.Allocator_Error.None)
	defer oa.array_free(&nvals)
	ns_val, ns_vc := oa.compute_sum_selection(&nvals, &short_sel)
	testing.expect_value(t, ns_val, 10.0)
	testing.expect_value(t, ns_vc, 1)

	// 2. compute_min_max_selection order-independent NaN handling.
	full_sel := oa.Selection{indices = idx_buf[:], length = 4}
	nan2_idx := [2]i32{0, 1}
	nan2_sel := oa.Selection{indices = nan2_idx[:], length = 2}

	lo1, hi1, vc1 := oa.compute_min_max_selection(&arr_first, &full_sel)
	lo2, hi2, vc2 := oa.compute_min_max_selection(&arr_last, &full_sel)
	testing.expect_value(t, vc1, 4)
	testing.expect_value(t, vc2, 4)
	testing.expect_value(t, lo1, -2.0)
	testing.expect_value(t, hi1, 5.0)
	testing.expect_value(t, lo2, -2.0)
	testing.expect_value(t, hi2, 5.0)

	alo, ahi, avc := oa.compute_min_max_selection(&arr_all_nan, &nan2_sel)
	testing.expect_value(t, avc, 2)
	testing.expect(t, math.is_nan(alo) && math.is_nan(ahi))

	// 3. compute_min_max_where order-independent NaN handling.
	mask4 := build_array([]bool{true, true, true, true})
	defer oa.array_free(&mask4)
	mask2 := build_array([]bool{true, true})
	defer oa.array_free(&mask2)

	wlo1, whi1, wvc1 := oa.compute_min_max_where(&arr_first, &mask4)
	wlo2, whi2, wvc2 := oa.compute_min_max_where(&arr_last, &mask4)
	testing.expect_value(t, wvc1, 4)
	testing.expect_value(t, wvc2, 4)
	testing.expect_value(t, wlo1, -2.0)
	testing.expect_value(t, whi1, 5.0)
	testing.expect_value(t, wlo2, -2.0)
	testing.expect_value(t, whi2, 5.0)

	walo, wahi, wavc := oa.compute_min_max_where(&arr_all_nan, &mask2)
	testing.expect_value(t, wavc, 2)
	testing.expect(t, math.is_nan(walo) && math.is_nan(wahi))

	// 4. compute_agg_where_compare order-independent NaN handling.
	pred4 := build_array([]f64{1.0, 2.0, 3.0, 4.0})
	defer oa.array_free(&pred4)
	pred2 := build_array([]f64{1.0, 2.0})
	defer oa.array_free(&pred2)

	agg1 := oa.compute_agg_where_compare(&arr_first, &pred4, .Gt, 0.0)
	agg2 := oa.compute_agg_where_compare(&arr_last, &pred4, .Gt, 0.0)
	testing.expect(t, agg1.valid && agg2.valid)
	testing.expect_value(t, agg1.count, 4)
	testing.expect_value(t, agg2.count, 4)
	testing.expect_value(t, agg1.min_val, -2.0)
	testing.expect_value(t, agg1.max_val, 5.0)
	testing.expect_value(t, agg2.min_val, -2.0)
	testing.expect_value(t, agg2.max_val, 5.0)

	agga := oa.compute_agg_where_compare(&arr_all_nan, &pred2, .Gt, 0.0)
	testing.expect(t, agga.valid)
	testing.expect_value(t, agga.count, 2)
	testing.expect(t, math.is_nan(agga.min_val) && math.is_nan(agga.max_val))

	// 5. Nullable branches of _agg_where_float_mono and _min_max_selection_typed with NaN + nulls.
	nb_nan := oa.builder_make(f64, 5)
	defer oa.builder_destroy(&nb_nan)
	oa.builder_append_null(&nb_nan)
	oa.builder_append(&nb_nan, nan)
	oa.builder_append(&nb_nan, 3.0)
	oa.builder_append(&nb_nan, -2.0)
	oa.builder_append(&nb_nan, 5.0)
	arr_null_nan, nn_err := oa.builder_finish(&nb_nan)
	testing.expect_value(t, nn_err, mem.Allocator_Error.None)
	defer oa.array_free(&arr_null_nan)

	pred5 := build_array([]f64{1.0, 2.0, 3.0, 4.0, 5.0})
	defer oa.array_free(&pred5)
	agg_null := oa.compute_agg_where_compare(&arr_null_nan, &pred5, .Gt, 0.0)
	testing.expect(t, agg_null.valid)
	testing.expect_value(t, agg_null.count, 4)
	testing.expect_value(t, agg_null.min_val, -2.0)
	testing.expect_value(t, agg_null.max_val, 5.0)

	idx5 := [5]i32{0, 1, 2, 3, 4}
	sel5 := oa.Selection{indices = idx5[:], length = 5}
	nlo, nhi, nvc := oa.compute_min_max_selection(&arr_null_nan, &sel5)
	testing.expect_value(t, nvc, 4)
	testing.expect_value(t, nlo, -2.0)
	testing.expect_value(t, nhi, 5.0)
}
