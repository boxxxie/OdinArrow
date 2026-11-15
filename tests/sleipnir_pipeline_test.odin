package skadi_tests

import "core:math"
import "core:mem"
import "core:testing"
import bs "../benchmarks/odin/stats"
import oa "../skadi"
import pipeline "../skadi/pipeline"

@(test)
test_sleipnir_pipeline_sel_2pred_parity_and_zero_alloc :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_base := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_base
		check_no_leaks(t, &track)
	}

	mp: pipeline.Morsel_Pipeline
	ok := pipeline.pipeline_init(&mp, 0, context.allocator)
	testing.expect(t, ok, "pipeline_init must succeed")
	defer pipeline.pipeline_destroy(&mp)

	n :: 100_000
	ba := oa.builder_make(f64, n)
	defer oa.builder_destroy(&ba)
	bb := oa.builder_make(f64, n)
	defer oa.builder_destroy(&bb)

	for i in 0..<n {
		if i % 41 == 0 {
			oa.builder_append_null(&ba)
		} else {
			oa.builder_append(&ba, f64(i % 10_000) * 0.5)
		}
		if i % 61 == 0 {
			oa.builder_append_null(&bb)
		} else {
			oa.builder_append(&bb, f64((i * 7 + 13) % 10_000) * 0.5)
		}
	}
	col_a, _ := oa.builder_finish(&ba)
	defer oa.array_free(&col_a)
	col_b, _ := oa.builder_finish(&bb)
	defer oa.array_free(&col_b)

	// Reference result
	ref_sum := f64(0)
	ref_vc := 0
	for i in 0..<n {
		if oa.array_is_null(&col_a, i) || oa.array_is_null(&col_b, i) { continue }
		va := oa.array_get(&col_a, i, f64)
		vb := oa.array_get(&col_b, i, f64)
		if va > 2500.0 && vb > 2500.0 {
			ref_sum += va
			ref_vc += 1
		}
	}

	// Warmup once
	_, _, w_ok := pipeline.pipeline_sel_2pred_sum_f64(&mp, &col_a, .Gt, 2500.0, &col_b, .Gt, 2500.0)
	testing.expect(t, w_ok)

	// Measure steady-state allocations on context.allocator
	state: bs.Bench_Alloc_State
	cnt := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &state,
	}
	saved_alloc := context.allocator
	context.allocator = bs.counting_allocator(&cnt)
	p_sum, p_vc, p_ok := pipeline.pipeline_sel_2pred_sum_f64(&mp, &col_a, .Gt, 2500.0, &col_b, .Gt, 2500.0)
	context.allocator = saved_alloc

	testing.expect(t, p_ok)
	testing.expect_value(t, state.alloc_count, u64(0))
	testing.expect_value(t, state.bytes_allocated, u64(0))
	testing.expect_value(t, p_vc, ref_vc)
	testing.expect(t, math.abs(p_sum - ref_sum) <= 1e-4, "pipeline sum must match reference")

	// Also test sliced arrays with non-zero offsets
	sa := oa.array_slice(col_a, 19, n - 31)
	sb := oa.array_slice(col_b, 19, n - 31)
	slice_sum, slice_vc, slice_ok := pipeline.pipeline_sel_2pred_sum_f64(&mp, &sa, .Le, 3000.0, &sb, .Ge, 1000.0)
	testing.expect(t, slice_ok)

	exp_s_sum, exp_s_vc := oa.compute_sel_2pred_sum(&sa, .Le, 3000.0, &sb, .Ge, 1000.0)
	testing.expect_value(t, slice_vc, exp_s_vc)
	testing.expect(t, math.abs(slice_sum - exp_s_sum) <= 1e-4, "sliced pipeline sum must match scalar kernel")
}

@(test)
test_sleipnir_pipeline_record_batch_stream :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	mp: pipeline.Morsel_Pipeline
	ok := pipeline.pipeline_init(&mp, 0, context.allocator)
	testing.expect(t, ok, "pipeline_init must succeed")
	defer pipeline.pipeline_destroy(&mp)

	fields := [2]oa.Field{
		oa.field_make("a", oa.Float64_Type{}, nullable = true),
		oa.field_make("b", oa.Float64_Type{}, nullable = false),
	}
	sc, sc_err := oa.schema_make(fields[:])
	testing.expect(t, sc_err == .None)
	defer oa.schema_free(&sc)

	lengths := [3]int{10_000, 33_000, 7_777}
	batches: [3]oa.Record_Batch
	defer {
		for &rb in batches {
			oa.record_batch_free(&rb)
		}
	}

	ref_sum := f64(0)
	ref_vc := 0
	for b_idx in 0..<3 {
		len_b := lengths[b_idx]
		ba := oa.builder_make(f64, len_b)
		bb := oa.builder_make(f64, len_b)
		for i in 0..<len_b {
			va := f64((i * 3 + b_idx * 17) % 500)
			vb := f64((i * 11 + b_idx * 5) % 500)
			if i % 29 == 0 {
				oa.builder_append_null(&ba)
			} else {
				oa.builder_append(&ba, va)
				if va > 100.0 && vb <= 400.0 {
					ref_sum += va
					ref_vc += 1
				}
			}
			oa.builder_append(&bb, vb)
		}
		ca, _ := oa.builder_finish(&ba)
		oa.builder_destroy(&ba)
		cb, _ := oa.builder_finish(&bb)
		oa.builder_destroy(&bb)
		cols := [2]oa.Array{ca, cb}
		rb, rb_ok := oa.record_batch_make(&sc, cols[:])
		testing.expect(t, rb_ok)
		batches[b_idx] = rb
	}

	s_sum, s_vc, s_ok := pipeline.pipeline_record_batch_stream_sum(&mp, batches[:], 0, .Gt, 100.0, 1, .Le, 400.0)
	testing.expect(t, s_ok)
	testing.expect_value(t, s_vc, ref_vc)
	testing.expect(t, math.abs(s_sum - ref_sum) <= 1e-4, "record batch stream sum mismatch")
}

@(test)
test_sleipnir_super_morsel_coarsening_and_sub_batches :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_base := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_base
		check_no_leaks(t, &track)
	}

	mp: pipeline.Morsel_Pipeline
	ok := pipeline.pipeline_init(&mp, 4, context.allocator)
	testing.expect(t, ok, "pipeline_init must succeed")
	defer pipeline.pipeline_destroy(&mp)

	// 1. Null-free f64 spanning multiple 65,536-row super-morsels with non-zero slice offset
	N_BIG :: 170_003
	ba := oa.builder_make(f64, N_BIG)
	defer oa.builder_destroy(&ba)
	bb := oa.builder_make(f64, N_BIG)
	defer oa.builder_destroy(&bb)
	for i in 0..<N_BIG {
		oa.builder_append(&ba, f64((i * 19 + 7) % 1000))
		oa.builder_append(&bb, f64((i * 31 + 13) % 1000))
	}
	col_a, _ := oa.builder_finish(&ba)
	defer oa.array_free(&col_a)
	col_b, _ := oa.builder_finish(&bb)
	defer oa.array_free(&col_b)

	sa_big := oa.array_slice(col_a, 17, N_BIG - 9)
	sb_big := oa.array_slice(col_b, 17, N_BIG - 9)

	// Warmup before checking steady-state allocations
	_, _, w_ok := pipeline.pipeline_sel_2pred_sum_f64(&mp, &sa_big, .Gt, 250.0, &sb_big, .Le, 600.0)
	testing.expect(t, w_ok)

	state: bs.Bench_Alloc_State
	cnt := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &state,
	}
	saved_alloc := context.allocator
	context.allocator = bs.counting_allocator(&cnt)
	p_sum, p_vc, p_ok := pipeline.pipeline_sel_2pred_sum_f64(&mp, &sa_big, .Gt, 250.0, &sb_big, .Le, 600.0)
	context.allocator = saved_alloc

	ref_sum, ref_vc := oa.compute_sel_2pred_sum(&sa_big, .Gt, 250.0, &sb_big, .Le, 600.0)
	testing.expect_value(t, state.alloc_count, u64(0))
	testing.expect_value(t, state.bytes_allocated, u64(0))
	testing.expect(t, p_ok)
	testing.expect_value(t, p_vc, ref_vc)
	testing.expect(t, math.abs(p_sum - ref_sum) <= 1e-3, "super-morsel big sum mismatch")

	// 2. Small unaligned slice (< 4096 rows)
	sa_small := oa.array_slice(col_a, 5, 3_116)
	sb_small := oa.array_slice(col_b, 5, 3_116)
	sm_sum, sm_vc, sm_ok := pipeline.pipeline_sel_2pred_sum_f64(&mp, &sa_small, .Ge, 400.0, &sb_small, .Lt, 700.0)
	sm_ref_sum, sm_ref_vc := oa.compute_sel_2pred_sum(&sa_small, .Ge, 400.0, &sb_small, .Lt, 700.0)
	testing.expect(t, sm_ok)
	testing.expect_value(t, sm_vc, sm_ref_vc)
	testing.expect(t, math.abs(sm_sum - sm_ref_sum) <= 1e-3, "small unaligned slice sum mismatch")

	// 3. Nullable f64 and nullable i32 columns spanning multiple super-morsels (_worker_fallback_range)
	N_FB :: 140_005
	bfa := oa.builder_make(f64, N_FB)
	defer oa.builder_destroy(&bfa)
	bfb := oa.builder_make(f64, N_FB)
	defer oa.builder_destroy(&bfb)
	bia := oa.builder_make(i32, N_FB)
	defer oa.builder_destroy(&bia)
	for i in 0..<N_FB {
		if i % 13 == 0 {
			oa.builder_append_null(&bfa)
		} else {
			oa.builder_append(&bfa, f64((i * 23 + 3) % 1000))
		}
		if i % 19 == 0 {
			oa.builder_append_null(&bfb)
		} else {
			oa.builder_append(&bfb, f64((i * 41 + 9) % 1000))
		}
		if i % 17 == 0 {
			oa.builder_append_null(&bia)
		} else {
			oa.builder_append(&bia, i32((i * 29 + 5) % 1000))
		}
	}
	col_fa, _ := oa.builder_finish(&bfa)
	defer oa.array_free(&col_fa)
	col_fb, _ := oa.builder_finish(&bfb)
	defer oa.array_free(&col_fb)
	col_ia, _ := oa.builder_finish(&bia)
	defer oa.array_free(&col_ia)

	fb_f_sum, fb_f_vc, fb_f_ok := pipeline.pipeline_sel_2pred_sum_f64(&mp, &col_fa, .Gt, 300.0, &col_fb, .Le, 800.0)
	fb_f_ref_sum, fb_f_ref_vc := oa.compute_sel_2pred_sum(&col_fa, .Gt, 300.0, &col_fb, .Le, 800.0)
	testing.expect(t, fb_f_ok)
	testing.expect_value(t, fb_f_vc, fb_f_ref_vc)
	testing.expect(t, math.abs(fb_f_sum - fb_f_ref_sum) <= 1e-3, "nullable f64 fallback sum mismatch")

	fb_i_sum, fb_i_vc, fb_i_ok := pipeline.pipeline_sel_2pred_sum_f64(&mp, &col_ia, .Ge, 120.0, &col_fb, .Lt, 750.0)
	fb_i_ref_sum, fb_i_ref_vc := oa.compute_sel_2pred_sum(&col_ia, .Ge, 120.0, &col_fb, .Lt, 750.0)
	testing.expect(t, fb_i_ok)
	testing.expect_value(t, fb_i_vc, fb_i_ref_vc)
	testing.expect(t, math.abs(fb_i_sum - fb_i_ref_sum) <= 1e-3, "nullable i32 fallback sum mismatch")

	// 4. Record batch stream across mixed sizes (< and > super_morsel_rows) + mixed nulls
	fields := [2]oa.Field{
		oa.field_make("a", oa.Float64_Type{}),
		oa.field_make("b", oa.Float64_Type{}),
	}
	sc, sc_err := oa.schema_make(fields[:])
	testing.expect_value(t, sc_err, nil)
	defer oa.schema_free(&sc)

	batch_sizes := [4]int{5_000, 70_000, 1_234, 135_000}
	batches: [4]oa.Record_Batch
	defer {
		for &rb in batches { oa.record_batch_free(&rb) }
	}
	stream_ref_sum := 0.0
	stream_ref_vc  := 0
	for sz, b_idx in batch_sizes {
		rba := oa.builder_make(f64, sz)
		rbb := oa.builder_make(f64, sz)
		for i in 0..<sz {
			if b_idx == 2 && i % 7 == 0 {
				oa.builder_append_null(&rba)
			} else {
				oa.builder_append(&rba, f64((i * 11 + b_idx * 17) % 500))
			}
			oa.builder_append(&rbb, f64((i * 17 + b_idx * 29) % 500))
		}
		ca, _ := oa.builder_finish(&rba)
		oa.builder_destroy(&rba)
		cb, _ := oa.builder_finish(&rbb)
		oa.builder_destroy(&rbb)

		b_ref_sum, b_ref_vc := oa.compute_sel_2pred_sum(&ca, .Gt, 100.0, &cb, .Le, 400.0)
		stream_ref_sum += b_ref_sum
		stream_ref_vc  += b_ref_vc

		cols := [2]oa.Array{ca, cb}
		rb, rb_ok := oa.record_batch_make(&sc, cols[:])
		testing.expect(t, rb_ok)
		batches[b_idx] = rb
	}

	s_sum, s_vc, s_ok := pipeline.pipeline_record_batch_stream_sum(&mp, batches[:], 0, .Gt, 100.0, 1, .Le, 400.0)
	testing.expect(t, s_ok)
	testing.expect_value(t, s_vc, stream_ref_vc)
	testing.expect(t, math.abs(s_sum - stream_ref_sum) <= 1e-3, "mixed batch stream sum mismatch")
}

@(private="file")
_verify_sort_index_parity :: proc(t: ^testing.T, actual, expected: ^oa.Array, msg: string) {
	testing.expect_value(t, actual.length, expected.length)
	if actual.length != expected.length { return }
	for i in 0..<expected.length {
		ai := oa.array_get(actual, i, i64)
		ei := oa.array_get(expected, i, i64)
		if ai != ei {
			testing.expect_value(t, ai, ei)
			testing.expect(t, false, msg)
			return
		}
	}
}

@(private="file")
_verify_numeric_sort_stability :: proc(t: ^testing.T, arr, indices: ^oa.Array, $T: typeid) {
	n := arr.length
	testing.expect_value(t, indices.length, n)
	if n <= 1 || indices.length != n { return }
	prev_idx := oa.array_get(indices, 0, i64)
	prev_val := oa.array_get(arr, int(prev_idx), T)
	for i in 1..<n {
		cur_idx := oa.array_get(indices, i, i64)
		cur_val := oa.array_get(arr, int(cur_idx), T)
		if cur_val < prev_val {
			testing.expect(t, false, "sort order violation")
			return
		}
		if cur_val == prev_val && cur_idx <= prev_idx {
			testing.expect(t, false, "sort stability violation")
			return
		}
		prev_val = cur_val
		prev_idx = cur_idx
	}
}

@(private="file")
_write_decimal_digits :: proc(buf: []u8, pos: int, v: int) -> int {
	p := pos
	digits := [6]u8{
		u8('0' + (v / 100_000) % 10),
		u8('0' + (v / 10_000)  % 10),
		u8('0' + (v / 1_000)   % 10),
		u8('0' + (v / 100)     % 10),
		u8('0' + (v / 10)      % 10),
		u8('0' +  v            % 10),
	}
	for d in digits {
		buf[p] = d
		p += 1
	}
	return p
}

@(test)
test_sleipnir_pipeline_radix_sort_i32_u32 :: proc(t: ^testing.T) {
	alloc_state := bs.Bench_Alloc_State{}
	cnt_data := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &alloc_state,
	}
	c_alloc := bs.counting_allocator(&cnt_data)

	mp: pipeline.Morsel_Pipeline
	testing.expect(t, pipeline.pipeline_init(&mp, 4, c_alloc), "pipeline_init failed")
	defer pipeline.pipeline_destroy(&mp)

	// 1. Uniform pseudo-random i32 with negatives + heavy duplicates + steady-state zero-scratch check
	n :: 24_000
	bi := oa.builder_make(i32)
	for i in 0..<n {
		v := i32((u64(i) * 2654435761) % 2000) - 1000
		if i % 97 == 0 { v = min(i32) }
		if i % 101 == 0 { v = max(i32) }
		oa.builder_append(&bi, v)
	}
	arr_i32, err_i32 := oa.builder_finish(&bi)
	testing.expect_value(t, err_i32, nil)
	oa.builder_destroy(&bi)
	defer oa.array_free(&arr_i32)

	ref_i32, rerr := oa.compute_sort_indices(&arr_i32)
	testing.expect_value(t, rerr, nil)
	defer oa.array_free(&ref_i32)

	// Warmup call allocates reusable pipeline scratch buffers
	warm_idx, werr := pipeline.pipeline_sort_indices(&mp, &arr_i32, c_alloc)
	testing.expect_value(t, werr, nil)
	_verify_sort_index_parity(t, &warm_idx, &ref_i32, "warmup i32 parity")
	_verify_numeric_sort_stability(t, &arr_i32, &warm_idx, i32)
	oa.array_free(&warm_idx, c_alloc)

	// Steady-state call: only 1 allocation (the returned i64 result buffer)
	alloc_state = {}
	act_i32, aerr := pipeline.pipeline_sort_indices_i32(&mp, &arr_i32, c_alloc)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, alloc_state.alloc_count, u64(1))
	_verify_sort_index_parity(t, &act_i32, &ref_i32, "steady-state i32 parity")
	oa.array_free(&act_i32, c_alloc)

	// 2. Sliced i32 (offset > 0)
	sliced_i32 := oa.array_slice(arr_i32, 37, n - 19)
	ref_sl, rsl_err := oa.compute_sort_indices(&sliced_i32)
	testing.expect_value(t, rsl_err, nil)
	defer oa.array_free(&ref_sl)
	act_sl, asl_err := pipeline.pipeline_sort_indices(&mp, &sliced_i32)
	testing.expect_value(t, asl_err, nil)
	defer oa.array_free(&act_sl)
	_verify_sort_index_parity(t, &act_sl, &ref_sl, "sliced i32 parity")

	// 3. Skewed single-MSB-bucket i32 (99.9% in [0, 64), rare extreme outliers)
	bsk := oa.builder_make(i32)
	for i in 0..<n {
		v := i32((u64(i) * 11400714819323198485) % 64)
		if i == 17 || i == 12_345 || i == n - 1 {
			v = i == 17 ? min(i32) : (i == 12_345 ? max(i32) : -987_654_321)
		}
		oa.builder_append(&bsk, v)
	}
	arr_skew, sk_err := oa.builder_finish(&bsk)
	testing.expect_value(t, sk_err, nil)
	oa.builder_destroy(&bsk)
	defer oa.array_free(&arr_skew)

	ref_skew, rsk_err := oa.compute_sort_indices(&arr_skew)
	testing.expect_value(t, rsk_err, nil)
	defer oa.array_free(&ref_skew)
	act_skew, ask_err := pipeline.pipeline_sort_indices(&mp, &arr_skew)
	testing.expect_value(t, ask_err, nil)
	defer oa.array_free(&act_skew)
	_verify_sort_index_parity(t, &act_skew, &ref_skew, "skewed single-bucket i32 parity")

	// 4. Constant i32 (diff_mask == 0 fast path)
	bc := oa.builder_make(i32)
	for _ in 0..<n {
		oa.builder_append(&bc, 777)
	}
	arr_const, c_err := oa.builder_finish(&bc)
	testing.expect_value(t, c_err, nil)
	oa.builder_destroy(&bc)
	defer oa.array_free(&arr_const)
	act_const, ac_err := pipeline.pipeline_sort_indices(&mp, &arr_const)
	testing.expect_value(t, ac_err, nil)
	defer oa.array_free(&act_const)
	for i in 0..<n {
		testing.expect_value(t, oa.array_get(&act_const, i, i64), i64(i))
	}

	// 5. Unsigned u32 with high-bit values (>= 0x8000_0000) & low-byte-only variance
	bu := oa.builder_make(u32)
	for i in 0..<n {
		v := (i % 2 == 0 ? u32(0x8000_0000) : u32(0)) | u32((u64(i) * 40503) & 0xFFFF_FFFF)
		if i % 250 == 0 { v = max(u32) }
		if i % 251 == 0 { v = 0 }
		oa.builder_append(&bu, v)
	}
	arr_u32, u_err := oa.builder_finish(&bu)
	testing.expect_value(t, u_err, nil)
	oa.builder_destroy(&bu)
	defer oa.array_free(&arr_u32)

	ref_u32, ru_err := oa.compute_sort_indices(&arr_u32)
	testing.expect_value(t, ru_err, nil)
	defer oa.array_free(&ref_u32)
	act_u32, au_err := pipeline.pipeline_sort_indices_u32(&mp, &arr_u32)
	testing.expect_value(t, au_err, nil)
	defer oa.array_free(&act_u32)
	_verify_sort_index_parity(t, &act_u32, &ref_u32, "u32 high-bit parity")
	_verify_numeric_sort_stability(t, &arr_u32, &act_u32, u32)

	// 6. Nullable i32 (nulls-last + slice offset > 0)
	bn := oa.builder_make(i32)
	for i in 0..<n {
		if i % 3 == 0 {
			oa.builder_append_null(&bn)
		} else {
			oa.builder_append(&bn, i32((i * 37) % 500) - 250)
		}
	}
	arr_null, n_err := oa.builder_finish(&bn)
	testing.expect_value(t, n_err, nil)
	oa.builder_destroy(&bn)
	defer oa.array_free(&arr_null)

	sliced_null := oa.array_slice(arr_null, 5, n - 3)
	ref_null, rn_err := oa.compute_sort_indices(&sliced_null)
	testing.expect_value(t, rn_err, nil)
	defer oa.array_free(&ref_null)
	act_null, an_err := pipeline.pipeline_sort_indices(&mp, &sliced_null)
	testing.expect_value(t, an_err, nil)
	defer oa.array_free(&act_null)
	_verify_sort_index_parity(t, &act_null, &ref_null, "nullable sliced i32 nulls-last parity")

	// 7. Small array fallback (< SORT_PARALLEL_PARTITION_MIN) + uninitialized pipeline fallback
	bsm := oa.builder_make(i32)
	for i in 0..<256 {
		oa.builder_append(&bsm, i32(256 - i))
	}
	arr_sm, sm_err := oa.builder_finish(&bsm)
	testing.expect_value(t, sm_err, nil)
	oa.builder_destroy(&bsm)
	defer oa.array_free(&arr_sm)

	ref_sm, rsm_err := oa.compute_sort_indices(&arr_sm)
	testing.expect_value(t, rsm_err, nil)
	defer oa.array_free(&ref_sm)
	act_sm, asm_err := pipeline.pipeline_sort_indices(&mp, &arr_sm)
	testing.expect_value(t, asm_err, nil)
	defer oa.array_free(&act_sm)
	_verify_sort_index_parity(t, &act_sm, &ref_sm, "small fallback i32 parity")

	uninit_mp: pipeline.Morsel_Pipeline
	act_uninit, au2_err := pipeline.pipeline_sort_indices(&uninit_mp, &arr_sm)
	testing.expect_value(t, au2_err, nil)
	defer oa.array_free(&act_uninit)
	_verify_sort_index_parity(t, &act_uninit, &ref_sm, "uninit pipeline fallback i32 parity")
}

@(test)
test_sleipnir_pipeline_string_and_umbra_sort :: proc(t: ^testing.T) {
	alloc_state := bs.Bench_Alloc_State{}
	cnt_data := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &alloc_state,
	}
	c_alloc := bs.counting_allocator(&cnt_data)

	mp: pipeline.Morsel_Pipeline
	testing.expect(t, pipeline.pipeline_init(&mp, 4, c_alloc), "pipeline_init failed")
	defer pipeline.pipeline_destroy(&mp)

	// 1. Mixed lengths (empty "", short <= 8B, inline 9..12B, long > 12B shared prefix, embedded NUL, duplicates)
	n :: 24_000
	sb := oa.string_builder_make(n)
	ub := oa.umbra_builder_make(n)
	buf: [64]u8
	for i in 0..<n {
		val: string
		switch i % 10 {
		case 0:
			val = ""
		case 1:
			buf[0] = u8('a' + (i * 7) % 26)
			buf[1] = 0
			buf[2] = u8('z' - i % 26)
			val = string(buf[:3])
		case 2:
			buf[0] = u8('a' + (i * 7) % 26)
			val = string(buf[:1])
		case 3, 4:
			copy(buf[:6], "inline")
			end_p := _write_decimal_digits(buf[:], 6, (i * 7919) % 100_000)
			val = string(buf[:end_p]) // 12 bytes
		case 5, 6, 7:
			copy(buf[:18], "shared_long_pfx_A_")
			end_p := _write_decimal_digits(buf[:], 18, (i * 104729) % 50_000)
			val = string(buf[:end_p]) // 24 bytes
		case 8:
			val = "shared_long_pfx_A_"
		case 9:
			copy(buf[:4], "top_")
			end_p := _write_decimal_digits(buf[:], 4, i % 17) // heavy duplicates
			val = string(buf[:end_p])
		}
		oa.string_builder_append(&sb, val)
		oa.umbra_append(&ub, val)
	}
	s_arr, s_err := oa.string_builder_finish(&sb)
	testing.expect_value(t, s_err, nil)
	oa.string_builder_destroy(&sb)
	defer oa.array_free(&s_arr)

	u_arr := oa.umbra_builder_finish(&ub)
	oa.umbra_builder_destroy(&ub)
	defer oa.umbra_free(&u_arr)

	ref_str, rs_err := oa.compute_sort_indices(&s_arr)
	testing.expect_value(t, rs_err, nil)
	defer oa.array_free(&ref_str)

	ref_umb := oa.umbra_sort_indices(&u_arr)
	defer oa.array_free(&ref_umb)
	_verify_sort_index_parity(t, &ref_umb, &ref_str, "baseline umbra == compute_sort_indices")

	// Warmup both string & umbra actor sorts
	warm_s, ws_err := pipeline.pipeline_sort_indices_str(&mp, &s_arr, c_alloc)
	testing.expect_value(t, ws_err, nil)
	_verify_sort_index_parity(t, &warm_s, &ref_str, "warmup actor string sort")
	oa.array_free(&warm_s, c_alloc)

	warm_u := pipeline.pipeline_umbra_sort_indices(&mp, &u_arr, c_alloc)
	_verify_sort_index_parity(t, &warm_u, &ref_umb, "warmup actor umbra sort")
	oa.array_free(&warm_u, c_alloc)

	// Steady-state single allocation checks
	alloc_state = {}
	act_s, as_err := pipeline.pipeline_sort_indices_str(&mp, &s_arr, c_alloc)
	testing.expect_value(t, as_err, nil)
	testing.expect_value(t, alloc_state.alloc_count, u64(1))
	_verify_sort_index_parity(t, &act_s, &ref_str, "steady-state actor string sort")
	oa.array_free(&act_s, c_alloc)

	alloc_state = {}
	act_u := pipeline.pipeline_umbra_sort_indices(&mp, &u_arr, c_alloc)
	testing.expect_value(t, alloc_state.alloc_count, u64(1))
	_verify_sort_index_parity(t, &act_u, &ref_umb, "steady-state actor umbra sort")
	oa.array_free(&act_u, c_alloc)

	// 2. All-same-leading-byte skewed strings ("usr_000..." + "u" + "us") for String_Type and Umbra
	ssk := oa.string_builder_make(n)
	usk := oa.umbra_builder_make(n)
	for i in 0..<n {
		val: string
		if i % 100 == 0 {
			val = "u"
		} else if i % 100 == 1 {
			val = "us"
		} else {
			copy(buf[:4], "usr_")
			end_p := _write_decimal_digits(buf[:], 4, (i * 31337) % 10_000)
			buf[end_p] = '_'
			end_p = _write_decimal_digits(buf[:], end_p + 1, i % 97)
			val = string(buf[:end_p]) // 17 bytes, > 12B, shared leading 'u','s','r','_'
		}
		oa.string_builder_append(&ssk, val)
		oa.umbra_append(&usk, val)
	}
	s_skew, ss_err := oa.string_builder_finish(&ssk)
	testing.expect_value(t, ss_err, nil)
	oa.string_builder_destroy(&ssk)
	defer oa.array_free(&s_skew)

	u_skew := oa.umbra_builder_finish(&usk)
	oa.umbra_builder_destroy(&usk)
	defer oa.umbra_free(&u_skew)

	ref_ssk, rss_err := oa.compute_sort_indices(&s_skew)
	testing.expect_value(t, rss_err, nil)
	defer oa.array_free(&ref_ssk)

	act_ssk, ass_err := pipeline.pipeline_sort_indices_str(&mp, &s_skew)
	testing.expect_value(t, ass_err, nil)
	defer oa.array_free(&act_ssk)
	_verify_sort_index_parity(t, &act_ssk, &ref_ssk, "skewed single-lead string sort parity")

	act_usk := pipeline.pipeline_umbra_sort_indices(&mp, &u_skew)
	defer oa.array_free(&act_usk)
	_verify_sort_index_parity(t, &act_usk, &ref_ssk, "skewed single-lead umbra sort parity")

	// 3. Nullable + sliced String_Type (nulls interleaved with "" and shared prefixes)
	sn := oa.string_builder_make(n)
	for i in 0..<n {
		if i % 4 == 0 {
			oa.string_builder_append_null(&sn)
		} else if i % 9 == 0 {
			oa.string_builder_append(&sn, "")
		} else {
			copy(buf[:5], "k_")
			buf[2] = u8('a' + i % 13)
			end_p := _write_decimal_digits(buf[:], 3, (i * 19) % 1000)
			oa.string_builder_append(&sn, string(buf[:end_p]))
		}
	}
	arr_sn, sn_err := oa.string_builder_finish(&sn)
	testing.expect_value(t, sn_err, nil)
	oa.string_builder_destroy(&sn)
	defer oa.array_free(&arr_sn)

	sl_sn := oa.array_slice(arr_sn, 11, n - 7)
	ref_sn, rsn_err := oa.compute_sort_indices(&sl_sn)
	testing.expect_value(t, rsn_err, nil)
	defer oa.array_free(&ref_sn)

	act_sn, asn_err := pipeline.pipeline_sort_indices(&mp, &sl_sn)
	testing.expect_value(t, asn_err, nil)
	defer oa.array_free(&act_sn)
	_verify_sort_index_parity(t, &act_sn, &ref_sn, "nullable sliced string nulls-last parity")
}

@(test)
test_sleipnir_pipeline_agg_where_f64 :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_base := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_base
		check_no_leaks(t, &track)
	}

	mp: pipeline.Morsel_Pipeline
	ok := pipeline.pipeline_init(&mp, 4, context.allocator)
	testing.expect(t, ok, "pipeline_init must succeed")
	defer pipeline.pipeline_destroy(&mp)

	// 1. Null-free f64 spanning multiple super-morsels across all 6 Compare_Op variants + 0-alloc check
	N :: 150_003
	bv := oa.builder_make(f64, N)
	defer oa.builder_destroy(&bv)
	bp := oa.builder_make(f64, N)
	defer oa.builder_destroy(&bp)
	for i in 0..<N {
		oa.builder_append(&bv, f64((i * 17 + 3) % 10_000) * 0.5 - 1000.0)
		oa.builder_append(&bp, f64((i * 29 + 11) % 10_000) * 0.5)
	}
	col_val, _ := oa.builder_finish(&bv)
	defer oa.array_free(&col_val)
	col_pred, _ := oa.builder_finish(&bp)
	defer oa.array_free(&col_pred)

	// Warmup before checking steady-state allocations
	_, w_ok := pipeline.pipeline_agg_where_f64(&mp, &col_val, &col_pred, .Gt, 2500.0)
	testing.expect(t, w_ok)

	state: bs.Bench_Alloc_State
	cnt := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &state,
	}
	saved_alloc := context.allocator
	context.allocator = bs.counting_allocator(&cnt)
	fast_agg, fast_ok := pipeline.pipeline_agg_where_f64(&mp, &col_val, &col_pred, .Gt, 2500.0)
	context.allocator = saved_alloc

	testing.expect(t, fast_ok)
	testing.expect_value(t, state.alloc_count, u64(0))
	testing.expect_value(t, state.bytes_allocated, u64(0))
	ref_gt := oa.compute_agg_where_compare(&col_val, &col_pred, .Gt, 2500.0)
	testing.expect_value(t, fast_agg.valid, ref_gt.valid)
	testing.expect_value(t, fast_agg.count, ref_gt.count)
	testing.expect_value(t, fast_agg.min_val, ref_gt.min_val)
	testing.expect_value(t, fast_agg.max_val, ref_gt.max_val)
	testing.expect(t, math.abs(fast_agg.sum - ref_gt.sum) <= 1e-4, "agg_where Gt sum mismatch")

	ops := [6]oa.Compare_Op{.Lt, .Le, .Gt, .Ge, .Eq, .Ne}
	scalars := [6]f64{1250.0, 2500.0, 3750.0, 500.0, 1000.0, 1000.0}
	for op, idx in ops {
		act, a_ok := pipeline.pipeline_agg_where_f64(&mp, &col_val, &col_pred, op, scalars[idx])
		ref := oa.compute_agg_where_compare(&col_val, &col_pred, op, scalars[idx])
		testing.expect(t, a_ok)
		testing.expect_value(t, act.valid, ref.valid)
		testing.expect_value(t, act.count, ref.count)
		testing.expect_value(t, act.min_val, ref.min_val)
		testing.expect_value(t, act.max_val, ref.max_val)
		testing.expect(t, math.abs(act.sum - ref.sum) <= 1e-4, "agg_where compare op sum mismatch")
	}

	// 2. Zero-match predicate and empty array
	none_agg, none_ok := pipeline.pipeline_agg_where_f64(&mp, &col_val, &col_pred, .Gt, 999_999.0)
	testing.expect(t, none_ok)
	testing.expect_value(t, none_agg.valid, false)
	testing.expect_value(t, none_agg.count, 0)
	testing.expect_value(t, none_agg.sum, 0.0)
	testing.expect_value(t, none_agg.min_val, 0.0)
	testing.expect_value(t, none_agg.max_val, 0.0)

	empty_v := oa.array_slice(col_val, 10, 10)
	empty_p := oa.array_slice(col_pred, 10, 10)
	emp_agg, emp_ok := pipeline.pipeline_agg_where_f64(&mp, &empty_v, &empty_p, .Gt, 0.0)
	testing.expect(t, emp_ok)
	testing.expect_value(t, emp_agg.valid, false)
	testing.expect_value(t, emp_agg.count, 0)

	// 3. Sliced arrays with non-zero offsets
	sl_v := oa.array_slice(col_val, 37, N - 19)
	sl_p := oa.array_slice(col_pred, 37, N - 19)
	sl_act, sl_ok := pipeline.pipeline_agg_where_f64(&mp, &sl_v, &sl_p, .Le, 3000.0)
	sl_ref := oa.compute_agg_where_compare(&sl_v, &sl_p, .Le, 3000.0)
	testing.expect(t, sl_ok)
	testing.expect_value(t, sl_act.valid, sl_ref.valid)
	testing.expect_value(t, sl_act.count, sl_ref.count)
	testing.expect_value(t, sl_act.min_val, sl_ref.min_val)
	testing.expect_value(t, sl_act.max_val, sl_ref.max_val)
	testing.expect(t, math.abs(sl_act.sum - sl_ref.sum) <= 1e-4, "sliced agg_where sum mismatch")

	// 4. Nullable f64, all-null f64, and nullable i32 inputs
	bnv := oa.builder_make(f64, N)
	defer oa.builder_destroy(&bnv)
	bnp := oa.builder_make(f64, N)
	defer oa.builder_destroy(&bnp)
	ball_null := oa.builder_make(f64, 5_000)
	defer oa.builder_destroy(&ball_null)
	biv := oa.builder_make(i32, N)
	defer oa.builder_destroy(&biv)
	bip := oa.builder_make(i32, N)
	defer oa.builder_destroy(&bip)
	for i in 0..<N {
		if i % 13 == 0 {
			oa.builder_append_null(&bnv)
		} else {
			oa.builder_append(&bnv, f64((i * 23 + 5) % 4000) - 500.0)
		}
		if i % 19 == 0 {
			oa.builder_append_null(&bnp)
		} else {
			oa.builder_append(&bnp, f64((i * 31 + 7) % 4000))
		}
		if i % 11 == 0 {
			oa.builder_append_null(&biv)
		} else {
			oa.builder_append(&biv, i32((i * 19 + 1) % 2000) - 500)
		}
		if i % 17 == 0 {
			oa.builder_append_null(&bip)
		} else {
			oa.builder_append(&bip, i32((i * 37 + 3) % 2000))
		}
	}
	for _ in 0..<5_000 {
		oa.builder_append_null(&ball_null)
	}
	col_nv, _ := oa.builder_finish(&bnv)
	defer oa.array_free(&col_nv)
	col_np, _ := oa.builder_finish(&bnp)
	defer oa.array_free(&col_np)
	col_all_null, _ := oa.builder_finish(&ball_null)
	defer oa.array_free(&col_all_null)
	col_iv, _ := oa.builder_finish(&biv)
	defer oa.array_free(&col_iv)
	col_ip, _ := oa.builder_finish(&bip)
	defer oa.array_free(&col_ip)

	nv_sl := oa.array_slice(col_nv, 11, N - 7)
	np_sl := oa.array_slice(col_np, 11, N - 7)
	nv_act, nv_ok := pipeline.pipeline_agg_where_f64(&mp, &nv_sl, &np_sl, .Ge, 1200.0)
	nv_ref := oa.compute_agg_where_compare(&nv_sl, &np_sl, .Ge, 1200.0)
	testing.expect(t, nv_ok)
	testing.expect_value(t, nv_act.valid, nv_ref.valid)
	testing.expect_value(t, nv_act.count, nv_ref.count)
	testing.expect_value(t, nv_act.min_val, nv_ref.min_val)
	testing.expect_value(t, nv_act.max_val, nv_ref.max_val)
	testing.expect(t, math.abs(nv_act.sum - nv_ref.sum) <= 1e-4, "nullable f64 agg_where sum mismatch")

	an_act, an_ok := pipeline.pipeline_agg_where_f64(&mp, &col_all_null, &col_all_null, .Ne, 0.0)
	testing.expect(t, an_ok)
	testing.expect_value(t, an_act.valid, false)
	testing.expect_value(t, an_act.count, 0)

	iv_act, iv_ok := pipeline.pipeline_agg_where_f64(&mp, &col_iv, &col_ip, .Lt, 900.0)
	iv_ref := oa.compute_agg_where_compare(&col_iv, &col_ip, .Lt, 900.0)
	testing.expect(t, iv_ok)
	testing.expect_value(t, iv_act.valid, iv_ref.valid)
	testing.expect_value(t, iv_act.count, iv_ref.count)
	testing.expect_value(t, iv_act.min_val, iv_ref.min_val)
	testing.expect_value(t, iv_act.max_val, iv_ref.max_val)
	testing.expect(t, math.abs(iv_act.sum - iv_ref.sum) <= 1e-4, "nullable i32 agg_where sum mismatch")
}

@(test)
test_sleipnir_pipeline_dict_value_counts_and_group_sum :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_base := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_base
		check_no_leaks(t, &track)
	}

	mp: pipeline.Morsel_Pipeline
	ok := pipeline.pipeline_init(&mp, 4, context.allocator)
	testing.expect(t, ok, "pipeline_init must succeed")
	defer pipeline.pipeline_destroy(&mp)

	// 1. Small-cardinality Str_Dict_Array with nulls + nullable f64 weights + sliced inputs
	N_SMALL :: 100_007
	sb := oa.string_builder_make(N_SMALL)
	defer oa.string_builder_destroy(&sb)
	wb := oa.builder_make(f64, N_SMALL)
	defer oa.builder_destroy(&wb)
	wib := oa.builder_make(i32, N_SMALL)
	defer oa.builder_destroy(&wib)

	tags := [16]string{
		"alpha_00", "bravo_01", "charlie2", "delta_03",
		"echo_004", "foxtrot5", "golf_006", "hotel_07",
		"india_08", "juliet_9", "kilo_010", "lima_011",
		"mike_012", "nov_0013", "oscar_14", "papa_015",
	}
	for i in 0..<N_SMALL {
		if i % 37 == 0 {
			oa.string_builder_append_null(&sb)
		} else {
			oa.string_builder_append(&sb, tags[(u64(i) * 2654435761) & 15])
		}
		if i % 29 == 0 {
			oa.builder_append_null(&wb)
			oa.builder_append_null(&wib)
		} else {
			oa.builder_append(&wb, f64((i * 13 + 7) % 1000) * 0.25)
			oa.builder_append(&wib, i32((i * 17 + 3) % 500) - 100)
		}
	}
	s_arr, _ := oa.string_builder_finish(&sb)
	defer oa.array_free(&s_arr)
	w_arr, _ := oa.builder_finish(&wb)
	defer oa.array_free(&w_arr)
	wi_arr, _ := oa.builder_finish(&wib)
	defer oa.array_free(&wi_arr)

	sd := oa.str_dict_encode(&s_arr)
	defer oa.str_dict_free(&sd)

	ref_vc := oa.str_dict_value_counts(&sd)
	defer delete(ref_vc)
	act_vc, act_nc, vc_ok := pipeline.pipeline_dict_value_counts(&mp, &sd)
	defer delete(act_vc)
	testing.expect(t, vc_ok)
	testing.expect_value(t, act_nc, sd.null_count)
	testing.expect_value(t, len(act_vc), len(ref_vc))
	for k in 0..<len(ref_vc) {
		testing.expect_value(t, act_vc[k], ref_vc[k])
	}

	// Steady-state 0-alloc check for _into variants
	out_vc := make([]i64, oa.n_dict(&sd))
	defer delete(out_vc)
	out_gs := make([]f64, oa.n_dict(&sd))
	defer delete(out_gs)

	state: bs.Bench_Alloc_State
	cnt := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &state,
	}
	saved_alloc := context.allocator
	context.allocator = bs.counting_allocator(&cnt)
	into_nc, into_vc_ok := pipeline.pipeline_dict_value_counts_into(&mp, &sd, out_vc)
	_, into_gs_ok := pipeline.pipeline_dict_group_sum_into(&mp, &sd, &w_arr, out_gs)
	context.allocator = saved_alloc

	testing.expect(t, into_vc_ok)
	testing.expect(t, into_gs_ok)
	testing.expect_value(t, into_nc, sd.null_count)
	testing.expect_value(t, state.alloc_count, u64(0))
	testing.expect_value(t, state.bytes_allocated, u64(0))

	ref_gs := oa.str_dict_group_sum(&sd, &w_arr)
	defer delete(ref_gs)
	for k in 0..<len(ref_gs) {
		testing.expect_value(t, out_vc[k], ref_vc[k])
		testing.expect(t, math.abs(out_gs[k] - ref_gs[k]) <= 1e-4, "str dict group_sum f64 mismatch")
	}

	// Sliced Str_Dict_Array + sliced i32 weights
	sd_sl := oa.str_dict_slice(sd, 19, N_SMALL - 13)
	wi_sl := oa.array_slice(wi_arr, 19, N_SMALL - 13)
	ref_sl_vc := oa.str_dict_value_counts(&sd_sl)
	defer delete(ref_sl_vc)
	ref_sl_gs := oa.str_dict_group_sum(&sd_sl, &wi_sl)
	defer delete(ref_sl_gs)

	act_sl_vc, act_sl_nc, sl_vc_ok := pipeline.pipeline_dict_value_counts(&mp, &sd_sl)
	defer delete(act_sl_vc)
	act_sl_gs, _, sl_gs_ok := pipeline.pipeline_dict_group_sum(&mp, &sd_sl, &wi_sl)
	defer delete(act_sl_gs)
	testing.expect(t, sl_vc_ok)
	testing.expect(t, sl_gs_ok)
	testing.expect_value(t, act_sl_nc, sd_sl.null_count)
	for k in 0..<len(ref_sl_vc) {
		testing.expect_value(t, act_sl_vc[k], ref_sl_vc[k])
		testing.expect(t, math.abs(act_sl_gs[k] - ref_sl_gs[k]) <= 1e-4, "sliced str dict group_sum i32 mismatch")
	}

	// 2. Medium-cardinality (> DICT_INITIAL_SCRATCH_CAP = 1024) exercising scratch growth
	N_MED :: 60_005
	CARD_MED :: 1_500
	med_codes := make([]i32, N_MED)
	defer delete(med_codes)
	exp_med_vc := make([]i64, CARD_MED)
	defer delete(exp_med_vc)
	exp_med_nc := 0
	bmed_w := oa.builder_make(f64, N_MED)
	defer oa.builder_destroy(&bmed_w)
	for i in 0..<N_MED {
		wv := f64((i * 11 + 5) % 200) * 0.5
		oa.builder_append(&bmed_w, wv)
		if i % 43 == 0 {
			med_codes[i] = oa.DICT_NULL_CODE
			exp_med_nc += 1
		} else {
			code := i32((u64(i) * 11400714819323198485) % CARD_MED)
			med_codes[i] = code
			exp_med_vc[code] += 1
		}
	}
	med_w, _ := oa.builder_finish(&bmed_w)
	defer oa.array_free(&med_w)

	act_med_vc, act_med_nc, med_vc_ok := pipeline.pipeline_dict_value_counts(&mp, med_codes, CARD_MED)
	defer delete(act_med_vc)
	testing.expect(t, med_vc_ok)
	testing.expect_value(t, act_med_nc, exp_med_nc)
	for k in 0..<CARD_MED {
		testing.expect_value(t, act_med_vc[k], exp_med_vc[k])
	}

	act_med_gs, _, med_gs_ok := pipeline.pipeline_dict_group_sum(&mp, med_codes, CARD_MED, &med_w)
	defer delete(act_med_gs)
	testing.expect(t, med_gs_ok)
	exp_med_gs := make([]f64, CARD_MED)
	defer delete(exp_med_gs)
	for i in 0..<N_MED {
		c := med_codes[i]
		if c >= 0 {
			exp_med_gs[c] += oa.array_get(&med_w, i, f64)
		}
	}
	for k in 0..<CARD_MED {
		testing.expect(t, math.abs(act_med_gs[k] - exp_med_gs[k]) <= 1e-4, "medium cardinality group_sum mismatch")
	}

	// 3. Numeric Dict_Array(f64) and Dict_Array(i32) including zero-alloc pipeline_dict_sum
	bf_dict := oa.builder_make(f64, N_SMALL)
	defer oa.builder_destroy(&bf_dict)
	for i in 0..<N_SMALL {
		if i % 53 == 0 {
			oa.builder_append_null(&bf_dict)
		} else {
			oa.builder_append(&bf_dict, f64((i * 7) % 64) * 1.5)
		}
	}
	f_arr, _ := oa.builder_finish(&bf_dict)
	defer oa.array_free(&f_arr)
	nd := oa.dict_encode(&f_arr, f64)
	defer oa.dict_free(&nd)

	nd_ref_vc := oa.dict_value_counts(&nd)
	defer delete(nd_ref_vc)
	nd_act_vc, nd_nc, nd_vc_ok := pipeline.pipeline_dict_value_counts(&mp, &nd)
	defer delete(nd_act_vc)
	testing.expect(t, nd_vc_ok)
	testing.expect_value(t, nd_nc, nd.null_count)
	for k in 0..<len(nd_ref_vc) {
		testing.expect_value(t, nd_act_vc[k], nd_ref_vc[k])
	}

	nd_ref_gs := oa.dict_group_sum(&nd, &w_arr)
	defer delete(nd_ref_gs)
	nd_act_gs, _, nd_gs_ok := pipeline.pipeline_dict_group_sum(&mp, &nd, &w_arr)
	defer delete(nd_act_gs)
	testing.expect(t, nd_gs_ok)
	for k in 0..<len(nd_ref_gs) {
		testing.expect(t, math.abs(nd_act_gs[k] - nd_ref_gs[k]) <= 1e-4, "numeric dict group_sum mismatch")
	}

	state = {}
	context.allocator = bs.counting_allocator(&cnt)
	nd_sum, nd_sum_nc, nd_sum_ok := pipeline.pipeline_dict_sum(&mp, &nd)
	context.allocator = saved_alloc
	testing.expect(t, nd_sum_ok)
	testing.expect_value(t, nd_sum_nc, nd.null_count)
	testing.expect_value(t, state.alloc_count, u64(0))
	testing.expect_value(t, state.bytes_allocated, u64(0))
	testing.expect(t, math.abs(nd_sum - oa.dict_sum(&nd)) <= 1e-4, "numeric pipeline_dict_sum mismatch")

	// 4. All-null dictionary (dict_len == 0)
	ball_str := oa.string_builder_make(5_000)
	defer oa.string_builder_destroy(&ball_str)
	for _ in 0..<5_000 {
		oa.string_builder_append_null(&ball_str)
	}
	all_null_sarr, _ := oa.string_builder_finish(&ball_str)
	defer oa.array_free(&all_null_sarr)
	all_null_sd := oa.str_dict_encode(&all_null_sarr)
	defer oa.str_dict_free(&all_null_sd)

	an_vc, an_nc, an_vc_ok := pipeline.pipeline_dict_value_counts(&mp, &all_null_sd)
	defer delete(an_vc)
	testing.expect(t, an_vc_ok)
	testing.expect_value(t, len(an_vc), 0)
	testing.expect_value(t, an_nc, 5_000)
}
