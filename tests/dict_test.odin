package skadi_tests

import "core:math"
import "core:mem"
import "core:testing"
import oa "../skadi"

mk_str_arr :: proc(vals: []string) -> oa.Array {
	b := oa.string_builder_make(len(vals))
	defer oa.string_builder_destroy(&b)
	for v in vals { oa.string_builder_append(&b, v) }
	arr, err := oa.string_builder_finish(&b)
	assert(err == nil)
	return arr
}

@(test)
test_dict_encode_decode :: proc(t: ^testing.T) {
	vals := []string{"red", "green", "red", "blue", "green", "red"}
	src := mk_str_arr(vals)
	defer oa.array_free(&src)

	d := oa.str_dict_encode(&src)
	defer oa.str_dict_free(&d)

	testing.expect_value(t, d.length, len(vals))
	testing.expect_value(t, oa.n_dict(&d), 3)   // red, green, blue

	for v, i in vals {
		testing.expect_value(t, oa.str_dict_get(&d, i), v)
	}

	dec, dec_err := oa.str_dict_decode(&d)
	testing.expect_value(t, dec_err, nil)
	defer oa.array_free(&dec)
	testing.expect_value(t, dec.length, len(vals))
	for v, i in vals {
		testing.expect_value(t, oa.array_get_string(&dec, i), v)
	}
}

@(test)
test_dict_numeric :: proc(t: ^testing.T) {
	// logical: 5,2,5,9,2,5,9  → dict {5,2,9}, codes by first-seen
	vb := oa.builder_make(f64, 7)
	defer oa.builder_destroy(&vb)
	vals := []f64{5, 2, 5, 9, 2, 5, 9}
	for v in vals { oa.builder_append(&vb, v) }
	src, err := oa.builder_finish(&vb)
	testing.expect_value(t, err, nil)
	defer oa.array_free(&src)

	d := oa.dict_encode(&src, f64)
	defer oa.dict_free(&d)
	testing.expect_value(t, d.length, 7)
	testing.expect_value(t, oa.dict_size(&d), 3)

	for v, i in vals { testing.expect(t, approx_eq(oa.dict_get(&d, i), v, 1e-9)) }

	// sum / min_max via the encoded kernels
	testing.expect(t, approx_eq(oa.dict_sum(&d), 5+2+5+9+2+5+9, 1e-9))
	lo, hi, ok := oa.dict_min_max(&d)
	testing.expect(t, ok)
	testing.expect(t, approx_eq(lo, 2, 1e-9))
	testing.expect(t, approx_eq(hi, 9, 1e-9))

	// value_counts: 5×3, 2×2, 9×2
	counts := oa.dict_value_counts(&d)
	defer delete(counts)
	total := i64(0)
	for c in counts { total += c }
	testing.expect_value(t, total, i64(7))

	// decode round-trip
	dec, _ := oa.dict_decode(&d)
	defer oa.array_free(&dec)
	for v, i in vals { testing.expect(t, approx_eq(oa.array_get(&dec, i, f64), v, 1e-9)) }
}

@(test)
test_dict_try_get_with_nulls :: proc(t: ^testing.T) {
	// Str_Dict_Array with nulls
	sb := oa.string_builder_make(4)
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_append(&sb, "alpha")
	oa.string_builder_append_null(&sb)
	oa.string_builder_append(&sb, "beta")
	oa.string_builder_append_null(&sb)
	s_arr, s_err := oa.string_builder_finish(&sb)
	testing.expect_value(t, s_err, nil)
	defer oa.array_free(&s_arr)

	sd := oa.str_dict_encode(&s_arr)
	defer oa.str_dict_free(&sd)

	testing.expect(t, !oa.str_dict_is_null(&sd, 0))
	testing.expect(t, oa.str_dict_is_null(&sd, 1))
	v0, ok0 := oa.str_dict_try_get(&sd, 0)
	testing.expect(t, ok0)
	testing.expect_value(t, v0, "alpha")
	testing.expect_value(t, oa.str_dict_get(&sd, 0), "alpha")
	v1, ok1 := oa.str_dict_try_get(&sd, 1)
	testing.expect(t, !ok1)
	testing.expect_value(t, v1, "")
	v2, ok2 := oa.str_dict_try_get(&sd, 2)
	testing.expect(t, ok2)
	testing.expect_value(t, v2, "beta")

	// Dict_Array(i32) with nulls
	nb := oa.builder_make(i32, 4)
	defer oa.builder_destroy(&nb)
	oa.builder_append(&nb, 10)
	oa.builder_append_null(&nb)
	oa.builder_append(&nb, 20)
	oa.builder_append_null(&nb)
	n_arr, n_err := oa.builder_finish(&nb)
	testing.expect_value(t, n_err, nil)
	defer oa.array_free(&n_arr)

	nd := oa.dict_encode(&n_arr, i32)
	defer oa.dict_free(&nd)

	testing.expect(t, !oa.dict_is_null(&nd, 0))
	testing.expect(t, oa.dict_is_null(&nd, 1))
	nv0, nok0 := oa.dict_try_get(&nd, 0)
	testing.expect(t, nok0)
	testing.expect_value(t, nv0, i32(10))
	testing.expect_value(t, oa.dict_get(&nd, 0), i32(10))
	nv1, nok1 := oa.dict_try_get(&nd, 1)
	testing.expect(t, !nok1)
	testing.expect_value(t, nv1, i32(0))
	nv2, nok2 := oa.dict_try_get(&nd, 2)
	testing.expect(t, nok2)
	testing.expect_value(t, nv2, i32(20))
}

@(test)
test_dict_nan_dedup_and_null_decode :: proc(t: ^testing.T) {
	// Multiple NaNs in Float64 must deduplicate to 1 dictionary entry.
	fb64 := oa.builder_make(f64, 5)
	defer oa.builder_destroy(&fb64)
	oa.builder_append(&fb64, 1.5)
	oa.builder_append(&fb64, math.nan_f64())
	oa.builder_append(&fb64, 2.5)
	oa.builder_append(&fb64, math.nan_f64())
	oa.builder_append(&fb64, 1.5)
	arr64, err64 := oa.builder_finish(&fb64)
	testing.expect_value(t, err64, nil)
	defer oa.array_free(&arr64)

	d64 := oa.dict_encode(&arr64, f64)
	defer oa.dict_free(&d64)
	testing.expect_value(t, oa.dict_size(&d64), 3)
	testing.expect(t, math.is_nan(oa.dict_get(&d64, 1)))
	testing.expect(t, math.is_nan(oa.dict_get(&d64, 3)))

	// Multiple NaNs in Float32 must deduplicate to 1 dictionary entry.
	fb32 := oa.builder_make(f32, 4)
	defer oa.builder_destroy(&fb32)
	oa.builder_append(&fb32, math.nan_f32())
	oa.builder_append(&fb32, f32(3.0))
	oa.builder_append(&fb32, math.nan_f32())
	oa.builder_append(&fb32, f32(3.0))
	arr32, err32 := oa.builder_finish(&fb32)
	testing.expect_value(t, err32, nil)
	defer oa.array_free(&arr32)

	d32 := oa.dict_encode(&arr32, f32)
	defer oa.dict_free(&d32)
	testing.expect_value(t, oa.dict_size(&d32), 2)

	// dict_decode must preserve null_count and validity bitmap.
	nb := oa.builder_make(i32, 5)
	defer oa.builder_destroy(&nb)
	oa.builder_append(&nb, 10)
	oa.builder_append_null(&nb)
	oa.builder_append(&nb, 20)
	oa.builder_append_null(&nb)
	oa.builder_append(&nb, 10)
	narr, nerr := oa.builder_finish(&nb)
	testing.expect_value(t, nerr, nil)
	defer oa.array_free(&narr)

	nd := oa.dict_encode(&narr, i32)
	defer oa.dict_free(&nd)
	dec, derr := oa.dict_decode(&nd)
	testing.expect_value(t, derr, nil)
	defer oa.array_free(&dec)

	testing.expect_value(t, dec.length, 5)
	testing.expect_value(t, oa.array_null_count(&dec), 2)
	testing.expect(t, !oa.array_is_null(&dec, 0))
	testing.expect(t, oa.array_is_null(&dec, 1))
	testing.expect(t, !oa.array_is_null(&dec, 2))
	testing.expect(t, oa.array_is_null(&dec, 3))
	testing.expect_value(t, oa.array_get(&dec, 0, i32), i32(10))
	testing.expect_value(t, oa.array_get(&dec, 2, i32), i32(20))
	testing.expect_value(t, oa.array_get(&dec, 4, i32), i32(10))
}

@(test)
test_dict_numeric_empty_all_null_nullable_and_nan :: proc(t: ^testing.T) {
	// 1. Empty (0-length) numeric array
	{
		eb := oa.builder_make(f64, 0)
		defer oa.builder_destroy(&eb)
		empty_src, err := oa.builder_finish(&eb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&empty_src)

		d := oa.dict_encode(&empty_src, f64)
		defer oa.dict_free(&d)
		testing.expect_value(t, d.length, 0)
		testing.expect_value(t, oa.dict_size(&d), 0)
		testing.expect_value(t, oa.dict_sum(&d), 0.0)
		_, _, mm_ok := oa.dict_min_max(&d)
		testing.expect(t, !mm_ok)
		counts := oa.dict_value_counts(&d)
		defer delete(counts)
		testing.expect_value(t, len(counts), 0)

		dec, d_err := oa.dict_decode(&d)
		testing.expect_value(t, d_err, nil)
		defer oa.array_free(&dec)
		testing.expect_value(t, dec.length, 0)
	}

	// 2. All-null numeric array
	{
		nb := oa.builder_make(i32, 4)
		defer oa.builder_destroy(&nb)
		for _ in 0..<4 { oa.builder_append_null(&nb) }
		nsrc, err := oa.builder_finish(&nb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&nsrc)

		d := oa.dict_encode(&nsrc, i32)
		defer oa.dict_free(&d)
		testing.expect_value(t, d.length, 4)
		testing.expect_value(t, d.null_count, 4)
		testing.expect_value(t, oa.dict_size(&d), 0)
		testing.expect_value(t, oa.dict_sum(&d), 0.0)
		_, _, mm_ok := oa.dict_min_max(&d)
		testing.expect(t, !mm_ok)
		counts := oa.dict_value_counts(&d)
		defer delete(counts)
		testing.expect_value(t, len(counts), 0)

		dec, d_err := oa.dict_decode(&d)
		testing.expect_value(t, d_err, nil)
		defer oa.array_free(&dec)
		testing.expect_value(t, dec.length, 4)
		testing.expect_value(t, oa.array_null_count(&dec), 4)
		for i in 0..<4 {
			testing.expect(t, oa.array_is_null(&dec, i))
		}
	}

	// 3. Sliced (offset > 0) nullable i64 array: dict_sum, dict_min_max, dict_value_counts, dict_decode
	{
		ib := oa.builder_make(i64, 7)
		defer oa.builder_destroy(&ib)
		oa.builder_append(&ib, i64(999))
		oa.builder_append(&ib, i64(100))
		oa.builder_append_null(&ib)
		oa.builder_append(&ib, i64(200))
		oa.builder_append(&ib, i64(100))
		oa.builder_append_null(&ib)
		oa.builder_append(&ib, i64(300))
		full, err := oa.builder_finish(&ib)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&full)

		sliced := oa.array_slice(full, 1, 6) // [100, null, 200, 100, null]
		d := oa.dict_encode(&sliced, i64)
		defer oa.dict_free(&d)
		testing.expect_value(t, d.length, 5)
		testing.expect_value(t, d.null_count, 2)
		testing.expect_value(t, oa.dict_size(&d), 2)
		testing.expect_value(t, oa.dict_sum(&d), 400.0)
		lo, hi, mm_ok := oa.dict_min_max(&d)
		testing.expect(t, mm_ok)
		testing.expect_value(t, lo, 100.0)
		testing.expect_value(t, hi, 200.0)
		counts := oa.dict_value_counts(&d)
		defer delete(counts)
		testing.expect_value(t, len(counts), 2)
		testing.expect_value(t, counts[0], i64(2)) // 100
		testing.expect_value(t, counts[1], i64(1)) // 200

		dec, d_err := oa.dict_decode(&d)
		testing.expect_value(t, d_err, nil)
		defer oa.array_free(&dec)
		testing.expect_value(t, dec.length, 5)
		testing.expect_value(t, oa.array_null_count(&dec), 2)
		testing.expect_value(t, oa.array_get(&dec, 0, i64), i64(100))
		testing.expect(t, oa.array_is_null(&dec, 1))
		testing.expect_value(t, oa.array_get(&dec, 2, i64), i64(200))
		testing.expect_value(t, oa.array_get(&dec, 3, i64), i64(100))
		testing.expect(t, oa.array_is_null(&dec, 4))
	}

	// 4. Nullable f64 with NaN deduplication & kernels
	{
		nan := math.nan_f64()
		fb := oa.builder_make(f64, 4)
		defer oa.builder_destroy(&fb)
		oa.builder_append(&fb, nan)
		oa.builder_append_null(&fb)
		oa.builder_append(&fb, f64(2.5))
		oa.builder_append(&fb, nan)
		src, err := oa.builder_finish(&fb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&src)

		d := oa.dict_encode(&src, f64)
		defer oa.dict_free(&d)
		testing.expect_value(t, oa.dict_size(&d), 2)
		lo, hi, mm_ok := oa.dict_min_max(&d)
		testing.expect(t, mm_ok)
		testing.expect_value(t, lo, f64(2.5))
		testing.expect_value(t, hi, f64(2.5))
		counts := oa.dict_value_counts(&d)
		defer delete(counts)
		testing.expect_value(t, counts[0], i64(2)) // NaN x2
		testing.expect_value(t, counts[1], i64(1)) // 2.5 x1

		dec, d_err := oa.dict_decode(&d)
		testing.expect_value(t, d_err, nil)
		defer oa.array_free(&dec)
		testing.expect(t, oa.array_is_valid(&dec, 0) && math.is_nan(oa.array_get(&dec, 0, f64)))
		testing.expect(t, oa.array_is_null(&dec, 1))
		testing.expect_value(t, oa.array_get(&dec, 2, f64), f64(2.5))
		testing.expect(t, oa.array_is_valid(&dec, 3) && math.is_nan(oa.array_get(&dec, 3, f64)))
	}
}

@(test)
test_dict_slice_and_group_sum :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved
		check_no_leaks(t, &track)
	}

	// Str_Dict_Array slice + str_dict_group_sum with nulls in both codes and weights
	sb := oa.string_builder_make(6)
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_append(&sb, "red")
	oa.string_builder_append(&sb, "blue")
	oa.string_builder_append_null(&sb)
	oa.string_builder_append(&sb, "red")
	oa.string_builder_append(&sb, "blue")
	oa.string_builder_append(&sb, "red")
	sarr, _ := oa.string_builder_finish(&sb)
	defer oa.array_free(&sarr)

	sd := oa.str_dict_encode(&sarr)
	defer oa.str_dict_free(&sd)

	wb := oa.builder_make(f64, 6)
	defer oa.builder_destroy(&wb)
	oa.builder_append(&wb, 100.0)
	oa.builder_append(&wb, 2.5)
	oa.builder_append(&wb, 99.0)
	oa.builder_append(&wb, 4.5)
	oa.builder_append_null(&wb)
	oa.builder_append(&wb, 5.5)
	warr, _ := oa.builder_finish(&wb)
	defer oa.array_free(&warr)

	sd_sl := oa.str_dict_slice(sd, 1, 6)
	defer oa.str_dict_free(&sd_sl)
	w_sl := oa.array_slice(warr, 1, 6)

	testing.expect_value(t, sd_sl.length, 5)
	testing.expect_value(t, sd_sl.null_count, 1)

	svc := oa.str_dict_value_counts(&sd_sl)
	defer delete(svc)
	testing.expect_value(t, svc[0], i64(2)) // "red"
	testing.expect_value(t, svc[1], i64(2)) // "blue"

	sgs := oa.str_dict_group_sum(&sd_sl, &w_sl)
	defer delete(sgs)
	testing.expect(t, approx_eq(sgs[0], 10.0, 1e-9)) // 4.5 + 5.5
	testing.expect(t, approx_eq(sgs[1], 2.5, 1e-9))  // 2.5 (index 4 weight is null)

	// Numeric Dict_Array(i32) slice + dict_group_sum
	nb := oa.builder_make(i32, 6)
	defer oa.builder_destroy(&nb)
	oa.builder_append(&nb, 10)
	oa.builder_append(&nb, 20)
	oa.builder_append_null(&nb)
	oa.builder_append(&nb, 10)
	oa.builder_append(&nb, 20)
	oa.builder_append(&nb, 10)
	narr, _ := oa.builder_finish(&nb)
	defer oa.array_free(&narr)

	nd := oa.dict_encode(&narr, i32)
	defer oa.dict_free(&nd)

	nd_sl := oa.dict_slice(nd, 1, 6)
	defer oa.dict_free(&nd_sl)
	testing.expect_value(t, nd_sl.length, 5)
	testing.expect_value(t, nd_sl.null_count, 1)

	ngs := oa.dict_group_sum(&nd_sl, &w_sl)
	defer delete(ngs)
	testing.expect(t, approx_eq(ngs[0], 10.0, 1e-9))
	testing.expect(t, approx_eq(ngs[1], 2.5, 1e-9))
}
