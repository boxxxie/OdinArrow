#!/usr/bin/env python3
"""Unit tests for benchmarks/compare_1v1.py statistical aggregation and comparison."""

from __future__ import annotations

import json
import math
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare_1v1 as cmp  # noqa: E402


class TestCompare1v1(unittest.TestCase):
    def test_percentile_and_compute_stats_sub_ns(self) -> None:
        samples = [0.20, 0.22, 0.24, 0.26, 0.28]
        st = cmp.compute_stats(samples, ops=10_000_000, bytes_used=80_000_000)
        self.assertAlmostEqual(st["median_ns"], 0.24, places=9)
        self.assertAlmostEqual(st["mean_ns"], 0.24, places=9)
        self.assertAlmostEqual(st["iqr_ns"], 0.04, places=9)
        self.assertAlmostEqual(st["variance_ns2"], 0.001, places=12)
        self.assertAlmostEqual(st["stddev_ns"], math.sqrt(0.001), places=9)
        self.assertAlmostEqual(st["p95_ns"], 0.276, places=9)
        self.assertAlmostEqual(st["total_ms"], 2.4, places=9)
        self.assertAlmostEqual(st["gb_per_sec"], 80_000_000 / 2_400_000.0, places=9)

    def test_pool_records_across_sessions(self) -> None:
        r1 = {
            "rank": 2,
            "group": "compute",
            "lang": "odin",
            "commit": "aaa1111",
            "run_id": "run1",
            "name": "sum_10m_f64_st",
            "ops": 10_000_000,
            "bytes_used": 80_000_000,
            "allocs_per_run": 4,
            "resizes_per_run": 0,
            "alloc_bytes_per_run": 2048,
            "peak_live_bytes": 1024,
            "pool_hits": 2,
            "pool_misses": 2,
            "samples_ns": [0.20, 0.22],
        }
        r2 = {
            "rank": 2,
            "group": "compute",
            "lang": "odin",
            "commit": "aaa1111",
            "run_id": "run2",
            "name": "sum_10m_f64_st",
            "ops": 10_000_000,
            "bytes_used": 80_000_000,
            "allocs_per_run": 6,
            "resizes_per_run": 2,
            "alloc_bytes_per_run": 4096,
            "peak_live_bytes": 4096,
            "pool_hits": 4,
            "pool_misses": 0,
            "samples_ns": [0.24, 0.26, 0.28],
        }
        pooled = cmp.pool_records([r1, r2], key_by_commit=True)
        self.assertEqual(len(pooled), 1)
        p = pooled[0]
        self.assertEqual(p["runs"], 5)
        self.assertEqual(p["session_count"], 2)
        self.assertAlmostEqual(p["median_ns"], 0.24, places=9)
        self.assertAlmostEqual(st_gbps := p["gb_per_sec"], 80_000_000 / 2_400_000.0, places=9)
        _ = st_gbps
        self.assertAlmostEqual(p["variance_ns2"], 0.001, places=12)
        self.assertTrue(p["has_alloc_telemetry"])
        self.assertEqual(p["allocs_per_run"], 5)
        self.assertEqual(p["resizes_per_run"], 1)
        self.assertEqual(p["alloc_bytes_per_run"], 3072)
        self.assertEqual(p["peak_live_bytes"], 4096)
        self.assertEqual(p["pool_hits"], 3)
        self.assertEqual(p["pool_misses"], 1)

    def test_welch_z_score_significance(self) -> None:
        fast = {"mean_ns": 0.20, "variance_ns2": 0.0001, "runs": 5, "samples_ns": [0.20] * 5}
        slow = {"mean_ns": 0.40, "variance_ns2": 0.0001, "runs": 5, "samples_ns": [0.40] * 5}
        z, sig = cmp.welch_z_score(fast, slow)
        self.assertGreater(z, 1.96)
        self.assertEqual(sig, "*")

        noisy_a = {"mean_ns": 1.00, "variance_ns2": 0.5, "runs": 3, "samples_ns": [0.5, 1.0, 1.5]}
        noisy_b = {"mean_ns": 1.05, "variance_ns2": 0.5, "runs": 3, "samples_ns": [0.55, 1.05, 1.55]}
        z2, sig2 = cmp.welch_z_score(noisy_a, noisy_b)
        self.assertLess(z2, 1.96)
        self.assertEqual(sig2, "~")

    def test_pair_st_mt_and_reports(self) -> None:
        odin_st = cmp.pool_records([{
            "rank": 2, "group": "compute", "lang": "odin", "commit": "c1", "run_id": "1",
            "name": "sum_10m_f64_st", "ops": 10_000_000, "samples_ns": [0.30, 0.30, 0.30, 0.31, 0.29],
        }])[0]
        odin_mt = cmp.pool_records([{
            "rank": 3, "group": "compute", "lang": "odin", "commit": "c1", "run_id": "1",
            "name": "sum_10m_f64_mt", "ops": 10_000_000, "samples_ns": [0.10, 0.10, 0.10, 0.10, 0.10],
        }])[0]
        cpp_st = cmp.pool_records([{
            "rank": 2, "group": "compute", "lang": "cpp", "commit": "c1", "run_id": "1",
            "name": "sum_10m_f64", "ops": 10_000_000, "samples_ns": [0.60, 0.60, 0.61, 0.59, 0.60],
        }])[0]

        rows = cmp.pair_benchmarks([odin_st, odin_mt], [cpp_st])
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["base_name"], "sum_10m_f64")
        self.assertAlmostEqual(row["st_speedup"], 2.0, places=6)
        self.assertAlmostEqual(row["mt_speedup"], 6.0, places=6)
        self.assertAlmostEqual(row["mt_scale"], 3.0, places=6)
        self.assertEqual(row["sig_st"], "*")

        hist = [
            {
                "rank": 2, "group": "compute", "lang": "odin", "commit": "c1", "run_id": "1",
                "name": "sum_10m_f64_st", "ops": 10_000_000, "samples_ns": [0.50, 0.50, 0.51, 0.49, 0.50],
            },
            {
                "rank": 2, "group": "compute", "lang": "odin", "commit": "c2", "run_id": "2",
                "name": "sum_10m_f64_st", "ops": 10_000_000, "samples_ns": [0.25, 0.25, 0.25, 0.26, 0.24],
            },
        ]
        commits_out = cmp.list_commits_report(hist)
        self.assertIn("c1", commits_out)
        self.assertIn("c2", commits_out)

        inspect_out = cmp.inspect_report(hist, "sum_10m_f64")
        self.assertIn("sum_10m_f64_st", inspect_out)

        cmp_out = cmp.compare_commits_report(hist, "c1", "c2", "odin")
        self.assertIn("FASTER*", cmp_out)

    def test_session_comparison_delta_prev_and_rendering(self) -> None:
        hist = [
            {
                "rank": 12, "group": "strings", "lang": "odin", "commit": "fa6a1e4", "run_id": "1000",
                "name": "string_build_1m", "ops": 1_000_000, "bytes_used": 14_125_000,
                "allocs_per_run": 10, "alloc_bytes_per_run": 10_485_760, "pool_hits": 4, "pool_misses": 6,
                "samples_ns": [5.00, 5.01, 4.99, 5.00, 5.00],
            },
            {
                "rank": 12, "group": "strings", "lang": "cpp", "commit": "fa6a1e4", "run_id": "1001",
                "name": "string_build_1m", "ops": 1_000_000, "bytes_used": 14_125_000,
                "allocs_per_run": 8, "alloc_bytes_per_run": 14_680_064,
                "samples_ns": [4.80, 4.80, 4.81, 4.79, 4.80],
            },
            {
                "rank": 12, "group": "strings", "lang": "odin", "commit": "fa6a1e4", "run_id": "2000",
                "name": "string_build_1m", "ops": 1_000_000, "bytes_used": 14_125_000,
                "allocs_per_run": 3, "alloc_bytes_per_run": 5_242_880, "pool_hits": 3, "pool_misses": 0,
                "samples_ns": [2.50, 2.50, 2.51, 2.49, 2.50],
            },
            {
                "rank": 12, "group": "strings", "lang": "cpp", "commit": "fa6a1e4", "run_id": "2000",
                "name": "string_build_1m", "ops": 1_000_000, "bytes_used": 14_125_000,
                "allocs_per_run": 8, "alloc_bytes_per_run": 14_680_064,
                "samples_ns": [4.80, 4.80, 4.80, 4.80, 4.80],
            },
        ]

        runs_out = cmp.list_runs_report(hist)
        self.assertIn("1000", runs_out)
        self.assertIn("2000", runs_out)

        cmp_runs_out = cmp.compare_runs_report(hist, "1000", "2000", "odin")
        self.assertIn("FASTER*", cmp_runs_out)
        self.assertIn("-50.00%", cmp_runs_out)

        cmp_last_out = cmp.compare_last_report(hist, "both")
        self.assertIn("Latest session diff [odin]: 1000 (prev) -> 2000 (latest)", cmp_last_out)
        self.assertIn("Latest session diff [cpp]: 1001 (prev) -> 2000 (latest)", cmp_last_out)

        curr_odin = [r for r in hist if r["lang"] == "odin" and r["run_id"] == "2000"]
        curr_cpp = [r for r in hist if r["lang"] == "cpp" and r["run_id"] == "2000"]
        prev_odin = cmp.resolve_previous_odin_records(curr_odin, hist)
        self.assertEqual(len(prev_odin), 1)
        self.assertEqual(prev_odin[0]["run_ids"], ["1000"])

        odin_pooled = cmp.pool_records(curr_odin)
        cpp_pooled = cmp.pool_records(curr_cpp)
        rows = cmp.pair_benchmarks(odin_pooled, cpp_pooled, prev_odin)
        self.assertEqual(len(rows), 1)
        self.assertAlmostEqual(rows[0]["delta_prev_pct"], -50.0, places=6)
        self.assertEqual(rows[0]["sig_prev"], "*")

        term_table = cmp.render_1v1_table(rows, markdown=False)
        self.assertIn("Δ Prev", term_table)
        self.assertIn("-50.0%*", term_table)
        self.assertIn("3(3p)/8", term_table)
        self.assertIn("5.7", term_table)  # 14.125 MB / 2.5 ms = 5.65 GB/s -> 5.7

        md_table = cmp.render_1v1_table(rows, markdown=True)
        self.assertIn("Allocs (Odin/C++)", md_table)
        self.assertIn("Alloc MB (Odin/C++)", md_table)
        self.assertIn("5.0/14.0", md_table)

    def test_update_readme_markers(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "RESULTS.md"
            p.write_text("# Results\n\n<!-- BENCHMARK_1V1_START -->\nold\n<!-- BENCHMARK_1V1_END -->\n", encoding="utf-8")
            cmp.update_readme_results(p, "| a | b |")
            txt = p.read_text(encoding="utf-8")
            self.assertIn("| a | b |", txt)
            self.assertNotIn("\nold\n", txt)
            # Idempotent re-write
            cmp.update_readme_results(p, "| c | d |")
            txt2 = p.read_text(encoding="utf-8")
            self.assertIn("| c | d |", txt2)
            self.assertNotIn("| a | b |", txt2)
            _ = json  # silence unused lint if checked


if __name__ == "__main__":
    unittest.main()
