package skadi_specs

import "core:math"
import "core:slice"
import "core:testing"
import oa "../skadi"

@(test)
prop_filter_and_take_match_oracle :: proc(t: ^testing.T) {
	seed :: u64(0x9E37_79B9_7F4A_7C15)
	rng := Spec_Rng{state = seed}

	for iter in 0 ..< 48 {
		defer free_all(context.temp_allocator)

		n := int(rng_next(&rng) % 300) + 8
		pass_pct := int(rng_next(&rng) % 2) == 0 ? 12 : 65

		src_oracle := make([]Maybe(i32), n, context.temp_allocator)
		mask_oracle := make([]Maybe(bool), n, context.temp_allocator)
		bin_oracle := make([]Maybe([]u8), n, context.temp_allocator)

		ib := oa.builder_make(i32, n)
		defer oa.builder_destroy(&ib)
		mb := oa.builder_make(bool, n)
		defer oa.builder_destroy(&mb)
		bb := oa.binary_builder_make(n)
		defer oa.binary_builder_destroy(&bb)

		for i in 0 ..< n {
			if rng_next(&rng) % 7 == 0 {
				src_oracle[i] = nil
				oa.builder_append_null(&ib)
			} else {
				v := i32(int(rng_next(&rng) % 1000) - 500)
				src_oracle[i] = v
				oa.builder_append(&ib, v)
			}

			if rng_next(&rng) % 11 == 0 {
				mask_oracle[i] = nil
				oa.builder_append_null(&mb)
			} else {
				p := int(rng_next(&rng) % 100) < pass_pct
				mask_oracle[i] = p
				oa.builder_append(&mb, p)
			}

			if rng_next(&rng) % 9 == 0 {
				bin_oracle[i] = nil
				oa.binary_builder_append_null(&bb)
			} else {
				raw := make([]u8, 3, context.temp_allocator)
				raw[0] = u8(i)
				raw[1] = u8(rng_next(&rng))
				raw[2] = 0xAA
				bin_oracle[i] = raw
				oa.binary_builder_append(&bb, raw)
			}
		}

		arr, ib_err := oa.builder_finish(&ib)
		if !testing.expectf(t, ib_err == nil, "seed=0x%X iter=%d ib finish err=%v", seed, iter, ib_err) {
			return
		}
		defer oa.array_free(&arr)

		mask, mb_err := oa.builder_finish(&mb)
		if !testing.expectf(t, mb_err == nil, "seed=0x%X iter=%d mb finish err=%v", seed, iter, mb_err) {
			return
		}
		defer oa.array_free(&mask)

		barr, bb_err := oa.binary_builder_finish(&bb)
		if !testing.expectf(t, bb_err == nil, "seed=0x%X iter=%d bb finish err=%v", seed, iter, bb_err) {
			return
		}
		defer oa.array_free(&barr)

		from := int(rng_next(&rng) % u64(n / 2))
		to := from + int(rng_next(&rng) % u64(n - from)) + 1

		arr_sl := oa.array_slice(arr, from, to)
		mask_sl := oa.array_slice(mask, from, to)
		barr_sl := oa.array_slice(barr, from, to)

		expected := make([dynamic]Maybe(i32), 0, to - from, context.temp_allocator)
		expected_bin := make([dynamic]Maybe([]u8), 0, to - from, context.temp_allocator)
		for i in from ..< to {
			if mval, mok := mask_oracle[i].?; mok && mval {
				append(&expected, src_oracle[i])
				append(&expected_bin, bin_oracle[i])
			}
		}

		filt, f_err := oa.compute_filter(&arr_sl, &mask_sl)
		if !testing.expectf(t, f_err == nil, "seed=0x%X iter=%d filter err=%v", seed, iter, f_err) {
			return
		}
		defer oa.array_free(&filt)

		if !testing.expectf(t, filt.length == len(expected), "seed=0x%X iter=%d filter len=%d want=%d", seed, iter, filt.length, len(expected)) {
			return
		}
		for want, k in expected {
			if wv, wok := want.?; wok {
				if !testing.expectf(t, oa.array_is_valid(&filt, k), "seed=0x%X iter=%d idx=%d: expected valid filtered element", seed, iter, k) {
					return
				}
				if !testing.expectf(t, oa.array_get(&filt, k, i32) == wv, "seed=0x%X iter=%d idx=%d: filter val mismatch", seed, iter, k) {
					return
				}
			} else {
				if !testing.expectf(t, oa.array_is_null(&filt, k), "seed=0x%X iter=%d idx=%d: expected null filtered element", seed, iter, k) {
					return
				}
			}
		}

		bfilt, bf_err := oa.compute_filter(&barr_sl, &mask_sl)
		if !testing.expectf(t, bf_err == nil, "seed=0x%X iter=%d binary filter err=%v", seed, iter, bf_err) {
			return
		}
		defer oa.array_free(&bfilt)

		if !testing.expectf(t, bfilt.length == len(expected_bin), "seed=0x%X iter=%d bfilt len=%d want=%d", seed, iter, bfilt.length, len(expected_bin)) {
			return
		}
		for want_b, k in expected_bin {
			if wb, bok := want_b.?; bok {
				if !testing.expectf(t, oa.array_is_valid(&bfilt, k), "seed=0x%X iter=%d idx=%d: expected valid filtered binary", seed, iter, k) {
					return
				}
				if !testing.expectf(t, slice.equal(oa.array_get_binary(&bfilt, k), wb), "seed=0x%X iter=%d idx=%d: binary filter mismatch", seed, iter, k) {
					return
				}
			} else {
				if !testing.expectf(t, oa.array_is_null(&bfilt, k), "seed=0x%X iter=%d idx=%d: expected null filtered binary", seed, iter, k) {
					return
				}
			}
		}

		take_k := 12
		idx_b := oa.builder_make(i64, take_k + 4)
		defer oa.builder_destroy(&idx_b)
		idx_oracle := make([]Maybe(int), take_k + 4, context.temp_allocator)
		for k in 0 ..< take_k + 4 {
			if k % 5 == 0 {
				oa.builder_append_null(&idx_b)
				idx_oracle[k] = nil
			} else {
				target := int(rng_next(&rng) % u64(arr_sl.length))
				idx_oracle[k] = target
				oa.builder_append(&idx_b, i64(target))
			}
		}
		idx_full, idx_err := oa.builder_finish(&idx_b)
		if !testing.expectf(t, idx_err == nil, "seed=0x%X iter=%d idx finish err=%v", seed, iter, idx_err) {
			return
		}
		defer oa.array_free(&idx_full)
		idx_sl := oa.array_slice(idx_full, 2, 2 + take_k)

		taken, t_err := oa.compute_take(&arr_sl, &idx_sl)
		if !testing.expectf(t, t_err == nil, "seed=0x%X iter=%d take err=%v", seed, iter, t_err) {
			return
		}
		defer oa.array_free(&taken)

		btaken, bt_err := oa.compute_take(&barr_sl, &idx_sl)
		if !testing.expectf(t, bt_err == nil, "seed=0x%X iter=%d binary take err=%v", seed, iter, bt_err) {
			return
		}
		defer oa.array_free(&btaken)

		if !testing.expectf(t, taken.length == take_k && btaken.length == take_k, "seed=0x%X iter=%d take length mismatch", seed, iter) {
			return
		}
		for k in 0 ..< take_k {
			if target, ok := idx_oracle[2 + k].?; ok {
				src_pos := from + target
				if wv, wok := src_oracle[src_pos].?; wok {
					if !testing.expectf(t, oa.array_is_valid(&taken, k), "seed=0x%X iter=%d idx=%d: take valid mismatch", seed, iter, k) {
						return
					}
					if !testing.expectf(t, oa.array_get(&taken, k, i32) == wv, "seed=0x%X iter=%d idx=%d: take val mismatch", seed, iter, k) {
						return
					}
				} else {
					if !testing.expectf(t, oa.array_is_null(&taken, k), "seed=0x%X iter=%d idx=%d: take null mismatch", seed, iter, k) {
						return
					}
				}
				if wb, bok := bin_oracle[src_pos].?; bok {
					if !testing.expectf(t, oa.array_is_valid(&btaken, k), "seed=0x%X iter=%d idx=%d: binary take valid mismatch", seed, iter, k) {
						return
					}
					if !testing.expectf(t, slice.equal(oa.array_get_binary(&btaken, k), wb), "seed=0x%X iter=%d idx=%d: binary take mismatch", seed, iter, k) {
						return
					}
				} else {
					if !testing.expectf(t, oa.array_is_null(&btaken, k), "seed=0x%X iter=%d idx=%d: binary take null mismatch", seed, iter, k) {
						return
					}
				}
			} else {
				if !testing.expectf(t, oa.array_is_null(&taken, k), "seed=0x%X iter=%d idx=%d: null index must produce null primitive element", seed, iter, k) {
					return
				}
				if !testing.expectf(t, oa.array_is_null(&btaken, k), "seed=0x%X iter=%d idx=%d: null index must produce null binary element", seed, iter, k) {
					return
				}
			}
		}
	}
}

@(test)
prop_sort_indices_stability_and_types :: proc(t: ^testing.T) {
	seed :: u64(0x517C_C1B7_2722_0A95)
	rng := Spec_Rng{state = seed}

	for iter in 0 ..< 32 {
		defer free_all(context.temp_allocator)

		n := int(rng_next(&rng) % 150) + 5
		fb := oa.builder_make(f64, n)
		defer oa.builder_destroy(&fb)
		ub := oa.builder_make(u64, n)
		defer oa.builder_destroy(&ub)

		for i in 0 ..< n {
			v := f64(int(rng_next(&rng) % 11) - 5) * 0.5
			if rng_next(&rng) % 6 == 0 {
				oa.builder_append_null(&fb)
			} else {
				oa.builder_append(&fb, v)
			}

			u_val: u64
			switch i % 5 {
			case 0:
				u_val = (u64(1) << 63) | (rng_next(&rng) % 16)
			case 1:
				u_val = rng_next(&rng) % 8
			case 2:
				u_val = 0xFFFF_0000_1234_5678
			case 3:
				u_val = rng_next(&rng)
			case:
				u_val = (u64(1) << 63) | rng_next(&rng)
			}
			oa.builder_append(&ub, u_val)
		}

		farr, fb_err := oa.builder_finish(&fb)
		if !testing.expectf(t, fb_err == nil, "seed=0x%X iter=%d fb finish err=%v", seed, iter, fb_err) {
			return
		}
		defer oa.array_free(&farr)

		uarr, ub_err := oa.builder_finish(&ub)
		if !testing.expectf(t, ub_err == nil, "seed=0x%X iter=%d ub finish err=%v", seed, iter, ub_err) {
			return
		}
		defer oa.array_free(&uarr)

		f_sl := oa.array_slice(farr, 1, n - 1)
		f_idx, f_err := oa.compute_sort_indices(&f_sl)
		if !testing.expectf(t, f_err == nil, "seed=0x%X iter=%d f64 sort err=%v", seed, iter, f_err) {
			return
		}
		defer oa.array_free(&f_idx)

		if !testing.expectf(t, f_idx.length == f_sl.length, "seed=0x%X iter=%d f_idx len mismatch", seed, iter) {
			return
		}
		seen_f := make([]bool, f_sl.length, context.temp_allocator)
		for k in 0 ..< f_idx.length {
			idx := int(oa.array_get(&f_idx, k, i64))
			if !testing.expectf(t, idx >= 0 && idx < f_sl.length, "seed=0x%X iter=%d: f64 index %d out of bounds [0, %d)", seed, iter, idx, f_sl.length) {
				return
			}
			if !testing.expectf(t, !seen_f[idx], "seed=0x%X iter=%d: duplicate f64 index %d", seed, iter, idx) {
				return
			}
			seen_f[idx] = true
		}
		for k in 1 ..< f_idx.length {
			prev_i := int(oa.array_get(&f_idx, k - 1, i64))
			curr_i := int(oa.array_get(&f_idx, k, i64))
			pn := oa.array_is_null(&f_sl, prev_i)
			cn := oa.array_is_null(&f_sl, curr_i)
			if pn && cn {
				if !testing.expectf(t, prev_i < curr_i, "seed=0x%X iter=%d: null ties must preserve ascending order", seed, iter) {
					return
				}
			} else if pn {
				testing.expectf(t, false, "seed=0x%X iter=%d: null ordered before non-null", seed, iter)
				return
			} else if !cn {
				pv := oa.array_get(&f_sl, prev_i, f64)
				cv := oa.array_get(&f_sl, curr_i, f64)
				if !testing.expectf(t, pv < cv || (pv == cv && prev_i < curr_i), "seed=0x%X iter=%d: float sort unstable or out of order", seed, iter) {
					return
				}
			}
		}

		u_sl := oa.array_slice(uarr, 1, n - 1)
		u_idx, u_err := oa.compute_sort_indices(&u_sl)
		if !testing.expectf(t, u_err == nil, "seed=0x%X iter=%d u64 sort err=%v", seed, iter, u_err) {
			return
		}
		defer oa.array_free(&u_idx)

		if !testing.expectf(t, u_idx.length == u_sl.length, "seed=0x%X iter=%d u_idx len mismatch", seed, iter) {
			return
		}
		seen_u := make([]bool, u_sl.length, context.temp_allocator)
		for k in 0 ..< u_idx.length {
			idx := int(oa.array_get(&u_idx, k, i64))
			if !testing.expectf(t, idx >= 0 && idx < u_sl.length, "seed=0x%X iter=%d: u64 index %d out of bounds [0, %d)", seed, iter, idx, u_sl.length) {
				return
			}
			if !testing.expectf(t, !seen_u[idx], "seed=0x%X iter=%d: duplicate u64 index %d", seed, iter, idx) {
				return
			}
			seen_u[idx] = true
		}
		for k in 1 ..< u_idx.length {
			pi := int(oa.array_get(&u_idx, k - 1, i64))
			ci := int(oa.array_get(&u_idx, k, i64))
			pv := oa.array_get(&u_sl, pi, u64)
			cv := oa.array_get(&u_sl, ci, u64)
			if !testing.expectf(t, pv < cv || (pv == cv && pi < ci), "seed=0x%X iter=%d: u64 radix sort unstable or out of order", seed, iter) {
				return
			}
		}
	}
}

@(test)
prop_arithmetic_and_cast_preserve_values_and_nulls :: proc(t: ^testing.T) {
	seed :: u64(0x243F_6A88_85A3_08D3)
	rng := Spec_Rng{state = seed}

	for iter in 0 ..< 32 {
		defer free_all(context.temp_allocator)

		n := 120
		lb := oa.builder_make(i32, n)
		defer oa.builder_destroy(&lb)
		rb := oa.builder_make(i32, n)
		defer oa.builder_destroy(&rb)

		l_or := make([]Maybe(i32), n, context.temp_allocator)
		r_or := make([]Maybe(i32), n, context.temp_allocator)

		for i in 0 ..< n {
			if rng_next(&rng) % 8 == 0 {
				l_or[i] = nil
				oa.builder_append_null(&lb)
			} else {
				lv := i32(int(rng_next(&rng) % 200) - 100)
				l_or[i] = lv
				oa.builder_append(&lb, lv)
			}

			if rng_next(&rng) % 9 == 0 {
				r_or[i] = nil
				oa.builder_append_null(&rb)
			} else {
				// Bounded non-zero operand so Add/Sub/Mul stay free of i32 overflow
				rv := i32(int(rng_next(&rng) % 20) + 1)
				r_or[i] = rv
				oa.builder_append(&rb, rv)
			}
		}

		la, lb_err := oa.builder_finish(&lb)
		if !testing.expectf(t, lb_err == nil, "seed=0x%X iter=%d lb finish err=%v", seed, iter, lb_err) {
			return
		}
		defer oa.array_free(&la)

		ra, rb_err := oa.builder_finish(&rb)
		if !testing.expectf(t, rb_err == nil, "seed=0x%X iter=%d rb finish err=%v", seed, iter, rb_err) {
			return
		}
		defer oa.array_free(&ra)

		l_sl := oa.array_slice(la, 3, n - 5)
		r_sl := oa.array_slice(ra, 3, n - 5)

		diff, sub_err := oa.compute_sub(&l_sl, &r_sl)
		if !testing.expectf(t, sub_err == nil, "seed=0x%X iter=%d compute_sub err=%v", seed, iter, sub_err) {
			return
		}
		defer oa.array_free(&diff)

		prod, mul_err := oa.compute_mul(&l_sl, &r_sl)
		if !testing.expectf(t, mul_err == nil, "seed=0x%X iter=%d compute_mul err=%v", seed, iter, mul_err) {
			return
		}
		defer oa.array_free(&prod)

		casted, cast_err := oa.compute_cast(&l_sl, oa.Float64_Type{})
		if !testing.expectf(t, cast_err == nil, "seed=0x%X iter=%d compute_cast err=%v", seed, iter, cast_err) {
			return
		}
		defer oa.array_free(&casted)

		for k in 0 ..< l_sl.length {
			lv, lok := l_or[3 + k].?
			rv, rok := r_or[3 + k].?
			if lok {
				if !testing.expectf(t, oa.array_is_valid(&casted, k), "seed=0x%X iter=%d idx=%d: cast lost validity", seed, iter, k) {
					return
				}
				if !testing.expectf(t, oa.array_get(&casted, k, f64) == f64(lv), "seed=0x%X iter=%d idx=%d: cast value mismatch", seed, iter, k) {
					return
				}
			} else {
				if !testing.expectf(t, oa.array_is_null(&casted, k), "seed=0x%X iter=%d idx=%d: cast lost null", seed, iter, k) {
					return
				}
			}

			if lok && rok {
				if !testing.expectf(t, oa.array_get(&diff, k, i32) == lv - rv, "seed=0x%X iter=%d idx=%d: sub mismatch", seed, iter, k) {
					return
				}
				if !testing.expectf(t, oa.array_get(&prod, k, i32) == lv * rv, "seed=0x%X iter=%d idx=%d: mul mismatch", seed, iter, k) {
					return
				}
			} else {
				if !testing.expectf(t, oa.array_is_null(&diff, k), "seed=0x%X iter=%d idx=%d: sub null propagation", seed, iter, k) {
					return
				}
				if !testing.expectf(t, oa.array_is_null(&prod, k), "seed=0x%X iter=%d idx=%d: mul null propagation", seed, iter, k) {
					return
				}
			}
		}
	}
}

@(test)
prop_parallel_kernels_agree_with_serial :: proc(t: ^testing.T) {
	n :: oa.PARALLEL_MIN_LENGTH + 7_777
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)

	for i in 0 ..< n {
		if i % 61 == 0 {
			oa.builder_append_null(&b)
		} else {
			oa.builder_append(&b, i32((i * 17) % 997) - 400)
		}
	}
	full, f_err := oa.builder_finish(&b)
	testing.expect_value(t, f_err, nil)
	if f_err != nil {
		return
	}
	defer oa.array_free(&full)

	sl := oa.array_slice(full, 5, n - 2)

	s_lo, s_hi, s_vc := oa.compute_min_max(&sl)
	p_lo, p_hi, p_vc := oa.compute_min_max_parallel(&sl, 4)
	testing.expect_value(t, p_vc, s_vc)
	testing.expect_value(t, p_lo, s_lo)
	testing.expect_value(t, p_hi, s_hi)

	s_mean, sm_vc := oa.compute_mean(&sl)
	p_mean, pm_vc := oa.compute_mean_parallel(&sl, 4)
	testing.expect_value(t, pm_vc, sm_vc)
	testing.expectf(t, math.abs(p_mean - s_mean) <= 1e-9, "parallel mean mismatch: got %v, want %v", p_mean, s_mean)
}

@(test)
prop_encoded_arrays_match_plain_oracle :: proc(t: ^testing.T) {
	rng := Spec_Rng{state = 0x1319_8A2E_0370_7344}
	defer free_all(context.temp_allocator)

	n :: 256
	ib := oa.builder_make(i32, n)
	defer oa.builder_destroy(&ib)

	cur: i32 = 10
	for i in 0 ..< n {
		if i % 7 == 0 {
			cur = i32(int(rng_next(&rng) % 8) - 4)
		}
		oa.builder_append(&ib, cur)
	}
	full, f_err := oa.builder_finish(&ib)
	testing.expect_value(t, f_err, nil)
	if f_err != nil {
		return
	}
	defer oa.array_free(&full)

	sl := oa.array_slice(full, 9, n - 5)
	plain_sum, _ := oa.compute_sum(&sl)
	plain_lo, plain_hi, _ := oa.compute_min_max(&sl)

	rle := oa.rle_encode(&sl, i32)
	defer oa.rle_free(&rle)
	testing.expectf(t, math.abs(oa.rle_sum(&rle) - plain_sum) <= 1e-9, "rle_sum mismatch: got %v, want %v", oa.rle_sum(&rle), plain_sum)
	rlo, rhi, rok := oa.rle_min_max(&rle)
	testing.expect(t, rok)
	testing.expect_value(t, rlo, plain_lo)
	testing.expect_value(t, rhi, plain_hi)

	da := oa.dict_encode(&sl, i32)
	defer oa.dict_free(&da)
	testing.expectf(t, math.abs(oa.dict_sum(&da) - plain_sum) <= 1e-9, "dict_sum mismatch: got %v, want %v", oa.dict_sum(&da), plain_sum)
	dlo, dhi, dok := oa.dict_min_max(&da)
	testing.expect(t, dok)
	testing.expect_value(t, dlo, plain_lo)
	testing.expect_value(t, dhi, plain_hi)

	samples := []string{
		"",
		"ab",
		"ab\x00c",
		"ab\x00d",
		"exactly_12_b",
		"thirteen_byte",
		"thirteen_bytf",
		"long_prefix_tie_alpha_1",
		"long_prefix_tie_alpha_2",
	}
	ub := oa.umbra_builder_make(len(samples))
	defer oa.umbra_builder_destroy(&ub)
	for s in samples {
		oa.umbra_append(&ub, s)
	}
	ua := oa.umbra_builder_finish(&ub)
	defer oa.umbra_free(&ua)

	ref := make([]string, len(samples), context.temp_allocator)
	copy(ref, samples)
	slice.sort(ref)

	uidx := oa.umbra_sort_indices(&ua)
	defer oa.array_free(&uidx)
	for k in 0 ..< len(samples) {
		got := oa.umbra_get(&ua, int(oa.array_get(&uidx, k, i64)))
		testing.expect_value(t, got, ref[k])
	}
}

@(private="file")
_prop_cmp_ordered :: proc(a, b: $T, op: oa.Compare_Op) -> bool {
	switch op {
	case .Eq: return a == b
	case .Ne: return a != b
	case .Lt: return a < b
	case .Le: return a <= b
	case .Gt: return a > b
	case .Ge: return a >= b
	}
	return false
}

// Property: Exact 64-bit (i64/u64) and cross-type f64 scalar comparisons, selections, refinement, and fused agg
// match an exact elementwise reference oracle across random slices, null patterns, and 64-bit boundary scalars.
@(test)
prop_cross_type_comparisons_match_exact_oracle :: proc(t: ^testing.T) {
	BASE_I64 :: i64(9_007_199_254_740_992)
	BASE_U64 :: u64(9_007_199_254_740_992)
	ops := [6]oa.Compare_Op{.Eq, .Ne, .Lt, .Le, .Gt, .Ge}

	seeds := []u64{0x1357_9BDF_2468_ACE0, 0x9E37_79B9_7F4A_7C15, 0xD1B5_4A32_D192_ED03}
	for seed in seeds {
		rng := Spec_Rng{state = seed}
		for iter in 0 ..< 25 {
			defer free_all(context.temp_allocator)

			n := int(rng_next(&rng) % 72) + 8
			from := int(rng_next(&rng) % u64(n / 2))
			to := from + int(rng_next(&rng) % u64(n - from)) + 1

			// 1. Exact i64 column + auxiliary predicate + i64 values
			bi64 := oa.builder_make(i64, n)
			defer oa.builder_destroy(&bi64)
			baux := oa.builder_make(i64, n)
			defer oa.builder_destroy(&baux)
			bval := oa.builder_make(i64, n)
			defer oa.builder_destroy(&bval)

			i64_valid := make([]bool, n, context.temp_allocator)
			i64_vals  := make([]i64, n, context.temp_allocator)
			aux_valid := make([]bool, n, context.temp_allocator)
			aux_vals  := make([]i64, n, context.temp_allocator)
			val_valid := make([]bool, n, context.temp_allocator)
			val_vals  := make([]i64, n, context.temp_allocator)

			i64_choices := [7]i64{min(i64), BASE_I64, BASE_I64 + 1, BASE_I64 + 2, -1, 0, max(i64)}
			for i in 0 ..< n {
				if rng_next(&rng) % 6 == 0 {
					oa.builder_append_null(&bi64)
				} else {
					v := (rng_next(&rng) % 3 == 0) ? i64(i64(rng_next(&rng) % 20) - 10) : i64_choices[int(rng_next(&rng) % 7)]
					oa.builder_append(&bi64, v)
					i64_valid[i] = true
					i64_vals[i] = v
				}
				if rng_next(&rng) % 7 == 0 {
					oa.builder_append_null(&baux)
				} else {
					av := i64(int(rng_next(&rng) % 41) - 20)
					oa.builder_append(&baux, av)
					aux_valid[i] = true
					aux_vals[i] = av
				}
				if rng_next(&rng) % 8 == 0 {
					oa.builder_append_null(&bval)
				} else {
					iv := i64(int(rng_next(&rng) % 31) - 15)
					oa.builder_append(&bval, iv)
					val_valid[i] = true
					val_vals[i] = iv
				}
			}

			arr_i64, i64_err := oa.builder_finish(&bi64)
			if !testing.expectf(t, i64_err == nil, "seed=0x%X iter=%d bi64 finish err=%v", seed, iter, i64_err) {
				return
			}
			defer oa.array_free(&arr_i64)

			arr_aux, aux_err := oa.builder_finish(&baux)
			if !testing.expectf(t, aux_err == nil, "seed=0x%X iter=%d baux finish err=%v", seed, iter, aux_err) {
				return
			}
			defer oa.array_free(&arr_aux)

			arr_val, val_err := oa.builder_finish(&bval)
			if !testing.expectf(t, val_err == nil, "seed=0x%X iter=%d bval finish err=%v", seed, iter, val_err) {
				return
			}
			defer oa.array_free(&arr_val)

			sl_i64 := oa.array_slice(arr_i64, from, to)
			sl_aux := oa.array_slice(arr_aux, from, to)
			sl_val := oa.array_slice(arr_val, from, to)

			s64 := i64_choices[iter % 7]
			for op in ops {
				mask, m_err := oa.compute_compare_i64(&sl_i64, op, s64)
				if !testing.expectf(t, m_err == nil, "seed=0x%X iter=%d op=%v i64 cmp err=%v", seed, iter, op, m_err) {
					return
				}
				defer oa.array_free(&mask)
				if !testing.expectf(t, mask.buffers[0].data == nil, "seed=0x%X iter=%d op=%v i64 mask must be dense", seed, iter, op) {
					return
				}

				sel := oa.compute_select_compare_i64(&sl_i64, op, s64)
				defer oa.selection_free(&sel)

				refined := oa.selection_refine_compare_i64(&sel, &sl_aux, .Ge, 0)
				defer oa.selection_free(&refined)

				agg := oa.compute_agg_where_compare_i64(&sl_val, &sl_i64, op, s64)

				ref_sel := make([dynamic]int, 0, to - from, context.temp_allocator)
				ref_ref := make([dynamic]int, 0, to - from, context.temp_allocator)
				ref_cnt := 0
				ref_sum := 0.0
				ref_min := 0.0
				ref_max := 0.0

				for row in 0 ..< (to - from) {
					orig := from + row
					if !i64_valid[orig] {
						if !testing.expectf(t, !oa.array_get(&mask, row, bool), "seed=0x%X iter=%d op=%v row=%d null must be false", seed, iter, op, row) {
							return
						}
						continue
					}
					want := _prop_cmp_ordered(i64_vals[orig], s64, op)
					if !testing.expectf(t, oa.array_get(&mask, row, bool) == want, "seed=0x%X iter=%d op=%v row=%d i64 mask mismatch", seed, iter, op, row) {
						return
					}
					if want {
						append(&ref_sel, row)
						if aux_valid[orig] && aux_vals[orig] >= 0 {
							append(&ref_ref, row)
						}
						if val_valid[orig] {
							fv := f64(val_vals[orig])
							if ref_cnt == 0 {
								ref_min = fv
								ref_max = fv
							} else {
								if fv < ref_min { ref_min = fv }
								if fv > ref_max { ref_max = fv }
							}
							ref_sum += fv
							ref_cnt += 1
						}
					}
				}

				if !testing.expectf(t, sel.length == len(ref_sel), "seed=0x%X iter=%d op=%v sel len=%d want=%d", seed, iter, op, sel.length, len(ref_sel)) {
					return
				}
				for want_idx, k in ref_sel {
					if !testing.expectf(t, int(sel.indices[k]) == want_idx, "seed=0x%X iter=%d op=%v sel[%d]=%d want=%d", seed, iter, op, k, int(sel.indices[k]), want_idx) {
						return
					}
				}
				if !testing.expectf(t, refined.length == len(ref_ref), "seed=0x%X iter=%d op=%v refined len=%d want=%d", seed, iter, op, refined.length, len(ref_ref)) {
					return
				}
				for want_idx, k in ref_ref {
					if !testing.expectf(t, int(refined.indices[k]) == want_idx, "seed=0x%X iter=%d op=%v refined[%d]=%d want=%d", seed, iter, op, k, int(refined.indices[k]), want_idx) {
						return
					}
				}
				if !testing.expectf(t, agg.count == ref_cnt, "seed=0x%X iter=%d op=%v agg count=%d want=%d", seed, iter, op, agg.count, ref_cnt) {
					return
				}
				if ref_cnt > 0 {
					if !testing.expectf(
						t,
						agg.valid && math.abs(agg.sum - ref_sum) <= 1e-9 && math.abs(agg.min_val - ref_min) <= 1e-9 && math.abs(agg.max_val - ref_max) <= 1e-9,
						"seed=0x%X iter=%d op=%v fused i64 agg=%v want=(sum=%v,min=%v,max=%v)",
						seed,
						iter,
						op,
						agg,
						ref_sum,
						ref_min,
						ref_max,
					) {
						return
					}
				} else {
					if !testing.expectf(t, !agg.valid, "seed=0x%X iter=%d op=%v empty fused i64 agg must be invalid", seed, iter, op) {
						return
					}
				}
			}

			// 2. Exact u64 column
			bu64 := oa.builder_make(u64, n)
			defer oa.builder_destroy(&bu64)
			u64_valid := make([]bool, n, context.temp_allocator)
			u64_vals  := make([]u64, n, context.temp_allocator)
			u64_choices := [7]u64{0, 1, BASE_U64, BASE_U64 + 1, BASE_U64 + 2, max(u64) - 1, max(u64)}

			for i in 0 ..< n {
				if rng_next(&rng) % 6 == 0 {
					oa.builder_append_null(&bu64)
				} else {
					v := (rng_next(&rng) % 3 == 0) ? rng_next(&rng) : u64_choices[int(rng_next(&rng) % 7)]
					oa.builder_append(&bu64, v)
					u64_valid[i] = true
					u64_vals[i] = v
				}
			}
			arr_u64, u64_err := oa.builder_finish(&bu64)
			if !testing.expectf(t, u64_err == nil, "seed=0x%X iter=%d bu64 finish err=%v", seed, iter, u64_err) {
				return
			}
			defer oa.array_free(&arr_u64)
			sl_u64 := oa.array_slice(arr_u64, from, to)

			su64 := u64_choices[iter % 7]
			for op in ops {
				mask, m_err := oa.compute_compare_u64(&sl_u64, op, su64)
				if !testing.expectf(t, m_err == nil, "seed=0x%X iter=%d op=%v u64 cmp err=%v", seed, iter, op, m_err) {
					return
				}
				defer oa.array_free(&mask)
				if !testing.expectf(t, mask.buffers[0].data == nil, "seed=0x%X iter=%d op=%v u64 mask must be dense", seed, iter, op) {
					return
				}
				for row in 0 ..< (to - from) {
					orig := from + row
					want := u64_valid[orig] ? _prop_cmp_ordered(u64_vals[orig], su64, op) : false
					if !testing.expectf(t, oa.array_get(&mask, row, bool) == want, "seed=0x%X iter=%d op=%v row=%d u64 mask mismatch", seed, iter, op, row) {
						return
					}
				}
			}

			// 3. Cross-type f64 scalar comparison against u8
			bu8 := oa.builder_make(u8, n)
			defer oa.builder_destroy(&bu8)
			u8_valid := make([]bool, n, context.temp_allocator)
			u8_vals  := make([]u8, n, context.temp_allocator)
			for i in 0 ..< n {
				if rng_next(&rng) % 5 == 0 {
					oa.builder_append_null(&bu8)
				} else {
					v := u8(rng_next(&rng) & 0xFF)
					oa.builder_append(&bu8, v)
					u8_valid[i] = true
					u8_vals[i] = v
				}
			}
			arr_u8, u8_err := oa.builder_finish(&bu8)
			if !testing.expectf(t, u8_err == nil, "seed=0x%X iter=%d bu8 finish err=%v", seed, iter, u8_err) {
				return
			}
			defer oa.array_free(&arr_u8)
			sl_u8 := oa.array_slice(arr_u8, from, to)

			u8_scalars := [5]f64{-1.5, 0.0, 127.5, 255.0, 300.0}
			sf64 := u8_scalars[iter % 5]
			for op in ops {
				mask, m_err := oa.compute_compare(&sl_u8, op, sf64)
				if !testing.expectf(t, m_err == nil, "seed=0x%X iter=%d op=%v u8 cmp err=%v", seed, iter, op, m_err) {
					return
				}
				defer oa.array_free(&mask)
				if !testing.expectf(t, mask.buffers[0].data == nil, "seed=0x%X iter=%d op=%v u8 mask must be dense", seed, iter, op) {
					return
				}
				for row in 0 ..< (to - from) {
					orig := from + row
					want := u8_valid[orig] ? _prop_cmp_ordered(f64(u8_vals[orig]), sf64, op) : false
					if !testing.expectf(t, oa.array_get(&mask, row, bool) == want, "seed=0x%X iter=%d op=%v row=%d u8 mask mismatch", seed, iter, op, row) {
						return
					}
				}
			}
		}
	}
}
