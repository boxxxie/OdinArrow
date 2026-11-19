package bench_skadi

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import oa "../../skadi"
import hugi "hugi:."
import bs "stats"

Bench_Config :: bs.Bench_Config
Bench_Stats  :: bs.Bench_Stats
Bench_Result :: bs.Bench_Result

Group_Fn :: #type proc(ctx: ^Bench_Context)

Bench_Context :: struct {
	cfg:           ^bs.Bench_Config,
	results:       [dynamic]bs.Bench_Result,
	flushed_count: int,
}

Bench_Accum :: struct {
	ops:             u64,
	bytes_used:      u64,
	runs:            int,
	warmup:          int,
	trial_idx:        int,
	samples_ns:       [dynamic]f64,
	samples_batch_ns: [dynamic]u64,
	t0:               time.Tick,
	t0_allocs:       u64,
	t0_resizes:      u64,
	t0_bytes:        u64,
	t0_hits:         u64,
	t0_misses:       u64,
	sum_allocs:      u64,
	sum_resizes:     u64,
	sum_alloc_bytes: u64,
	max_peak_live:   u64,
	sum_pool_hits:   u64,
	sum_pool_misses: u64,
}

g_alloc_state:     bs.Bench_Alloc_State
g_pool_hits_ptr:   ^u64
g_pool_misses_ptr: ^u64

bench_context_init :: proc(cfg: ^bs.Bench_Config, allocator := context.allocator) -> Bench_Context {
	return Bench_Context{
		cfg     = cfg,
		results = make([dynamic]bs.Bench_Result, allocator),
	}
}

bench_context_destroy :: proc(ctx: ^Bench_Context, allocator := context.allocator) {
	for &r in ctx.results {
		bs.result_destroy(&r, allocator)
	}
	delete(ctx.results)
	ctx.flushed_count = 0
}

bench_accum_init :: proc(runs, warmup: int, ops: u64, bytes_used: u64 = 0, allocator := context.allocator) -> Bench_Accum {
	samples := make([dynamic]f64, 0, runs, allocator)
	batch_samples := make([dynamic]u64, 0, runs, allocator)
	return Bench_Accum{
		ops              = max(ops, 1),
		bytes_used       = bytes_used,
		runs             = runs,
		warmup           = warmup,
		samples_ns       = samples,
		samples_batch_ns = batch_samples,
	}
}

bench_accum_start :: #force_inline proc(a: ^Bench_Accum) {
	g_alloc_state.trial_live_bytes = 0
	g_alloc_state.trial_peak_live_bytes = 0
	a.t0_allocs  = g_alloc_state.alloc_count
	a.t0_resizes = g_alloc_state.resize_count
	a.t0_bytes   = g_alloc_state.bytes_allocated
	a.t0_hits    = g_pool_hits_ptr^ if g_pool_hits_ptr != nil else 0
	a.t0_misses  = g_pool_misses_ptr^ if g_pool_misses_ptr != nil else 0
	a.t0 = time.tick_now()
}

bench_accum_stop :: #force_inline proc(a: ^Bench_Accum) {
	elapsed_ns := time.duration_nanoseconds(time.tick_since(a.t0))
	batch_ns := u64(max(elapsed_ns, 0))
	ns := f64(elapsed_ns)
	if a.trial_idx >= a.warmup {
		a.sum_allocs      += g_alloc_state.alloc_count - a.t0_allocs
		a.sum_resizes     += g_alloc_state.resize_count - a.t0_resizes
		a.sum_alloc_bytes += g_alloc_state.bytes_allocated - a.t0_bytes
		if g_alloc_state.trial_peak_live_bytes > a.max_peak_live {
			a.max_peak_live = g_alloc_state.trial_peak_live_bytes
		}
		if g_pool_hits_ptr != nil {
			a.sum_pool_hits += g_pool_hits_ptr^ - a.t0_hits
		}
		if g_pool_misses_ptr != nil {
			a.sum_pool_misses += g_pool_misses_ptr^ - a.t0_misses
		}
		append(&a.samples_batch_ns, batch_ns)
		append(&a.samples_ns, ns / f64(a.ops))
	}
	a.trial_idx += 1
	free_all(context.temp_allocator)
}

bench_accum_finish :: proc(
	a:          ^Bench_Accum,
	ctx:        ^Bench_Context,
	rank:       int,
	group:      string,
	name:       string,
	allocator   := context.allocator,
) {
	stats := bs.compute_stats(a.samples_ns[:], a.ops, a.bytes_used, allocator)
	eff_runs := u64(max(a.runs, 1))
	res := bs.Bench_Result{
		rank                = rank,
		group               = strings.clone(group, allocator),
		lang                = strings.clone(ctx.cfg.lang, allocator),
		commit              = strings.clone(ctx.cfg.commit, allocator),
		run_id              = strings.clone(ctx.cfg.run_id, allocator),
		name                = strings.clone(name, allocator),
		ops                 = a.ops,
		runs                = a.runs,
		warmup              = a.warmup,
		bytes_used          = a.bytes_used,
		allocs_per_run      = a.sum_allocs / eff_runs,
		resizes_per_run     = a.sum_resizes / eff_runs,
		alloc_bytes_per_run = a.sum_alloc_bytes / eff_runs,
		peak_live_bytes     = a.max_peak_live,
		pool_hits           = a.sum_pool_hits / eff_runs,
		pool_misses         = a.sum_pool_misses / eff_runs,
		stats               = stats,
		samples_ns          = a.samples_ns,
		samples_batch_ns    = a.samples_batch_ns,
	}
	a.samples_ns = {}
	a.samples_batch_ns = {}
	append(&ctx.results, res)
	print_result(&ctx.results[len(ctx.results) - 1], ctx.cfg.legacy, ctx.cfg.quiet)
}

should_run :: proc(ctx: ^Bench_Context, name: string) -> bool {
	return bs.matches_filter(ctx.cfg, name)
}

print_header :: proc(cfg: ^bs.Bench_Config) {
	if cfg.legacy || cfg.quiet { return }
	hw := oa.hardware_config_get()
	fmt.printf(
		"Skadi Benchmarks (commit=%s, runs=%d, warmup=%d, lang=%s)\n",
		cfg.commit, cfg.runs, cfg.warmup, cfg.lang,
	)
	fmt.printf(
		"Hardware: %dC/%dT, L1d=%dKB, L2=%dKB, L3=%dKB, morsel_target=%dKB\n",
		hw.physical_cores,
		hw.logical_cores,
		hw.l1d_bytes / 1024,
		hw.l2_bytes / 1024,
		hw.l3_bytes / 1024,
		hw.morsel_target_bytes / 1024,
	)
	fmt.println("-------------------------------------------------------------------------------------------------------------------------------")
	fmt.printf(
		"%-26s | %9s | %10s | %10s | %9s | %7s | %10s | %13s | %8s | %7s | %8s\n",
		"Benchmark", "Total(ms)", "Med(ns/op)", "Mean", "StdDev", "CV%", "p95", "Ops/s", "MB", "GB/s", "Allocs",
	)
	fmt.println("-------------------------------------------------------------------------------------------------------------------------------")
}

print_result :: proc(r: ^bs.Bench_Result, legacy := false, quiet := false) {
	if quiet { return }
	if legacy {
		fmt.printf("%s=%.0f\n", r.name, r.stats.median_ns * f64(max(r.ops, 1)))
		return
	}
	mb := f64(r.bytes_used) / (1024.0 * 1024.0)
	fmt.printf(
		"%-26s | %9.3f | %10.4f | %10.4f | %9.4f | %6.2f%% | %10.4f | %13.0f | %8.2f | %7.2f | %8d\n",
		r.name,
		r.stats.total_ms,
		r.stats.median_ns,
		r.stats.mean_ns,
		r.stats.stddev_ns,
		r.stats.cv_pct,
		r.stats.p95_ns,
		r.stats.ops_per_sec,
		mb,
		r.stats.gb_per_sec,
		r.allocs_per_run,
	)
}

flush_group_results :: proc(ctx: ^Bench_Context, allocator := context.allocator) {
	cfg := ctx.cfg
	if cfg.legacy { return }
	if len(ctx.results) <= ctx.flushed_count { return }

	write_snap := cfg.packet_out_path == "" || cfg.output_explicit
	write_hist := !cfg.no_history && (cfg.packet_out_path == "" || cfg.history_explicit)
	if !write_snap && !write_hist {
		ctx.flushed_count = len(ctx.results)
		return
	}

	new_entries := make([dynamic]bs.Jsonl_Entry, 0, len(ctx.results), allocator)
	defer {
		for e in new_entries {
			delete(e.line, allocator)
		}
		delete(new_entries)
	}
	for &r in ctx.results {
		line := bs.format_result_json(&r, allocator)
		append(&new_entries, bs.Jsonl_Entry{rank = r.rank, line = line})
	}

	if write_snap {
		preserve_existing := cfg.append_mode || len(cfg.groups) > 0 || len(cfg.filter) > 0
		existing_str := ""
		existing_bytes: []u8
		if preserve_existing {
			if data, err := os.read_entire_file(cfg.output_path, allocator); err == nil {
				existing_bytes = data
				existing_str = string(data)
			}
		}
		defer delete(existing_bytes, allocator)

		merged_str := bs.merge_jsonl_records(existing_str, new_entries[:], preserve_existing, allocator)
		defer delete(merged_str, allocator)
		_ = os.write_entire_file(cfg.output_path, transmute([]u8)merged_str)
	}

	if write_hist {
		if hf, h_err := os.open(cfg.history_path, {.Write, .Create, .Append}, os.Permissions_Default_File); h_err == nil {
			defer os.close(hf)
			for i := ctx.flushed_count; i < len(new_entries); i += 1 {
				line := new_entries[i].line
				_ = _write_all(hf, transmute([]u8)line)
				_ = _write_all(hf, []u8{'\n'})
			}
		}
	}

	ctx.flushed_count = len(ctx.results)
}

write_hugi_packet :: proc(ctx: ^Bench_Context, allocator := context.allocator) -> bool {
	cfg := ctx.cfg
	if cfg.packet_out_path == "" {
		return true
	}

	ts_unix := i64(time.to_unix_nanoseconds(time.now())) / 1_000_000_000
	pkt := hugi.Run_Packet{
		suite_name     = strings.clone("skadi", allocator),
		lang           = strings.clone(cfg.lang, allocator),
		commit         = strings.clone(cfg.commit, allocator),
		run_id         = strings.clone(cfg.run_id, allocator),
		os             = strings.clone(ODIN_OS_STRING, allocator),
		arch           = strings.clone(ODIN_ARCH_STRING, allocator),
		optimization   = strings.clone(fmt.tprintf("%v", ODIN_OPTIMIZATION_MODE), allocator),
		odin_version   = strings.clone(ODIN_VERSION, allocator),
		timestamp_unix = ts_unix,
		selective      = len(cfg.groups) > 0 || len(cfg.filter) > 0,
		records        = make([dynamic]hugi.Record, 0, len(ctx.results), allocator),
	}
	defer hugi.packet_destroy(&pkt, allocator)

	for &r in ctx.results {
		ops := max(r.ops, 1)
		ops_f := f64(ops)
		rec := hugi.Record{
			rank               = r.rank,
			group_name         = strings.clone(r.group, allocator),
			name               = strings.clone(r.name, allocator),
			full_name          = strings.clone(r.name, allocator),
			ops_per_sample     = ops,
			samples            = len(r.samples_batch_ns),
			warmup             = r.warmup,
			bytes_per_op       = r.bytes_used / ops,
			mb_per_sec         = r.stats.gb_per_sec * 1024.0,
			footprint_bytes    = r.bytes_used,
			allocs_per_op      = f64(r.allocs_per_run) / ops_f,
			resizes_per_op     = f64(r.resizes_per_run) / ops_f,
			alloc_bytes_per_op = f64(r.alloc_bytes_per_run) / ops_f,
			peak_heap_bytes    = i64(r.peak_live_bytes),
			error              = strings.clone("", allocator),
			metrics            = make([dynamic]hugi.Metric, allocator),
			samples_batch_ns   = make([dynamic]u64, len(r.samples_batch_ns), allocator),
		}
		copy(rec.samples_batch_ns[:], r.samples_batch_ns[:])
		if r.pool_hits > 0 || r.pool_misses > 0 {
			append(&rec.metrics, hugi.Metric{
				unit  = strings.clone("pool_hits", allocator),
				value = f64(r.pool_hits),
			})
			append(&rec.metrics, hugi.Metric{
				unit  = strings.clone("pool_misses", allocator),
				value = f64(r.pool_misses),
			})
		}
		hugi.recompute_record_stats_from_samples(&rec)
		hugi.refresh_record_throughput(&rec, overwrite = false)
		append(&pkt.records, rec)
	}

	if err := hugi.write_packet_file(cfg.packet_out_path, pkt); err != nil {
		fmt.eprintfln("Failed to write hugi packet '%s': %v", cfg.packet_out_path, err)
		return false
	}
	return true
}

@(private="file")
_write_all :: proc(f: ^os.File, data: []u8) -> bool {
	written := 0
	for written < len(data) {
		n, err := os.write(f, data[written:])
		if err != nil || n <= 0 { return false }
		written += n
	}
	return true
}

run_group :: proc(ctx: ^Bench_Context, group_name: string, fn: Group_Fn) {
	if !bs.matches_group(ctx.cfg, group_name) { return }
	fn(ctx)
	flush_group_results(ctx)
}

print_usage :: proc() {
	fmt.println("Usage: bench_runner [options]")
	fmt.println("  --runs N         Measured runs per benchmark (default: 5)")
	fmt.println("  --warmup N       Warmup runs per benchmark (default: 1)")
	fmt.println("  --n N            Override large array element count (default: 10000000)")
	fmt.println("  --commit SHA     Override git commit SHA")
	fmt.println("  --run-id ID      Override run ID")
	fmt.println("  --lang NAME      Language tag in JSONL (default: odin)")
	fmt.println("  --output PATH     JSONL snapshot path (default: benchmarks/odin.jsonl)")
	fmt.println("  --history PATH    JSONL history path (default: benchmarks/history.jsonl)")
	fmt.println("  --packet-out PATH Write hugi Run_Packet (.hpk) to PATH")
	fmt.println("  --groups LIST     Comma-separated groups (builders,compute,strings,fusion,encoding,ipc)")
	fmt.println("  --filter SUBSTR   Run only benchmarks matching substring")
	fmt.println("  --append          Merge/update matching ranks into existing output")
	fmt.println("  --no-history      Do not append to history JSONL")
	fmt.println("  --legacy          Emit legacy key=ns lines only")
	fmt.println("  --quiet           Suppress terminal table output")
}
