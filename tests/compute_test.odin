package skadi_tests

import "core:mem"
import "core:os"
import "core:testing"
import oa "../skadi"

// ── helpers ───────────────────────────────────────────────────────────────────

build_bool_mask :: proc(pass: []bool) -> oa.Array {
	b := oa.builder_make(bool)
	defer oa.builder_destroy(&b)
	for v in pass {
		oa.builder_append(&b, v)
	}
	arr, _ := oa.builder_finish(&b)
	return arr
}

approx_eq :: proc(a, b, eps: f64) -> bool {
	d := a - b
	return d >= -eps && d <= eps
}

// ── sum ───────────────────────────────────────────────────────────────────────

@(test)
test_compute_sum_i32 :: proc(t: ^testing.T) {
	arr := build_array([]i32{1, 2, 3, 4, 5})
	defer oa.array_free(&arr)
	sum, n := oa.compute_sum(&arr)
	testing.expect_value(t, sum, f64(15))
	testing.expect_value(t, n, 5)
}

@(test)
test_compute_sum_with_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(10))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(20))
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	sum, n := oa.compute_sum(&arr)
	testing.expect_value(t, sum, f64(30))
	testing.expect_value(t, n, 2)
}

@(test)
test_compute_sum_f64 :: proc(t: ^testing.T) {
	arr := build_array([]f64{1.5, 2.5, 3.0})
	defer oa.array_free(&arr)
	sum, _ := oa.compute_sum(&arr)
	testing.expect(t, approx_eq(sum, 7.0, 1e-12))
}

@(test)
test_compute_sum_empty :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)
	sum, n := oa.compute_sum(&arr)
	testing.expect_value(t, sum, f64(0))
	testing.expect_value(t, n, 0)
}

// ── min / max ─────────────────────────────────────────────────────────────────

@(test)
test_compute_min_max_i32 :: proc(t: ^testing.T) {
	arr := build_array([]i32{5, 1, 8, 3, 2})
	defer oa.array_free(&arr)
	mn, mn_n := oa.compute_min(&arr)
	mx, mx_n := oa.compute_max(&arr)
	testing.expect_value(t, mn, f64(1))
	testing.expect_value(t, mn_n, 5)
	testing.expect_value(t, mx, f64(8))
	testing.expect_value(t, mx_n, 5)
}

@(test)
test_compute_min_with_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(7))
	oa.builder_append_null(&b)
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	mn, n := oa.compute_min(&arr)
	testing.expect_value(t, mn, f64(7))
	testing.expect_value(t, n, 1)
}

@(test)
test_compute_min_all_null :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append_null(&b)
	oa.builder_append_null(&b)
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	_, n := oa.compute_min(&arr)
	testing.expect_value(t, n, 0)
}

// ── mean ──────────────────────────────────────────────────────────────────────

@(test)
test_compute_mean :: proc(t: ^testing.T) {
	arr := build_array([]f64{1.0, 2.0, 3.0, 4.0, 5.0})
	defer oa.array_free(&arr)
	mean, n := oa.compute_mean(&arr)
	testing.expect(t, approx_eq(mean, 3.0, 1e-12))
	testing.expect_value(t, n, 5)
}

@(test)
test_compute_mean_with_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(f64)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, f64(10.0))
	oa.builder_append_null(&b)
	oa.builder_append(&b, f64(20.0))
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	mean, n := oa.compute_mean(&arr)
	testing.expect(t, approx_eq(mean, 15.0, 1e-12))
	testing.expect_value(t, n, 2)
}

// ── count ─────────────────────────────────────────────────────────────────────

@(test)
test_compute_count :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(1))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(3))
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	total, valid := oa.compute_count(&arr)
	testing.expect_value(t, total, 3)
	testing.expect_value(t, valid, 2)
}

// ── filter ────────────────────────────────────────────────────────────────────

@(test)
test_filter_basic :: proc(t: ^testing.T) {
	arr  := build_array([]i32{10, 20, 30, 40, 50})
	mask := build_bool_mask([]bool{true, false, true, false, true})
	defer oa.array_free(&arr)
	defer oa.array_free(&mask)

	result, err := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&result)
	testing.expect(t, err == nil)
	testing.expect_value(t, result.length, 3)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(10))
	testing.expect_value(t, oa.array_get(&result, 1, i32), i32(30))
	testing.expect_value(t, oa.array_get(&result, 2, i32), i32(50))
}

@(test)
test_filter_null_in_source :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(1))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(3))
	src, _ := oa.builder_finish(&b)
	defer oa.array_free(&src)

	mask := build_bool_mask([]bool{true, true, true})
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&src, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 3)
	testing.expect(t, oa.array_is_valid(&result, 0))
	testing.expect(t, oa.array_is_null(&result, 1))
	testing.expect(t, oa.array_is_valid(&result, 2))
}

@(test)
test_filter_null_in_mask :: proc(t: ^testing.T) {
	// Null mask entries → exclude element (treated as false)
	src := build_array([]i32{1, 2, 3})
	defer oa.array_free(&src)

	bm := oa.builder_make(bool)
	defer oa.builder_destroy(&bm)
	oa.builder_append(&bm, true)
	oa.builder_append_null(&bm) // null mask → exclude
	oa.builder_append(&bm, true)
	mask, _ := oa.builder_finish(&bm)
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&src, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 2)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(1))
	testing.expect_value(t, oa.array_get(&result, 1, i32), i32(3))
}

@(test)
test_filter_all_false :: proc(t: ^testing.T) {
	arr  := build_array([]i32{1, 2, 3})
	mask := build_bool_mask([]bool{false, false, false})
	defer oa.array_free(&arr)
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 0)
}

@(test)
test_filter_all_true :: proc(t: ^testing.T) {
	vals := []i32{7, 8, 9}
	arr  := build_array(vals)
	mask := build_bool_mask([]bool{true, true, true})
	defer oa.array_free(&arr)
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 3)
	check_values(t, &result, vals)
}

@(test)
test_filter_float64 :: proc(t: ^testing.T) {
	arr  := build_array([]f64{1.1, 2.2, 3.3, 4.4})
	mask := build_bool_mask([]bool{false, true, false, true})
	defer oa.array_free(&arr)
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 2)
	testing.expect(t, approx_eq(oa.array_get(&result, 0, f64), 2.2, 1e-12))
	testing.expect(t, approx_eq(oa.array_get(&result, 1, f64), 4.4, 1e-12))
}

@(test)
test_filter_string :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	oa.string_builder_append(&b, "keep")
	oa.string_builder_append(&b, "drop")
	oa.string_builder_append(&b, "keep2")
	src, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&src)

	mask := build_bool_mask([]bool{true, false, true})
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&src, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 2)
	testing.expect_value(t, oa.array_get_string(&result, 0), "keep")
	testing.expect_value(t, oa.array_get_string(&result, 1), "keep2")
}

// ── large array compute ───────────────────────────────────────────────────────

@(test)
test_compute_sum_large :: proc(t: ^testing.T) {
	n :: 1_000_000
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	for i in 0..<n {
		oa.builder_append(&b, i32(i))
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	sum, valid := oa.compute_sum(&arr)
	expected := f64(n) * f64(n - 1) / 2.0
	testing.expect(t, approx_eq(sum, expected, 1.0), "sum must match arithmetic series formula")
	testing.expect_value(t, valid, n)
}

@(test)
test_compute_min_max_large :: proc(t: ^testing.T) {
	n :: 100_000
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	for i in 0..<n {
		oa.builder_append(&b, i32(n - i)) // n, n-1, ..., 1
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	mn, _ := oa.compute_min(&arr)
	mx, _ := oa.compute_max(&arr)
	testing.expect_value(t, mn, f64(1))
	testing.expect_value(t, mx, f64(n))
}

@(test)
test_compute_filter_large :: proc(t: ^testing.T) {
	n :: 1_000_000
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	for i in 0..<n { oa.builder_append(&b, i32(i)) }
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	mb := oa.builder_make(bool, n)
	defer oa.builder_destroy(&mb)
	for i in 0..<n { oa.builder_append(&mb, i % 2 == 0) } // even elements pass
	mask, _ := oa.builder_finish(&mb)
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, n / 2)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(0))
	testing.expect_value(t, oa.array_get(&result, 1, i32), i32(2))
}

// ── min_max (single pass) ─────────────────────────────────────────────────────

@(test)
test_compute_min_max :: proc(t: ^testing.T) {
	arr := build_array([]i32{5, 1, 9, 3, 7})
	defer oa.array_free(&arr)
	lo, hi, n := oa.compute_min_max(&arr)
	testing.expect_value(t, lo, f64(1))
	testing.expect_value(t, hi, f64(9))
	testing.expect_value(t, n, 5)
}

@(test)
test_compute_min_max_with_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(10))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(3))
	oa.builder_append(&b, i32(8))
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	lo, hi, n := oa.compute_min_max(&arr)
	testing.expect_value(t, lo, f64(3))
	testing.expect_value(t, hi, f64(10))
	testing.expect_value(t, n, 3)
}

// ── take ──────────────────────────────────────────────────────────────────────

@(test)
test_compute_take :: proc(t: ^testing.T) {
	src := build_array([]i32{10, 20, 30, 40, 50})
	defer oa.array_free(&src)

	ib := oa.builder_make(i64)
	defer oa.builder_destroy(&ib)
	oa.builder_append(&ib, i64(4))
	oa.builder_append(&ib, i64(1))
	oa.builder_append(&ib, i64(3))
	idx, _ := oa.builder_finish(&ib)
	defer oa.array_free(&idx)

	result, _ := oa.compute_take(&src, &idx)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 3)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(50))
	testing.expect_value(t, oa.array_get(&result, 1, i32), i32(20))
	testing.expect_value(t, oa.array_get(&result, 2, i32), i32(40))
}

// ── cast ──────────────────────────────────────────────────────────────────────

@(test)
test_compute_cast_i32_to_f64 :: proc(t: ^testing.T) {
	src := build_array([]i32{1, 2, 3})
	defer oa.array_free(&src)

	result, _ := oa.compute_cast(&src, oa.Float64_Type{})
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 3)
	testing.expect(t, approx_eq(oa.array_get(&result, 0, f64), 1.0, 1e-10))
	testing.expect(t, approx_eq(oa.array_get(&result, 2, f64), 3.0, 1e-10))
}

// Large cast: output exceeds the non-temporal-store threshold (8 MiB), so this
// exercises the streaming-store path plus its scalar tail (length is not a
// multiple of the SIMD width).
@(test)
test_compute_cast_large_nt :: proc(t: ^testing.T) {
	n := 1_048_583 // > 1Mi f64 = 8 MiB out; %8 == 7 → 7-element tail
	b := oa.builder_make(i32, n)
	for i in 0..<n { oa.builder_append(&b, i32(i)) }
	src, _ := oa.builder_finish(&b)
	oa.builder_destroy(&b)
	defer oa.array_free(&src)

	result, _ := oa.compute_cast(&src, oa.Float64_Type{})
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, n)
	testing.expect(t, approx_eq(oa.array_get(&result, 0, f64),       0.0,         1e-6))
	testing.expect(t, approx_eq(oa.array_get(&result, 123_456, f64), 123_456.0,   1e-6))
	testing.expect(t, approx_eq(oa.array_get(&result, n - 1, f64),   f64(n - 1),  1e-6))   // tail
	testing.expect(t, approx_eq(oa.array_get(&result, n - 4, f64),   f64(n - 4),  1e-6))   // tail
}

// ── arithmetic ────────────────────────────────────────────────────────────────

@(test)
test_compute_add :: proc(t: ^testing.T) {
	a := build_array([]i32{1, 2, 3})
	b := build_array([]i32{10, 20, 30})
	defer oa.array_free(&a); defer oa.array_free(&b)

	result, _ := oa.compute_add(&a, &b)
	defer oa.array_free(&result)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(11))
	testing.expect_value(t, oa.array_get(&result, 1, i32), i32(22))
	testing.expect_value(t, oa.array_get(&result, 2, i32), i32(33))
}

// Large add: output exceeds the non-temporal-store threshold, exercising the
// streaming-store path and its scalar tail (length not a multiple of SIMD width).
@(test)
test_compute_add_large_nt :: proc(t: ^testing.T) {
	n := 2_097_157 // > 2Mi i32 = 8 MiB out; %16 == 5 → 5-element tail
	ab := oa.builder_make(i32, n)
	bb := oa.builder_make(i32, n)
	for i in 0..<n { oa.builder_append(&ab, i32(i)); oa.builder_append(&bb, i32(2 * i)) }
	a, _ := oa.builder_finish(&ab); oa.builder_destroy(&ab)
	b, _ := oa.builder_finish(&bb); oa.builder_destroy(&bb)
	defer oa.array_free(&a); defer oa.array_free(&b)

	result, _ := oa.compute_add(&a, &b)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, n)
	testing.expect_value(t, oa.array_get(&result, 0, i32),         i32(0))
	testing.expect_value(t, oa.array_get(&result, 500_000, i32),   i32(3 * 500_000))
	testing.expect_value(t, oa.array_get(&result, n - 1, i32),     i32(3 * (n - 1)))   // tail
	testing.expect_value(t, oa.array_get(&result, n - 3, i32),     i32(3 * (n - 3)))   // tail
}

@(test)
test_compute_arithmetic_null_propagation :: proc(t: ^testing.T) {
	ab := oa.builder_make(i32)
	defer oa.builder_destroy(&ab)
	oa.builder_append(&ab, i32(5))
	oa.builder_append_null(&ab)
	oa.builder_append(&ab, i32(7))
	a, _ := oa.builder_finish(&ab)
	defer oa.array_free(&a)

	b := build_array([]i32{1, 2, 3})
	defer oa.array_free(&b)

	result, _ := oa.compute_add(&a, &b)
	defer oa.array_free(&result)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(6))
	testing.expect(t, oa.array_is_null(&result, 1))
	testing.expect_value(t, oa.array_get(&result, 2, i32), i32(10))
}

// ── sort_indices ──────────────────────────────────────────────────────────────

@(test)
test_sort_indices_i32 :: proc(t: ^testing.T) {
	a := build_array([]i32{30, 10, 20, 10, 40})
	defer oa.array_free(&a)

	idx, _ := oa.compute_sort_indices(&a)
	defer oa.array_free(&idx)

	// Ascending order; ties (two 10s at positions 1 and 3) stay in input order.
	testing.expect_value(t, idx.length, 5)
	testing.expect_value(t, oa.array_get(&idx, 0, i64), i64(1))
	testing.expect_value(t, oa.array_get(&idx, 1, i64), i64(3))
	testing.expect_value(t, oa.array_get(&idx, 2, i64), i64(2))
	testing.expect_value(t, oa.array_get(&idx, 3, i64), i64(0))
	testing.expect_value(t, oa.array_get(&idx, 4, i64), i64(4))

	// Feeding the indices into take yields a sorted array.
	sorted, _ := oa.compute_take(&a, &idx)
	defer oa.array_free(&sorted)
	testing.expect_value(t, oa.array_get(&sorted, 0, i32), i32(10))
	testing.expect_value(t, oa.array_get(&sorted, 1, i32), i32(10))
	testing.expect_value(t, oa.array_get(&sorted, 2, i32), i32(20))
	testing.expect_value(t, oa.array_get(&sorted, 3, i32), i32(30))
	testing.expect_value(t, oa.array_get(&sorted, 4, i32), i32(40))
}

// Negative values exercise the radix sort's sign-bit bias encoding: a plain
// unsigned byte radix would otherwise order negatives after positives.
@(test)
test_sort_indices_i32_negatives :: proc(t: ^testing.T) {
	a := build_array([]i32{5, -3, 0, -100, 7, -3, 2147483647, -2147483648})
	defer oa.array_free(&a)

	idx, _ := oa.compute_sort_indices(&a)
	defer oa.array_free(&idx)

	sorted, _ := oa.compute_take(&a, &idx)
	defer oa.array_free(&sorted)

	expected := []i32{-2147483648, -100, -3, -3, 0, 5, 7, 2147483647}
	testing.expect_value(t, sorted.length, len(expected))
	for v, i in expected {
		testing.expect_value(t, oa.array_get(&sorted, i, i32), v)
	}
	// Stable: the two -3s keep input order (index 1 before index 5).
	testing.expect_value(t, oa.array_get(&idx, 2, i64), i64(1))
	testing.expect_value(t, oa.array_get(&idx, 3, i64), i64(5))
}

@(test)
test_sort_indices_nulls_last :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(5))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(1))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(3))
	a, _ := oa.builder_finish(&b)
	defer oa.array_free(&a)

	idx, _ := oa.compute_sort_indices(&a)
	defer oa.array_free(&idx)

	// Non-null ascending first: 1(@2), 3(@4), 5(@0); then nulls in order: @1, @3.
	testing.expect_value(t, oa.array_get(&idx, 0, i64), i64(2))
	testing.expect_value(t, oa.array_get(&idx, 1, i64), i64(4))
	testing.expect_value(t, oa.array_get(&idx, 2, i64), i64(0))
	testing.expect_value(t, oa.array_get(&idx, 3, i64), i64(1))
	testing.expect_value(t, oa.array_get(&idx, 4, i64), i64(3))
}

@(test)
test_sort_indices_string :: proc(t: ^testing.T) {
	sb := oa.string_builder_make()
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_append(&sb, "pear")
	oa.string_builder_append(&sb, "apple")
	oa.string_builder_append(&sb, "cherry")
	oa.string_builder_append(&sb, "apple")
	a, _ := oa.string_builder_finish(&sb)
	defer oa.array_free(&a)

	idx, _ := oa.compute_sort_indices(&a)
	defer oa.array_free(&idx)

	// apple(@1), apple(@3) stable, cherry(@2), pear(@0)
	testing.expect_value(t, oa.array_get(&idx, 0, i64), i64(1))
	testing.expect_value(t, oa.array_get(&idx, 1, i64), i64(3))
	testing.expect_value(t, oa.array_get(&idx, 2, i64), i64(2))
	testing.expect_value(t, oa.array_get(&idx, 3, i64), i64(0))
}

// ── null-aware aggregation (B2) ─────────────────────────────────────────────────

// Build an f64 array with a deterministic sparse-null pattern and check the
// bulk null-aware kernels against a scalar reference. N is not a multiple of 8,
// so the run/mixed-byte/tail paths are all exercised.
@(test)
test_agg_with_nulls_matches_scalar :: proc(t: ^testing.T) {
	N :: 1003
	b := oa.builder_make(f64, N)
	defer oa.builder_destroy(&b)

	ref_sum:   f64 = 0.0
	ref_min:   f64 = 1e18
	ref_max:   f64 = -1e18
	ref_valid: int = 0
	for i in 0..<N {
		if (i * 7 + 3) % 13 == 0 {
			oa.builder_append_null(&b)
		} else {
			v := f64((i * 131) % 997) - 500.0
			oa.builder_append(&b, v)
			ref_sum += v
			if v < ref_min { ref_min = v }
			if v > ref_max { ref_max = v }
			ref_valid += 1
		}
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	sum, vc := oa.compute_sum(&arr)
	testing.expect_value(t, vc, ref_valid)
	testing.expect(t, approx_eq(sum, ref_sum, 1e-6))

	lo, hi, vc2 := oa.compute_min_max(&arr)
	testing.expect_value(t, vc2, ref_valid)
	testing.expect(t, approx_eq(lo, ref_min, 1e-9))
	testing.expect(t, approx_eq(hi, ref_max, 1e-9))

	mn, _ := oa.compute_min(&arr)
	mx, _ := oa.compute_max(&arr)
	testing.expect(t, approx_eq(mn, ref_min, 1e-9))
	testing.expect(t, approx_eq(mx, ref_max, 1e-9))
}

// Same idea for i32 (exercises the SIMD run reducers) plus an all-null array.
@(test)
test_agg_with_nulls_i32_and_empty :: proc(t: ^testing.T) {
	N :: 512
	b := oa.builder_make(i32, N)
	defer oa.builder_destroy(&b)
	ref_sum := 0.0; ref_lo := 1 << 30; ref_hi := -(1 << 30); ref_valid := 0
	for i in 0..<N {
		if i % 5 == 0 {
			oa.builder_append_null(&b)
		} else {
			v := (i * 37) % 251 - 120
			oa.builder_append(&b, i32(v))
			ref_sum += f64(v)
			if v < ref_lo { ref_lo = v }
			if v > ref_hi { ref_hi = v }
			ref_valid += 1
		}
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	sum, vc := oa.compute_sum(&arr)
	testing.expect_value(t, vc, ref_valid)
	testing.expect(t, approx_eq(sum, ref_sum, 1e-9))
	lo, hi, _ := oa.compute_min_max(&arr)
	testing.expect(t, approx_eq(lo, f64(ref_lo), 1e-9))
	testing.expect(t, approx_eq(hi, f64(ref_hi), 1e-9))

	// All-null array: valid_count 0, no crash.
	nb := oa.builder_make(i32, 20)
	defer oa.builder_destroy(&nb)
	for _ in 0..<20 { oa.builder_append_null(&nb) }
	na, _ := oa.builder_finish(&nb)
	defer oa.array_free(&na)
	s2, v2 := oa.compute_sum(&na)
	testing.expect_value(t, v2, 0)
	testing.expect(t, approx_eq(s2, 0.0, 1e-12))
}

// A sliced array exercises both the byte-aligned (offset 8) bulk path and the
// unaligned (offset 3) fallback path.
@(test)
test_agg_with_nulls_sliced :: proc(t: ^testing.T) {
	N :: 200
	b := oa.builder_make(f64, N)
	defer oa.builder_destroy(&b)
	for i in 0..<N {
		if i % 11 == 0 { oa.builder_append_null(&b) }
		else           { oa.builder_append(&b, f64(i)) }
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	check :: proc(tc: ^testing.T, a: ^oa.Array) {
		ref_sum := 0.0; ref_valid := 0
		for i in 0..<a.length {
			if !oa.array_is_null(a, i) { ref_sum += oa.array_get(a, i, f64); ref_valid += 1 }
		}
		sum, vc := oa.compute_sum(a)
		testing.expect_value(tc, vc, ref_valid)
		testing.expect(tc, approx_eq(sum, ref_sum, 1e-6))
	}

	s_aligned := oa.array_slice(arr, 8, 180)   // offset 8  → bulk path
	check(t, &s_aligned)
	s_unaligned := oa.array_slice(arr, 3, 175)  // offset 3  → fallback path
	check(t, &s_unaligned)
}

@(test)
test_compute_unaligned_sliced_f64_simd :: proc(t: ^testing.T) {
	b := oa.builder_make(f64, 40)
	defer oa.builder_destroy(&b)
	for i in 0..<40 {
		oa.builder_append(&b, f64(i))
	}
	arr, err := oa.builder_finish(&b)
	testing.expect_value(t, err, nil)
	defer oa.array_free(&arr)

	// Sliced with offset = 1, length = 35 (null-free)
	sl := oa.array_slice(arr, 1, 36)
	testing.expect_value(t, sl.offset, 1)
	testing.expect_value(t, sl.length, 35)

	// compute_sum on unaligned f64 slice (#simd[4]f64)
	sum, count := oa.compute_sum(&sl)
	testing.expect_value(t, count, 35)
	// sum of 1..35 is 35 * 36 / 2 = 630.0
	testing.expect(t, approx_eq(sum, 630.0, 1e-6), "unaligned sliced sum mismatch")

	// compute_compare on unaligned f64 slice (#simd[8]f64)
	mask, cmp_err := oa.compute_compare(&sl, .Gt, 20.0)
	testing.expect_value(t, cmp_err, nil)
	defer oa.array_free(&mask)
	testing.expect_value(t, mask.length, 35)
	for i in 0..<35 {
		val := oa.array_get(&sl, i, f64)
		expected := val > 20.0
		testing.expect_value(t, oa.array_get(&mask, i, bool), expected)
	}
}

@(test)
test_compute_large_ipc_nt_store_alignment :: proc(t: ^testing.T) {
	n := 2 * 1024 * 1024
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	for i in 0..<n {
		oa.builder_append(&b, i32(i % 1000))
	}
	arr, b_err := oa.builder_finish(&b)
	testing.expect_value(t, b_err, nil)

	fields := []oa.Field{oa.field_make("val", oa.Int32_Type{})}
	sc, s_err := oa.schema_make(fields)
	testing.expect_value(t, s_err, nil)
	defer oa.schema_free(&sc)

	rb, rb_ok := oa.record_batch_make(&sc, []oa.Array{arr})
	testing.expect(t, rb_ok)
	if !rb_ok {
		oa.array_free(&arr)
		return
	}
	defer oa.record_batch_free(&rb)

	path_str := ipc_test_temp_path("large_nt", "arrow")
	defer {
		os.remove(path_str)
		delete(path_str)
	}

	wrote := oa.ipc_write_file(path_str, &sc, []oa.Record_Batch{rb})
	testing.expect(t, wrote)

	sc_read, batches, ok := oa.ipc_read_file(path_str, use_mmap = false)
	testing.expect(t, ok)
	defer {
		if sc_read != nil {
			oa.schema_free(sc_read)
			free(sc_read)
		}
		for bx in batches {
			bc := bx
			oa.record_batch_free(&bc)
		}
		delete(batches)
	}
	testing.expect_value(t, len(batches), 1)
	if !ok || len(batches) == 0 {
		return
	}
	col := oa.record_batch_column_at(&batches[0], 0)

	// Cast i32 to i64 triggers _cast_impl with n * size_of(i64) = 16 MiB >= 8 MiB NT store
	cast_res, c_err := oa.compute_cast(col, oa.Int64_Type{})
	testing.expect_value(t, c_err, nil)
	defer oa.array_free(&cast_res)
	testing.expect_value(t, cast_res.length, n)
	if cast_res.length == n {
		testing.expect_value(t, oa.array_get(&cast_res, 0, i64), i64(0))
		testing.expect_value(t, oa.array_get(&cast_res, n - 1, i64), i64((n - 1) % 1000))
	}
}

@(test)
test_cast_sliced_offset_8_masks_validity_trailing_bits :: proc(t: ^testing.T) {
	// Force validity bitmap to be allocated and set bits 1..15 valid, bit 0 null
	b2 := oa.builder_make(i32, 16)
	defer oa.builder_destroy(&b2)
	oa.builder_append_null(&b2)
	for i in 1..<16 {
		oa.builder_append(&b2, i32(i))
	}
	arr2, b2_err := oa.builder_finish(&b2)
	testing.expect_value(t, b2_err, nil)
	defer oa.array_free(&arr2)

	sl := oa.array_slice(arr2, 8, 11) // offset = 8 (byte-aligned), length = 3
	cast_res, c_err := oa.compute_cast(&sl, oa.Float64_Type{})
	testing.expect_value(t, c_err, nil)
	defer oa.array_free(&cast_res)

	testing.expect(t, cast_res.buffers[0].data != nil, "validity bitmap must be preserved")
	if cast_res.buffers[0].data != nil {
		// Only bits 0, 1, 2 should be set (0b0000_0111 = 0x07), trailing bits 3..7 must be 0
		testing.expect_value(t, cast_res.buffers[0].data[0], u8(0x07))
	}
}

@(test)
test_agg_where_compare_i64_on_float_columns :: proc(t: ^testing.T) {
	b := oa.builder_make(f64, 4)
	defer oa.builder_destroy(&b)
	// 2^53 = 9007199254740992.0 (exact in f64), 2^53 + 2 = 9007199254740994.0 (exact in f64)
	oa.builder_append(&b, 9007199254740992.0)
	oa.builder_append(&b, 9007199254740994.0)
	oa.builder_append(&b, -5.0)
	oa.builder_append_null(&b)
	arr, b_err := oa.builder_finish(&b)
	testing.expect_value(t, b_err, nil)
	defer oa.array_free(&arr)

	// Compare f64 column against i64(2^53 + 1): only 2^53 + 2 is > 2^53 + 1
	agg := oa.compute_agg_where_compare_i64(&arr, &arr, .Gt, i64(9_007_199_254_740_993))
	testing.expect(t, agg.valid)
	testing.expect_value(t, agg.count, 1)
	testing.expect_value(t, agg.min_val, 9007199254740994.0)
	testing.expect_value(t, agg.max_val, 9007199254740994.0)

	// f32 column check
	bf := oa.builder_make(f32, 3)
	defer oa.builder_destroy(&bf)
	oa.builder_append(&bf, f32(10.0))
	oa.builder_append(&bf, f32(20.0))
	oa.builder_append(&bf, f32(30.0))
	arrf, bf_err := oa.builder_finish(&bf)
	testing.expect_value(t, bf_err, nil)
	defer oa.array_free(&arrf)

	aggf := oa.compute_agg_where_compare_i64(&arrf, &arrf, .Ge, i64(20))
	testing.expect(t, aggf.valid)
	testing.expect_value(t, aggf.count, 2)
	testing.expect_value(t, aggf.sum, 50.0)
}

@(test)
test_compute_sort_indices_temp_allocator_no_leak :: proc(t: ^testing.T) {
	N :: 2048
	b := oa.builder_make(i32, N)
	defer oa.builder_destroy(&b)
	for i in 0..<N {
		oa.builder_append(&b, i32(N - i))
	}
	arr, arr_err := oa.builder_finish(&b)
	testing.expect_value(t, arr_err, mem.Allocator_Error.None)
	defer oa.array_free(&arr)

	for _ in 0..<25 {
		idx, err := oa.compute_sort_indices(&arr)
		testing.expect_value(t, err, mem.Allocator_Error.None)
		testing.expect_value(t, oa.array_get(&idx, 0, i64), i64(N - 1))
		oa.array_free(&idx)
	}
}
