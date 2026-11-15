package skadi_tests

import "core:math"
import "core:testing"
import oa "../skadi"

@(test)
test_rle_build_and_kernels :: proc(t: ^testing.T) {
	// logical: 5,5,5, 2, 9,9, 5  → 4 runs
	vals := []f64{5, 5, 5, 2, 9, 9, 5}
	b := oa.rle_builder_make(f64)
	defer oa.rle_builder_destroy(&b)
	for v in vals { oa.rle_append(&b, v) }
	a := oa.rle_builder_finish(&b)
	defer oa.rle_free(&a)

	testing.expect_value(t, a.length, 7)
	testing.expect_value(t, oa.rle_run_count(&a), 4)

	// sum / min / max via the encoded kernels
	testing.expect(t, approx_eq(oa.rle_sum(&a), 5+5+5+2+9+9+5, 1e-9))
	lo, hi, ok := oa.rle_min_max(&a)
	testing.expect(t, ok)
	testing.expect(t, approx_eq(lo, 2, 1e-9))
	testing.expect(t, approx_eq(hi, 9, 1e-9))

	// random access via binary search
	testing.expect(t, approx_eq(oa.rle_get(&a, 0), 5, 1e-9))
	testing.expect(t, approx_eq(oa.rle_get(&a, 3), 2, 1e-9))
	testing.expect(t, approx_eq(oa.rle_get(&a, 4), 9, 1e-9))
	testing.expect(t, approx_eq(oa.rle_get(&a, 6), 5, 1e-9))
}

@(test)
test_rle_decode_roundtrip :: proc(t: ^testing.T) {
	vals := []i32{3, 3, 3, 3, 7, 1, 1}
	b := oa.rle_builder_make(i32)
	defer oa.rle_builder_destroy(&b)
	for v in vals { oa.rle_append(&b, v) }
	a := oa.rle_builder_finish(&b)
	defer oa.rle_free(&a)

	dec, _ := oa.rle_decode(&a)
	defer oa.array_free(&dec)
	testing.expect_value(t, dec.length, len(vals))
	for v, i in vals {
		testing.expect_value(t, oa.array_get(&dec, i, i32), v)
	}
}

// Encoding a plain array, then summing the encoded form must match the plain sum,
// and the encoded form must be much smaller for runny data.
@(test)
test_rle_encode_matches_plain :: proc(t: ^testing.T) {
	N :: 10_000
	pb := oa.builder_make(i32, N)
	defer oa.builder_destroy(&pb)
	ref_sum := 0.0
	for i in 0..<N {
		v := i32((i / 100) % 5)   // 100-long runs, 5 distinct values
		oa.builder_append(&pb, v)
		ref_sum += f64(v)
	}
	plain, err := oa.builder_finish(&pb)
	testing.expect_value(t, err, nil)
	defer oa.array_free(&plain)

	a := oa.rle_encode(&plain, i32)
	defer oa.rle_free(&a)

	testing.expect_value(t, a.length, N)
	testing.expect(t, oa.rle_run_count(&a) <= N / 50, "should collapse 100-long runs")
	testing.expect(t, approx_eq(oa.rle_sum(&a), ref_sum, 1e-6))
	testing.expect(t, oa.rle_encoded_bytes(&a) < N * size_of(i32), "encoded form is smaller")
}

@(test)
test_rle_try_get_with_nulls :: proc(t: ^testing.T) {
	b := oa.rle_builder_make(i32)
	defer oa.rle_builder_destroy(&b)
	oa.rle_append(&b, 42)
	oa.rle_append(&b, 42)
	oa.rle_append_null(&b)
	oa.rle_append_null(&b)
	oa.rle_append(&b, 99)

	a := oa.rle_builder_finish(&b)
	defer oa.rle_free(&a)

	testing.expect(t, !oa.rle_is_null(&a, 0))
	testing.expect(t, oa.rle_is_null(&a, 2))
	testing.expect(t, oa.rle_is_null(&a, 3))
	testing.expect(t, !oa.rle_is_null(&a, 4))

	v0, ok0 := oa.rle_try_get(&a, 0)
	testing.expect(t, ok0)
	testing.expect_value(t, v0, i32(42))
	testing.expect_value(t, oa.rle_get(&a, 1), i32(42))

	v2, ok2 := oa.rle_try_get(&a, 2)
	testing.expect(t, !ok2)
	testing.expect_value(t, v2, i32(0))

	v4, ok4 := oa.rle_try_get(&a, 4)
	testing.expect(t, ok4)
	testing.expect_value(t, v4, i32(99))
}

@(test)
test_rle_encode_decode_preserves_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(i32, 7)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, 7)
	oa.builder_append(&b, 7)
	oa.builder_append_null(&b)
	oa.builder_append(&b, 7)
	oa.builder_append_null(&b)
	oa.builder_append_null(&b)
	oa.builder_append(&b, 9)
	src, err := oa.builder_finish(&b)
	testing.expect_value(t, err, nil)
	defer oa.array_free(&src)

	enc := oa.rle_encode(&src, i32)
	defer oa.rle_free(&enc)
	testing.expect_value(t, oa.rle_run_count(&enc), 5)

	dec, dec_err := oa.rle_decode(&enc)
	testing.expect_value(t, dec_err, nil)
	defer oa.array_free(&dec)
	testing.expect_value(t, dec.length, 7)
	testing.expect_value(t, oa.array_null_count(&dec), 3)
	testing.expect(t, !oa.array_is_null(&dec, 0))
	testing.expect(t, !oa.array_is_null(&dec, 1))
	testing.expect(t, oa.array_is_null(&dec, 2))
	testing.expect(t, !oa.array_is_null(&dec, 3))
	testing.expect(t, oa.array_is_null(&dec, 4))
	testing.expect(t, oa.array_is_null(&dec, 5))
	testing.expect(t, !oa.array_is_null(&dec, 6))
	testing.expect_value(t, oa.array_get(&dec, 0, i32), i32(7))
	testing.expect_value(t, oa.array_get(&dec, 3, i32), i32(7))
	testing.expect_value(t, oa.array_get(&dec, 6, i32), i32(9))
}

@(test)
test_rle_empty_all_null_and_nan_edges :: proc(t: ^testing.T) {
	// 1. Empty (0-length) array
	{
		eb := oa.builder_make(f64, 0)
		defer oa.builder_destroy(&eb)
		empty_src, err := oa.builder_finish(&eb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&empty_src)

		enc := oa.rle_encode(&empty_src, f64)
		defer oa.rle_free(&enc)
		testing.expect_value(t, enc.length, 0)
		testing.expect_value(t, oa.rle_run_count(&enc), 0)
		testing.expect_value(t, oa.rle_sum(&enc), 0.0)
		_, _, mm_ok := oa.rle_min_max(&enc)
		testing.expect(t, !mm_ok)

		dec, d_err := oa.rle_decode(&enc)
		testing.expect_value(t, d_err, nil)
		defer oa.array_free(&dec)
		testing.expect_value(t, dec.length, 0)
		testing.expect_value(t, oa.array_null_count(&dec), 0)
	}

	// 2. All-null array
	{
		nb := oa.builder_make(i32, 5)
		defer oa.builder_destroy(&nb)
		for _ in 0..<5 { oa.builder_append_null(&nb) }
		nsrc, err := oa.builder_finish(&nb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&nsrc)

		enc := oa.rle_encode(&nsrc, i32)
		defer oa.rle_free(&enc)
		testing.expect_value(t, enc.length, 5)
		testing.expect_value(t, enc.null_count, 5)
		testing.expect_value(t, oa.rle_run_count(&enc), 1)
		testing.expect_value(t, oa.rle_sum(&enc), 0.0)
		_, _, mm_ok := oa.rle_min_max(&enc)
		testing.expect(t, !mm_ok)

		dec, d_err := oa.rle_decode(&enc)
		testing.expect_value(t, d_err, nil)
		defer oa.array_free(&dec)
		testing.expect_value(t, dec.length, 5)
		testing.expect_value(t, oa.array_null_count(&dec), 5)
		for i in 0..<5 {
			testing.expect(t, oa.array_is_null(&dec, i))
		}
	}

	// 3. Sliced (offset > 0) nullable i64 array
	{
		ib := oa.builder_make(i64, 9)
		defer oa.builder_destroy(&ib)
		oa.builder_append(&ib, i64(999))
		oa.builder_append(&ib, i64(10))
		oa.builder_append(&ib, i64(10))
		oa.builder_append_null(&ib)
		oa.builder_append_null(&ib)
		oa.builder_append(&ib, i64(20))
		oa.builder_append(&ib, i64(20))
		oa.builder_append_null(&ib)
		oa.builder_append(&ib, i64(888))
		full, err := oa.builder_finish(&ib)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&full)

		sliced := oa.array_slice(full, 1, 8) // [10, 10, null, null, 20, 20, null]
		ref_sum, _ := oa.compute_sum(&sliced)
		ref_lo, ref_hi, ref_valid := oa.compute_min_max(&sliced)

		enc := oa.rle_encode(&sliced, i64)
		defer oa.rle_free(&enc)
		testing.expect_value(t, enc.length, 7)
		testing.expect_value(t, enc.null_count, 3)
		testing.expect_value(t, oa.rle_run_count(&enc), 4)
		testing.expect_value(t, oa.rle_sum(&enc), ref_sum)
		lo, hi, ok := oa.rle_min_max(&enc)
		testing.expect_value(t, ok, ref_valid > 0)
		testing.expect_value(t, lo, ref_lo)
		testing.expect_value(t, hi, ref_hi)

		dec, d_err := oa.rle_decode(&enc)
		testing.expect_value(t, d_err, nil)
		defer oa.array_free(&dec)
		testing.expect_value(t, dec.length, 7)
		testing.expect_value(t, oa.array_null_count(&dec), 3)
		testing.expect_value(t, oa.array_get(&dec, 0, i64), i64(10))
		testing.expect_value(t, oa.array_get(&dec, 1, i64), i64(10))
		testing.expect(t, oa.array_is_null(&dec, 2))
		testing.expect(t, oa.array_is_null(&dec, 3))
		testing.expect_value(t, oa.array_get(&dec, 4, i64), i64(20))
		testing.expect_value(t, oa.array_get(&dec, 5, i64), i64(20))
		testing.expect(t, oa.array_is_null(&dec, 6))
	}

	// 4. NaN run coalescing with nulls in f64
	{
		nan := math.nan_f64()
		fb := oa.builder_make(f64, 7)
		defer oa.builder_destroy(&fb)
		oa.builder_append(&fb, nan)
		oa.builder_append(&fb, nan)
		oa.builder_append(&fb, f64(1.5))
		oa.builder_append(&fb, f64(1.5))
		oa.builder_append_null(&fb)
		oa.builder_append(&fb, nan)
		oa.builder_append(&fb, nan)
		src, err := oa.builder_finish(&fb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&src)

		enc := oa.rle_encode(&src, f64)
		defer oa.rle_free(&enc)
		testing.expect_value(t, enc.length, 7)
		testing.expect_value(t, oa.rle_run_count(&enc), 4)
		lo, hi, ok := oa.rle_min_max(&enc)
		testing.expect(t, ok)
		testing.expect_value(t, lo, f64(1.5))
		testing.expect_value(t, hi, f64(1.5))

		dec, d_err := oa.rle_decode(&enc)
		testing.expect_value(t, d_err, nil)
		defer oa.array_free(&dec)
		testing.expect(t, oa.array_is_valid(&dec, 0) && math.is_nan(oa.array_get(&dec, 0, f64)))
		testing.expect(t, oa.array_is_valid(&dec, 1) && math.is_nan(oa.array_get(&dec, 1, f64)))
		testing.expect_value(t, oa.array_get(&dec, 2, f64), f64(1.5))
		testing.expect_value(t, oa.array_get(&dec, 3, f64), f64(1.5))
		testing.expect(t, oa.array_is_null(&dec, 4))
		testing.expect(t, oa.array_is_valid(&dec, 5) && math.is_nan(oa.array_get(&dec, 5, f64)))
		testing.expect(t, oa.array_is_valid(&dec, 6) && math.is_nan(oa.array_get(&dec, 6, f64)))
	}
}
