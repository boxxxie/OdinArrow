package skadi_tests

import "core:mem"
import "core:testing"
import bs "../benchmarks/odin/stats"
import oa "../skadi"

// ── String: basic roundtrip ───────────────────────────────────────────────────

@(test)
test_string_roundtrip_no_nulls :: proc(t: ^testing.T) {
	words := []string{"hello", "world", "odin", "arrow"}
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	for w in words {
		oa.string_builder_append(&b, w)
	}
	arr, err := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)

	testing.expect(t, err == nil)
	_, is_str := arr.type.(oa.String_Type)
	testing.expect(t, is_str, "type must be String_Type")
	testing.expect_value(t, arr.length, 4)
	testing.expect_value(t, arr.null_count, 0)
	testing.expect(t, arr.buffers[0].data == nil, "no validity bitmap when no nulls")

	for w, i in words {
		testing.expect_value(t, oa.array_get_string(&arr, i), w)
	}
}

// ── String: nulls ─────────────────────────────────────────────────────────────

@(test)
test_string_with_nulls :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	oa.string_builder_append(&b, "first")
	oa.string_builder_append_null(&b)
	oa.string_builder_append(&b, "third")
	oa.string_builder_append_null(&b)

	arr, err := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)
	testing.expect(t, err == nil)

	testing.expect_value(t, arr.length, 4)
	testing.expect_value(t, arr.null_count, 2)
	testing.expect(t, arr.buffers[0].data != nil, "validity bitmap must exist")

	testing.expect(t, oa.array_is_valid(&arr, 0))
	testing.expect(t, oa.array_is_null(&arr, 1))
	testing.expect(t, oa.array_is_valid(&arr, 2))
	testing.expect(t, oa.array_is_null(&arr, 3))

	testing.expect_value(t, oa.array_get_string(&arr, 0), "first")
	testing.expect_value(t, oa.array_get_string(&arr, 2), "third")
}

// ── String: empty string element ─────────────────────────────────────────────

@(test)
test_string_empty_element :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	oa.string_builder_append(&b, "")
	oa.string_builder_append(&b, "x")
	oa.string_builder_append(&b, "")

	arr, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)

	testing.expect_value(t, oa.array_get_string(&arr, 0), "")
	testing.expect_value(t, oa.array_get_string(&arr, 1), "x")
	testing.expect_value(t, oa.array_get_string(&arr, 2), "")
}

// ── String: zero-copy view into buffer ───────────────────────────────────────

@(test)
test_string_is_zero_copy :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	oa.string_builder_append(&b, "hello")

	arr, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)

	s := oa.array_get_string(&arr, 0)
	// The string data pointer must lie inside buffers[2]
	s_start := uintptr(raw_data(transmute([]u8)s))
	buf_start := uintptr(arr.buffers[2].data)
	buf_end   := buf_start + uintptr(arr.buffers[2].size)
	testing.expect(t, s_start >= buf_start && s_start < buf_end, "string must point into data buffer")
}

// ── String: slice (zero-copy) ─────────────────────────────────────────────────

@(test)
test_string_slice :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	strs := []string{"a", "bb", "ccc", "dddd", "eeeee"}
	for s in strs {
		oa.string_builder_append(&b, s)
	}
	arr, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)

	sl := oa.array_slice(arr, 1, 4) // ["bb", "ccc", "dddd"]
	testing.expect_value(t, sl.length, 3)
	testing.expect_value(t, oa.array_get_string(&sl, 0), "bb")
	testing.expect_value(t, oa.array_get_string(&sl, 1), "ccc")
	testing.expect_value(t, oa.array_get_string(&sl, 2), "dddd")
}

// ── String: reset and reuse ───────────────────────────────────────────────────

@(test)
test_string_builder_reset :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)

	oa.string_builder_append(&b, "round1")
	arr1, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr1)

	oa.string_builder_reset(&b)
	oa.string_builder_append(&b, "round2")
	arr2, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr2)

	testing.expect_value(t, oa.array_get_string(&arr2, 0), "round2")
}

// ── String: no memory leaks ───────────────────────────────────────────────────

@(test)
test_string_no_leak :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	defer check_no_leaks(t, &track)
	context.allocator = mem.tracking_allocator(&track)

	b := oa.string_builder_make()
	oa.string_builder_append(&b, "hello")
	oa.string_builder_append_null(&b)
	oa.string_builder_append(&b, "world")
	arr, _ := oa.string_builder_finish(&b)
	oa.string_builder_destroy(&b)
	oa.array_free(&arr)
}

// ── Binary ────────────────────────────────────────────────────────────────────

@(test)
test_binary_roundtrip :: proc(t: ^testing.T) {
	b := oa.binary_builder_make()
	defer oa.binary_builder_destroy(&b)
	oa.binary_builder_append(&b, []u8{0xDE, 0xAD})
	oa.binary_builder_append_null(&b)
	oa.binary_builder_append(&b, []u8{0xBE, 0xEF, 0xFF})

	arr, err := oa.binary_builder_finish(&b)
	defer oa.array_free(&arr)
	testing.expect(t, err == nil)

	_, is_bin := arr.type.(oa.Binary_Type)
	testing.expect(t, is_bin, "type must be Binary_Type")
	testing.expect_value(t, arr.length, 3)
	testing.expect_value(t, arr.null_count, 1)

	got0 := oa.array_get_binary(&arr, 0)
	testing.expect_value(t, len(got0), 2)
	testing.expect_value(t, got0[0], u8(0xDE))
	testing.expect_value(t, got0[1], u8(0xAD))

	testing.expect(t, oa.array_is_null(&arr, 1))

	got2 := oa.array_get_binary(&arr, 2)
	testing.expect_value(t, len(got2), 3)
	testing.expect_value(t, got2[2], u8(0xFF))
}

// ── Large string array (1M entries) ──────────────────────────────────────────

@(test)
test_string_large :: proc(t: ^testing.T) {
	n :: 1_000_000
	b := oa.string_builder_make(n)
	defer oa.string_builder_destroy(&b)
	for i in 0..<n {
		if i % 50 == 0 {
			oa.string_builder_append_null(&b)
		} else {
			oa.string_builder_append(&b, "hello")
		}
	}
	arr, err := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)
	testing.expect(t, err == nil)
	testing.expect_value(t, arr.length, n)
	testing.expect_value(t, arr.null_count, n / 50)
	testing.expect(t, oa.array_is_null(&arr, 0))
	testing.expect_value(t, oa.array_get_string(&arr, 1), "hello")
}

// ── LargeString (i64 offsets) ──────────────────────────────────────────────────

@(test)
test_large_string_roundtrip :: proc(t: ^testing.T) {
	words := []string{"hello", "world", "odin", "arrow", "λambda"}
	b := oa.large_string_builder_make()
	defer oa.large_string_builder_destroy(&b)
	for w in words { oa.large_string_builder_append(&b, w) }

	arr, err := oa.large_string_builder_finish(&b)
	defer oa.array_free(&arr)

	testing.expect(t, err == nil)
	_, is_large := arr.type.(oa.Large_String_Type)
	testing.expect(t, is_large, "type should be Large_String_Type")
	testing.expect_value(t, arr.length, len(words))
	testing.expect_value(t, arr.null_count, 0)
	for w, i in words {
		testing.expect_value(t, oa.array_get_large_string(&arr, i), w)
	}

	// Offsets buffer must hold i64 values: byte length = (n+1)*8.
	testing.expect_value(t, arr.buffers[1].size, (len(words) + 1) * size_of(i64))
}

@(test)
test_large_string_nulls_and_empty :: proc(t: ^testing.T) {
	b := oa.large_string_builder_make()
	defer oa.large_string_builder_destroy(&b)
	oa.large_string_builder_append(&b, "a")
	oa.large_string_builder_append_null(&b)
	oa.large_string_builder_append(&b, "")
	oa.large_string_builder_append(&b, "ccc")

	arr, _ := oa.large_string_builder_finish(&b)
	defer oa.array_free(&arr)

	testing.expect_value(t, arr.length, 4)
	testing.expect_value(t, arr.null_count, 1)
	testing.expect_value(t, oa.array_get_large_string(&arr, 0), "a")
	testing.expect(t, oa.array_is_null(&arr, 1))
	testing.expect_value(t, oa.array_get_large_string(&arr, 2), "")
	testing.expect_value(t, oa.array_get_large_string(&arr, 3), "ccc")
}

@(test)
test_large_string_slice :: proc(t: ^testing.T) {
	b := oa.large_string_builder_make()
	defer oa.large_string_builder_destroy(&b)
	words := []string{"zero", "one", "two", "three"}
	for w in words { oa.large_string_builder_append(&b, w) }
	arr, _ := oa.large_string_builder_finish(&b)
	defer oa.array_free(&arr)

	// Zero-copy slice [1:3] → "one", "two".
	s := oa.array_slice(arr, 1, 3)
	testing.expect_value(t, s.length, 2)
	testing.expect_value(t, oa.array_get_large_string(&s, 0), "one")
	testing.expect_value(t, oa.array_get_large_string(&s, 1), "two")
}

@(test)
test_large_binary_roundtrip :: proc(t: ^testing.T) {
	b := oa.large_binary_builder_make()
	defer oa.large_binary_builder_destroy(&b)
	oa.large_binary_builder_append(&b, []u8{0x00, 0xFF, 0x10})
	oa.large_binary_builder_append_null(&b)
	oa.large_binary_builder_append(&b, []u8{0x42})

	arr, _ := oa.large_binary_builder_finish(&b)
	defer oa.array_free(&arr)

	_, is_large := arr.type.(oa.Large_Binary_Type)
	testing.expect(t, is_large, "type should be Large_Binary_Type")
	testing.expect_value(t, arr.length, 3)
	testing.expect_value(t, arr.null_count, 1)
	testing.expect(t, mem.compare(oa.array_get_large_binary(&arr, 0), []u8{0x00, 0xFF, 0x10}) == 0)
	testing.expect(t, oa.array_is_null(&arr, 1))
	testing.expect(t, mem.compare(oa.array_get_large_binary(&arr, 2), []u8{0x42}) == 0)
}

@(test)
test_varlen_builders_reset_reuse_with_nulls :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}
	context.allocator = mem.tracking_allocator(&track)

	// Binary_Builder reset before finish, reuse with nulls, then reset after finish.
	{
		bb := oa.binary_builder_make(4)
		defer oa.binary_builder_destroy(&bb)
		oa.binary_builder_append(&bb, []u8{1, 2, 3})
		oa.binary_builder_append_null(&bb)
		oa.binary_builder_reset(&bb)
		testing.expect_value(t, bb.length, 0)
		testing.expect_value(t, bb.null_count, 0)

		oa.binary_builder_append(&bb, []u8{0xAA})
		oa.binary_builder_append_null(&bb)
		oa.binary_builder_append(&bb, []u8{0xBB, 0xCC})
		arr, err := oa.binary_builder_finish(&bb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&arr)
		testing.expect_value(t, arr.length, 3)
		testing.expect_value(t, arr.null_count, 1)
		testing.expect(t, oa.array_is_valid(&arr, 0))
		testing.expect(t, mem.compare(oa.array_get_binary(&arr, 0), []u8{0xAA}) == 0)
		testing.expect(t, oa.array_is_null(&arr, 1))
		testing.expect(t, oa.array_is_valid(&arr, 2))
		testing.expect(t, mem.compare(oa.array_get_binary(&arr, 2), []u8{0xBB, 0xCC}) == 0)

		oa.binary_builder_reset(&bb)
		oa.binary_builder_append(&bb, []u8{0xDD})
		arr2, err2 := oa.binary_builder_finish(&bb)
		testing.expect_value(t, err2, nil)
		defer oa.array_free(&arr2)
		testing.expect_value(t, arr2.length, 1)
		testing.expect_value(t, oa.array_null_count(&arr2), 0)
		testing.expect(t, mem.compare(oa.array_get_binary(&arr2, 0), []u8{0xDD}) == 0)
	}

	// Large_String_Builder reset before finish, reuse with nulls, then reset after finish.
	{
		lsb := oa.large_string_builder_make(4)
		defer oa.large_string_builder_destroy(&lsb)
		oa.large_string_builder_append(&lsb, "discard_me")
		oa.large_string_builder_append_null(&lsb)
		oa.large_string_builder_reset(&lsb)
		testing.expect_value(t, lsb.length, 0)
		testing.expect_value(t, lsb.null_count, 0)

		oa.large_string_builder_append_null(&lsb)
		oa.large_string_builder_append(&lsb, "kept1")
		oa.large_string_builder_append(&lsb, "")
		oa.large_string_builder_append(&lsb, "kept2")
		arr, err := oa.large_string_builder_finish(&lsb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&arr)
		testing.expect_value(t, arr.length, 4)
		testing.expect_value(t, oa.array_null_count(&arr), 1)
		testing.expect(t, oa.array_is_null(&arr, 0))
		testing.expect_value(t, oa.array_get_large_string(&arr, 1), "kept1")
		testing.expect_value(t, oa.array_get_large_string(&arr, 2), "")
		testing.expect_value(t, oa.array_get_large_string(&arr, 3), "kept2")

		oa.large_string_builder_reset(&lsb)
		oa.large_string_builder_append(&lsb, "after")
		arr2, err2 := oa.large_string_builder_finish(&lsb)
		testing.expect_value(t, err2, nil)
		defer oa.array_free(&arr2)
		testing.expect_value(t, arr2.length, 1)
		testing.expect_value(t, oa.array_get_large_string(&arr2, 0), "after")
	}

	// Large_Binary_Builder reset before finish, reuse with nulls, then reset after finish.
	{
		lbb := oa.large_binary_builder_make(4)
		defer oa.large_binary_builder_destroy(&lbb)
		oa.large_binary_builder_append(&lbb, []u8{9, 9})
		oa.large_binary_builder_append_null(&lbb)
		oa.large_binary_builder_reset(&lbb)
		testing.expect_value(t, lbb.length, 0)
		testing.expect_value(t, lbb.null_count, 0)

		oa.large_binary_builder_append(&lbb, []u8{0x11, 0x22})
		oa.large_binary_builder_append_null(&lbb)
		oa.large_binary_builder_append(&lbb, []u8{})
		arr, err := oa.large_binary_builder_finish(&lbb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&arr)
		testing.expect_value(t, arr.length, 3)
		testing.expect_value(t, oa.array_null_count(&arr), 1)
		testing.expect(t, mem.compare(oa.array_get_large_binary(&arr, 0), []u8{0x11, 0x22}) == 0)
		testing.expect(t, oa.array_is_null(&arr, 1))
		testing.expect_value(t, len(oa.array_get_large_binary(&arr, 2)), 0)

		oa.large_binary_builder_reset(&lbb)
		oa.large_binary_builder_append(&lbb, []u8{0x77})
		arr2, err2 := oa.large_binary_builder_finish(&lbb)
		testing.expect_value(t, err2, nil)
		defer oa.array_free(&arr2)
		testing.expect_value(t, arr2.length, 1)
		testing.expect(t, mem.compare(oa.array_get_large_binary(&arr2, 0), []u8{0x77}) == 0)
	}
}

@(test)
test_string_builder_initial_data_cap_exact_allocs :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	state: bs.Bench_Alloc_State
	cnt := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &state,
	}
	alloc := bs.counting_allocator(&cnt)

	n :: 2000
	samples := [4]string{"alpha_0001", "bravo_0002", "charlie_03", "delta_0004"}
	b := oa.string_builder_make(n, alloc, n * 12)
	for i in 0..<n {
		if i % 50 == 0 {
			oa.string_builder_append_null(&b)
		} else {
			oa.string_builder_append(&b, samples[i & 3])
		}
	}
	arr, err := oa.string_builder_finish(&b, alloc)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	testing.expect_value(t, state.alloc_count, u64(3))
	testing.expect_value(t, state.resize_count, u64(0))
	testing.expect(t, state.trial_live_bytes > 0)

	for i in 0..<n {
		if i % 50 == 0 {
			testing.expect(t, oa.array_is_null(&arr, i))
		} else {
			testing.expect_value(t, oa.array_get_string(&arr, i), samples[i & 3])
		}
	}

	oa.array_free(&arr, alloc)
	oa.string_builder_destroy(&b)
	testing.expect_value(t, state.trial_live_bytes, i64(0))

	// Zero-data capacity case: all nulls should still roundtrip and free to 0 live bytes.
	state = {}
	b_zero := oa.string_builder_make(16, alloc, 0)
	for _ in 0..<16 {
		oa.string_builder_append_null(&b_zero)
	}
	arr_zero, err_zero := oa.string_builder_finish(&b_zero, alloc)
	testing.expect_value(t, err_zero, mem.Allocator_Error.None)
	testing.expect_value(t, state.alloc_count, u64(3))
	oa.array_free(&arr_zero, alloc)
	oa.string_builder_destroy(&b_zero)
	testing.expect_value(t, state.trial_live_bytes, i64(0))
}

@(test)
test_string_array_view_and_sum_lengths :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	// Dense (no nulls)
	b_dense := oa.string_builder_make(130, context.allocator, 130 * 10)
	defer oa.string_builder_destroy(&b_dense)
	ref_dense := i64(0)
	for i in 0..<130 {
		s := "abcd" if (i & 1) == 0 else "efghij"
		oa.string_builder_append(&b_dense, s)
		ref_dense += i64(len(s))
	}
	arr_dense, _ := oa.string_builder_finish(&b_dense)
	defer oa.array_free(&arr_dense)

	sv_dense := oa.array_string_view(&arr_dense)
	testing.expect_value(t, oa.string_view_sum_lengths(&sv_dense), ref_dense)
	testing.expect_value(t, oa.string_view_get(&sv_dense, 0), "abcd")
	testing.expect_value(t, oa.string_view_len(&sv_dense, 1), 6)

	// Nullable with non-zero slice offset spanning u64 validity boundaries
	b_null := oa.string_builder_make(200, context.allocator, 200 * 10)
	defer oa.string_builder_destroy(&b_null)
	for i in 0..<200 {
		if i % 7 == 0 {
			oa.string_builder_append_null(&b_null)
		} else {
			oa.string_builder_append(&b_null, "hello_1" if (i % 3 == 0) else "xy")
		}
	}
	arr_null, _ := oa.string_builder_finish(&b_null)
	defer oa.array_free(&arr_null)

	sliced := oa.array_slice(arr_null, 7, 190)
	ref_sliced := i64(0)
	for i in 0..<sliced.length {
		if !oa.array_is_null(&sliced, i) {
			ref_sliced += i64(len(oa.array_get_string(&sliced, i)))
		}
	}
	sv_sliced := oa.array_string_view(&sliced)
	testing.expect_value(t, oa.string_view_sum_lengths(&sv_sliced), ref_sliced)
	testing.expect_value(t, oa.string_view_is_null(&sv_sliced, 0), oa.array_is_null(&sliced, 0))

	// Empty array and all-null array
	b_empty := oa.string_builder_make(0, context.allocator, 0)
	defer oa.string_builder_destroy(&b_empty)
	arr_empty, _ := oa.string_builder_finish(&b_empty)
	defer oa.array_free(&arr_empty)
	sv_empty := oa.array_string_view(&arr_empty)
	testing.expect_value(t, oa.string_view_sum_lengths(&sv_empty), i64(0))
}
