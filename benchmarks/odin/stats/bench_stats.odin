package bench_stats

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

Bench_Config :: struct {
	runs:             int,
	warmup:           int,
	n_scale:          int,
	pin_cpu:          int,
	has_pin:          bool,
	counters:         bool,
	test_mode:        bool,
	host_warned:      bool,
	commit:           string,
	run_id:           string,
	lang:             string,
	output_path:      string,
	history_path:     string,
	packet_out_path:  string,
	output_explicit:  bool,
	history_explicit: bool,
	append_mode:      bool,
	no_history:       bool,
	legacy:           bool,
	quiet:            bool,
	groups:           [dynamic]string,
	filter:           string,
}

Bench_Stats :: struct {
	median_ns:    f64,
	mean_ns:      f64,
	stddev_ns:    f64,
	variance_ns2: f64,
	cv_pct:       f64,
	min_ns:       f64,
	max_ns:       f64,
	iqr_ns:       f64,
	p95_ns:       f64,
	p99_ns:       f64,
	total_ms:     f64,
	ops_per_sec:  f64,
	gb_per_sec:   f64,
}

Bench_Result :: struct {
	rank:                int,
	group:               string,
	lang:                string,
	commit:              string,
	run_id:              string,
	name:                string,
	ops:                 u64,
	runs:                int,
	warmup:              int,
	bytes_used:          u64,
	allocs_per_run:      u64,
	resizes_per_run:     u64,
	alloc_bytes_per_run: u64,
	peak_live_bytes:     u64,
	pool_hits:           u64,
	pool_misses:         u64,
	stats:               Bench_Stats,
	samples_ns:          [dynamic]f64,
	samples_batch_ns:    [dynamic]u64,
}

Bench_Alloc_State :: struct {
	alloc_count:           u64,
	resize_count:          u64,
	bytes_allocated:       u64,
	trial_live_bytes:      i64,
	trial_peak_live_bytes: u64,
}

Counting_Allocator_Data :: struct {
	backing: mem.Allocator,
	state:   ^Bench_Alloc_State,
}

counting_allocator :: proc(data: ^Counting_Allocator_Data) -> mem.Allocator {
	return mem.Allocator{procedure = _counting_allocator_proc, data = data}
}

@(private="file")
_counting_allocator_proc :: proc(
	allocator_data: rawptr,
	mode:           mem.Allocator_Mode,
	size, alignment: int,
	old_memory:     rawptr,
	old_size:       int,
	loc             := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	d := cast(^Counting_Allocator_Data)allocator_data
	res, err := d.backing.procedure(d.backing.data, mode, size, alignment, old_memory, old_size, loc)
	if err != .None || d.state == nil {
		return res, err
	}
	st := d.state
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size > 0 {
			intrinsics.atomic_add(&st.alloc_count, 1)
			intrinsics.atomic_add(&st.bytes_allocated, u64(size))
			new_live := intrinsics.atomic_add(&st.trial_live_bytes, i64(size)) + i64(size)
			if new_live > 0 {
				_atomic_update_peak(&st.trial_peak_live_bytes, u64(new_live))
			}
		}
	case .Resize, .Resize_Non_Zeroed:
		if size == 0 {
			if old_memory != nil && old_size > 0 {
				intrinsics.atomic_sub(&st.trial_live_bytes, i64(old_size))
			}
		} else {
			intrinsics.atomic_add(&st.resize_count, 1)
			if size > old_size {
				intrinsics.atomic_add(&st.bytes_allocated, u64(size - old_size))
			}
			delta := i64(size - old_size)
			new_live := intrinsics.atomic_add(&st.trial_live_bytes, delta) + delta
			if new_live > 0 {
				_atomic_update_peak(&st.trial_peak_live_bytes, u64(new_live))
			}
		}
	case .Free:
		if old_memory != nil && old_size > 0 {
			intrinsics.atomic_sub(&st.trial_live_bytes, i64(old_size))
		}
	case .Free_All:
		intrinsics.atomic_store(&st.trial_live_bytes, 0)
	case .Query_Features, .Query_Info:
	}
	return res, err
}

@(private="file")
_atomic_update_peak :: proc "contextless" (peak_ptr: ^u64, candidate: u64) {
	cur := intrinsics.atomic_load_explicit(peak_ptr, .Relaxed)
	for candidate > cur {
		prev, ok := intrinsics.atomic_compare_exchange_weak_explicit(peak_ptr, cur, candidate, .Relaxed, .Relaxed)
		if ok { break }
		cur = prev
	}
}

Jsonl_Entry :: struct {
	rank: int,
	line: string,
}

// Linear-interpolated percentile over a sorted non-empty slice of samples.
percentile :: proc(sorted: []f64, p: f64) -> f64 {
	n := len(sorted)
	if n == 0 { return 0 }
	if n == 1 { return sorted[0] }
	clamped := p
	if clamped < 0 { clamped = 0 }
	if clamped > 1 { clamped = 1 }
	pos := clamped * f64(n - 1)
	lo := int(math.floor(pos))
	hi := int(math.ceil(pos))
	if lo == hi { return sorted[lo] }
	frac := pos - f64(lo)
	return sorted[lo] * (1.0 - frac) + sorted[hi] * frac
}

// Compute descriptive and quantile statistics over per-op nanosecond samples.
compute_stats :: proc(samples_ns: []f64, ops: u64, bytes_used: u64 = 0, allocator := context.allocator) -> Bench_Stats {
	n := len(samples_ns)
	if n == 0 { return {} }

	sorted, err := slice.clone(samples_ns, allocator)
	if err != nil { return {} }
	defer delete(sorted, allocator)
	slice.sort(sorted)

	sum := 0.0
	for s in samples_ns {
		sum += s
	}
	mean := sum / f64(n)

	variance := 0.0
	if n > 1 {
		sq_sum := 0.0
		for s in samples_ns {
			d := s - mean
			sq_sum += d * d
		}
		variance = sq_sum / f64(n - 1)
	}
	stddev := math.sqrt(variance)
	cv := 0.0
	if mean > 0 {
		cv = (stddev / mean) * 100.0
	}

	med := percentile(sorted, 0.50)
	q25 := percentile(sorted, 0.25)
	q75 := percentile(sorted, 0.75)
	p95 := percentile(sorted, 0.95)
	p99 := percentile(sorted, 0.99)

	eff_ops := ops
	if eff_ops == 0 { eff_ops = 1 }
	total_ns := med * f64(eff_ops)
	total_ms := total_ns / 1_000_000.0
	ops_per_sec := 0.0
	if med > 0 {
		ops_per_sec = 1_000_000_000.0 / med
	}
	gb_per_sec := (f64(bytes_used) / total_ns) if (total_ns > 0 && bytes_used > 0) else 0.0

	return Bench_Stats{
		median_ns    = med,
		mean_ns      = mean,
		stddev_ns    = stddev,
		variance_ns2 = variance,
		cv_pct       = cv,
		min_ns       = sorted[0],
		max_ns       = sorted[n - 1],
		iqr_ns       = q75 - q25,
		p95_ns       = p95,
		p99_ns       = p99,
		total_ms     = total_ms,
		ops_per_sec  = ops_per_sec,
		gb_per_sec   = gb_per_sec,
	}
}

config_destroy :: proc(cfg: ^Bench_Config, allocator := context.allocator) {
	delete(cfg.commit, allocator)
	delete(cfg.run_id, allocator)
	delete(cfg.lang, allocator)
	delete(cfg.output_path, allocator)
	delete(cfg.history_path, allocator)
	delete(cfg.packet_out_path, allocator)
	delete(cfg.filter, allocator)
	for g in cfg.groups {
		delete(g, allocator)
	}
	delete(cfg.groups)
	cfg^ = {}
}

result_destroy :: proc(r: ^Bench_Result, allocator := context.allocator) {
	delete(r.group, allocator)
	delete(r.lang, allocator)
	delete(r.commit, allocator)
	delete(r.run_id, allocator)
	delete(r.name, allocator)
	delete(r.samples_ns)
	delete(r.samples_batch_ns)
	r^ = {}
}

_replace_str :: proc(dst: ^string, val: string, allocator: mem.Allocator) {
	delete(dst^, allocator)
	dst^ = strings.clone(val, allocator)
}

_append_groups_csv :: proc(dst: ^[dynamic]string, csv: string, allocator: mem.Allocator) {
	it := csv
	for part in strings.split_iterator(&it, ",") {
		trimmed := strings.trim_space(part)
		if len(trimmed) > 0 {
			append(dst, strings.clone(trimmed, allocator))
		}
	}
}

parse_cli_args :: proc(
	args:            []string,
	default_lang:    string,
	default_output:  string,
	default_history: string,
	allocator        := context.allocator,
) -> (cfg: Bench_Config, ok: bool, show_help: bool) {
	cfg = Bench_Config{
		runs            = 5,
		warmup          = 1,
		n_scale         = 0,
		pin_cpu         = -1,
		commit          = resolve_git_commit(".", allocator),
		run_id          = fmt.aprintf("%d", time.to_unix_nanoseconds(time.now()) / 1_000_000, allocator = allocator),
		lang            = strings.clone(default_lang, allocator),
		output_path     = strings.clone(default_output, allocator),
		history_path    = strings.clone(default_history, allocator),
		packet_out_path = strings.clone("", allocator),
		groups          = make([dynamic]string, allocator),
		filter          = strings.clone("", allocator),
	}

	i := 0
	for i < len(args) {
		arg := args[i]
		val := ""
		has_inline_val := false
		if eq_idx := strings.index_byte(arg, '='); eq_idx > 0 {
			val = arg[eq_idx + 1:]
			arg = arg[:eq_idx]
			has_inline_val = true
		}

		next_val :: proc(args: []string, idx: ^int, inline: string, has_inline: bool) -> (string, bool) {
			if has_inline { return inline, true }
			if idx^ + 1 >= len(args) { return "", false }
			idx^ += 1
			return args[idx^], true
		}

		switch arg {
		case "-h", "--help":
			return cfg, true, true
		case "--append":
			cfg.append_mode = true
		case "--no-history":
			cfg.no_history = true
		case "--legacy":
			cfg.legacy = true
		case "--quiet":
			cfg.quiet = true
		case "--test":
			cfg.test_mode = true
		case "--counters":
			cfg.counters = true
		case "--host-warned":
			cfg.host_warned = true
		case "--pin":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			n, p_ok := strconv.parse_int(v)
			if !p_ok || n < 0 {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			cfg.pin_cpu = n
			cfg.has_pin = true
		case "--runs":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			n, p_ok := strconv.parse_int(v)
			if !p_ok || n < 1 {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			cfg.runs = n
		case "--warmup":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			n, p_ok := strconv.parse_int(v)
			if !p_ok || n < 0 {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			cfg.warmup = n
		case "--n":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			n, p_ok := strconv.parse_int(v)
			if !p_ok || n < 1 {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			cfg.n_scale = n
		case "--commit":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			_replace_str(&cfg.commit, v, allocator)
		case "--run-id":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			_replace_str(&cfg.run_id, v, allocator)
		case "--lang":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			_replace_str(&cfg.lang, v, allocator)
		case "--output":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			_replace_str(&cfg.output_path, v, allocator)
			cfg.output_explicit = true
		case "--history":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			_replace_str(&cfg.history_path, v, allocator)
			cfg.history_explicit = true
		case "--packet-out":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			_replace_str(&cfg.packet_out_path, v, allocator)
		case "--groups":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			_append_groups_csv(&cfg.groups, v, allocator)
		case "--filter":
			v, v_ok := next_val(args, &i, val, has_inline_val)
			if !v_ok {
				config_destroy(&cfg, allocator)
				return {}, false, false
			}
			_replace_str(&cfg.filter, v, allocator)
		case:
			config_destroy(&cfg, allocator)
			return {}, false, false
		}
		i += 1
	}

	if cfg.test_mode {
		cfg.runs = 1
		cfg.warmup = 0
	}

	return cfg, true, false
}

matches_group :: proc(cfg: ^Bench_Config, group: string) -> bool {
	if len(cfg.groups) == 0 { return true }
	for g in cfg.groups {
		if strings.equal_fold(g, group) { return true }
	}
	return false
}

matches_filter :: proc(cfg: ^Bench_Config, name: string) -> bool {
	if len(cfg.filter) == 0 { return true }
	low_name := strings.to_lower(name, context.temp_allocator)
	low_flt  := strings.to_lower(cfg.filter, context.temp_allocator)
	return strings.contains(low_name, low_flt)
}

resolve_git_commit :: proc(repo_root := ".", allocator := context.allocator) -> string {
	head_path := fmt.tprintf("%s/.git/HEAD", repo_root)
	head_bytes, head_err := os.read_entire_file(head_path, allocator)
	if head_err != nil {
		return strings.clone("unknown", allocator)
	}
	defer delete(head_bytes, allocator)

	head_str := strings.trim_space(string(head_bytes))
	if strings.has_prefix(head_str, "ref: ") {
		ref_rel := strings.trim_space(head_str[5:])
		ref_path := fmt.tprintf("%s/.git/%s", repo_root, ref_rel)
		if ref_bytes, ref_err := os.read_entire_file(ref_path, allocator); ref_err == nil {
			defer delete(ref_bytes, allocator)
			sha := strings.trim_space(string(ref_bytes))
			if len(sha) > 7 { sha = sha[:7] }
			if len(sha) > 0 { return strings.clone(sha, allocator) }
		}

		// Fallback to packed-refs when branch is not loose under .git/refs/.
		packed_path := fmt.tprintf("%s/.git/packed-refs", repo_root)
		if packed_bytes, p_err := os.read_entire_file(packed_path, allocator); p_err == nil {
			defer delete(packed_bytes, allocator)
			it := string(packed_bytes)
			for line in strings.split_lines_iterator(&it) {
				trimmed := strings.trim_space(line)
				if len(trimmed) == 0 || trimmed[0] == '#' || trimmed[0] == '^' { continue }
				sp := strings.index_byte(trimmed, ' ')
				if sp <= 0 { continue }
				sha := trimmed[:sp]
				rname := strings.trim_space(trimmed[sp + 1:])
				if rname == ref_rel {
					if len(sha) > 7 { sha = sha[:7] }
					return strings.clone(sha, allocator)
				}
			}
		}
		return strings.clone("unknown", allocator)
	}

	if len(head_str) > 7 { head_str = head_str[:7] }
	if len(head_str) == 0 { return strings.clone("unknown", allocator) }
	return strings.clone(head_str, allocator)
}

json_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(&b, `\"`)
		case '\\':
			strings.write_string(&b, `\\`)
		case '\n':
			strings.write_string(&b, `\n`)
		case '\r':
			strings.write_string(&b, `\r`)
		case '\t':
			strings.write_string(&b, `\t`)
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

format_result_json :: proc(r: ^Bench_Result, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	esc_group  := json_escape(r.group, allocator)
	esc_lang   := json_escape(r.lang, allocator)
	esc_commit := json_escape(r.commit, allocator)
	esc_run_id := json_escape(r.run_id, allocator)
	esc_name   := json_escape(r.name, allocator)
	defer {
		delete(esc_group, allocator)
		delete(esc_lang, allocator)
		delete(esc_commit, allocator)
		delete(esc_run_id, allocator)
		delete(esc_name, allocator)
	}

	fmt.sbprintf(
		&b,
		`{{"rank":%d,"group":"%s","lang":"%s","commit":"%s","run_id":"%s","name":"%s","ops":%d,"runs":%d,"warmup":%d,"total_ms":%.4f,"ns_per_op":%.6f,"mean_ns":%.6f,"median_ns":%.6f,"stddev_ns":%.6f,"variance_ns2":%.6f,"cv_pct":%.2f,"min_ns":%.6f,"max_ns":%.6f,"iqr_ns":%.6f,"p95_ns":%.6f,"p99_ns":%.6f,"ops_per_sec":%.0f,"gb_per_sec":%.2f,"bytes_used":%d,"allocs_per_run":%d,"resizes_per_run":%d,"alloc_bytes_per_run":%d,"peak_live_bytes":%d,"pool_hits":%d,"pool_misses":%d,"samples_ns":[`,
		r.rank, esc_group, esc_lang, esc_commit, esc_run_id, esc_name,
		r.ops, r.runs, r.warmup,
		r.stats.total_ms, r.stats.median_ns, r.stats.mean_ns, r.stats.median_ns,
		r.stats.stddev_ns, r.stats.variance_ns2, r.stats.cv_pct,
		r.stats.min_ns, r.stats.max_ns, r.stats.iqr_ns, r.stats.p95_ns, r.stats.p99_ns,
		r.stats.ops_per_sec, r.stats.gb_per_sec, r.bytes_used,
		r.allocs_per_run, r.resizes_per_run, r.alloc_bytes_per_run, r.peak_live_bytes,
		r.pool_hits, r.pool_misses,
	)

	for s, idx in r.samples_ns {
		if idx > 0 { strings.write_byte(&b, ',') }
		fmt.sbprintf(&b, "%.6f", s)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

extract_json_int_field :: proc(line: string, key: string) -> (val: int, ok: bool) {
	needle := fmt.tprintf(`"%s"`, key)
	idx := strings.index(line, needle)
	if idx < 0 { return 0, false }
	rest := line[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 { return 0, false }
	num_part := strings.trim_left_space(rest[colon + 1:])
	if len(num_part) == 0 { return 0, false }
	end := 0
	if num_part[0] == '-' { end = 1 }
	for end < len(num_part) && num_part[end] >= '0' && num_part[end] <= '9' {
		end += 1
	}
	if end == 0 || (end == 1 && num_part[0] == '-') { return 0, false }
	return strconv.parse_int(num_part[:end])
}

merge_jsonl_records :: proc(
	existing_content:  string,
	new_entries:       []Jsonl_Entry,
	preserve_existing: bool,
	allocator          := context.allocator,
) -> string {
	merged := make([dynamic]Jsonl_Entry, allocator)
	defer delete(merged)

	if preserve_existing && len(existing_content) > 0 {
		it := existing_content
		for line in strings.split_lines_iterator(&it) {
			trimmed := strings.trim_space(line)
			if len(trimmed) == 0 { continue }
			rank, r_ok := extract_json_int_field(trimmed, "rank")
			if !r_ok { continue }
			overridden := false
			for ne in new_entries {
				if ne.rank == rank {
					overridden = true
					break
				}
			}
			if !overridden {
				append(&merged, Jsonl_Entry{rank = rank, line = trimmed})
			}
		}
	}

	for ne in new_entries {
		replaced := false
		for &m in merged {
			if m.rank == ne.rank {
				m.line = ne.line
				replaced = true
				break
			}
		}
		if !replaced {
			append(&merged, ne)
		}
	}

	slice.sort_by(merged[:], proc(a, b: Jsonl_Entry) -> bool {
		return a.rank < b.rank
	})

	b := strings.builder_make(allocator)
	for m in merged {
		strings.write_string(&b, m.line)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}
