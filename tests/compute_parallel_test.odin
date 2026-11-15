package skadi_tests

import "core:math"
import "core:mem"
import "core:testing"
import oa "../skadi"

// Parallel kernels must agree with the serial kernels for any input size,
// including lengths above PARALLEL_MIN_LENGTH (so the threaded path runs)
// and lengths that don't divide evenly across threads.

PAR_N :: oa.PARALLEL_MIN_LENGTH + 12_345 // odd size: uneven chunks

build_large_i32 :: proc(with_nulls: bool) -> oa.Array {
	b := oa.builder_make(i32, PAR_N)
	defer oa.builder_destroy(&b)
	for i in 0..<PAR_N {
		if with_nulls && i % 97 == 0 {
			oa.builder_append_null(&b)
		} else {
			oa.builder_append(&b, i32(i % 1000) - 500)
		}
	}
	arr, _ := oa.builder_finish(&b)
	return arr
}

@(test)
test_parallel_sum_matches_serial :: proc(t: ^testing.T) {
	arr := build_large_i32(false)
	defer oa.array_free(&arr)

	s_sum, s_n := oa.compute_sum(&arr)
	p_sum, p_n := oa.compute_sum_parallel(&arr, 4)
	testing.expect_value(t, p_sum, s_sum)
	testing.expect_value(t, p_n, s_n)
}

@(test)
test_parallel_sum_with_nulls :: proc(t: ^testing.T) {
	arr := build_large_i32(true)
	defer oa.array_free(&arr)

	s_sum, s_n := oa.compute_sum(&arr)
	p_sum, p_n := oa.compute_sum_parallel(&arr, 3)
	testing.expect_value(t, p_sum, s_sum)
	testing.expect_value(t, p_n, s_n)
}

@(test)
test_parallel_min_max :: proc(t: ^testing.T) {
	arr := build_large_i32(true)
	defer oa.array_free(&arr)

	s_min, s_minn := oa.compute_min(&arr)
	p_min, p_minn := oa.compute_min_parallel(&arr, 4)
	testing.expect_value(t, p_min, s_min)
	testing.expect_value(t, p_minn, s_minn)

	s_max, s_maxn := oa.compute_max(&arr)
	p_max, p_maxn := oa.compute_max_parallel(&arr, 4)
	testing.expect_value(t, p_max, s_max)
	testing.expect_value(t, p_maxn, s_maxn)
}

@(test)
test_parallel_small_falls_back :: proc(t: ^testing.T) {
	arr := build_array([]i32{1, 2, 3, 4, 5})
	defer oa.array_free(&arr)
	sum, n := oa.compute_sum_parallel(&arr, 4)
	testing.expect_value(t, sum, f64(15))
	testing.expect_value(t, n, 5)
}

@(test)
test_parallel_filter_matches_serial :: proc(t: ^testing.T) {
	arr := build_large_i32(true)
	defer oa.array_free(&arr)

	mb := oa.builder_make(bool, PAR_N)
	defer oa.builder_destroy(&mb)
	for i in 0..<PAR_N {
		oa.builder_append(&mb, i % 3 == 0)
	}
	mask, _ := oa.builder_finish(&mb)
	defer oa.array_free(&mask)

	s, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&s)
	p, _ := oa.compute_filter_parallel(&arr, &mask, 4)
	defer oa.array_free(&p)

	testing.expect_value(t, p.length, s.length)
	testing.expect_value(t, oa.array_null_count(&p), oa.array_null_count(&s))
	for i in 0..<s.length {
		sv, s_ok := oa.array_try_get(&s, i, i32)
		pv, p_ok := oa.array_try_get(&p, i, i32)
		testing.expect_value(t, p_ok, s_ok)
		if s_ok {
			testing.expect_value(t, pv, sv)
		}
	}
}

@(test)
test_parallel_filter_bool :: proc(t: ^testing.T) {
	b := oa.builder_make(bool, PAR_N)
	defer oa.builder_destroy(&b)
	for i in 0..<PAR_N {
		if i % 53 == 0 {
			oa.builder_append_null(&b)
		} else {
			oa.builder_append(&b, i % 2 == 0)
		}
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	mb := oa.builder_make(bool, PAR_N)
	defer oa.builder_destroy(&mb)
	for i in 0..<PAR_N {
		oa.builder_append(&mb, i % 7 != 0)
	}
	mask, _ := oa.builder_finish(&mb)
	defer oa.array_free(&mask)

	s, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&s)
	p, _ := oa.compute_filter_parallel(&arr, &mask, 4)
	defer oa.array_free(&p)

	testing.expect_value(t, p.length, s.length)
	for i in 0..<s.length {
		sv, s_ok := oa.array_try_get(&s, i, bool)
		pv, p_ok := oa.array_try_get(&p, i, bool)
		testing.expect_value(t, p_ok, s_ok)
		if s_ok {
			testing.expect_value(t, pv, sv)
		}
	}
}

@(test)
test_parallel_aggs_f64_i64_nulls_and_slice_offsets :: proc(t: ^testing.T) {
	pad_n :: PAR_N + 16
	fb := oa.builder_make(f64, pad_n)
	defer oa.builder_destroy(&fb)
	ib := oa.builder_make(i64, pad_n)
	defer oa.builder_destroy(&ib)
	for i in 0..<pad_n {
		if i % 89 == 0 {
			oa.builder_append_null(&fb)
			oa.builder_append_null(&ib)
		} else {
			v := (i * 37) % 1003 - 500
			oa.builder_append(&fb, f64(v) * 0.25)
			oa.builder_append(&ib, i64(v))
		}
	}
	farr, f_err := oa.builder_finish(&fb)
	testing.expect_value(t, f_err, nil)
	defer oa.array_free(&farr)
	iarr, i_err := oa.builder_finish(&ib)
	testing.expect_value(t, i_err, nil)
	defer oa.array_free(&iarr)

	check_aggs :: proc(t: ^testing.T, arr: ^oa.Array) {
		s_sum, s_sn := oa.compute_sum(arr)
		p_sum, p_sn := oa.compute_sum_parallel(arr, 4)
		testing.expect_value(t, p_sn, s_sn)
		testing.expect(t, math.abs(p_sum - s_sum) < 1e-6)

		s_min, s_mn := oa.compute_min(arr)
		p_min, p_mn := oa.compute_min_parallel(arr, 4)
		testing.expect_value(t, p_mn, s_mn)
		testing.expect(t, math.abs(p_min - s_min) < 1e-9)

		s_max, s_xn := oa.compute_max(arr)
		p_max, p_xn := oa.compute_max_parallel(arr, 4)
		testing.expect_value(t, p_xn, s_xn)
		testing.expect(t, math.abs(p_max - s_max) < 1e-9)

		s_mean, s_an := oa.compute_mean(arr)
		p_mean, p_an := oa.compute_mean_parallel(arr, 4)
		testing.expect_value(t, p_an, s_an)
		testing.expect(t, math.abs(p_mean - s_mean) < 1e-6)

		s_lo, s_hi, s_mmn := oa.compute_min_max(arr)
		p_lo, p_hi, p_mmn := oa.compute_min_max_parallel(arr, 4)
		testing.expect_value(t, p_mmn, s_mmn)
		testing.expect(t, math.abs(p_lo - s_lo) < 1e-9)
		testing.expect(t, math.abs(p_hi - s_hi) < 1e-9)
	}

	// Test both byte-aligned (offset=8) and unaligned (offset=3) slices above PARALLEL_MIN_LENGTH.
	for off in ([]int{8, 3}) {
		fs := oa.array_slice(farr, off, pad_n - 1)
		is := oa.array_slice(iarr, off, pad_n - 1)
		check_aggs(t, &fs)
		check_aggs(t, &is)
	}
}

@(test)
test_parallel_filter_f64_varlen_and_sliced :: proc(t: ^testing.T) {
	// 1. f64 multi-threaded (offset=8) and fallback (offset=3) with nulls + nullable mask
	{
		pad_n :: PAR_N + 16
		fb := oa.builder_make(f64, pad_n)
		defer oa.builder_destroy(&fb)
		mb := oa.builder_make(bool, pad_n)
		defer oa.builder_destroy(&mb)
		for i in 0..<pad_n {
			if i % 73 == 0 {
				oa.builder_append_null(&fb)
			} else {
				oa.builder_append(&fb, f64(i) * 0.5)
			}
			if i % 67 == 0 {
				oa.builder_append_null(&mb)
			} else {
				oa.builder_append(&mb, i % 4 != 0)
			}
		}
		farr, f_err := oa.builder_finish(&fb)
		testing.expect_value(t, f_err, nil)
		defer oa.array_free(&farr)
		marr, m_err := oa.builder_finish(&mb)
		testing.expect_value(t, m_err, nil)
		defer oa.array_free(&marr)

		for off in ([]int{8, 3}) {
			fs := oa.array_slice(farr, off, pad_n - 1)
			ms := oa.array_slice(marr, off, pad_n - 1)
			ser, s_err := oa.compute_filter(&fs, &ms)
			testing.expect_value(t, s_err, nil)
			defer oa.array_free(&ser)
			par, p_err := oa.compute_filter_parallel(&fs, &ms, 4)
			testing.expect_value(t, p_err, nil)
			defer oa.array_free(&par)

			testing.expect_value(t, par.length, ser.length)
			testing.expect_value(t, oa.array_null_count(&par), oa.array_null_count(&ser))
			for i in 0..<ser.length {
				testing.expect_value(t, oa.array_is_valid(&par, i), oa.array_is_valid(&ser, i))
				if oa.array_is_valid(&ser, i) {
					testing.expect_value(t, oa.array_get(&par, i, f64), oa.array_get(&ser, i, f64))
				}
			}
		}
	}

	// Build shared sliced mask for varlen filter tests
	mbv := oa.builder_make(bool, 6)
	defer oa.builder_destroy(&mbv)
	oa.builder_append(&mbv, false)
	oa.builder_append(&mbv, true)
	oa.builder_append(&mbv, true)
	oa.builder_append_null(&mbv)
	oa.builder_append(&mbv, true)
	oa.builder_append(&mbv, false)
	full_mask, fm_err := oa.builder_finish(&mbv)
	testing.expect_value(t, fm_err, nil)
	defer oa.array_free(&full_mask)
	smask := oa.array_slice(full_mask, 1, 5) // [true, true, null, true]

	// 2. Binary_Type
	{
		bb := oa.binary_builder_make(6)
		defer oa.binary_builder_destroy(&bb)
		oa.binary_builder_append(&bb, []u8{0x00})
		oa.binary_builder_append(&bb, []u8{0x01, 0x02})
		oa.binary_builder_append_null(&bb)
		oa.binary_builder_append(&bb, []u8{0x03})
		oa.binary_builder_append(&bb, []u8{0x04, 0x05, 0x06})
		oa.binary_builder_append(&bb, []u8{0x07})
		full_b, err := oa.binary_builder_finish(&bb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&full_b)
		sb := oa.array_slice(full_b, 1, 5)

		ser, s_err := oa.compute_filter(&sb, &smask)
		testing.expect_value(t, s_err, nil)
		defer oa.array_free(&ser)
		par, p_err := oa.compute_filter_parallel(&sb, &smask, 4)
		testing.expect_value(t, p_err, nil)
		defer oa.array_free(&par)

		testing.expect_value(t, par.length, 3)
		testing.expect_value(t, par.length, ser.length)
		testing.expect_value(t, oa.array_null_count(&par), 1)
		testing.expect(t, mem.compare(oa.array_get_binary(&par, 0), []u8{0x01, 0x02}) == 0)
		testing.expect(t, oa.array_is_null(&par, 1))
		testing.expect(t, mem.compare(oa.array_get_binary(&par, 2), []u8{0x04, 0x05, 0x06}) == 0)
	}

	// 3. Large_String_Type
	{
		lsb := oa.large_string_builder_make(6)
		defer oa.large_string_builder_destroy(&lsb)
		oa.large_string_builder_append(&lsb, "pad0")
		oa.large_string_builder_append(&lsb, "kept_one")
		oa.large_string_builder_append_null(&lsb)
		oa.large_string_builder_append(&lsb, "dropped")
		oa.large_string_builder_append(&lsb, "")
		oa.large_string_builder_append(&lsb, "pad1")
		full_ls, err := oa.large_string_builder_finish(&lsb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&full_ls)
		sls := oa.array_slice(full_ls, 1, 5)

		ser, s_err := oa.compute_filter(&sls, &smask)
		testing.expect_value(t, s_err, nil)
		defer oa.array_free(&ser)
		par, p_err := oa.compute_filter_parallel(&sls, &smask, 4)
		testing.expect_value(t, p_err, nil)
		defer oa.array_free(&par)

		testing.expect_value(t, par.length, 3)
		testing.expect_value(t, par.length, ser.length)
		testing.expect_value(t, oa.array_null_count(&par), 1)
		testing.expect_value(t, oa.array_get_large_string(&par, 0), "kept_one")
		testing.expect(t, oa.array_is_null(&par, 1))
		testing.expect_value(t, oa.array_get_large_string(&par, 2), "")
	}

	// 4. Large_Binary_Type
	{
		lbb := oa.large_binary_builder_make(6)
		defer oa.large_binary_builder_destroy(&lbb)
		oa.large_binary_builder_append(&lbb, []u8{0xAA})
		oa.large_binary_builder_append(&lbb, []u8{0x10, 0x20})
		oa.large_binary_builder_append_null(&lbb)
		oa.large_binary_builder_append(&lbb, []u8{0x30})
		oa.large_binary_builder_append(&lbb, []u8{})
		oa.large_binary_builder_append(&lbb, []u8{0xBB})
		full_lb, err := oa.large_binary_builder_finish(&lbb)
		testing.expect_value(t, err, nil)
		defer oa.array_free(&full_lb)
		slb := oa.array_slice(full_lb, 1, 5)

		ser, s_err := oa.compute_filter(&slb, &smask)
		testing.expect_value(t, s_err, nil)
		defer oa.array_free(&ser)
		par, p_err := oa.compute_filter_parallel(&slb, &smask, 4)
		testing.expect_value(t, p_err, nil)
		defer oa.array_free(&par)

		testing.expect_value(t, par.length, 3)
		testing.expect_value(t, par.length, ser.length)
		testing.expect_value(t, oa.array_null_count(&par), 1)
		testing.expect(t, mem.compare(oa.array_get_large_binary(&par, 0), []u8{0x10, 0x20}) == 0)
		testing.expect(t, oa.array_is_null(&par, 1))
		testing.expect_value(t, len(oa.array_get_large_binary(&par, 2)), 0)
	}
}
