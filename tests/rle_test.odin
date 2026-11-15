package skadi_tests

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
	plain, _ := oa.builder_finish(&pb)
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
