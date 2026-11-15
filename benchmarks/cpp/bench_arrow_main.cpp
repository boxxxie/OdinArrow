#include <arrow/api.h>
#include <arrow/compute/api.h>
#include <arrow/compute/initialize.h>
#include <arrow/io/file.h>
#include <arrow/ipc/api.h>
#include <arrow/memory_pool.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr int64_t DEFAULT_N_LARGE  = 10'000'000;
constexpr int64_t DEFAULT_N_STRING = 1'000'000;

volatile double  g_sink_f64 = 0.0;
volatile int64_t g_sink_i64 = 0;

struct BenchConfig {
    int runs = 5;
    int warmup = 1;
    int64_t n_scale = 0;
    std::string commit;
    std::string run_id;
    std::string lang = "cpp";
    std::string output_path = "benchmarks/cpp.jsonl";
    std::string history_path = "benchmarks/history.jsonl";
    std::vector<std::string> groups;
    std::string filter;
    bool append_mode = false;
    bool no_history = false;
    bool legacy = false;
};

struct BenchStats {
    double median_ns = 0.0;
    double mean_ns = 0.0;
    double stddev_ns = 0.0;
    double variance_ns2 = 0.0;
    double cv_pct = 0.0;
    double min_ns = 0.0;
    double max_ns = 0.0;
    double iqr_ns = 0.0;
    double p95_ns = 0.0;
    double p99_ns = 0.0;
    double total_ms = 0.0;
    double ops_per_sec = 0.0;
    double gb_per_sec = 0.0;
};

struct BenchResult {
    int rank = 0;
    std::string group;
    std::string lang;
    std::string commit;
    std::string run_id;
    std::string name;
    uint64_t ops = 0;
    int runs = 0;
    int warmup = 0;
    uint64_t bytes_used = 0;
    uint64_t allocs_per_run = 0;
    uint64_t resizes_per_run = 0;
    uint64_t alloc_bytes_per_run = 0;
    uint64_t peak_live_bytes = 0;
    uint64_t pool_hits = 0;
    uint64_t pool_misses = 0;
    BenchStats stats;
    std::vector<double> samples_ns;
};

std::string trim_str(const std::string& s) {
    size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) ++start;
    size_t end = s.size();
    while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) --end;
    return s.substr(start, end - start);
}

std::string to_lower_str(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

bool iequals(const std::string& a, const std::string& b) {
    return to_lower_str(a) == to_lower_str(b);
}

std::string resolve_git_commit(const std::string& repo_root = ".") {
    std::ifstream head_in(repo_root + "/.git/HEAD");
    if (!head_in) return "unknown";
    std::string head_line;
    std::getline(head_in, head_line);
    head_line = trim_str(head_line);
    if (head_line.empty()) return "unknown";

    if (head_line.rfind("ref: ", 0) == 0) {
        std::string ref_rel = trim_str(head_line.substr(5));
        std::ifstream ref_in(repo_root + "/.git/" + ref_rel);
        if (ref_in) {
            std::string sha;
            std::getline(ref_in, sha);
            sha = trim_str(sha);
            if (!sha.empty()) return sha.size() > 7 ? sha.substr(0, 7) : sha;
        }
        std::ifstream packed_in(repo_root + "/.git/packed-refs");
        if (packed_in) {
            std::string line;
            while (std::getline(packed_in, line)) {
                std::string t = trim_str(line);
                if (t.empty() || t[0] == '#' || t[0] == '^') continue;
                size_t sp = t.find(' ');
                if (sp == std::string::npos) continue;
                std::string sha = t.substr(0, sp);
                std::string rname = trim_str(t.substr(sp + 1));
                if (rname == ref_rel) return sha.size() > 7 ? sha.substr(0, 7) : sha;
            }
        }
        return "unknown";
    }
    return head_line.size() > 7 ? head_line.substr(0, 7) : head_line;
}

std::string default_run_id() {
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    return std::to_string(ms);
}

double percentile_sorted(const std::vector<double>& sorted, double p) {
    size_t n = sorted.size();
    if (n == 0) return 0.0;
    if (n == 1) return sorted[0];
    double clamped = std::max(0.0, std::min(1.0, p));
    double pos = clamped * static_cast<double>(n - 1);
    size_t lo = static_cast<size_t>(std::floor(pos));
    size_t hi = static_cast<size_t>(std::ceil(pos));
    if (lo == hi) return sorted[lo];
    double frac = pos - static_cast<double>(lo);
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

BenchStats compute_stats(const std::vector<double>& samples, uint64_t ops, uint64_t bytes_used = 0) {
    BenchStats st{};
    size_t n = samples.size();
    if (n == 0) return st;

    std::vector<double> sorted = samples;
    std::sort(sorted.begin(), sorted.end());

    double sum = 0.0;
    for (double s : samples) sum += s;
    double mean = sum / static_cast<double>(n);

    double variance = 0.0;
    if (n > 1) {
        double sq = 0.0;
        for (double s : samples) {
            double d = s - mean;
            sq += d * d;
        }
        variance = sq / static_cast<double>(n - 1);
    }
    double stddev = std::sqrt(variance);
    double cv = (mean > 0.0) ? (stddev / mean) * 100.0 : 0.0;

    double med = percentile_sorted(sorted, 0.50);
    double q25 = percentile_sorted(sorted, 0.25);
    double q75 = percentile_sorted(sorted, 0.75);
    double p95 = percentile_sorted(sorted, 0.95);
    double p99 = percentile_sorted(sorted, 0.99);

    uint64_t eff_ops = (ops > 0) ? ops : 1;
    double total_ns = med * static_cast<double>(eff_ops);
    st.median_ns = med;
    st.mean_ns = mean;
    st.stddev_ns = stddev;
    st.variance_ns2 = variance;
    st.cv_pct = cv;
    st.min_ns = sorted.front();
    st.max_ns = sorted.back();
    st.iqr_ns = q75 - q25;
    st.p95_ns = p95;
    st.p99_ns = p99;
    st.total_ms = total_ns / 1'000'000.0;
    st.ops_per_sec = (med > 0.0) ? (1'000'000'000.0 / med) : 0.0;
    st.gb_per_sec = (total_ns > 0.0 && bytes_used > 0) ? (static_cast<double>(bytes_used) / total_ns) : 0.0;
    return st;
}

std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 4);
    for (char c : s) {
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:   out.push_back(c); break;
        }
    }
    return out;
}

std::string format_result_json(const BenchResult& r) {
    std::ostringstream os;
    os.setf(std::ios::fixed);
    os << "{\"rank\":" << r.rank
       << ",\"group\":\"" << json_escape(r.group) << "\""
       << ",\"lang\":\"" << json_escape(r.lang) << "\""
       << ",\"commit\":\"" << json_escape(r.commit) << "\""
       << ",\"run_id\":\"" << json_escape(r.run_id) << "\""
       << ",\"name\":\"" << json_escape(r.name) << "\""
       << ",\"ops\":" << r.ops
       << ",\"runs\":" << r.runs
       << ",\"warmup\":" << r.warmup;
    os.precision(4);
    os << ",\"total_ms\":" << r.stats.total_ms;
    os.precision(6);
    os << ",\"ns_per_op\":" << r.stats.median_ns
       << ",\"mean_ns\":" << r.stats.mean_ns
       << ",\"median_ns\":" << r.stats.median_ns
       << ",\"stddev_ns\":" << r.stats.stddev_ns
       << ",\"variance_ns2\":" << r.stats.variance_ns2;
    os.precision(2);
    os << ",\"cv_pct\":" << r.stats.cv_pct;
    os.precision(6);
    os << ",\"min_ns\":" << r.stats.min_ns
       << ",\"max_ns\":" << r.stats.max_ns
       << ",\"iqr_ns\":" << r.stats.iqr_ns
       << ",\"p95_ns\":" << r.stats.p95_ns
       << ",\"p99_ns\":" << r.stats.p99_ns;
    os.precision(0);
    os << ",\"ops_per_sec\":" << r.stats.ops_per_sec;
    os.precision(2);
    os << ",\"gb_per_sec\":" << r.stats.gb_per_sec
       << ",\"bytes_used\":" << r.bytes_used
       << ",\"allocs_per_run\":" << r.allocs_per_run
       << ",\"resizes_per_run\":" << r.resizes_per_run
       << ",\"alloc_bytes_per_run\":" << r.alloc_bytes_per_run
       << ",\"peak_live_bytes\":" << r.peak_live_bytes
       << ",\"pool_hits\":" << r.pool_hits
       << ",\"pool_misses\":" << r.pool_misses
       << ",\"samples_ns\":[";
    os.precision(6);
    for (size_t i = 0; i < r.samples_ns.size(); ++i) {
        if (i > 0) os << ',';
        os << r.samples_ns[i];
    }
    os << "]}";
    return os.str();
}

bool extract_json_int_field(const std::string& line, const std::string& key, int& out_val) {
    std::string needle = "\"" + key + "\"";
    size_t pos = line.find(needle);
    if (pos == std::string::npos) return false;
    size_t colon = line.find(':', pos + needle.size());
    if (colon == std::string::npos) return false;
    size_t i = colon + 1;
    while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) ++i;
    if (i >= line.size()) return false;
    size_t start = i;
    if (line[i] == '-') ++i;
    while (i < line.size() && std::isdigit(static_cast<unsigned char>(line[i]))) ++i;
    if (i == start || (i == start + 1 && line[start] == '-')) return false;
    out_val = std::stoi(line.substr(start, i - start));
    return true;
}

void write_merged_jsonl(const BenchConfig& cfg, const std::vector<BenchResult>& results, size_t prev_flushed) {
    if (cfg.legacy || results.size() <= prev_flushed) return;

    bool preserve = cfg.append_mode || !cfg.groups.empty() || !cfg.filter.empty();
    std::map<int, std::string> by_rank;

    if (preserve) {
        std::ifstream existing(cfg.output_path);
        if (existing) {
            std::string line;
            while (std::getline(existing, line)) {
                std::string t = trim_str(line);
                if (t.empty()) continue;
                int r = 0;
                if (extract_json_int_field(t, "rank", r)) {
                    by_rank[r] = t;
                }
            }
        }
    }

    std::vector<std::string> newly_formatted;
    newly_formatted.reserve(results.size());
    for (const auto& r : results) {
        std::string js = format_result_json(r);
        by_rank[r.rank] = js;
        newly_formatted.push_back(std::move(js));
    }

    {
        std::ofstream out(cfg.output_path, std::ios::trunc);
        for (const auto& kv : by_rank) {
            out << kv.second << '\n';
        }
    }

    if (!cfg.no_history) {
        std::ofstream hist(cfg.history_path, std::ios::app);
        for (size_t i = prev_flushed; i < newly_formatted.size(); ++i) {
            hist << newly_formatted[i] << '\n';
        }
    }
}

void print_usage() {
    std::printf(
        "Usage: bench_arrow_cpp [options]\n"
        "  --runs N         Measured runs per benchmark (default: 5)\n"
        "  --warmup N       Warmup runs per benchmark (default: 1)\n"
        "  --n N            Override large array element count (default: 10000000)\n"
        "  --commit SHA     Override git commit SHA\n"
        "  --run-id ID      Override run ID\n"
        "  --lang NAME      Language tag in JSONL (default: cpp)\n"
        "  --output PATH    JSONL snapshot path (default: benchmarks/cpp.jsonl)\n"
        "  --history PATH   JSONL history path (default: benchmarks/history.jsonl)\n"
        "  --groups LIST    Comma-separated groups (builders,compute,strings,fusion,encoding,ipc)\n"
        "  --filter SUBSTR  Run only benchmarks matching substring\n"
        "  --append         Merge/update matching ranks into existing output\n"
        "  --no-history     Do not append to history JSONL\n"
        "  --legacy         Emit legacy key=ns lines only\n");
}

bool parse_cli_args(int argc, char** argv, BenchConfig& cfg, bool& show_help) {
    cfg.commit = resolve_git_commit(".");
    cfg.run_id = default_run_id();
    show_help = false;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        std::string val;
        bool has_inline = false;
        size_t eq = arg.find('=');
        if (eq != std::string::npos && eq > 0) {
            val = arg.substr(eq + 1);
            arg = arg.substr(0, eq);
            has_inline = true;
        }
        auto next_val = [&](std::string& out) -> bool {
            if (has_inline) { out = val; return true; }
            if (i + 1 >= argc) return false;
            out = argv[++i];
            return true;
        };

        if (arg == "-h" || arg == "--help") {
            show_help = true;
            return true;
        } else if (arg == "--append") {
            cfg.append_mode = true;
        } else if (arg == "--no-history") {
            cfg.no_history = true;
        } else if (arg == "--legacy") {
            cfg.legacy = true;
        } else if (arg == "--runs") {
            std::string v;
            if (!next_val(v)) return false;
            cfg.runs = std::stoi(v);
            if (cfg.runs < 1) return false;
        } else if (arg == "--warmup") {
            std::string v;
            if (!next_val(v)) return false;
            cfg.warmup = std::stoi(v);
            if (cfg.warmup < 0) return false;
        } else if (arg == "--n") {
            std::string v;
            if (!next_val(v)) return false;
            cfg.n_scale = std::stoll(v);
            if (cfg.n_scale < 1) return false;
        } else if (arg == "--commit") {
            if (!next_val(cfg.commit)) return false;
        } else if (arg == "--run-id") {
            if (!next_val(cfg.run_id)) return false;
        } else if (arg == "--lang") {
            if (!next_val(cfg.lang)) return false;
        } else if (arg == "--output") {
            if (!next_val(cfg.output_path)) return false;
        } else if (arg == "--history") {
            if (!next_val(cfg.history_path)) return false;
        } else if (arg == "--groups") {
            std::string v;
            if (!next_val(v)) return false;
            std::stringstream ss(v);
            std::string part;
            while (std::getline(ss, part, ',')) {
                std::string t = trim_str(part);
                if (!t.empty()) cfg.groups.push_back(t);
            }
        } else if (arg == "--filter") {
            if (!next_val(cfg.filter)) return false;
        } else {
            return false;
        }
    }
    return true;
}

bool matches_group(const BenchConfig& cfg, const std::string& g) {
    if (cfg.groups.empty()) return true;
    for (const auto& candidate : cfg.groups) {
        if (iequals(candidate, g)) return true;
    }
    return false;
}

bool matches_filter(const BenchConfig& cfg, const std::string& name) {
    if (cfg.filter.empty()) return true;
    return to_lower_str(name).find(to_lower_str(cfg.filter)) != std::string::npos;
}

void print_header(const BenchConfig& cfg) {
    if (cfg.legacy) return;
    std::printf(
        "Apache Arrow C++ Benchmarks (commit=%s, runs=%d, warmup=%d, lang=%s)\n",
        cfg.commit.c_str(), cfg.runs, cfg.warmup, cfg.lang.c_str());
    std::printf("-------------------------------------------------------------------------------------------------------------------------------\n");
    std::printf(
        "%-26s | %9s | %10s | %10s | %9s | %7s | %10s | %13s | %8s | %7s | %8s\n",
        "Benchmark", "Total(ms)", "Med(ns/op)", "Mean", "StdDev", "CV%", "p95", "Ops/s", "MB", "GB/s", "Allocs");
    std::printf("-------------------------------------------------------------------------------------------------------------------------------\n");
}

void print_result(const BenchResult& r, bool legacy) {
    if (legacy) {
        uint64_t eff_ops = (r.ops > 0) ? r.ops : 1;
        std::printf("%s=%.0f\n", r.name.c_str(), r.stats.median_ns * static_cast<double>(eff_ops));
        return;
    }
    double mb = static_cast<double>(r.bytes_used) / (1024.0 * 1024.0);
    std::printf(
        "%-26s | %9.3f | %10.4f | %10.4f | %9.4f | %6.2f%% | %10.4f | %13.0f | %8.2f | %7.2f | %8llu\n",
        r.name.c_str(),
        r.stats.total_ms,
        r.stats.median_ns,
        r.stats.mean_ns,
        r.stats.stddev_ns,
        r.stats.cv_pct,
        r.stats.p95_ns,
        r.stats.ops_per_sec,
        mb,
        r.stats.gb_per_sec,
        static_cast<unsigned long long>(r.allocs_per_run));
}

struct BenchContext {
    BenchConfig cfg;
    std::vector<BenchResult> results;
    size_t flushed_count = 0;

    void sizes(int64_t& n_large, int64_t& n_string) const {
        if (cfg.n_scale > 0) {
            n_large = cfg.n_scale;
            n_string = std::max<int64_t>(cfg.n_scale / 10, 1000);
        } else {
            n_large = DEFAULT_N_LARGE;
            n_string = DEFAULT_N_STRING;
        }
    }

    template <typename SetupFn, typename WorkFn, typename TeardownFn>
    void record(int rank, const std::string& group, const std::string& name,
                uint64_t ops, uint64_t bytes_used,
                SetupFn&& /*unused_tag*/, WorkFn&& work, TeardownFn&& after_stop) {
        std::vector<double> samples;
        samples.reserve(static_cast<size_t>(cfg.runs));
        int total = cfg.warmup + cfg.runs;
        uint64_t eff_ops = (ops > 0) ? ops : 1;
        arrow::MemoryPool* pool = arrow::default_memory_pool();
        uint64_t sum_allocs = 0;
        uint64_t sum_bytes = 0;
        uint64_t max_live = 0;

        for (int t = 0; t < total; ++t) {
            int64_t allocs0 = pool->num_allocations();
            int64_t bytes0  = pool->total_bytes_allocated();
            int64_t live0   = pool->bytes_allocated();
            auto t0 = std::chrono::steady_clock::now();
            work();
            auto t1 = std::chrono::steady_clock::now();
            int64_t allocs1 = pool->num_allocations();
            int64_t bytes1  = pool->total_bytes_allocated();
            int64_t live1   = pool->bytes_allocated();
            after_stop();
            double ns = static_cast<double>(
                std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count());
            if (t >= cfg.warmup) {
                int64_t d_allocs = std::max<int64_t>(0, allocs1 - allocs0);
                int64_t d_bytes  = std::max<int64_t>(0, bytes1 - bytes0);
                int64_t d_live   = std::max<int64_t>(0, live1 - live0);
                if (d_live == 0 && d_bytes > 0) {
                    d_live = d_bytes;
                }
                sum_allocs += static_cast<uint64_t>(d_allocs);
                sum_bytes  += static_cast<uint64_t>(d_bytes);
                max_live    = std::max<uint64_t>(max_live, static_cast<uint64_t>(d_live));
                samples.push_back(ns / static_cast<double>(eff_ops));
            }
        }
        uint64_t eff_runs = static_cast<uint64_t>(std::max(cfg.runs, 1));
        BenchResult r;
        r.rank = rank;
        r.group = group;
        r.lang = cfg.lang;
        r.commit = cfg.commit;
        r.run_id = cfg.run_id;
        r.name = name;
        r.ops = eff_ops;
        r.runs = cfg.runs;
        r.warmup = cfg.warmup;
        r.bytes_used = bytes_used;
        r.allocs_per_run = sum_allocs / eff_runs;
        r.resizes_per_run = 0;
        r.alloc_bytes_per_run = sum_bytes / eff_runs;
        r.peak_live_bytes = max_live;
        r.pool_hits = 0;
        r.pool_misses = 0;
        r.stats = compute_stats(samples, eff_ops, bytes_used);
        r.samples_ns = std::move(samples);
        results.push_back(std::move(r));
        print_result(results.back(), cfg.legacy);
    }
};

std::shared_ptr<arrow::Array> finish_builder(arrow::ArrayBuilder& b) {
    std::shared_ptr<arrow::Array> out;
    auto st = b.Finish(&out);
    if (!st.ok()) {
        std::fprintf(stderr, "Arrow builder finish failed: %s\n", st.ToString().c_str());
        std::exit(1);
    }
    return out;
}

std::shared_ptr<arrow::Array> make_i32_array(int64_t n, bool with_nulls) {
    arrow::Int32Builder b;
    (void)b.Reserve(n);
    for (int64_t i = 0; i < n; ++i) {
        if (with_nulls && (i % 100 == 0)) {
            (void)b.AppendNull();
        } else {
            (void)b.Append(static_cast<int32_t>(i % 100000));
        }
    }
    return finish_builder(b);
}

std::shared_ptr<arrow::Array> make_f64_array(int64_t n, bool with_nulls) {
    arrow::DoubleBuilder b;
    (void)b.Reserve(n);
    for (int64_t i = 0; i < n; ++i) {
        if (with_nulls && (i % 100 == 0)) {
            (void)b.AppendNull();
        } else {
            (void)b.Append(static_cast<double>(i % 10000) * 0.5);
        }
    }
    return finish_builder(b);
}

std::shared_ptr<arrow::Array> make_bool_mask(int64_t n) {
    arrow::BooleanBuilder b;
    (void)b.Reserve(n);
    for (int64_t i = 0; i < n; ++i) {
        (void)b.Append((i & 1) == 0);
    }
    return finish_builder(b);
}

std::shared_ptr<arrow::Array> make_sparse_bool_mask(int64_t n) {
    arrow::BooleanBuilder b;
    (void)b.Reserve(n);
    for (int64_t i = 0; i < n; ++i) {
        (void)b.Append((i % 100) == 0);
    }
    return finish_builder(b);
}

std::shared_ptr<arrow::Array> make_string_array(int64_t n) {
    static const char* kSamples[16] = {
        "alpha_0001", "bravo_0002", "charlie_03", "delta_0004",
        "echo_00005", "foxtrot_06", "golf_00007", "hotel_0008",
        "india_0009", "juliet_010", "kilo_00011", "lima_00012",
        "mike_00013", "nov_000014", "oscar_0015", "papa_00016",
    };
    arrow::StringBuilder b;
    (void)b.Reserve(n);
    (void)b.ReserveData(n * 11);
    for (int64_t i = 0; i < n; ++i) {
        if (i % 50 == 0) {
            (void)b.AppendNull();
        } else {
            (void)b.Append(kSamples[i & 15], 10);
        }
    }
    return finish_builder(b);
}

uint64_t array_bytes(const std::shared_ptr<arrow::Array>& arr) {
    uint64_t total = 0;
    for (const auto& buf : arr->data()->buffers) {
        if (buf) total += static_cast<uint64_t>(buf->size());
    }
    return total;
}

void group_builders(BenchContext& ctx) {
    int64_t n_large = 0, n_string = 0;
    ctx.sizes(n_large, n_string);
    if (!matches_filter(ctx.cfg, "array_build_10m_i32")) return;

    uint64_t bytes = static_cast<uint64_t>(n_large) * sizeof(int32_t) +
                     static_cast<uint64_t>((n_large + 7) / 8);
    std::shared_ptr<arrow::Array> built;
    ctx.record(
        1, "builders", "array_build_10m_i32", static_cast<uint64_t>(n_large), bytes, 0,
        [&]() {
            arrow::Int32Builder b;
            (void)b.Reserve(n_large);
            for (int64_t i = 0; i < n_large; ++i) {
                if (i % 100 == 0) {
                    (void)b.AppendNull();
                } else {
                    (void)b.Append(static_cast<int32_t>(i));
                }
            }
            built = finish_builder(b);
            g_sink_i64 = built->length();
        },
        [&]() { built.reset(); });
}

void group_compute(BenchContext& ctx) {
    namespace cp = arrow::compute;
    int64_t n_large = 0, n_string = 0;
    ctx.sizes(n_large, n_string);

    bool need_sum_f64   = matches_filter(ctx.cfg, "sum_10m_f64");
    bool need_sum_nulls = matches_filter(ctx.cfg, "sum_10m_f64_nulls");
    bool need_sum_i32   = matches_filter(ctx.cfg, "sum_10m_i32");
    bool need_mm        = matches_filter(ctx.cfg, "min_max_10m_i32");
    bool need_filter    = matches_filter(ctx.cfg, "filter_10m_i32");
    bool need_filter_sp = matches_filter(ctx.cfg, "filter_10m_i32_sparse");
    bool need_cmp_gt    = matches_filter(ctx.cfg, "compare_gt_10m_i32");
    bool need_cmp_gt_f64 = matches_filter(ctx.cfg, "compare_gt_10m_f64");
    bool need_arith_add = matches_filter(ctx.cfg, "arith_add_10m_f64");
    bool need_cast      = matches_filter(ctx.cfg, "cast_10m_i32_f64");
    bool need_take      = matches_filter(ctx.cfg, "take_1m_i32");
    bool need_sort      = matches_filter(ctx.cfg, "sort_indices_1m_i32");

    if (need_sum_f64 || need_arith_add || need_cmp_gt_f64) {
        auto arr = make_f64_array(n_large, false);
        if (need_sum_f64) {
            ctx.record(
                2, "compute", "sum_10m_f64", static_cast<uint64_t>(n_large), array_bytes(arr), 0,
                [&]() {
                    auto d = cp::Sum(arr).ValueOrDie();
                    g_sink_f64 = d.scalar_as<arrow::DoubleScalar>().value;
                },
                []() {});
        }
        if (need_arith_add) {
            arrow::Datum out;
            ctx.record(
                16, "compute", "arith_add_10m_f64", static_cast<uint64_t>(n_large), array_bytes(arr) * 2, 0,
                [&]() {
                    out = cp::Add(arr, arr).ValueOrDie();
                    g_sink_i64 = out.length();
                },
                [&]() { out = arrow::Datum(); });
        }
        if (need_cmp_gt_f64) {
            arrow::Datum out;
            ctx.record(
                31, "compute", "compare_gt_10m_f64", static_cast<uint64_t>(n_large), array_bytes(arr), 0,
                [&]() {
                    out = cp::CallFunction("greater", {arr, arrow::Datum(2500.0)}).ValueOrDie();
                    g_sink_i64 = out.length();
                },
                [&]() { out = arrow::Datum(); });
        }
    }

    if (need_sum_nulls) {
        auto arr = make_f64_array(n_large, true);
        ctx.record(
            4, "compute", "sum_10m_f64_nulls", static_cast<uint64_t>(n_large), array_bytes(arr), 0,
            [&]() {
                auto d = cp::Sum(arr).ValueOrDie();
                g_sink_f64 = d.scalar_as<arrow::DoubleScalar>().value;
            },
            []() {});
    }

    if (need_sum_i32 || need_mm || need_filter || need_filter_sp || need_cmp_gt || need_cast || need_take) {
        auto arr = make_i32_array(n_large, false);
        uint64_t abytes = array_bytes(arr);

        if (need_sum_i32) {
            ctx.record(
                6, "compute", "sum_10m_i32", static_cast<uint64_t>(n_large), abytes, 0,
                [&]() {
                    auto d = cp::Sum(arr).ValueOrDie();
                    g_sink_i64 = d.scalar_as<arrow::Int64Scalar>().value;
                },
                []() {});
        }

        if (need_mm) {
            ctx.record(
                8, "compute", "min_max_10m_i32", static_cast<uint64_t>(n_large), abytes, 0,
                [&]() {
                    auto d = cp::MinMax(arr).ValueOrDie();
                    const auto& ss = d.scalar_as<arrow::StructScalar>();
                    g_sink_i64 = static_cast<int64_t>(ss.value.size());
                },
                []() {});
        }

        if (need_filter) {
            auto mask = make_bool_mask(n_large);
            uint64_t fbytes = abytes + array_bytes(mask);
            arrow::Datum filtered;
            ctx.record(
                10, "compute", "filter_10m_i32", static_cast<uint64_t>(n_large), fbytes, 0,
                [&]() {
                    filtered = cp::Filter(arr, mask).ValueOrDie();
                    g_sink_i64 = filtered.length();
                },
                [&]() { filtered = arrow::Datum(); });
        }

        if (need_filter_sp) {
            auto sp_mask = make_sparse_bool_mask(n_large);
            uint64_t fbytes = abytes + array_bytes(sp_mask);
            arrow::Datum filtered;
            ctx.record(
                32, "compute", "filter_10m_i32_sparse", static_cast<uint64_t>(n_large), fbytes, 0,
                [&]() {
                    filtered = cp::Filter(arr, sp_mask).ValueOrDie();
                    g_sink_i64 = filtered.length();
                },
                [&]() { filtered = arrow::Datum(); });
        }

        if (need_cmp_gt) {
            arrow::Datum out;
            ctx.record(
                15, "compute", "compare_gt_10m_i32", static_cast<uint64_t>(n_large), abytes, 0,
                [&]() {
                    out = cp::CallFunction("greater", {arr, arrow::Datum(static_cast<int32_t>(50000))}).ValueOrDie();
                    g_sink_i64 = out.length();
                },
                [&]() { out = arrow::Datum(); });
        }

        if (need_cast) {
            arrow::Datum out;
            ctx.record(
                17, "compute", "cast_10m_i32_f64", static_cast<uint64_t>(n_large), abytes, 0,
                [&]() {
                    out = cp::Cast(*arr, arrow::float64()).ValueOrDie();
                    g_sink_i64 = out.length();
                },
                [&]() { out = arrow::Datum(); });
        }

        if (need_take) {
            arrow::Int64Builder ib;
            (void)ib.Reserve(n_string);
            for (int64_t i = 0; i < n_string; ++i) {
                (void)ib.Append(static_cast<int64_t>((static_cast<uint64_t>(i) * 2654435761ULL) % static_cast<uint64_t>(n_large)));
            }
            auto idx_arr = finish_builder(ib);
            uint64_t tbytes = array_bytes(idx_arr) + static_cast<uint64_t>(n_string) * sizeof(int32_t);
            arrow::Datum out;
            ctx.record(
                18, "compute", "take_1m_i32", static_cast<uint64_t>(n_string), tbytes, 0,
                [&]() {
                    out = cp::Take(arr, idx_arr).ValueOrDie();
                    g_sink_i64 = out.length();
                },
                [&]() { out = arrow::Datum(); });
        }
    }

    if (need_sort) {
        arrow::Int32Builder sb;
        (void)sb.Reserve(n_string);
        for (int64_t i = 0; i < n_string; ++i) {
            (void)sb.Append(static_cast<int32_t>((static_cast<uint64_t>(i) * 2654435761ULL) % 100000ULL));
        }
        auto sort_arr = finish_builder(sb);
        std::shared_ptr<arrow::Array> out;
        ctx.record(
            19, "compute", "sort_indices_1m_i32", static_cast<uint64_t>(n_string), array_bytes(sort_arr), 0,
            [&]() {
                out = cp::SortIndices(*sort_arr).ValueOrDie();
                g_sink_i64 = out->length();
            },
            [&]() { out.reset(); });
    }
}

void group_strings(BenchContext& ctx) {
    namespace cp = arrow::compute;
    int64_t n_large = 0, n_string = 0;
    ctx.sizes(n_large, n_string);

    static const char* kSamples[16] = {
        "alpha_0001", "bravo_0002", "charlie_03", "delta_0004",
        "echo_00005", "foxtrot_06", "golf_00007", "hotel_0008",
        "india_0009", "juliet_010", "kilo_00011", "lima_00012",
        "mike_00013", "nov_000014", "oscar_0015", "papa_00016",
    };

    if (matches_filter(ctx.cfg, "string_build_1m")) {
        uint64_t bytes = static_cast<uint64_t>(n_string) * 14 +
                         static_cast<uint64_t>((n_string + 7) / 8);
        std::shared_ptr<arrow::Array> built;
        ctx.record(
            12, "strings", "string_build_1m", static_cast<uint64_t>(n_string), bytes, 0,
            [&]() {
                arrow::StringBuilder b;
                (void)b.Reserve(n_string);
                (void)b.ReserveData(n_string * 11);
                for (int64_t i = 0; i < n_string; ++i) {
                    if (i % 50 == 0) {
                        (void)b.AppendNull();
                    } else {
                        (void)b.Append(kSamples[i & 15], 10);
                    }
                }
                built = finish_builder(b);
                g_sink_i64 = built->length();
            },
            [&]() { built.reset(); });
    }

    bool need_scan = matches_filter(ctx.cfg, "string_scan_1m");
    bool need_flt  = matches_filter(ctx.cfg, "filter_1m_string");
    if (need_scan || need_flt) {
        auto arr = make_string_array(n_string);
        if (need_scan) {
            auto sa = std::static_pointer_cast<arrow::StringArray>(arr);
            ctx.record(
                13, "strings", "string_scan_1m", static_cast<uint64_t>(n_string), array_bytes(arr), 0,
                [&]() {
                    int64_t total_len = 0;
                    for (int64_t i = 0; i < n_string; ++i) {
                        if (!sa->IsNull(i)) {
                            total_len += static_cast<int64_t>(sa->GetView(i).size());
                        }
                    }
                    g_sink_i64 = total_len;
                },
                []() {});
        }
        if (need_flt) {
            auto mask = make_bool_mask(n_string);
            uint64_t fbytes = array_bytes(arr) + array_bytes(mask);
            arrow::Datum filtered;
            ctx.record(
                20, "strings", "filter_1m_string", static_cast<uint64_t>(n_string), fbytes, 0,
                [&]() {
                    filtered = cp::Filter(arr, mask).ValueOrDie();
                    g_sink_i64 = filtered.length();
                },
                [&]() { filtered = arrow::Datum(); });
        }
    }

    if (matches_filter(ctx.cfg, "sort_indices_100k_str")) {
        int64_t n_sort_str = std::max<int64_t>(n_string / 10, 1000);
        static const char* kSortSamples[16] = {
            "alpha_key_000001", "bravo_key_000002", "charlie_key_0003", "delta_key_000004",
            "echo_key_0000005", "foxtrot_key_0006", "golf_key_0000007", "hotel_key_000008",
            "india_key_000009", "juliet_key_00010", "kilo_key_0000011", "lima_key_0000012",
            "mike_key_0000013", "novem_key_000014", "oscar_key_000015", "papa_key_0000016",
        };
        arrow::StringBuilder sb;
        (void)sb.Reserve(n_sort_str);
        (void)sb.ReserveData(n_sort_str * 16);
        for (int64_t i = 0; i < n_sort_str; ++i) {
            (void)sb.Append(kSortSamples[(static_cast<uint64_t>(i) * 2654435761ULL) & 15], 16);
        }
        auto str_arr = finish_builder(sb);
        std::shared_ptr<arrow::Array> idx;
        ctx.record(
            33, "strings", "sort_indices_100k_str", static_cast<uint64_t>(n_sort_str), array_bytes(str_arr), 0,
            [&]() {
                idx = cp::SortIndices(*str_arr).ValueOrDie();
                g_sink_i64 = idx->length();
            },
            [&]() { idx.reset(); });
    }
}

void group_fusion(BenchContext& ctx) {
    namespace cp = arrow::compute;
    int64_t n_large = 0, n_string = 0;
    ctx.sizes(n_large, n_string);

    bool need_sum_where = matches_filter(ctx.cfg, "sum_where_10m_f64");
    bool need_agg_where = matches_filter(ctx.cfg, "agg_where_10m_f64");
    bool need_sel_2pred = matches_filter(ctx.cfg, "sel_2pred_sum_10m_f64");
    if (!need_sum_where && !need_agg_where && !need_sel_2pred) return;

    auto arr_f64 = make_f64_array(n_large, false);
    uint64_t bytes = array_bytes(arr_f64);

    if (need_sum_where) {
        auto mask = make_bool_mask(n_large);
        ctx.record(
            22, "fusion", "sum_where_10m_f64", static_cast<uint64_t>(n_large), bytes + array_bytes(mask), 0,
            [&]() {
                auto f = cp::Filter(arr_f64, mask).ValueOrDie();
                auto d = cp::Sum(f).ValueOrDie();
                g_sink_f64 = d.scalar_as<arrow::DoubleScalar>().value;
            },
            []() {});
    }

    if (need_agg_where) {
        ctx.record(
            23, "fusion", "agg_where_10m_f64", static_cast<uint64_t>(n_large), bytes * 2, 0,
            [&]() {
                auto m = cp::CallFunction("greater", {arr_f64, arrow::Datum(2500.0)}).ValueOrDie();
                auto f = cp::Filter(arr_f64, m).ValueOrDie();
                auto s = cp::Sum(f).ValueOrDie();
                auto mm = cp::MinMax(f).ValueOrDie();
                auto c = cp::Count(f).ValueOrDie();
                g_sink_f64 = s.scalar_as<arrow::DoubleScalar>().value +
                             static_cast<double>(mm.scalar_as<arrow::StructScalar>().value.size()) +
                             static_cast<double>(c.scalar_as<arrow::Int64Scalar>().value);
            },
            []() {});
    }

    if (need_sel_2pred) {
        arrow::DoubleBuilder b1;
        (void)b1.Reserve(n_large);
        for (int64_t i = 0; i < n_large; ++i) {
            (void)b1.Append(static_cast<double>((i * 7 + 13) % 10000) * 0.5);
        }
        auto c1 = finish_builder(b1);
        ctx.record(
            24, "fusion", "sel_2pred_sum_10m_f64", static_cast<uint64_t>(n_large), bytes * 3, 0,
            [&]() {
                auto m0 = cp::CallFunction("greater", {arr_f64, arrow::Datum(2500.0)}).ValueOrDie();
                auto m1 = cp::CallFunction("greater", {c1, arrow::Datum(2500.0)}).ValueOrDie();
                auto m = cp::And(m0, m1).ValueOrDie();
                auto f = cp::Filter(arr_f64, m).ValueOrDie();
                auto d = cp::Sum(f).ValueOrDie();
                g_sink_f64 = d.scalar_as<arrow::DoubleScalar>().value;
            },
            []() {});
    }
}

void group_encoding(BenchContext& ctx) {
    namespace cp = arrow::compute;
    int64_t n_large = 0, n_string = 0;
    ctx.sizes(n_large, n_string);

    static const char* kSamples[16] = {
        "alpha_0001", "bravo_0002", "charlie_03", "delta_0004",
        "echo_00005", "foxtrot_06", "golf_00007", "hotel_0008",
        "india_0009", "juliet_010", "kilo_00011", "lima_00012",
        "mike_00013", "nov_000014", "oscar_0015", "papa_00016",
    };

    if (matches_filter(ctx.cfg, "dict_vc_1m_str")) {
        arrow::StringDictionaryBuilder db;
        (void)db.Reserve(n_string);
        for (int64_t i = 0; i < n_string; ++i) {
            (void)db.Append(kSamples[i & 15], 10);
        }
        auto dict_arr = finish_builder(db);
        std::shared_ptr<arrow::Array> vc;
        ctx.record(
            25, "encoding", "dict_vc_1m_str", static_cast<uint64_t>(n_string),
            static_cast<uint64_t>(n_string) * sizeof(int32_t), 0,
            [&]() {
                vc = cp::ValueCounts(dict_arr).ValueOrDie();
                g_sink_i64 = vc->length();
            },
            [&]() { vc.reset(); });
    }

    if (matches_filter(ctx.cfg, "rle_sum_10m_f64")) {
        arrow::DoubleBuilder rb;
        (void)rb.Reserve(n_large);
        for (int64_t i = 0; i < n_large; ++i) {
            (void)rb.Append(static_cast<double>(i / 1000));
        }
        auto plain_arr = finish_builder(rb);
        ctx.record(
            26, "encoding", "rle_sum_10m_f64", static_cast<uint64_t>(n_large), array_bytes(plain_arr), 0,
            [&]() {
                auto d = cp::Sum(plain_arr).ValueOrDie();
                g_sink_f64 = d.scalar_as<arrow::DoubleScalar>().value;
            },
            []() {});
    }

    if (matches_filter(ctx.cfg, "umbra_sort_100k_str")) {
        int64_t n_umbra = std::max<int64_t>(n_string / 10, 1000);
        static const char* kUmbraSamples[16] = {
            "alpha_key_000001", "bravo_key_000002", "charlie_key_0003", "delta_key_000004",
            "echo_key_0000005", "foxtrot_key_0006", "golf_key_0000007", "hotel_key_000008",
            "india_key_000009", "juliet_key_00010", "kilo_key_0000011", "lima_key_0000012",
            "mike_key_0000013", "novem_key_000014", "oscar_key_000015", "papa_key_0000016",
        };
        arrow::StringBuilder sb;
        (void)sb.Reserve(n_umbra);
        (void)sb.ReserveData(n_umbra * 16);
        for (int64_t i = 0; i < n_umbra; ++i) {
            (void)sb.Append(kUmbraSamples[(static_cast<uint64_t>(i) * 2654435761ULL) & 15], 16);
        }
        auto str_arr = finish_builder(sb);
        std::shared_ptr<arrow::Array> idx;
        ctx.record(
            27, "encoding", "umbra_sort_100k_str", static_cast<uint64_t>(n_umbra), array_bytes(str_arr), 0,
            [&]() {
                idx = cp::SortIndices(*str_arr).ValueOrDie();
                g_sink_i64 = idx->length();
            },
            [&]() { idx.reset(); });
    }
}

void group_ipc(BenchContext& ctx) {
    int64_t n_large = 0, n_string = 0;
    ctx.sizes(n_large, n_string);
    bool need_rt    = matches_filter(ctx.cfg, "ipc_roundtrip_10m_i32");
    bool need_write = matches_filter(ctx.cfg, "ipc_write_10m_i32");
    bool need_read  = matches_filter(ctx.cfg, "ipc_read_mmap_10m_i32");
    if (!need_rt && !need_write && !need_read) return;

    auto schema = arrow::schema({arrow::field("x", arrow::int32(), false)});
    auto arr = make_i32_array(n_large, false);
    auto batch = arrow::RecordBatch::Make(schema, n_large, {arr});
    const char* path = "/tmp/arrow_cpp_bench_ipc_1v1.arrow";

    if (need_rt) {
        std::shared_ptr<arrow::RecordBatch> read_back;
        ctx.record(
            14, "ipc", "ipc_roundtrip_10m_i32", static_cast<uint64_t>(n_large), array_bytes(arr), 0,
            [&]() {
                auto out = arrow::io::FileOutputStream::Open(path).ValueOrDie();
                auto w = arrow::ipc::MakeFileWriter(out, schema).ValueOrDie();
                (void)w->WriteRecordBatch(*batch);
                (void)w->Close();
                (void)out->Close();

                auto in = arrow::io::ReadableFile::Open(path).ValueOrDie();
                auto rd = arrow::ipc::RecordBatchFileReader::Open(in).ValueOrDie();
                read_back = rd->ReadRecordBatch(0).ValueOrDie();
                (void)in->Close();
                g_sink_i64 = read_back->num_rows();
            },
            [&]() { read_back.reset(); });
    }

    if (need_write) {
        ctx.record(
            28, "ipc", "ipc_write_10m_i32", static_cast<uint64_t>(n_large), array_bytes(arr), 0,
            [&]() {
                auto out = arrow::io::FileOutputStream::Open(path).ValueOrDie();
                auto w = arrow::ipc::MakeFileWriter(out, schema).ValueOrDie();
                (void)w->WriteRecordBatch(*batch);
                (void)w->Close();
                (void)out->Close();
                g_sink_i64 = 1;
            },
            []() {});
    }

    if (need_read) {
        {
            auto out = arrow::io::FileOutputStream::Open(path).ValueOrDie();
            auto w = arrow::ipc::MakeFileWriter(out, schema).ValueOrDie();
            (void)w->WriteRecordBatch(*batch);
            (void)w->Close();
            (void)out->Close();
        }
        std::shared_ptr<arrow::RecordBatch> read_back;
        ctx.record(
            29, "ipc", "ipc_read_mmap_10m_i32", static_cast<uint64_t>(n_large), array_bytes(arr), 0,
            [&]() {
                auto in = arrow::io::MemoryMappedFile::Open(path, arrow::io::FileMode::READ).ValueOrDie();
                auto rd = arrow::ipc::RecordBatchFileReader::Open(in).ValueOrDie();
                read_back = rd->ReadRecordBatch(0).ValueOrDie();
                (void)in->Close();
                g_sink_i64 = read_back->num_rows();
            },
            [&]() { read_back.reset(); });
    }

    std::remove(path);
}

template <typename Fn>
void run_group(BenchContext& ctx, const std::string& group_name, Fn&& fn) {
    if (!matches_group(ctx.cfg, group_name)) return;
    fn(ctx);
    write_merged_jsonl(ctx.cfg, ctx.results, ctx.flushed_count);
    ctx.flushed_count = ctx.results.size();
}

}  // namespace

int main(int argc, char** argv) {
    if (!arrow::compute::Initialize().ok()) {
        std::fprintf(stderr, "Failed to initialize arrow::compute.\n");
        return 1;
    }

    BenchContext ctx;
    bool show_help = false;
    if (!parse_cli_args(argc, argv, ctx.cfg, show_help)) {
        std::fprintf(stderr, "Invalid command-line arguments.\n");
        print_usage();
        return 1;
    }
    if (show_help) {
        print_usage();
        return 0;
    }

    print_header(ctx.cfg);
    run_group(ctx, "builders", group_builders);
    run_group(ctx, "compute",  group_compute);
    run_group(ctx, "strings",  group_strings);
    run_group(ctx, "fusion",   group_fusion);
    run_group(ctx, "encoding", group_encoding);
    run_group(ctx, "ipc",      group_ipc);

    return 0;
}
