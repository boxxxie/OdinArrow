package bench_skadi

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import oa "../../skadi"
import pipeline "../../skadi/pipeline"
import bs "stats"

@(private="file")
_sink_f64: f64
@(private="file")
_sink_i64: i64

@(private="file")
g_pool: oa.Buffer_Pool
@(private="file")
g_alloc: mem.Allocator

DEFAULT_N_LARGE  :: 10_000_000
DEFAULT_N_STRING :: 1_000_000

_scale_sizes :: proc(cfg: ^bs.Bench_Config) -> (n_large, n_string: int) {
	if cfg.n_scale > 0 {
		n_large = cfg.n_scale
		n_string = max(cfg.n_scale / 10, 1000)
		return
	}
	return DEFAULT_N_LARGE, DEFAULT_N_STRING
}

_make_i32_array :: proc(n: int, with_nulls: bool) -> oa.Array {
	b := oa.builder_make(i32, n)
	if with_nulls {
		for i in 0..<n {
			if i % 100 == 0 {
				oa.builder_append_null(&b)
			} else {
				oa.builder_append(&b, i32(i % 100_000))
			}
		}
	} else {
		for i in 0..<n {
			oa.builder_append(&b, i32(i % 100_000))
		}
	}
	arr, err := oa.builder_finish(&b)
	assert(err == .None, "bench i32 array build failed")
	return arr
}

_make_f64_array :: proc(n: int, with_nulls: bool) -> oa.Array {
	b := oa.builder_make(f64, n)
	if with_nulls {
		for i in 0..<n {
			if i % 100 == 0 {
				oa.builder_append_null(&b)
			} else {
				oa.builder_append(&b, f64(i % 10_000) * 0.5)
			}
		}
	} else {
		for i in 0..<n {
			oa.builder_append(&b, f64(i % 10_000) * 0.5)
		}
	}
	arr, err := oa.builder_finish(&b)
	assert(err == .None, "bench f64 array build failed")
	return arr
}

_make_filter_mask :: proc(n: int) -> oa.Array {
	b := oa.builder_make(bool, n)
	for i in 0..<n {
		oa.builder_append(&b, (i & 1) == 0)
	}
	arr, err := oa.builder_finish(&b)
	assert(err == .None, "bench mask build failed")
	return arr
}

_make_sparse_filter_mask :: proc(n: int) -> oa.Array {
	b := oa.builder_make(bool, n)
	for i in 0..<n {
		oa.builder_append(&b, (i % 100) == 0)
	}
	arr, err := oa.builder_finish(&b)
	assert(err == .None, "bench sparse mask build failed")
	return arr
}

_make_string_array :: proc(n: int) -> oa.Array {
	b := oa.string_builder_make(n)
	samples := [16]string{
		"alpha_0001", "bravo_0002", "charlie_03", "delta_0004",
		"echo_00005", "foxtrot_06", "golf_00007", "hotel_0008",
		"india_0009", "juliet_010", "kilo_00011", "lima_00012",
		"mike_00013", "nov_000014", "oscar_0015", "papa_00016",
	}
	for i in 0..<n {
		if i % 50 == 0 {
			oa.string_builder_append_null(&b)
		} else {
			oa.string_builder_append(&b, samples[i & 15])
		}
	}
	arr, err := oa.string_builder_finish(&b)
	assert(err == .None, "bench string build failed")
	return arr
}

_array_bytes :: proc(arr: ^oa.Array) -> u64 {
	total := u64(0)
	for buf in arr.buffers {
		total += u64(buf.size)
	}
	return total
}

group_builders :: proc(ctx: ^Bench_Context) {
	n_large, _ := _scale_sizes(ctx.cfg)
	if !should_run(ctx, "array_build_10m_i32") { return }

	bytes := u64(n_large) * size_of(i32) + u64(oa.bitmap_byte_count(n_large))
	acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
	total_trials := ctx.cfg.warmup + ctx.cfg.runs
	for _ in 0..<total_trials {
		bench_accum_start(&acc)
		b := oa.builder_make(i32, n_large, g_alloc)
		for i in 0..<n_large {
			if i % 100 == 0 {
				oa.builder_append_null(&b)
			} else {
				oa.builder_append(&b, i32(i))
			}
		}
		arr, err := oa.builder_finish(&b, g_alloc)
		bench_accum_stop(&acc)
		assert(err == .None)
		intrinsics.volatile_store(&_sink_i64, i64(arr.length))
		oa.array_free(&arr, g_alloc)
		oa.builder_destroy(&b)
	}
	bench_accum_finish(&acc, ctx, 1, "builders", "array_build_10m_i32")
}

group_compute :: proc(ctx: ^Bench_Context) {
	n_large, n_string := _scale_sizes(ctx.cfg)
	total_trials := ctx.cfg.warmup + ctx.cfg.runs

	need_sum_f64   := should_run(ctx, "sum_10m_f64_st")
	need_sum_f64_mt := should_run(ctx, "sum_10m_f64_mt")
	need_sum_null_st := should_run(ctx, "sum_10m_f64_nulls_st")
	need_sum_null_mt := should_run(ctx, "sum_10m_f64_nulls_mt")
	need_sum_i32_st := should_run(ctx, "sum_10m_i32_st")
	need_sum_i32_mt := should_run(ctx, "sum_10m_i32_mt")
	need_mm_st     := should_run(ctx, "min_max_10m_i32_st")
	need_mm_mt     := should_run(ctx, "min_max_10m_i32_mt")
	need_filter_st := should_run(ctx, "filter_10m_i32_st")
	need_filter_mt    := should_run(ctx, "filter_10m_i32_mt")
	need_filter_sp_st := should_run(ctx, "filter_10m_i32_sparse_st")
	need_filter_sp_mt := should_run(ctx, "filter_10m_i32_sparse_mt")
	need_cmp_gt       := should_run(ctx, "compare_gt_10m_i32")
	need_cmp_gt_f64   := should_run(ctx, "compare_gt_10m_f64")
	need_arith_add    := should_run(ctx, "arith_add_10m_f64")
	need_cast         := should_run(ctx, "cast_10m_i32_f64")
	need_take_st      := should_run(ctx, "take_1m_i32_st")
	need_take_mt      := should_run(ctx, "take_1m_i32_mt")
	need_sort         := should_run(ctx, "sort_indices_1m_i32")
	need_sort_actor   := should_run(ctx, "sort_indices_1m_i32_actor")

	if need_sum_f64 || need_sum_f64_mt || need_arith_add || need_cmp_gt_f64 {
		arr := _make_f64_array(n_large, false)
		defer oa.array_free(&arr)
		bytes := _array_bytes(&arr)

		if need_sum_f64 {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				s, _ := oa.compute_sum(&arr)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_f64, s)
			}
			bench_accum_finish(&acc, ctx, 2, "compute", "sum_10m_f64_st")
		}

		if need_sum_f64_mt {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				s, _ := oa.compute_sum_parallel(&arr)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_f64, s)
			}
			bench_accum_finish(&acc, ctx, 3, "compute", "sum_10m_f64_mt")
		}

		if need_arith_add {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes * 2)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				out, err := oa.compute_add(&arr, &arr, g_alloc)
				bench_accum_stop(&acc)
				assert(err == .None)
				intrinsics.volatile_store(&_sink_i64, i64(out.length))
				oa.array_free(&out, g_alloc)
			}
			bench_accum_finish(&acc, ctx, 16, "compute", "arith_add_10m_f64")
		}

		if need_cmp_gt_f64 {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				out, err := oa.compute_compare(&arr, .Gt, 2500.0, g_alloc)
				bench_accum_stop(&acc)
				assert(err == .None)
				intrinsics.volatile_store(&_sink_i64, i64(out.length))
				oa.array_free(&out, g_alloc)
			}
			bench_accum_finish(&acc, ctx, 31, "compute", "compare_gt_10m_f64")
		}
	}

	if need_sum_null_st || need_sum_null_mt {
		arr := _make_f64_array(n_large, true)
		defer oa.array_free(&arr)
		bytes := _array_bytes(&arr)

		if need_sum_null_st {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				s, _ := oa.compute_sum(&arr)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_f64, s)
			}
			bench_accum_finish(&acc, ctx, 4, "compute", "sum_10m_f64_nulls_st")
		}

		if need_sum_null_mt {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				s, _ := oa.compute_sum_parallel(&arr)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_f64, s)
			}
			bench_accum_finish(&acc, ctx, 5, "compute", "sum_10m_f64_nulls_mt")
		}
	}

	if need_sum_i32_st || need_sum_i32_mt || need_mm_st || need_mm_mt || need_filter_st || need_filter_mt || need_filter_sp_st || need_filter_sp_mt || need_cmp_gt || need_cast || need_take_st || need_take_mt {
		arr := _make_i32_array(n_large, false)
		defer oa.array_free(&arr)
		bytes := _array_bytes(&arr)

		if need_sum_i32_st {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				s, _ := oa.compute_sum(&arr)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_f64, s)
			}
			bench_accum_finish(&acc, ctx, 6, "compute", "sum_10m_i32_st")
		}

		if need_sum_i32_mt {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				s, _ := oa.compute_sum_parallel(&arr)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_f64, s)
			}
			bench_accum_finish(&acc, ctx, 7, "compute", "sum_10m_i32_mt")
		}

		if need_mm_st {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				lo, hi, _ := oa.compute_min_max(&arr)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_f64, lo + hi)
			}
			bench_accum_finish(&acc, ctx, 8, "compute", "min_max_10m_i32_st")
		}

		if need_mm_mt {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				lo, hi, _ := oa.compute_min_max_parallel(&arr)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_f64, lo + hi)
			}
			bench_accum_finish(&acc, ctx, 9, "compute", "min_max_10m_i32_mt")
		}

		if need_filter_st || need_filter_mt {
			mask := _make_filter_mask(n_large)
			defer oa.array_free(&mask)
			fbytes := bytes + _array_bytes(&mask)

			if need_filter_st {
				acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), fbytes)
				for _ in 0..<total_trials {
					bench_accum_start(&acc)
					out, err := oa.compute_filter(&arr, &mask, g_alloc)
					bench_accum_stop(&acc)
					assert(err == .None)
					intrinsics.volatile_store(&_sink_i64, i64(out.length))
					oa.array_free(&out, g_alloc)
				}
				bench_accum_finish(&acc, ctx, 10, "compute", "filter_10m_i32_st")
			}

			if need_filter_mt {
				acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), fbytes)
				for _ in 0..<total_trials {
					bench_accum_start(&acc)
					out, err := oa.compute_filter_parallel(&arr, &mask, 0, g_alloc)
					bench_accum_stop(&acc)
					assert(err == .None)
					intrinsics.volatile_store(&_sink_i64, i64(out.length))
					oa.array_free(&out, g_alloc)
				}
				bench_accum_finish(&acc, ctx, 11, "compute", "filter_10m_i32_mt")
			}
		}

		if need_filter_sp_st || need_filter_sp_mt {
			sp_mask := _make_sparse_filter_mask(n_large)
			defer oa.array_free(&sp_mask)
			fbytes := bytes + _array_bytes(&sp_mask)

			if need_filter_sp_st {
				acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), fbytes)
				for _ in 0..<total_trials {
					bench_accum_start(&acc)
					out, err := oa.compute_filter(&arr, &sp_mask, g_alloc)
					bench_accum_stop(&acc)
					assert(err == .None)
					intrinsics.volatile_store(&_sink_i64, i64(out.length))
					oa.array_free(&out, g_alloc)
				}
				bench_accum_finish(&acc, ctx, 32, "compute", "filter_10m_i32_sparse_st")
			}

			if need_filter_sp_mt {
				acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), fbytes)
				for _ in 0..<total_trials {
					bench_accum_start(&acc)
					out, err := oa.compute_filter_parallel(&arr, &sp_mask, 0, g_alloc)
					bench_accum_stop(&acc)
					assert(err == .None)
					intrinsics.volatile_store(&_sink_i64, i64(out.length))
					oa.array_free(&out, g_alloc)
				}
				bench_accum_finish(&acc, ctx, 34, "compute", "filter_10m_i32_sparse_mt")
			}
		}

		if need_cmp_gt {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				out, err := oa.compute_compare_i64(&arr, .Gt, 50_000, g_alloc)
				bench_accum_stop(&acc)
				assert(err == .None)
				intrinsics.volatile_store(&_sink_i64, i64(out.length))
				oa.array_free(&out, g_alloc)
			}
			bench_accum_finish(&acc, ctx, 15, "compute", "compare_gt_10m_i32")
		}

		if need_cast {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				out, err := oa.compute_cast(&arr, oa.Float64_Type{}, g_alloc)
				bench_accum_stop(&acc)
				assert(err == .None)
				intrinsics.volatile_store(&_sink_i64, i64(out.length))
				oa.array_free(&out, g_alloc)
			}
			bench_accum_finish(&acc, ctx, 17, "compute", "cast_10m_i32_f64")
		}

		if need_take_st || need_take_mt {
			ib := oa.builder_make(i64, n_string)
			for i in 0..<n_string {
				oa.builder_append(&ib, i64((u64(i) * 2654435761) % u64(n_large)))
			}
			idx_arr, idx_err := oa.builder_finish(&ib)
			assert(idx_err == .None)
			oa.builder_destroy(&ib)
			defer oa.array_free(&idx_arr)

			tbytes := _array_bytes(&idx_arr) + u64(n_string) * size_of(i32)
			if need_take_st {
				acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_string), tbytes)
				for _ in 0..<total_trials {
					bench_accum_start(&acc)
					out, err := oa.compute_take(&arr, &idx_arr, g_alloc)
					bench_accum_stop(&acc)
					assert(err == .None)
					intrinsics.volatile_store(&_sink_i64, i64(out.length))
					oa.array_free(&out, g_alloc)
				}
				bench_accum_finish(&acc, ctx, 18, "compute", "take_1m_i32_st")
			}

			if need_take_mt {
				acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_string), tbytes)
				for _ in 0..<total_trials {
					bench_accum_start(&acc)
					out, err := oa.compute_take_parallel(&arr, &idx_arr, 0, g_alloc)
					bench_accum_stop(&acc)
					assert(err == .None)
					intrinsics.volatile_store(&_sink_i64, i64(out.length))
					oa.array_free(&out, g_alloc)
				}
				bench_accum_finish(&acc, ctx, 30, "compute", "take_1m_i32_mt")
			}
		}
	}

	if need_sort || need_sort_actor {
		sb := oa.builder_make(i32, n_string)
		for i in 0..<n_string {
			oa.builder_append(&sb, i32((u64(i) * 2654435761) % 100_000))
		}
		sort_arr, s_err := oa.builder_finish(&sb)
		assert(s_err == .None)
		oa.builder_destroy(&sb)
		defer oa.array_free(&sort_arr)

		if need_sort {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_string), _array_bytes(&sort_arr))
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				out, err := oa.compute_sort_indices(&sort_arr, g_alloc)
				bench_accum_stop(&acc)
				assert(err == .None)
				intrinsics.volatile_store(&_sink_i64, i64(out.length))
				oa.array_free(&out, g_alloc)
			}
			bench_accum_finish(&acc, ctx, 19, "compute", "sort_indices_1m_i32")
		}

		if need_sort_actor {
			mp: pipeline.Morsel_Pipeline
			p_ok := pipeline.pipeline_init(&mp, 0, g_alloc)
			assert(p_ok, "sleipnir morsel pipeline init failed")
			defer pipeline.pipeline_destroy(&mp)

			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_string), _array_bytes(&sort_arr))
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				out, err := pipeline.pipeline_sort_indices_i32(&mp, &sort_arr, g_alloc)
				bench_accum_stop(&acc)
				assert(err == .None)
				intrinsics.volatile_store(&_sink_i64, i64(out.length))
				oa.array_free(&out, g_alloc)
			}
			bench_accum_finish(&acc, ctx, 36, "compute", "sort_indices_1m_i32_actor")
		}
	}
}

group_strings :: proc(ctx: ^Bench_Context) {
	_, n_string := _scale_sizes(ctx.cfg)
	total_trials := ctx.cfg.warmup + ctx.cfg.runs

	samples := [16]string{
		"alpha_0001", "bravo_0002", "charlie_03", "delta_0004",
		"echo_00005", "foxtrot_06", "golf_00007", "hotel_0008",
		"india_0009", "juliet_010", "kilo_00011", "lima_00012",
		"mike_00013", "nov_000014", "oscar_0015", "papa_00016",
	}

	if should_run(ctx, "string_build_1m") {
		bytes := u64(n_string) * 14 + u64(oa.bitmap_byte_count(n_string))
		acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_string), bytes)
		for _ in 0..<total_trials {
			bench_accum_start(&acc)
			b := oa.string_builder_make(n_string, g_alloc, n_string * 11)
			for i in 0..<n_string {
				if i % 50 == 0 {
					oa.string_builder_append_null(&b)
				} else {
					oa.string_builder_append(&b, samples[i & 15])
				}
			}
			arr, err := oa.string_builder_finish(&b, g_alloc)
			bench_accum_stop(&acc)
			assert(err == .None)
			intrinsics.volatile_store(&_sink_i64, i64(arr.length))
			oa.array_free(&arr, g_alloc)
			oa.string_builder_destroy(&b)
		}
		bench_accum_finish(&acc, ctx, 12, "strings", "string_build_1m")
	}

	need_scan     := should_run(ctx, "string_scan_1m")
	need_flt_st   := should_run(ctx, "filter_1m_string_st")
	need_flt_mt   := should_run(ctx, "filter_1m_string_mt")

	if need_scan || need_flt_st || need_flt_mt {
		arr := _make_string_array(n_string)
		defer oa.array_free(&arr)
		bytes := _array_bytes(&arr)

		if need_scan {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_string), bytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				sv := oa.array_string_view(&arr)
				total_len := oa.string_view_sum_lengths(&sv)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_i64, total_len)
			}
			bench_accum_finish(&acc, ctx, 13, "strings", "string_scan_1m")
		}

		if need_flt_st || need_flt_mt {
			mask := _make_filter_mask(n_string)
			defer oa.array_free(&mask)
			fbytes := bytes + _array_bytes(&mask)

			if need_flt_st {
				acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_string), fbytes)
				for _ in 0..<total_trials {
					bench_accum_start(&acc)
					out, err := oa.compute_filter(&arr, &mask, g_alloc)
					bench_accum_stop(&acc)
					assert(err == .None)
					intrinsics.volatile_store(&_sink_i64, i64(out.length))
					oa.array_free(&out, g_alloc)
				}
				bench_accum_finish(&acc, ctx, 20, "strings", "filter_1m_string_st")
			}

			if need_flt_mt {
				acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_string), fbytes)
				for _ in 0..<total_trials {
					bench_accum_start(&acc)
					out, err := oa.compute_filter_parallel(&arr, &mask, 0, g_alloc)
					bench_accum_stop(&acc)
					assert(err == .None)
					intrinsics.volatile_store(&_sink_i64, i64(out.length))
					oa.array_free(&out, g_alloc)
				}
				bench_accum_finish(&acc, ctx, 21, "strings", "filter_1m_string_mt")
			}
		}
	}

	need_str_sort       := should_run(ctx, "sort_indices_100k_str")
	need_str_sort_actor := should_run(ctx, "sort_indices_100k_str_actor")
	if need_str_sort || need_str_sort_actor {
		n_sort_str := max(n_string / 10, 1000)
		sort_samples := [16]string{
			"alpha_key_000001", "bravo_key_000002", "charlie_key_0003", "delta_key_000004",
			"echo_key_0000005", "foxtrot_key_0006", "golf_key_0000007", "hotel_key_000008",
			"india_key_000009", "juliet_key_00010", "kilo_key_0000011", "lima_key_0000012",
			"mike_key_0000013", "novem_key_000014", "oscar_key_000015", "papa_key_0000016",
		}
		sb := oa.string_builder_make(n_sort_str, context.allocator, n_sort_str * 16)
		for i in 0..<n_sort_str {
			oa.string_builder_append(&sb, sort_samples[(u64(i) * 2654435761) & 15])
		}
		s_arr, s_err := oa.string_builder_finish(&sb)
		assert(s_err == .None)
		oa.string_builder_destroy(&sb)
		defer oa.array_free(&s_arr)

		if need_str_sort {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_sort_str), _array_bytes(&s_arr))
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				idx, err := oa.compute_sort_indices(&s_arr, g_alloc)
				bench_accum_stop(&acc)
				assert(err == .None)
				intrinsics.volatile_store(&_sink_i64, i64(idx.length))
				oa.array_free(&idx, g_alloc)
			}
			bench_accum_finish(&acc, ctx, 33, "strings", "sort_indices_100k_str")
		}

		if need_str_sort_actor {
			mp: pipeline.Morsel_Pipeline
			p_ok := pipeline.pipeline_init(&mp, 0, g_alloc)
			assert(p_ok, "sleipnir morsel pipeline init failed")
			defer pipeline.pipeline_destroy(&mp)

			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_sort_str), _array_bytes(&s_arr))
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				idx, err := pipeline.pipeline_sort_indices_str(&mp, &s_arr, g_alloc)
				bench_accum_stop(&acc)
				assert(err == .None)
				intrinsics.volatile_store(&_sink_i64, i64(idx.length))
				oa.array_free(&idx, g_alloc)
			}
			bench_accum_finish(&acc, ctx, 37, "strings", "sort_indices_100k_str_actor")
		}
	}
}

group_fusion :: proc(ctx: ^Bench_Context) {
	n_large, _ := _scale_sizes(ctx.cfg)
	total_trials := ctx.cfg.warmup + ctx.cfg.runs

	need_sum_where       := should_run(ctx, "sum_where_10m_f64")
	need_agg_where       := should_run(ctx, "agg_where_10m_f64")
	need_agg_where_actor := should_run(ctx, "agg_where_10m_f64_actor")
	need_sel_2pred       := should_run(ctx, "sel_2pred_sum_10m_f64")
	need_sel_2pred_mt    := should_run(ctx, "sel_2pred_sum_10m_f64_mt")
	need_sel_2pred_actor := should_run(ctx, "sel_2pred_sum_10m_f64_actor")
	if !need_sum_where && !need_agg_where && !need_agg_where_actor && !need_sel_2pred && !need_sel_2pred_mt && !need_sel_2pred_actor { return }

	arr_f64 := _make_f64_array(n_large, false)
	defer oa.array_free(&arr_f64)
	bytes := _array_bytes(&arr_f64)

	if need_sum_where {
		mask := _make_filter_mask(n_large)
		defer oa.array_free(&mask)
		acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes + _array_bytes(&mask))
		for _ in 0..<total_trials {
			bench_accum_start(&acc)
			s, _ := oa.compute_sum_where(&arr_f64, &mask)
			bench_accum_stop(&acc)
			intrinsics.volatile_store(&_sink_f64, s)
		}
		bench_accum_finish(&acc, ctx, 22, "fusion", "sum_where_10m_f64")
	}

	if need_agg_where {
		acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes * 2)
		for _ in 0..<total_trials {
			bench_accum_start(&acc)
			aggs := oa.compute_agg_where_compare(&arr_f64, &arr_f64, .Gt, 2500.0)
			bench_accum_stop(&acc)
			intrinsics.volatile_store(&_sink_f64, aggs.sum + aggs.min_val + aggs.max_val)
		}
		bench_accum_finish(&acc, ctx, 23, "fusion", "agg_where_10m_f64")
	}

	if need_agg_where_actor {
		mp: pipeline.Morsel_Pipeline
		p_ok := pipeline.pipeline_init(&mp, 0, g_alloc)
		assert(p_ok, "sleipnir morsel pipeline init failed")
		defer pipeline.pipeline_destroy(&mp)

		acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes * 2)
		for _ in 0..<total_trials {
			bench_accum_start(&acc)
			aggs, run_ok := pipeline.pipeline_agg_where_f64(&mp, &arr_f64, &arr_f64, .Gt, 2500.0)
			bench_accum_stop(&acc)
			assert(run_ok, "sleipnir agg_where pipeline run failed")
			intrinsics.volatile_store(&_sink_f64, aggs.sum + aggs.min_val + aggs.max_val)
		}
		bench_accum_finish(&acc, ctx, 39, "fusion", "agg_where_10m_f64_actor")
	}

	if need_sel_2pred || need_sel_2pred_mt || need_sel_2pred_actor {
		b1 := oa.builder_make(f64, n_large)
		for i in 0..<n_large {
			oa.builder_append(&b1, f64(((i * 7 + 13) % 10_000)) * 0.5)
		}
		c1, c1_err := oa.builder_finish(&b1)
		assert(c1_err == .None)
		oa.builder_destroy(&b1)
		defer oa.array_free(&c1)

		if need_sel_2pred {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes * 3)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				s, _ := oa.compute_sel_2pred_sum(&arr_f64, .Gt, 2500.0, &c1, .Gt, 2500.0, g_alloc)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_f64, s)
			}
			bench_accum_finish(&acc, ctx, 24, "fusion", "sel_2pred_sum_10m_f64")
		}

		if need_sel_2pred_mt {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes * 3)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				s, _ := oa.compute_sel_2pred_sum_parallel(&arr_f64, .Gt, 2500.0, &c1, .Gt, 2500.0)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_f64, s)
			}
			bench_accum_finish(&acc, ctx, 34, "fusion", "sel_2pred_sum_10m_f64_mt")
		}

		if need_sel_2pred_actor {
			mp: pipeline.Morsel_Pipeline
			p_ok := pipeline.pipeline_init(&mp, 0, g_alloc)
			assert(p_ok, "sleipnir morsel pipeline init failed")
			defer pipeline.pipeline_destroy(&mp)

			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes * 3)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				s, _, run_ok := pipeline.pipeline_sel_2pred_sum_f64(&mp, &arr_f64, .Gt, 2500.0, &c1, .Gt, 2500.0)
				bench_accum_stop(&acc)
				assert(run_ok, "sleipnir morsel pipeline run failed")
				intrinsics.volatile_store(&_sink_f64, s)
			}
			bench_accum_finish(&acc, ctx, 35, "fusion", "sel_2pred_sum_10m_f64_actor")
		}
	}
}

group_encoding :: proc(ctx: ^Bench_Context) {
	n_large, n_string := _scale_sizes(ctx.cfg)
	total_trials := ctx.cfg.warmup + ctx.cfg.runs

	samples := [16]string{
		"alpha_0001", "bravo_0002", "charlie_03", "delta_0004",
		"echo_00005", "foxtrot_06", "golf_00007", "hotel_0008",
		"india_0009", "juliet_010", "kilo_00011", "lima_00012",
		"mike_00013", "nov_000014", "oscar_0015", "papa_00016",
	}

	need_dict_vc       := should_run(ctx, "dict_vc_1m_str")
	need_dict_vc_actor := should_run(ctx, "dict_vc_1m_str_actor")
	if need_dict_vc || need_dict_vc_actor {
		sb := oa.string_builder_make(n_string)
		oa.string_builder_reserve_data(&sb, n_string * 11)
		for i in 0..<n_string {
			oa.string_builder_append(&sb, samples[i & 15])
		}
		s_arr, s_err := oa.string_builder_finish(&sb)
		assert(s_err == .None)
		oa.string_builder_destroy(&sb)
		defer oa.array_free(&s_arr)

		dict_arr := oa.str_dict_encode(&s_arr)
		defer oa.str_dict_free(&dict_arr)

		dbytes := u64(n_string) * size_of(i32)

		if need_dict_vc {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_string), dbytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				counts := oa.str_dict_value_counts(&dict_arr)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_i64, counts[0])
				delete(counts)
			}
			bench_accum_finish(&acc, ctx, 25, "encoding", "dict_vc_1m_str")
		}

		if need_dict_vc_actor {
			mp: pipeline.Morsel_Pipeline
			p_ok := pipeline.pipeline_init(&mp, 0, g_alloc)
			assert(p_ok, "sleipnir morsel pipeline init failed")
			defer pipeline.pipeline_destroy(&mp)

			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_string), dbytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				counts, _, run_ok := pipeline.pipeline_dict_value_counts(&mp, &dict_arr)
				bench_accum_stop(&acc)
				assert(run_ok, "sleipnir dict_vc pipeline run failed")
				intrinsics.volatile_store(&_sink_i64, counts[0])
				delete(counts)
			}
			bench_accum_finish(&acc, ctx, 40, "encoding", "dict_vc_1m_str_actor")
		}
	}

	if should_run(ctx, "rle_sum_10m_f64") {
		rb := oa.rle_builder_make(f64, max(n_large / 1000, 16))
		for i in 0..<n_large {
			oa.rle_append(&rb, f64(i / 1000))
		}
		rle_arr := oa.rle_builder_finish(&rb)
		oa.rle_builder_destroy(&rb)
		defer oa.rle_free(&rle_arr)

		acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), u64(oa.rle_encoded_bytes(&rle_arr)))
		for _ in 0..<total_trials {
			bench_accum_start(&acc)
			s := oa.rle_sum(&rle_arr)
			bench_accum_stop(&acc)
			intrinsics.volatile_store(&_sink_f64, s)
		}
		bench_accum_finish(&acc, ctx, 26, "encoding", "rle_sum_10m_f64")
	}

	need_umbra_sort       := should_run(ctx, "umbra_sort_100k_str")
	need_umbra_sort_actor := should_run(ctx, "umbra_sort_100k_str_actor")
	if need_umbra_sort || need_umbra_sort_actor {
		n_umbra := max(n_string / 10, 1000)
		umbra_samples := [16]string{
			"alpha_key_000001", "bravo_key_000002", "charlie_key_0003", "delta_key_000004",
			"echo_key_0000005", "foxtrot_key_0006", "golf_key_0000007", "hotel_key_000008",
			"india_key_000009", "juliet_key_00010", "kilo_key_0000011", "lima_key_0000012",
			"mike_key_0000013", "novem_key_000014", "oscar_key_000015", "papa_key_0000016",
		}
		ub := oa.umbra_builder_make(n_umbra)
		for i in 0..<n_umbra {
			s := umbra_samples[(u64(i) * 2654435761) & 15]
			oa.umbra_append(&ub, s)
		}
		u_arr := oa.umbra_builder_finish(&ub)
		oa.umbra_builder_destroy(&ub)
		defer oa.umbra_free(&u_arr)

		ubytes := u64(len(u_arr.slots)) * size_of(oa.Umbra_String) + u64(len(u_arr.data))

		if need_umbra_sort {
			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_umbra), ubytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				idx := oa.umbra_sort_indices(&u_arr, g_alloc)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_i64, i64(idx.length))
				oa.array_free(&idx, g_alloc)
			}
			bench_accum_finish(&acc, ctx, 27, "encoding", "umbra_sort_100k_str")
		}

		if need_umbra_sort_actor {
			mp: pipeline.Morsel_Pipeline
			p_ok := pipeline.pipeline_init(&mp, 0, g_alloc)
			assert(p_ok, "sleipnir morsel pipeline init failed")
			defer pipeline.pipeline_destroy(&mp)

			acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_umbra), ubytes)
			for _ in 0..<total_trials {
				bench_accum_start(&acc)
				idx := pipeline.pipeline_umbra_sort_indices(&mp, &u_arr, g_alloc)
				bench_accum_stop(&acc)
				intrinsics.volatile_store(&_sink_i64, i64(idx.length))
				oa.array_free(&idx, g_alloc)
			}
			bench_accum_finish(&acc, ctx, 38, "encoding", "umbra_sort_100k_str_actor")
		}
	}
}

group_ipc :: proc(ctx: ^Bench_Context) {
	n_large, _ := _scale_sizes(ctx.cfg)
	need_rt    := should_run(ctx, "ipc_roundtrip_10m_i32")
	need_write := should_run(ctx, "ipc_write_10m_i32")
	need_read  := should_run(ctx, "ipc_read_mmap_10m_i32")
	if !need_rt && !need_write && !need_read { return }

	total_trials := ctx.cfg.warmup + ctx.cfg.runs
	fields := [1]oa.Field{oa.field_make("x", oa.Int32_Type{}, nullable = false)}
	sc, sc_err := oa.schema_make(fields[:])
	assert(sc_err == .None)
	defer oa.schema_free(&sc)

	arr := _make_i32_array(n_large, false)
	defer oa.array_free(&arr)

	cols := [1]oa.Array{arr}
	rb, rb_ok := oa.record_batch_make(&sc, cols[:])
	assert(rb_ok)
	// Do not call record_batch_free(&rb) here because columns shares `arr` above (freed by defer).
	defer delete(rb.columns)

	ipc_path := "/tmp/skadi_bench_ipc_1v1.arrow"
	defer _ = os.remove(ipc_path)

	bytes := _array_bytes(&arr)
	batches_out := [1]oa.Record_Batch{rb}

	if need_rt {
		acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
		for _ in 0..<total_trials {
			bench_accum_start(&acc)
			w_ok := oa.ipc_write_file(ipc_path, &sc, batches_out[:])
			out_sc, out_batches, r_ok := oa.ipc_read_file(ipc_path)
			bench_accum_stop(&acc)
			assert(w_ok && r_ok)
			intrinsics.volatile_store(&_sink_i64, i64(len(out_batches)))
			for &bx in out_batches {
				oa.record_batch_free(&bx)
			}
			delete(out_batches)
			oa.schema_free(out_sc)
			free(out_sc)
		}
		bench_accum_finish(&acc, ctx, 14, "ipc", "ipc_roundtrip_10m_i32")
	}

	if need_write {
		acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
		for _ in 0..<total_trials {
			bench_accum_start(&acc)
			w_ok := oa.ipc_write_file(ipc_path, &sc, batches_out[:])
			bench_accum_stop(&acc)
			assert(w_ok)
			intrinsics.volatile_store(&_sink_i64, 1)
		}
		bench_accum_finish(&acc, ctx, 28, "ipc", "ipc_write_10m_i32")
	}

	if need_read {
		pre_ok := oa.ipc_write_file(ipc_path, &sc, batches_out[:])
		assert(pre_ok)
		acc := bench_accum_init(ctx.cfg.runs, ctx.cfg.warmup, u64(n_large), bytes)
		for _ in 0..<total_trials {
			bench_accum_start(&acc)
			out_sc, out_batches, r_ok := oa.ipc_read_file(ipc_path, validate = true, use_mmap = true)
			bench_accum_stop(&acc)
			assert(r_ok)
			intrinsics.volatile_store(&_sink_i64, i64(len(out_batches)))
			for &bx in out_batches {
				oa.record_batch_free(&bx)
			}
			delete(out_batches)
			oa.schema_free(out_sc)
			free(out_sc)
		}
		bench_accum_finish(&acc, ctx, 29, "ipc", "ipc_read_mmap_10m_i32")
	}
}

main :: proc() {
	base_alloc := context.allocator
	oa.buffer_pool_init(&g_pool, base_alloc)
	defer oa.buffer_pool_destroy(&g_pool)

	g_pool_hits_ptr   = &g_pool.hits
	g_pool_misses_ptr = &g_pool.misses

	pool_cnt := bs.Counting_Allocator_Data{
		backing = oa.buffer_pool_allocator(&g_pool),
		state   = &g_alloc_state,
	}
	heap_cnt := bs.Counting_Allocator_Data{
		backing = base_alloc,
		state   = &g_alloc_state,
	}
	g_alloc = bs.counting_allocator(&pool_cnt)
	context.allocator = bs.counting_allocator(&heap_cnt)
	defer context.allocator = base_alloc

	args := os.args[1:]
	cfg, ok, show_help := bs.parse_cli_args(
		args,
		"odin",
		"benchmarks/odin.jsonl",
		"benchmarks/history.jsonl",
		base_alloc,
	)
	if !ok {
		fmt.eprintln("Invalid command-line arguments.")
		print_usage()
		os.exit(1)
	}
	defer bs.config_destroy(&cfg, base_alloc)
	if show_help {
		print_usage()
		return
	}

	ctx := bench_context_init(&cfg, base_alloc)
	defer bench_context_destroy(&ctx, base_alloc)

	print_header(&cfg)
	run_group(&ctx, "builders", group_builders)
	run_group(&ctx, "compute",  group_compute)
	run_group(&ctx, "strings",  group_strings)
	run_group(&ctx, "fusion",   group_fusion)
	run_group(&ctx, "encoding", group_encoding)
	run_group(&ctx, "ipc",      group_ipc)
	if cfg.packet_out_path != "" {
		if !write_hugi_packet(&ctx, base_alloc) {
			os.exit(1)
		}
	}
}
