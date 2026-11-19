#!/usr/bin/env python3
"""Statistical 1v1 benchmark runner, pooler, and regression comparator for Skadi."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent


def resolve_git_commit(repo_root: Path = ROOT) -> str:
    """Resolve current Git HEAD commit SHA (7 chars) without spawning git when possible."""
    git_dir = repo_root / ".git"
    head_file = git_dir / "HEAD"
    if not head_file.exists():
        return "unknown"
    head = head_file.read_text(encoding="utf-8").strip()
    if head.startswith("ref: "):
        ref_rel = head[5:].strip()
        ref_file = git_dir / ref_rel
        if ref_file.exists():
            sha = ref_file.read_text(encoding="utf-8").strip()
            return sha[:7] if sha else "unknown"
        packed = git_dir / "packed-refs"
        if packed.exists():
            for line in packed.read_text(encoding="utf-8").splitlines():
                t = line.strip()
                if not t or t.startswith("#") or t.startswith("^"):
                    continue
                parts = t.split()
                if len(parts) >= 2 and parts[1] == ref_rel:
                    return parts[0][:7]
        return "unknown"
    return head[:7] if head else "unknown"


def canonical_name(name: str) -> tuple[str, str]:
    """Return (canonical_base_name, variant) where variant is 'st' or 'mt'."""
    if name.endswith("_mt"):
        return name[:-3], "mt"
    if name.endswith("_st"):
        return name[:-3], "st"
    return name, "st"


def percentile_sorted(sorted_vals: list[float], p: float) -> float:
    """Linear-interpolated percentile over a sorted non-empty list."""
    n = len(sorted_vals)
    if n == 0:
        return 0.0
    if n == 1:
        return float(sorted_vals[0])
    clamped = max(0.0, min(1.0, p))
    pos = clamped * (n - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return float(sorted_vals[lo])
    frac = pos - lo
    return sorted_vals[lo] * (1.0 - frac) + sorted_vals[hi] * frac


def compute_stats(samples_ns: list[float], ops: int, bytes_used: int = 0) -> dict[str, float]:
    """Compute descriptive and quantile statistics matching the Odin/C++ harnesses."""
    n = len(samples_ns)
    if n == 0:
        return {
            "median_ns": 0.0,
            "mean_ns": 0.0,
            "stddev_ns": 0.0,
            "variance_ns2": 0.0,
            "cv_pct": 0.0,
            "min_ns": 0.0,
            "max_ns": 0.0,
            "iqr_ns": 0.0,
            "p95_ns": 0.0,
            "p99_ns": 0.0,
            "total_ms": 0.0,
            "ops_per_sec": 0.0,
            "gb_per_sec": 0.0,
        }
    vals = [float(x) for x in samples_ns]
    s = sorted(vals)
    mean = sum(vals) / n
    if n > 1:
        variance = sum((x - mean) ** 2 for x in vals) / (n - 1)
    else:
        variance = 0.0
    stddev = math.sqrt(variance)
    cv_pct = (stddev / mean) * 100.0 if mean > 0.0 else 0.0
    med = percentile_sorted(s, 0.50)
    q25 = percentile_sorted(s, 0.25)
    q75 = percentile_sorted(s, 0.75)
    p95 = percentile_sorted(s, 0.95)
    p99 = percentile_sorted(s, 0.99)
    eff_ops = max(int(ops), 1)
    total_ns = med * eff_ops
    total_ms = total_ns / 1_000_000.0
    ops_per_sec = (1_000_000_000.0 / med) if med > 0.0 else 0.0
    gb_per_sec = (float(bytes_used) / total_ns) if (total_ns > 0.0 and bytes_used > 0) else 0.0
    return {
        "median_ns": med,
        "mean_ns": mean,
        "stddev_ns": stddev,
        "variance_ns2": variance,
        "cv_pct": cv_pct,
        "min_ns": s[0],
        "max_ns": s[-1],
        "iqr_ns": q75 - q25,
        "p95_ns": p95,
        "p99_ns": p99,
        "total_ms": total_ms,
        "ops_per_sec": ops_per_sec,
        "gb_per_sec": gb_per_sec,
    }


def welch_z_score(rec_a: dict[str, Any], rec_b: dict[str, Any]) -> tuple[float, str]:
    """Compute Welch's two-sample z-statistic and significance marker ('*' or '~')."""
    n_a = max(len(rec_a.get("samples_ns", [])), int(rec_a.get("runs", 0)))
    n_b = max(len(rec_b.get("samples_ns", [])), int(rec_b.get("runs", 0)))
    if n_a <= 0 or n_b <= 0:
        return 0.0, "~"
    mean_a = float(rec_a["mean_ns"])
    mean_b = float(rec_b["mean_ns"])
    var_a = float(rec_a.get("variance_ns2", 0.0))
    var_b = float(rec_b.get("variance_ns2", 0.0))
    se2 = (var_a / n_a) + (var_b / n_b)
    if se2 <= 0.0:
        if math.isclose(mean_a, mean_b, rel_tol=1e-9, abs_tol=1e-12):
            return 0.0, "~"
        return math.inf, "*"
    z = abs(mean_a - mean_b) / math.sqrt(se2)
    return z, ("*" if z >= 1.96 else "~")


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    """Read non-empty JSON lines from path."""
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        records.append(json.loads(line))
    return records


def _resolve_hugi_bin() -> str:
    found = shutil.which("hugi")
    if found:
        return found
    local_bin = Path.home() / ".local" / "bin" / "hugi"
    if local_bin.exists():
        return str(local_bin)
    return "hugi"


def map_hugi_record(rec: dict[str, Any]) -> dict[str, Any]:
    """Map a hugi JSONL export record to the internal compare_1v1 record shape."""
    ops = max(int(rec.get("ops_per_sample", rec.get("ops", 1))), 1)
    p50 = float(rec.get("p50_ns", rec.get("median_ns", 0.0)))
    stddev = float(rec.get("std_dev_ns", rec.get("stddev_ns", 0.0)))
    mb_per_sec = float(rec.get("mb_per_sec", 0.0))
    bytes_per_op = int(rec.get("bytes_per_op", 0))
    footprint = int(rec.get("footprint_bytes", 0))
    bytes_used = footprint if footprint > 0 else bytes_per_op * ops
    samples_ns = [float(x) for x in rec.get("samples_ns", [])]
    runs = int(rec.get("run_count", rec.get("runs", 0))) or len(samples_ns)
    name = str(rec.get("full_name") or rec.get("name", ""))
    group = str(rec.get("group_name") or rec.get("group", ""))
    return {
        "rank": int(rec.get("rank", 9999)),
        "group": group,
        "lang": str(rec.get("lang", "")),
        "commit": str(rec.get("commit", "")),
        "run_id": str(rec.get("run_id", "")),
        "name": name,
        "ops": ops,
        "runs": runs,
        "warmup": int(rec.get("warmup", 1)),
        "total_ms": (p50 * ops) / 1_000_000.0,
        "ns_per_op": p50,
        "mean_ns": float(rec.get("mean_ns", p50)),
        "median_ns": p50,
        "stddev_ns": stddev,
        "variance_ns2": stddev * stddev,
        "cv_pct": float(rec.get("cv_pct", 0.0)),
        "min_ns": float(rec.get("min_ns", 0.0)),
        "max_ns": float(rec.get("max_ns", 0.0)),
        "iqr_ns": float(rec.get("iqr_ns", 0.0)),
        "p95_ns": float(rec.get("p95_ns", 0.0)),
        "p99_ns": float(rec.get("p99_ns", 0.0)),
        "ops_per_sec": float(rec.get("ops_per_sec", 0.0)),
        "gb_per_sec": mb_per_sec / 1024.0,
        "bytes_used": bytes_used,
        "allocs_per_run": round(float(rec.get("allocs_per_op", 0.0)) * ops),
        "resizes_per_run": int(rec.get("resizes_per_run", 0)),
        "alloc_bytes_per_run": round(float(rec.get("alloc_bytes_per_op", 0.0)) * ops),
        "peak_live_bytes": int(rec.get("peak_heap_bytes", 0)),
        "pool_hits": int(rec.get("pool_hits", 0)),
        "pool_misses": int(rec.get("pool_misses", 0)),
        "samples_ns": samples_ns,
    }


def load_hugidb(db_path: Path) -> list[dict[str, Any]]:
    """Invoke `hugi export` on a .hugidb store and map JSONL rows into internal dicts."""
    if not db_path.exists():
        return []
    cmd = [
        _resolve_hugi_bin(),
        "export",
        "--db",
        str(db_path),
        "--lang",
        "all",
        "--all-commits",
        "--format",
        "jsonl",
        "--out",
        "-",
    ]
    proc = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr.strip()}"
        )
    records: list[dict[str, Any]] = []
    for raw in proc.stdout.splitlines():
        line = raw.strip()
        if not line:
            continue
        records.append(map_hugi_record(json.loads(line)))
    return records


def pool_records(records: list[dict[str, Any]], key_by_commit: bool = False) -> list[dict[str, Any]]:
    """Pool samples_ns across matching (lang, name) or (commit, lang, name) records."""
    grouped: dict[tuple[Any, ...], list[dict[str, Any]]] = defaultdict(list)
    for rec in records:
        if key_by_commit:
            k = (str(rec.get("commit", "")), str(rec.get("lang", "")), str(rec.get("name", "")))
        else:
            k = (str(rec.get("lang", "")), str(rec.get("name", "")))
        grouped[k].append(rec)

    pooled: list[dict[str, Any]] = []
    for _, recs in grouped.items():
        all_samples: list[float] = []
        run_ids: list[str] = []
        commits: list[str] = []
        rank = min(int(r.get("rank", 9999)) for r in recs)
        ops = max(int(r.get("ops", 1)) for r in recs)
        bytes_used = max(int(r.get("bytes_used", 0)) for r in recs)
        group = str(recs[-1].get("group", ""))
        lang = str(recs[-1].get("lang", ""))
        name = str(recs[-1].get("name", ""))

        for r in recs:
            rid = str(r.get("run_id", ""))
            if rid and rid not in run_ids:
                run_ids.append(rid)
            c = str(r.get("commit", ""))
            if c and c not in commits:
                commits.append(c)
            s_list = r.get("samples_ns")
            if isinstance(s_list, list) and s_list:
                all_samples.extend(float(x) for x in s_list)
            elif "median_ns" in r:
                all_samples.append(float(r["median_ns"]))

        st = compute_stats(all_samples, ops, bytes_used)
        if st["gb_per_sec"] == 0.0 and bytes_used == 0:
            gb_vals = [float(r.get("gb_per_sec", 0.0)) for r in recs if float(r.get("gb_per_sec", 0.0)) > 0.0]
            if gb_vals:
                st["gb_per_sec"] = gb_vals[-1]
        telem_recs = [
            r for r in recs
            if any(k in r for k in ("allocs_per_run", "alloc_bytes_per_run", "peak_live_bytes", "pool_hits"))
        ]
        if telem_recs:
            nt = len(telem_recs)
            allocs_per_run = round(sum(int(r.get("allocs_per_run", 0)) for r in telem_recs) / nt)
            resizes_per_run = round(sum(int(r.get("resizes_per_run", 0)) for r in telem_recs) / nt)
            alloc_bytes_per_run = round(sum(int(r.get("alloc_bytes_per_run", 0)) for r in telem_recs) / nt)
            peak_live_bytes = max(int(r.get("peak_live_bytes", 0)) for r in telem_recs)
            pool_hits = round(sum(int(r.get("pool_hits", 0)) for r in telem_recs) / nt)
            pool_misses = round(sum(int(r.get("pool_misses", 0)) for r in telem_recs) / nt)
        else:
            allocs_per_run = 0
            resizes_per_run = 0
            alloc_bytes_per_run = 0
            peak_live_bytes = 0
            pool_hits = 0
            pool_misses = 0

        out = {
            "rank": rank,
            "group": group,
            "lang": lang,
            "commit": commits[-1] if commits else "unknown",
            "run_ids": run_ids,
            "session_count": len(run_ids) if run_ids else len(recs),
            "name": name,
            "ops": ops,
            "runs": len(all_samples),
            "bytes_used": bytes_used,
            "allocs_per_run": allocs_per_run,
            "resizes_per_run": resizes_per_run,
            "alloc_bytes_per_run": alloc_bytes_per_run,
            "peak_live_bytes": peak_live_bytes,
            "pool_hits": pool_hits,
            "pool_misses": pool_misses,
            "has_alloc_telemetry": bool(telem_recs),
            "samples_ns": all_samples,
            "ns_per_op": st["median_ns"],
            **st,
        }
        pooled.append(out)

    pooled.sort(key=lambda r: (int(r["rank"]), str(r["lang"]), str(r["name"])))
    return pooled


def resolve_previous_odin_records(
    current_odin_recs: list[dict[str, Any]],
    history_recs: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Find the most recent prior session records in history for each current Odin benchmark."""
    if not current_odin_recs or not history_recs:
        return []

    curr_run_by_name: dict[str, str] = {}
    for rec in current_odin_recs:
        name = str(rec.get("name", ""))
        rid = str(rec.get("run_id", ""))
        if name:
            curr_run_by_name[name] = rid

    hist_by_name: dict[str, list[tuple[str, list[dict[str, Any]]]]] = {}
    for rec in history_recs:
        if str(rec.get("lang", "")) != "odin":
            continue
        name = str(rec.get("name", ""))
        if name not in curr_run_by_name:
            continue
        rid = str(rec.get("run_id", ""))
        sessions = hist_by_name.setdefault(name, [])
        if rid and sessions and sessions[-1][0] == rid:
            sessions[-1][1].append(rec)
        elif rid:
            found = False
            for s_rid, s_recs in sessions:
                if s_rid == rid:
                    s_recs.append(rec)
                    found = True
                    break
            if not found:
                sessions.append((rid, [rec]))
        else:
            sessions.append(("", [rec]))

    prev_raw: list[dict[str, Any]] = []
    for name, curr_rid in curr_run_by_name.items():
        sessions = hist_by_name.get(name, [])
        if not sessions:
            continue
        chosen: list[dict[str, Any]] | None = None
        if curr_rid:
            match_idx = -1
            for idx, (s_rid, _) in enumerate(sessions):
                if s_rid == curr_rid:
                    match_idx = idx
            if match_idx > 0:
                chosen = sessions[match_idx - 1][1]
            elif match_idx == -1:
                chosen = sessions[-1][1]
        elif len(sessions) >= 2:
            chosen = sessions[-2][1]
        if chosen:
            prev_raw.extend(chosen)

    return pool_records(prev_raw, key_by_commit=False) if prev_raw else []


def pair_benchmarks(
    odin_recs: list[dict[str, Any]],
    cpp_recs: list[dict[str, Any]],
    prev_odin_recs: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Pair Odin ST vs Arrow C++ ST baselines and attach Odin MT scaling + previous Odin ST."""
    rows_by_base: dict[str, dict[str, Any]] = {}
    prev_st_by_base: dict[str, dict[str, Any]] = {}

    for r in prev_odin_recs or []:
        base, variant = canonical_name(str(r["name"]))
        if variant == "st":
            prev_st_by_base[base] = r

    def ensure_row(base: str, rank: int, group: str) -> dict[str, Any]:
        if base not in rows_by_base:
            rows_by_base[base] = {
                "base_name": base,
                "rank": rank,
                "group": group,
                "odin_st": None,
                "odin_mt": None,
                "cpp_st": None,
                "prev_odin_st": prev_st_by_base.get(base),
            }
        else:
            rows_by_base[base]["rank"] = min(rows_by_base[base]["rank"], rank)
            if not rows_by_base[base]["group"] and group:
                rows_by_base[base]["group"] = group
        return rows_by_base[base]

    for r in odin_recs:
        base, variant = canonical_name(str(r["name"]))
        row = ensure_row(base, int(r.get("rank", 9999)), str(r.get("group", "")))
        row[f"odin_{variant}"] = r

    for r in cpp_recs:
        base, _ = canonical_name(str(r["name"]))
        row = ensure_row(base, int(r.get("rank", 9999)), str(r.get("group", "")))
        row["cpp_st"] = r

    for base, row in rows_by_base.items():
        if not base.endswith("_actor"):
            continue
        stem = base[: -len("_actor")]
        stem_row = rows_by_base.get(stem)
        if stem_row is None:
            continue
        if row["cpp_st"] is None and stem_row["cpp_st"] is not None:
            row["cpp_st"] = stem_row["cpp_st"]
        if row["odin_st"] is not None and stem_row["odin_st"] is not None:
            row["stem_odin_st"] = stem_row["odin_st"]
            if stem_row["odin_mt"] is None:
                stem_row["odin_mt"] = row["odin_st"]

    rows = sorted(rows_by_base.values(), key=lambda x: (int(x["rank"]), x["base_name"]))
    for row in rows:
        st = row["odin_st"]
        mt = row["odin_mt"]
        cpp = row["cpp_st"]
        prev_st = row["prev_odin_st"]
        if st and cpp and st["median_ns"] > 0:
            row["st_speedup"] = cpp["median_ns"] / st["median_ns"]
            row["z_st"], row["sig_st"] = welch_z_score(st, cpp)
        else:
            row["st_speedup"] = None
            row["z_st"], row["sig_st"] = None, ""
        if mt and cpp and mt["median_ns"] > 0:
            row["mt_speedup"] = cpp["median_ns"] / mt["median_ns"]
        else:
            row["mt_speedup"] = None
        if st and mt and mt["median_ns"] > 0:
            row["mt_scale"] = st["median_ns"] / mt["median_ns"]
        elif st and row.get("stem_odin_st") and st["median_ns"] > 0:
            row["mt_scale"] = row["stem_odin_st"]["median_ns"] / st["median_ns"]
        else:
            row["mt_scale"] = None
        if st and prev_st and prev_st["median_ns"] > 0:
            row["delta_prev_pct"] = ((st["median_ns"] - prev_st["median_ns"]) / prev_st["median_ns"]) * 100.0
            row["z_prev"], row["sig_prev"] = welch_z_score(prev_st, st)
        else:
            row["delta_prev_pct"] = None
            row["z_prev"], row["sig_prev"] = None, ""
    return rows


def format_ms_cell(rec: dict[str, Any] | None) -> str:
    if rec is None:
        return "-"
    return f"{rec['total_ms']:.2f}"


def format_gbps_cell(rec: dict[str, Any] | None) -> str:
    if rec is None:
        return "-"
    return f"{rec.get('gb_per_sec', 0.0):.1f}"


def format_delta_prev_cell(row: dict[str, Any]) -> str:
    pct = row.get("delta_prev_pct")
    if pct is None:
        return "-"
    sig = row.get("sig_prev", "")
    return f"{pct:+.1f}%{sig}"


def format_allocs_pair(st: dict[str, Any] | None, cpp: dict[str, Any] | None) -> str:
    def fmt_one(rec: dict[str, Any] | None, include_pool: bool) -> str:
        if rec is None or not rec.get("has_alloc_telemetry", False):
            return "-"
        allocs = int(rec.get("allocs_per_run", 0))
        hits = int(rec.get("pool_hits", 0))
        if include_pool and hits > 0:
            return f"{allocs}({hits}p)"
        return f"{allocs}"

    return f"{fmt_one(st, True)}/{fmt_one(cpp, False)}"


def format_alloc_mb_pair(st: dict[str, Any] | None, cpp: dict[str, Any] | None) -> str:
    def fmt_one(rec: dict[str, Any] | None) -> str:
        if rec is None or not rec.get("has_alloc_telemetry", False):
            return "-"
        mb = float(rec.get("alloc_bytes_per_run", 0)) / (1024.0 * 1024.0)
        return f"{mb:.1f}"

    return f"{fmt_one(st)}/{fmt_one(cpp)}"


def format_ratio_cell(val: float | None, sig: str = "") -> str:
    if val is None:
        return "-"
    if sig:
        return f"{val:.2f}x {sig}"
    return f"{val:.2f}x"


def render_1v1_table(rows: list[dict[str, Any]], markdown: bool = False) -> str:
    """Render side-by-side Odin ST vs Arrow C++ ST (+ Odin MT scaling, GB/s, allocs, Δ Prev) table."""
    lines: list[str] = []
    if markdown:
        lines.append(
            "| Benchmark | Group | Odin ST (ms) | Δ Prev | Arrow C++ ST (ms) | ST Speedup (z) | "
            "Odin GB/s | C++ GB/s | Allocs (Odin/C++) | Alloc MB (Odin/C++) | "
            "Odin MT (ms) | MT vs C++ | MT Scale | Odin ST CV% | C++ CV% |"
        )
        lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for row in rows:
            st = row["odin_st"]
            mt = row["odin_mt"]
            cpp = row["cpp_st"]
            st_cv = f"{st['cv_pct']:.1f}%" if st else "-"
            cpp_cv = f"{cpp['cv_pct']:.1f}%" if cpp else "-"
            z_str = f"{row['st_speedup']:.2f}x ({row['z_st']:.1f}{row['sig_st']})" if row["st_speedup"] is not None else "-"
            lines.append(
                f"| `{row['base_name']}` | {row['group']} | {format_ms_cell(st)} | {format_delta_prev_cell(row)} | "
                f"{format_ms_cell(cpp)} | {z_str} | {format_gbps_cell(st)} | {format_gbps_cell(cpp)} | "
                f"{format_allocs_pair(st, cpp)} | {format_alloc_mb_pair(st, cpp)} | "
                f"{format_ms_cell(mt)} | {format_ratio_cell(row['mt_speedup'])} | "
                f"{format_ratio_cell(row['mt_scale'])} | {st_cv} | {cpp_cv} |"
            )
    else:
        header = (
            f"{'Benchmark':<24} | {'Group':<8} | {'Odin ST(ms)':>11} | {'Δ Prev':>9} | {'C++ ST(ms)':>10} | "
            f"{'ST/C++':>10} | {'Odin GB/s':>9} | {'Allocs(O/C)':>14} | {'Odin MT(ms)':>11} | {'MT/C++':>8} | {'Scale':>7} | {'z':>6}"
        )
        sep = "-" * len(header)
        lines.append(header)
        lines.append(sep)
        for row in rows:
            st = row["odin_st"]
            mt = row["odin_mt"]
            cpp = row["cpp_st"]
            z_cell = "-" if row["z_st"] is None else ("inf" if math.isinf(row["z_st"]) else f"{row['z_st']:.1f}")
            lines.append(
                f"{row['base_name']:<24} | {row['group']:<8} | {format_ms_cell(st):>11} | {format_delta_prev_cell(row):>9} | "
                f"{format_ms_cell(cpp):>10} | {format_ratio_cell(row['st_speedup'], row['sig_st']):>10} | "
                f"{format_gbps_cell(st):>9} | {format_allocs_pair(st, cpp):>14} | {format_ms_cell(mt):>11} | "
                f"{format_ratio_cell(row['mt_speedup']):>8} | {format_ratio_cell(row['mt_scale']):>7} | {z_cell:>6}"
            )
        lines.append(sep)
        lines.append(
            "Legend: Ratio > 1.00x means Odin is faster than Arrow C++. "
            "Δ Prev < 0% means Odin got faster vs previous session. * z >= 1.96 (p < 0.05), ~ not statistically significant. "
            "Allocs '(Np)' shows Buffer_Pool hits."
        )
    return "\n".join(lines)


def list_runs_report(history_recs: list[dict[str, Any]]) -> str:
    """List recorded benchmark sessions (run_id) in chronological order."""
    if not history_recs:
        return "No history records found."

    runs_order: list[str] = []
    by_run: dict[str, dict[str, Any]] = {}
    for rec in history_recs:
        rid = str(rec.get("run_id", "") or "unknown")
        if rid not in by_run:
            runs_order.append(rid)
            by_run[rid] = {
                "commits": [],
                "langs": [],
                "benchmarks": set(),
                "samples": 0,
            }
        info = by_run[rid]
        c = str(rec.get("commit", "unknown"))
        if c not in info["commits"]:
            info["commits"].append(c)
        l = str(rec.get("lang", "unknown"))
        if l not in info["langs"]:
            info["langs"].append(l)
        info["benchmarks"].add(str(rec.get("name", "")))
        s = rec.get("samples_ns", [])
        info["samples"] += len(s) if s else 1

    lines = [
        f"{'Run ID':<16} | {'Commit':<10} | {'Langs':<10} | {'Benchmarks':>10} | {'Total Samples':>13}",
        "-" * 71,
    ]
    for rid in runs_order:
        info = by_run[rid]
        lines.append(
            f"{rid:<16} | {','.join(info['commits']):<10} | {','.join(info['langs']):<10} | "
            f"{len(info['benchmarks']):>10} | {info['samples']:>13}"
        )
    return "\n".join(lines)


def list_commits_report(history_recs: list[dict[str, Any]]) -> str:
    """Summarize commits, languages, sessions, and sample totals present in history.jsonl."""
    if not history_recs:
        return "No history records found."
    by_cl: dict[tuple[str, str], dict[str, Any]] = {}
    for rec in history_recs:
        c = str(rec.get("commit", "unknown"))
        l = str(rec.get("lang", "unknown"))
        key = (c, l)
        if key not in by_cl:
            by_cl[key] = {"run_ids": set(), "benchmarks": set(), "samples": 0}
        if rec.get("run_id"):
            by_cl[key]["run_ids"].add(str(rec["run_id"]))
        by_cl[key]["benchmarks"].add(str(rec.get("name", "")))
        s = rec.get("samples_ns", [])
        by_cl[key]["samples"] += len(s) if s else 1

    lines = [
        f"{'Commit':<12} | {'Lang':<8} | {'Sessions':>8} | {'Benchmarks':>10} | {'Total Samples':>13}",
        "-" * 63,
    ]
    for (c, l) in sorted(by_cl.keys()):
        info = by_cl[(c, l)]
        lines.append(
            f"{c:<12} | {l:<8} | {len(info['run_ids']):>8} | {len(info['benchmarks']):>10} | {info['samples']:>13}"
        )
    lines.append("")
    lines.append("Sessions (chronological):")
    lines.append(list_runs_report(history_recs))
    return "\n".join(lines)


def inspect_report(history_recs: list[dict[str, Any]], pattern: str, lang_filter: str = "both") -> str:
    """Inspect per-run and pooled distributions for benchmarks matching substring pattern."""
    low = pattern.lower()
    matched = [
        r for r in history_recs
        if low in str(r.get("name", "")).lower()
        and (lang_filter == "both" or str(r.get("lang", "")) == lang_filter)
    ]
    if not matched:
        return f"No history records matched pattern '{pattern}'."

    pooled = pool_records(matched, key_by_commit=True)
    lines: list[str] = []
    for p in pooled:
        lines.append(
            f"[{p['lang']}] {p['name']} @ {p['commit']} "
            f"(sessions={p['session_count']}, n={p['runs']}, ops={p['ops']}):"
        )
        lines.append(
            f"  total={p['total_ms']:.4f} ms | med={p['median_ns']:.6f} ns/op | "
            f"mean={p['mean_ns']:.6f} | std={p['stddev_ns']:.6f} | CV={p['cv_pct']:.2f}% | GB/s={p['gb_per_sec']:.2f}"
        )
        lines.append(
            f"  min={p['min_ns']:.6f} | iqr={p['iqr_ns']:.6f} | p95={p['p95_ns']:.6f} | "
            f"p99={p['p99_ns']:.6f} | max={p['max_ns']:.6f} | ops/s={p['ops_per_sec']:.0f}"
        )
        if p.get("has_alloc_telemetry", False):
            alloc_mb = p["alloc_bytes_per_run"] / (1024.0 * 1024.0)
            peak_mb = p["peak_live_bytes"] / (1024.0 * 1024.0)
            lines.append(
                f"  allocs/run={p['allocs_per_run']} | resizes/run={p['resizes_per_run']} | "
                f"alloc_bytes={alloc_mb:.2f} MB | peak_live={peak_mb:.2f} MB | "
                f"pool_hits={p['pool_hits']} | pool_misses={p['pool_misses']}"
            )
        samples_preview = ", ".join(f"{x:.4f}" for x in p["samples_ns"][:12])
        if len(p["samples_ns"]) > 12:
            samples_preview += f", ... ({len(p['samples_ns'])} total)"
        lines.append(f"  samples_ns=[{samples_preview}]")
    return "\n".join(lines)


def _match_commit(rec_commit: str, target: str) -> bool:
    return rec_commit == target or rec_commit.startswith(target) or target.startswith(rec_commit)


def _filter_by_run_id(records: list[dict[str, Any]], target: str) -> list[dict[str, Any]]:
    exact = [r for r in records if str(r.get("run_id", "")) == target]
    if exact:
        return exact
    return [r for r in records if str(r.get("run_id", "")).startswith(target)]


def _render_comparison_table(
    title: str,
    label_a: str,
    label_b: str,
    pooled_a: dict[tuple[str, str], dict[str, Any]],
    pooled_b: dict[tuple[str, str], dict[str, Any]],
    empty_msg: str,
) -> str:
    keys = sorted(
        set(pooled_a.keys()) & set(pooled_b.keys()),
        key=lambda k: (int(pooled_a[k]["rank"]), k[0], k[1]),
    )
    if not keys:
        return empty_msg

    col_a = label_a + " (ms)"
    col_b = label_b + " (ms)"
    w_a = max(12, len(col_a))
    w_b = max(12, len(col_b))
    header = f"{'Lang':<6} | {'Benchmark':<24} | {col_a:>{w_a}} | {col_b:>{w_b}} | {'Change':>10} | {'z':>6} | Status"
    lines = [title, header, "-" * len(header)]
    for k in keys:
        a = pooled_a[k]
        b = pooled_b[k]
        speedup = a["median_ns"] / b["median_ns"] if b["median_ns"] > 0 else 1.0
        pct = ((b["median_ns"] - a["median_ns"]) / a["median_ns"]) * 100.0 if a["median_ns"] > 0 else 0.0
        z, sig = welch_z_score(a, b)
        if sig == "*":
            status = "FASTER*" if speedup > 1.0 else "SLOWER*"
        else:
            status = "noise~"
        z_str = "inf" if math.isinf(z) else f"{z:.2f}"
        lines.append(
            f"{k[0]:<6} | {k[1]:<24} | {a['total_ms']:>{w_a}.3f} | {b['total_ms']:>{w_b}.3f} | "
            f"{pct:>+9.2f}% | {z_str:>6} | {status}"
        )
    return "\n".join(lines)


def compare_commits_report(
    history_recs: list[dict[str, Any]],
    sha_a: str,
    sha_b: str,
    lang_filter: str = "both",
) -> str:
    """Compare pooled distributions between two commit SHAs using Welch's z-test."""
    recs_a = [
        r for r in history_recs
        if _match_commit(str(r.get("commit", "")), sha_a)
        and (lang_filter == "both" or str(r.get("lang", "")) == lang_filter)
    ]
    recs_b = [
        r for r in history_recs
        if _match_commit(str(r.get("commit", "")), sha_b)
        and (lang_filter == "both" or str(r.get("lang", "")) == lang_filter)
    ]
    pooled_a = {(r["lang"], r["name"]): r for r in pool_records(recs_a, key_by_commit=False)}
    pooled_b = {(r["lang"], r["name"]): r for r in pool_records(recs_b, key_by_commit=False)}
    return _render_comparison_table(
        f"Commit comparison: {sha_a} (baseline) -> {sha_b} (target)",
        sha_a,
        sha_b,
        pooled_a,
        pooled_b,
        f"No overlapping benchmarks found between commit '{sha_a}' and '{sha_b}'.",
    )


def compare_runs_report(
    history_recs: list[dict[str, Any]],
    run_a: str,
    run_b: str,
    lang_filter: str = "both",
) -> str:
    """Compare two sessions (run_id) in history.jsonl using Welch's z-test."""
    lang_filtered = [
        r for r in history_recs
        if (lang_filter == "both" or str(r.get("lang", "")) == lang_filter)
    ]
    recs_a = _filter_by_run_id(lang_filtered, run_a)
    recs_b = _filter_by_run_id(lang_filtered, run_b)
    pooled_a = {(r["lang"], r["name"]): r for r in pool_records(recs_a, key_by_commit=False)}
    pooled_b = {(r["lang"], r["name"]): r for r in pool_records(recs_b, key_by_commit=False)}
    return _render_comparison_table(
        f"Session comparison: {run_a} (baseline) -> {run_b} (target)",
        run_a,
        run_b,
        pooled_a,
        pooled_b,
        f"No overlapping benchmarks found between run '{run_a}' and '{run_b}'.",
    )


def compare_last_report(history_recs: list[dict[str, Any]], lang_filter: str = "both") -> str:
    """Compare each language's latest recorded session against its previous session."""
    langs = ["odin", "cpp"] if lang_filter == "both" else [lang_filter]
    sections: list[str] = []
    for lang in langs:
        lang_recs = [r for r in history_recs if str(r.get("lang", "")) == lang]
        run_ids: list[str] = []
        for r in lang_recs:
            rid = str(r.get("run_id", ""))
            if rid and rid not in run_ids:
                run_ids.append(rid)
        if len(run_ids) < 2:
            continue
        run_prev, run_last = run_ids[-2], run_ids[-1]
        recs_a = [r for r in lang_recs if str(r.get("run_id", "")) == run_prev]
        recs_b = [r for r in lang_recs if str(r.get("run_id", "")) == run_last]
        pooled_a = {(r["lang"], r["name"]): r for r in pool_records(recs_a, key_by_commit=False)}
        pooled_b = {(r["lang"], r["name"]): r for r in pool_records(recs_b, key_by_commit=False)}
        sections.append(
            _render_comparison_table(
                f"Latest session diff [{lang}]: {run_prev} (prev) -> {run_last} (latest)",
                run_prev,
                run_last,
                pooled_a,
                pooled_b,
                f"No overlapping benchmarks between '{run_prev}' and '{run_last}' for {lang}.",
            )
        )
    if not sections:
        return "Need at least 2 recorded sessions in history to compare last run."
    return "\n\n".join(sections)


def update_readme_results(readme_path: Path, markdown_table: str) -> None:
    """Replace content between <!-- BENCHMARK_1V1_START --> and <!-- BENCHMARK_1V1_END -->."""
    start_marker = "<!-- BENCHMARK_1V1_START -->"
    end_marker = "<!-- BENCHMARK_1V1_END -->"
    block = f"{start_marker}\n\n{markdown_table}\n\n{end_marker}"
    text = readme_path.read_text(encoding="utf-8") if readme_path.exists() else ""
    if start_marker in text and end_marker in text:
        pattern = re.compile(
            re.escape(start_marker) + r".*?" + re.escape(end_marker),
            re.DOTALL,
        )
        new_text = pattern.sub(block, text, count=1)
    else:
        sep = "\n\n" if text and not text.endswith("\n\n") else ""
        new_text = f"{text}{sep}## Statistical 1v1 Comparison (Odin ST / MT vs Arrow C++ ST)\n\n{block}\n"
    readme_path.write_text(new_text, encoding="utf-8")


def _run_cmd(cmd: list[str], cwd: Path = ROOT) -> None:
    proc = subprocess.run(cmd, cwd=str(cwd))
    if proc.returncode != 0:
        raise RuntimeError(f"Command failed ({proc.returncode}): {' '.join(cmd)}")


def build_and_run_runners(args: argparse.Namespace) -> None:
    """Compile with full optimizations and execute selected language runners."""
    run_id = args.run_id or str(int(time.time() * 1000))
    common_flags: list[str] = [
        "--runs", str(args.runs),
        "--warmup", str(args.warmup),
        "--history", str(args.history),
        "--run-id", run_id,
    ]
    if args.n is not None:
        common_flags += ["--n", str(args.n)]
    if args.commit:
        common_flags += ["--commit", args.commit]
    if args.append:
        common_flags.append("--append")
    if args.no_history:
        common_flags.append("--no-history")
    if args.groups:
        common_flags += ["--groups", args.groups]
    if args.filter:
        common_flags += ["--filter", args.filter]

    (ROOT / "bin").mkdir(parents=True, exist_ok=True)

    if args.lang in ("odin", "both"):
        build_cmd = [
            "odin", "build", "benchmarks/odin",
            "-out:bin/bench_runner", "-o:speed", "-microarch:native",
        ]
        hugi_col = ROOT.parent / "hugi" / "hugi"
        if hugi_col.is_dir():
            build_cmd.append(f"-collection:hugi={hugi_col}")
        _run_cmd(build_cmd)
        _run_cmd([str(ROOT / "bin" / "bench_runner"), "--output", str(args.odin_jsonl), *common_flags])

    if args.lang in ("cpp", "both"):
        _run_cmd(["make", "bin/bench_arrow_cpp"])
        _run_cmd([str(ROOT / "bin" / "bench_arrow_cpp"), "--output", str(args.cpp_jsonl), *common_flags])


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Skadi vs Apache Arrow C++ statistical 1v1 comparator")
    p.add_argument("--runs", type=int, default=5, help="Measured trials per benchmark (default: 5)")
    p.add_argument("--warmup", type=int, default=1, help="Warmup trials per benchmark (default: 1)")
    p.add_argument("--n", type=int, default=None, help="Override large array element count")
    p.add_argument("--commit", type=str, default=None, help="Override git commit SHA")
    p.add_argument("--run-id", type=str, default=None, help="Override run ID")
    p.add_argument("--append", action="store_true", help="Append/merge matched ranks into snapshot files")
    p.add_argument("--no-history", action="store_true", help="Do not append to history JSONL")
    p.add_argument("--groups", type=str, default=None, help="Comma-separated groups to run/filter")
    p.add_argument("--filter", type=str, default=None, help="Substring filter for benchmark names")
    p.add_argument("--lang", choices=["odin", "cpp", "both"], default="both", help="Which runner(s) to run/show")
    p.add_argument("--odin-jsonl", type=Path, default=ROOT / "benchmarks" / "odin.jsonl")
    p.add_argument("--cpp-jsonl", type=Path, default=ROOT / "benchmarks" / "cpp.jsonl")
    p.add_argument("--history", type=Path, default=ROOT / "benchmarks" / "history.jsonl")
    p.add_argument("--hugidb", type=Path, default=ROOT / "benchmarks" / "history.hugidb")
    p.add_argument("--from-jsonl", action="store_true", help="Analyze existing JSONL without running binaries")
    p.add_argument("--from-hugidb", action="store_true", help="Analyze existing .hugidb store without running binaries")
    p.add_argument("--pool", action="store_true", help="Pool all matching commit samples from history.jsonl")
    p.add_argument("--list-commits", action="store_true", help="List commits and sessions in history.jsonl")
    p.add_argument("--list-runs", action="store_true", help="List sessions (run_id) chronologically from history.jsonl")
    p.add_argument("--inspect", type=str, default=None, help="Inspect distribution for matching benchmarks")
    p.add_argument("--compare-commits", nargs=2, metavar=("SHA_A", "SHA_B"), help="Compare two commit SHAs in history")
    p.add_argument("--compare-runs", nargs=2, metavar=("RUN_A", "RUN_B"), help="Compare two run IDs in history")
    p.add_argument("--compare-last", action="store_true", help="Compare the latest session against the previous session")
    p.add_argument("--markdown", action="store_true", help="Print Markdown formatted 1v1 table")
    p.add_argument("--update-readme", action="store_true", help="Update benchmarks/RESULTS.md 1v1 section")
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    def _load_history_source() -> list[dict[str, Any]]:
        return load_hugidb(args.hugidb) if args.from_hugidb else load_jsonl(args.history)

    if args.list_commits:
        print(list_commits_report(_load_history_source()))
        return 0

    if args.list_runs:
        print(list_runs_report(_load_history_source()))
        return 0

    if args.inspect is not None:
        print(inspect_report(_load_history_source(), args.inspect, args.lang))
        return 0

    if args.compare_commits is not None:
        sha_a, sha_b = args.compare_commits
        print(compare_commits_report(_load_history_source(), sha_a, sha_b, args.lang))
        return 0

    if args.compare_runs is not None:
        run_a, run_b = args.compare_runs
        print(compare_runs_report(_load_history_source(), run_a, run_b, args.lang))
        return 0

    if args.compare_last:
        print(compare_last_report(_load_history_source(), args.lang))
        return 0

    if not args.from_jsonl and not args.from_hugidb:
        build_and_run_runners(args)

    if args.from_hugidb:
        history_recs = load_hugidb(args.hugidb)
        if args.commit:
            hist = [r for r in history_recs if _match_commit(str(r.get("commit", "")), args.commit)]
        elif args.pool:
            target_commit = resolve_git_commit(ROOT)
            matched = [r for r in history_recs if _match_commit(str(r.get("commit", "")), target_commit)]
            hist = matched if matched else history_recs
        else:
            latest_map: dict[tuple[str, str], dict[str, Any]] = {}
            for r in history_recs:
                latest_map[(str(r.get("lang", "")), str(r.get("name", "")))] = r
            hist = list(latest_map.values())
        odin_raw = [r for r in hist if r.get("lang") == "odin"] if args.lang in ("odin", "both") else []
        cpp_raw = [r for r in hist if r.get("lang") == "cpp"] if args.lang in ("cpp", "both") else []
    else:
        history_recs = load_jsonl(args.history)
        if args.pool:
            target_commit = args.commit or resolve_git_commit(ROOT)
            hist = [r for r in history_recs if _match_commit(str(r.get("commit", "")), target_commit)]
            odin_raw = [r for r in hist if r.get("lang") == "odin"] if args.lang in ("odin", "both") else []
            cpp_raw = [r for r in hist if r.get("lang") == "cpp"] if args.lang in ("cpp", "both") else []
        else:
            odin_raw = load_jsonl(args.odin_jsonl) if args.lang in ("odin", "both") else []
            cpp_raw = load_jsonl(args.cpp_jsonl) if args.lang in ("cpp", "both") else []

    if args.groups:
        allowed_g = {g.strip().lower() for g in args.groups.split(",") if g.strip()}
        odin_raw = [r for r in odin_raw if str(r.get("group", "")).lower() in allowed_g]
        cpp_raw = [r for r in cpp_raw if str(r.get("group", "")).lower() in allowed_g]
    if args.filter:
        f_low = args.filter.lower()
        odin_raw = [r for r in odin_raw if f_low in str(r.get("name", "")).lower()]
        cpp_raw = [r for r in cpp_raw if f_low in str(r.get("name", "")).lower()]

    odin_pooled = pool_records(odin_raw, key_by_commit=False)
    cpp_pooled = pool_records(cpp_raw, key_by_commit=False)
    prev_odin_pooled = resolve_previous_odin_records(odin_raw, history_recs) if odin_raw else []
    rows = pair_benchmarks(odin_pooled, cpp_pooled, prev_odin_pooled)

    print()
    print(render_1v1_table(rows, markdown=args.markdown))

    if args.update_readme:
        md_table = render_1v1_table(rows, markdown=True)
        update_readme_results(ROOT / "benchmarks" / "RESULTS.md", md_table)
    return 0


if __name__ == "__main__":
    sys.exit(main())
