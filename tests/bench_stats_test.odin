package skadi_tests

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import bs "../benchmarks/odin/stats"

@(private="file")
g_bench_stats_test_seq: u64

_approx :: proc(a, b, eps: f64) -> bool {
	return math.abs(a - b) <= eps
}

@(test)
test_bench_stats_percentile_and_summary :: proc(t: ^testing.T) {
	// Per-op sub-nanosecond samples (10M elements in ~2.0-2.8 ms -> 0.20..0.28 ns/op).
	samples := []f64{0.20, 0.22, 0.24, 0.26, 0.28}
	st := bs.compute_stats(samples, 10_000_000, 80_000_000)

	testing.expect(t, _approx(st.median_ns, 0.24, 1e-9), "median should be 0.24")
	testing.expect(t, _approx(st.mean_ns, 0.24, 1e-9), "mean should be 0.24")
	testing.expect(t, _approx(st.min_ns, 0.20, 1e-9), "min should be 0.20")
	testing.expect(t, _approx(st.max_ns, 0.28, 1e-9), "max should be 0.28")
	// 25th percentile at index 1.0 (=0.22), 75th at index 3.0 (=0.26) -> IQR = 0.04
	testing.expect(t, _approx(st.iqr_ns, 0.04, 1e-9), "IQR should be 0.04")
	// Sample variance = ((0.04^2 * 2) + (0.02^2 * 2)) / 4 = 0.001 -> stddev = sqrt(0.001)
	testing.expect(t, _approx(st.variance_ns2, 0.001, 1e-12), "variance should be 0.001")
	testing.expect(t, _approx(st.stddev_ns, math.sqrt(0.001), 1e-9), "stddev mismatch")
	// p95 = sorted[3] + 0.8*(0.28-0.26) = 0.276
	testing.expect(t, _approx(st.p95_ns, 0.276, 1e-9), "p95 should be 0.276")
	testing.expect(t, _approx(st.total_ms, 2.4, 1e-9), "total_ms should be 2.4")
	testing.expect(t, _approx(st.ops_per_sec, 1e9 / 0.24, 1.0), "ops_per_sec mismatch")
	// 80,000,000 bytes / (0.24 * 10,000,000 ns) = 80,000,000 / 2,400,000 = 33.3333... GB/s
	testing.expect(t, _approx(st.gb_per_sec, 80.0 / 2.4, 1e-9), "gb_per_sec mismatch")
}

@(test)
test_bench_stats_cli_parsing :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	args := []string{
		"--runs", "10",
		"--warmup=3",
		"--n", "100000",
		"--commit", "deadbee",
		"--run-id", "r42",
		"--groups", "compute,strings",
		"--filter", "sum_10m",
		"--lang", "odin_custom",
		"--output", "/tmp/out.jsonl",
		"--history", "/tmp/hist.jsonl",
		"--packet-out", "/tmp/run.hpk",
		"--append",
		"--no-history",
		"--legacy",
		"--quiet",
	}
	cfg, ok, help := bs.parse_cli_args(args, "odin", "benchmarks/odin.jsonl", "benchmarks/history.jsonl")
	defer bs.config_destroy(&cfg)

	testing.expect(t, ok, "CLI parse should succeed")
	testing.expect(t, !help, "help flag should be false")
	testing.expect_value(t, cfg.runs, 10)
	testing.expect_value(t, cfg.warmup, 3)
	testing.expect_value(t, cfg.n_scale, 100_000)
	testing.expect_value(t, cfg.commit, "deadbee")
	testing.expect_value(t, cfg.run_id, "r42")
	testing.expect_value(t, cfg.lang, "odin_custom")
	testing.expect_value(t, cfg.output_path, "/tmp/out.jsonl")
	testing.expect_value(t, cfg.history_path, "/tmp/hist.jsonl")
	testing.expect_value(t, cfg.packet_out_path, "/tmp/run.hpk")
	testing.expect(t, cfg.output_explicit)
	testing.expect(t, cfg.history_explicit)
	testing.expect(t, cfg.append_mode)
	testing.expect(t, cfg.no_history)
	testing.expect(t, cfg.legacy)
	testing.expect(t, cfg.quiet)
	testing.expect_value(t, len(cfg.groups), 2)
	testing.expect(t, bs.matches_group(&cfg, "Compute"))
	testing.expect(t, !bs.matches_group(&cfg, "ipc"))
	testing.expect(t, bs.matches_filter(&cfg, "sum_10m_f64_mt"))
	testing.expect(t, !bs.matches_filter(&cfg, "filter_10m"))
}

@(test)
test_bench_stats_git_commit_resolution :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	seq := sync.atomic_add(&g_bench_stats_test_seq, 1)
	tmp_dir := fmt.aprintf("%s/skadi_git_test_repo_%d_%d", os.temp_dir(context.temp_allocator), os.get_pid(), seq)
	git_dir := fmt.aprintf("%s/.git", tmp_dir)
	refs_dir := fmt.aprintf("%s/refs/heads", git_dir)
	head_path := fmt.aprintf("%s/HEAD", git_dir)
	main_ref_path := fmt.aprintf("%s/main", refs_dir)
	packed_refs_path := fmt.aprintf("%s/packed-refs", git_dir)
	_ = os.mkdir_all(refs_dir)
	defer {
		_ = os.remove(main_ref_path)
		_ = os.remove(packed_refs_path)
		_ = os.remove(head_path)
		_ = os.remove_all(tmp_dir)
		delete(packed_refs_path)
		delete(main_ref_path)
		delete(head_path)
		delete(refs_dir)
		delete(git_dir)
		delete(tmp_dir)
	}

	// Case 1: loose ref in HEAD
	_ = os.write_entire_file(head_path, transmute([]u8)string("ref: refs/heads/main\n"))
	_ = os.write_entire_file(main_ref_path, transmute([]u8)string("abcdef1234567890abcdef1234567890abcdef12\n"))
	c1 := bs.resolve_git_commit(tmp_dir)
	defer delete(c1)
	testing.expect_value(t, c1, "abcdef1")

	// Case 2: packed-refs fallback
	_ = os.remove(main_ref_path)
	_ = os.write_entire_file(packed_refs_path, transmute([]u8)string("# pack-refs\n9876543210fedcba9876543210fedcba98765432 refs/heads/main\n"))
	c2 := bs.resolve_git_commit(tmp_dir)
	defer delete(c2)
	testing.expect_value(t, c2, "9876543")

	// Case 3: detached HEAD
	_ = os.write_entire_file(head_path, transmute([]u8)string("1234abcd5678\n"))
	c3 := bs.resolve_git_commit(tmp_dir)
	defer delete(c3)
	testing.expect_value(t, c3, "1234abc")
}

@(test)
test_bench_stats_jsonl_rank_merge_and_format :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	existing := "{\"rank\":1,\"name\":\"a\"}\n{\"rank\":3,\"name\":\"old_c\"}\n{\"rank\":14,\"name\":\"z\"}\n"
	updates := [2]bs.Jsonl_Entry{
		{rank = 3, line = `{"rank":3,"name":"new_c"}`},
		{rank = 2, line = `{"rank":2,"name":"b"}`},
	}

	merged := bs.merge_jsonl_records(existing, updates[:], preserve_existing = true)
	defer delete(merged)

	expected := "{\"rank\":1,\"name\":\"a\"}\n{\"rank\":2,\"name\":\"b\"}\n{\"rank\":3,\"name\":\"new_c\"}\n{\"rank\":14,\"name\":\"z\"}\n"
	testing.expect_value(t, merged, expected)

	// Sub-nanosecond JSON precision check (must not truncate to 0).
	samples := make([dynamic]f64)
	append(&samples, 0.214532)
	append(&samples, 0.220110)
	res := bs.Bench_Result{
		rank                = 3,
		group               = strings.clone("compute"),
		lang                = strings.clone("odin"),
		commit              = strings.clone("abc1234"),
		run_id              = strings.clone("run1"),
		name                = strings.clone("sum_10m_f64_mt"),
		ops                 = 10_000_000,
		runs                = 2,
		warmup              = 1,
		bytes_used          = 80_000_000,
		allocs_per_run      = 4,
		resizes_per_run     = 1,
		alloc_bytes_per_run = 4096,
		peak_live_bytes     = 2048,
		pool_hits           = 3,
		pool_misses         = 1,
		stats               = bs.compute_stats(samples[:], 10_000_000, 80_000_000),
		samples_ns          = samples,
	}
	defer bs.result_destroy(&res)

	json_line := bs.format_result_json(&res)
	defer delete(json_line)
	testing.expect(t, strings.contains(json_line, `"ns_per_op":0.217321`), "sub-nanosecond ns_per_op must retain fractional digits")
	testing.expect(t, strings.contains(json_line, `"samples_ns":[0.214532,0.220110]`), "samples_ns must retain fractional digits")
	testing.expect(t, strings.contains(json_line, `"gb_per_sec":36.81`), "gb_per_sec should be formatted in JSON")
	testing.expect(t, strings.contains(json_line, `"allocs_per_run":4`), "allocs_per_run should be formatted in JSON")
	testing.expect(t, strings.contains(json_line, `"resizes_per_run":1`), "resizes_per_run should be formatted in JSON")
	testing.expect(t, strings.contains(json_line, `"alloc_bytes_per_run":4096`), "alloc_bytes_per_run should be formatted in JSON")
	testing.expect(t, strings.contains(json_line, `"peak_live_bytes":2048`), "peak_live_bytes should be formatted in JSON")
	testing.expect(t, strings.contains(json_line, `"pool_hits":3`), "pool_hits should be formatted in JSON")
	testing.expect(t, strings.contains(json_line, `"pool_misses":1`), "pool_misses should be formatted in JSON")
}

@(test)
test_bench_stats_counting_allocator :: proc(t: ^testing.T) {
	state: bs.Bench_Alloc_State
	cnt_data := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &state,
	}
	alloc := bs.counting_allocator(&cnt_data)

	p1, err1 := mem.alloc_bytes(1024, 64, alloc)
	testing.expect_value(t, err1, mem.Allocator_Error.None)
	testing.expect_value(t, state.alloc_count, u64(1))
	testing.expect_value(t, state.bytes_allocated, u64(1024))
	testing.expect_value(t, state.trial_live_bytes, i64(1024))
	testing.expect_value(t, state.trial_peak_live_bytes, u64(1024))

	p2, err2 := mem.alloc_bytes(512, 64, alloc)
	testing.expect_value(t, err2, mem.Allocator_Error.None)
	testing.expect_value(t, state.alloc_count, u64(2))
	testing.expect_value(t, state.bytes_allocated, u64(1536))
	testing.expect_value(t, state.trial_live_bytes, i64(1536))
	testing.expect_value(t, state.trial_peak_live_bytes, u64(1536))

	mem.free_with_size(raw_data(p2), 512, alloc)
	testing.expect_value(t, state.trial_live_bytes, i64(1024))
	testing.expect_value(t, state.trial_peak_live_bytes, u64(1536))

	grown, err3 := mem.resize(raw_data(p1), 1024, 2048, 64, alloc)
	testing.expect_value(t, err3, mem.Allocator_Error.None)
	testing.expect_value(t, state.resize_count, u64(1))
	testing.expect_value(t, state.bytes_allocated, u64(2560))
	testing.expect_value(t, state.trial_live_bytes, i64(2048))
	testing.expect_value(t, state.trial_peak_live_bytes, u64(2048))

	mem.free_with_size(grown, 2048, alloc)
	testing.expect_value(t, state.trial_live_bytes, i64(0))
	testing.expect_value(t, state.trial_peak_live_bytes, u64(2048))
}

@(test)
test_bench_stats_counting_allocator_concurrent :: proc(t: ^testing.T) {
	state: bs.Bench_Alloc_State
	cnt_data := bs.Counting_Allocator_Data{
		backing = context.allocator,
		state   = &state,
	}
	alloc := bs.counting_allocator(&cnt_data)

	Thread_Ctx :: struct {
		alloc: mem.Allocator,
		iters: int,
	}
	worker_fn :: proc(th: ^thread.Thread) {
		c := cast(^Thread_Ctx)th.data
		for _ in 0..<c.iters {
			p, err := mem.alloc_bytes(256, 64, c.alloc)
			if err == .None {
				mem.free_with_size(raw_data(p), 256, c.alloc)
			}
		}
	}

	N_THREADS :: 4
	ITERS :: 1000
	ctxs: [N_THREADS]Thread_Ctx
	threads: [N_THREADS]^thread.Thread
	for i in 0..<N_THREADS {
		ctxs[i] = Thread_Ctx{alloc = alloc, iters = ITERS}
		threads[i] = thread.create(worker_fn)
		threads[i].data = &ctxs[i]
		thread.start(threads[i])
	}
	for i in 0..<N_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	testing.expect_value(t, state.alloc_count, u64(N_THREADS * ITERS))
	testing.expect_value(t, state.bytes_allocated, u64(N_THREADS * ITERS * 256))
	testing.expect_value(t, state.trial_live_bytes, i64(0))
	testing.expect(t, state.trial_peak_live_bytes >= 256)
}
