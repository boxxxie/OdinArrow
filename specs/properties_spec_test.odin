package odinarrow_specs

import "core:math"
import "core:testing"
import oa "../src"

Spec_Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Spec_Rng) -> u64 {
	r.state = r.state * 6364136223846793005 + 1442695040888963407
	x := r.state
	x ~= x >> 30
	x *= 0xbf58476d1ce4e5b9
	x ~= x >> 27
	x *= 0x94d049bb133111eb
	x ~= x >> 31
	return x
}

@(test)
prop_sliced_null_aggregations_match_scalar_oracle :: proc(t: ^testing.T) {
	seed :: u64(0xCAFE_BABE_1234_5678)
	rng := Spec_Rng{state = seed}

	for iter in 0 ..< 64 {
		defer free_all(context.temp_allocator)

		n := int(rng_next(&rng) % 520) + 1
		null_mod := int(rng_next(&rng) % 11)

		oracle := make([]Maybe(i32), n, context.temp_allocator)
		mask_oracle := make([]Maybe(bool), n, context.temp_allocator)
		b := oa.builder_make(i32, n)
		defer oa.builder_destroy(&b)
		mb := oa.builder_make(bool, n)
		defer oa.builder_destroy(&mb)
		allow_mask_nulls := (iter % 3) != 0
		pass_pct := (iter % 2) == 0 ? 15 : 65

		for i in 0 ..< n {
			if int(rng_next(&rng) % 10) < null_mod {
				val := i32(int(rng_next(&rng) % 2001) - 1000)
				oracle[i] = val
				oa.builder_append(&b, val)
			} else {
				oracle[i] = nil
				oa.builder_append_null(&b)
			}

			if allow_mask_nulls && (rng_next(&rng) % 7) == 0 {
				mask_oracle[i] = nil
				oa.builder_append_null(&mb)
			} else {
				pass := int(rng_next(&rng) % 100) < pass_pct
				mask_oracle[i] = pass
				oa.builder_append(&mb, pass)
			}
		}
		full, err := oa.builder_finish(&b)
		if !testing.expectf(t, err == nil, "seed=0x%X iter=%d finish err=%v", seed, iter, err) {
			return
		}
		defer oa.array_free(&full)

		full_mask, m_err := oa.builder_finish(&mb)
		if !testing.expectf(t, m_err == nil, "seed=0x%X iter=%d mask finish err=%v", seed, iter, m_err) {
			return
		}
		defer oa.array_free(&full_mask)

		from := (iter % 5 == 0) ? 0 : int(rng_next(&rng) % u64(n))
		to := from + int(rng_next(&rng) % u64(n - from + 1))
		sl := oa.array_slice(full, from, to)
		mask_sl := oa.array_slice(full_mask, from, to)

		ref_sum: f64 = 0
		ref_lo: i32 = max(i32)
		ref_hi: i32 = min(i32)
		ref_vc := 0
		for item in oracle[from:to] {
			if v, ok := item.?; ok {
				ref_sum += f64(v)
				ref_lo = min(ref_lo, v)
				ref_hi = max(ref_hi, v)
				ref_vc += 1
			}
		}

		got_sum, got_vc := oa.compute_sum(&sl)
		if !testing.expectf(t, got_vc == ref_vc, "seed=0x%X iter=%d sum valid_count=%d want=%d", seed, iter, got_vc, ref_vc) {
			return
		}
		if !testing.expectf(t, math.abs(got_sum - ref_sum) <= 1e-6, "seed=0x%X iter=%d sum=%v want=%v", seed, iter, got_sum, ref_sum) {
			return
		}

		got_lo, got_hi, mm_vc := oa.compute_min_max(&sl)
		if !testing.expectf(t, mm_vc == ref_vc, "seed=0x%X iter=%d min_max valid_count=%d want=%d", seed, iter, mm_vc, ref_vc) {
			return
		}
		if ref_vc > 0 {
			if !testing.expectf(t, got_lo == f64(ref_lo) && got_hi == f64(ref_hi), "seed=0x%X iter=%d min_max=(%v,%v) want=(%v,%v)", seed, iter, got_lo, got_hi, f64(ref_lo), f64(ref_hi)) {
				return
			}
		}

		solo_lo, lo_vc := oa.compute_min(&sl)
		solo_hi, hi_vc := oa.compute_max(&sl)
		if !testing.expectf(t, lo_vc == ref_vc && hi_vc == ref_vc, "seed=0x%X iter=%d min/max vc=(%d,%d) want=%d", seed, iter, lo_vc, hi_vc, ref_vc) {
			return
		}
		if ref_vc > 0 {
			if !testing.expectf(t, solo_lo == f64(ref_lo) && solo_hi == f64(ref_hi), "seed=0x%X iter=%d solo min/max=(%v,%v) want=(%v,%v)", seed, iter, solo_lo, solo_hi, f64(ref_lo), f64(ref_hi)) {
				return
			}
		}

		ref_indices := make([dynamic]int, 0, to - from, context.temp_allocator)
		where_sum: f64 = 0
		where_lo: i32 = max(i32)
		where_hi: i32 = min(i32)
		where_vc := 0
		for k in from ..< to {
			if mval, mok := mask_oracle[k].?; mok && mval {
				append(&ref_indices, k - from)
				if v, vok := oracle[k].?; vok {
					where_sum += f64(v)
					where_lo = min(where_lo, v)
					where_hi = max(where_hi, v)
					where_vc += 1
				}
			}
		}

		got_cnt_where := oa.compute_count_where(&mask_sl)
		if !testing.expectf(t, got_cnt_where == len(ref_indices), "seed=0x%X iter=%d count_where=%d want=%d", seed, iter, got_cnt_where, len(ref_indices)) {
			return
		}

		w_sum, w_sum_vc := oa.compute_sum_where(&sl, &mask_sl)
		if !testing.expectf(t, w_sum_vc == where_vc && math.abs(w_sum - where_sum) <= 1e-6, "seed=0x%X iter=%d sum_where=(%v,%d) want=(%v,%d)", seed, iter, w_sum, w_sum_vc, where_sum, where_vc) {
			return
		}

		w_lo, w_hi, w_mm_vc := oa.compute_min_max_where(&sl, &mask_sl)
		w_solo_lo, w_lo_vc := oa.compute_min_where(&sl, &mask_sl)
		w_solo_hi, w_hi_vc := oa.compute_max_where(&sl, &mask_sl)
		if !testing.expectf(t, w_mm_vc == where_vc && w_lo_vc == where_vc && w_hi_vc == where_vc, "seed=0x%X iter=%d where min/max vc=(%d,%d,%d) want=%d", seed, iter, w_mm_vc, w_lo_vc, w_hi_vc, where_vc) {
			return
		}
		if where_vc > 0 {
			if !testing.expectf(t, w_lo == f64(where_lo) && w_hi == f64(where_hi) && w_solo_lo == f64(where_lo) && w_solo_hi == f64(where_hi), "seed=0x%X iter=%d where min/max=(%v,%v,%v,%v) want=(%v,%v)", seed, iter, w_lo, w_hi, w_solo_lo, w_solo_hi, f64(where_lo), f64(where_hi)) {
				return
			}
		}

		w_mean, w_mean_vc := oa.compute_mean_where(&sl, &mask_sl)
		want_mean := where_vc > 0 ? where_sum / f64(where_vc) : 0.0
		if !testing.expectf(t, w_mean_vc == where_vc && math.abs(w_mean - want_mean) <= 1e-6, "seed=0x%X iter=%d mean_where=(%v,%d) want=(%v,%d)", seed, iter, w_mean, w_mean_vc, want_mean, where_vc) {
			return
		}

		sel := oa.compute_select(&mask_sl)
		defer oa.selection_free(&sel)
		if !testing.expectf(t, oa.compute_count_selection(&sel) == len(ref_indices) && sel.length == len(ref_indices), "seed=0x%X iter=%d selection len=%d want=%d", seed, iter, sel.length, len(ref_indices)) {
			return
		}
		for want_idx, idx in ref_indices {
			if !testing.expectf(t, int(sel.indices[idx]) == want_idx, "seed=0x%X iter=%d sel[%d]=%d want=%d", seed, iter, idx, int(sel.indices[idx]), want_idx) {
				return
			}
		}

		s_sum, s_sum_vc := oa.compute_sum_selection(&sl, &sel)
		if !testing.expectf(t, s_sum_vc == where_vc && math.abs(s_sum - where_sum) <= 1e-6, "seed=0x%X iter=%d sum_selection=(%v,%d) want=(%v,%d)", seed, iter, s_sum, s_sum_vc, where_sum, where_vc) {
			return
		}

		s_lo, s_hi, s_mm_vc := oa.compute_min_max_selection(&sl, &sel)
		if !testing.expectf(t, s_mm_vc == where_vc, "seed=0x%X iter=%d min_max_selection vc=%d want=%d", seed, iter, s_mm_vc, where_vc) {
			return
		}
		if where_vc > 0 {
			if !testing.expectf(t, s_lo == f64(where_lo) && s_hi == f64(where_hi), "seed=0x%X iter=%d min_max_selection=(%v,%v) want=(%v,%v)", seed, iter, s_lo, s_hi, f64(where_lo), f64(where_hi)) {
				return
			}
		}

		// Chained f64 scalar selection + refinement: sl > -200.0 AND sl <= 400.0
		sel_cmp := oa.compute_select_compare(&sl, .Gt, -200.0)
		defer oa.selection_free(&sel_cmp)
		sel_ref := oa.selection_refine_compare(&sel_cmp, &sl, .Le, 400.0)
		defer oa.selection_free(&sel_ref)

		chained_sum, chained_vc := oa.compute_sum_selection(&sl, &sel_ref)
		ref_chained_sum: f64 = 0
		ref_chained_vc := 0
		for item in oracle[from:to] {
			if v, ok := item.?; ok && f64(v) > -200.0 && f64(v) <= 400.0 {
				ref_chained_sum += f64(v)
				ref_chained_vc += 1
			}
		}
		if !testing.expectf(
			t,
			chained_vc == ref_chained_vc && math.abs(chained_sum - ref_chained_sum) <= 1e-6,
			"seed=0x%X iter=%d chained f64 selection sum=(%v,%d) want=(%v,%d)",
			seed,
			iter,
			chained_sum,
			chained_vc,
			ref_chained_sum,
			ref_chained_vc,
		) {
			return
		}
	}
}
