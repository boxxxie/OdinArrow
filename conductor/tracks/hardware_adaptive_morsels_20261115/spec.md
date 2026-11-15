# Specification: Hardware-Aware Execution Config & Cache-Adaptive Morsel Sizing

## Overview
Currently, `skadi/compute_parallel.odin` relies on hardcoded row-count constants (`PARALLEL_MIN_LENGTH :: 262_144`, `MAX_MORSELS :: 256`, and `target := nt * 4`) and `os.get_processor_core_count()` (which returns logical Hyper-Threading / SMT threads rather than physical cores), while `_Compute_Pool` in `skadi/thread_pool.odin` uses `sync.cond_broadcast(&p.work_cond)` to wake all logical worker threads even when fewer are active. On an i7-7700HQ (4 physical cores / 8 logical threads, 32 KB L1d, 256 KB L2 per core, 6 MB shared L3):
- Bandwidth-bound AVX2 kernels launch 8 SMT threads competing for 4 physical cores, splitting L1d/L2 caches in half, or wake idle SMT threads via `cond_broadcast` only to have them re-lock `p.mutex`.
- Morsels are sized at `312,500` rows regardless of element byte width (`1 B` for `i8` vs `24 B/row` for `arith_add` / binary ops), producing `2.5 MB`–`7.5 MB` morsels that overflow per-core L2 (`256 KB`) and even shared L3 (`6 MB`).
- Multi-predicate selection pipelines (`sel_2pred_sum_10m_f64` in `benchmarks/odin/bench_main.odin`, using `skadi/compare.odin` and `skadi/selection.odin`) execute bulk-synchronously across all `10M` rows, spilling `39.3 MB` of intermediate `i32` selection vectors to DRAM instead of iterating over L2-resident morsels.

This track introduces auto-detected `Hardware_Config` (physical vs logical cores, L1d/L2/L3 cache byte sizes from Linux sysfs with fallbacks and runtime overrides), fixes spurious wakeups in `skadi/thread_pool.odin`, and adapts parallel thread counts, byte-budgeted morsel sizes, and L2-chunked multi-stage selection execution to the underlying CPU.

---

## Functional Requirements

### 1. Hardware Topology & Cache Discovery (`skadi/hardware_config.odin`)
- Define `Hardware_Config :: struct`:
  - `physical_cores: int` — detected on Linux by reading `/sys/devices/system/cpu/cpu*/topology/core_id` + `physical_package_id` (or deduplicating `thread_siblings_list`) so multi-socket systems count physical cores accurately; fallback to `logical_cores` (or `max(logical_cores / 2, 1)` if sysfs SMT indicator exists).
  - `logical_cores: int` (`os.get_processor_core_count()`).
  - `l1d_bytes: int` — detected by inspecting `/sys/devices/system/cpu/cpu0/cache/index*/level` (`1`) and `/sys/devices/system/cpu/cpu0/cache/index*/type` (`Data`, skipping `Instruction` cache e.g. `index1`) and parsing `size` (`"32K"`, `"256K"`, `"6144K"`, `"6M"`), default `32 * 1024`.
  - `l2_bytes: int` — detected from cache `level == 2` (`Unified`/`Data`), default `256 * 1024`.
  - `l3_bytes: int` — detected from cache `level == 3` (`Unified`), default `6 * 1024 * 1024`.
  - `morsel_target_bytes: int` — default `l2_bytes / 2` (e.g., `128 KB`).
  - `parallel_min_bytes: int` — default `max(l3_bytes / 4, 512 * 1024)`.
- Provide `hardware_config_get() -> Hardware_Config`, `hardware_config_set(cfg: Hardware_Config)`, and `hardware_config_reset()` (thread-safe, lazy `sync.Once` initialization with stack-only sysfs parsing and zero heap leaks).

### 2. Pool Wakeup Hygiene & Byte-Budgeted Morsel Sizing (`skadi/thread_pool.odin`, `skadi/compute_parallel.odin`)
- Prevent spurious SMT wakeups in `_Compute_Pool` (`skadi/thread_pool.odin`): replace or guard `sync.cond_broadcast(&p.work_cond)` with per-worker wakeup state (or pool worker count / targeted wakeup) so unused SMT threads do not wake up and contend on `p.mutex` when `active_workers < p.n`.
- Update `_resolve_threads(requested: int, length: int, bytes_per_row := 8)` in `skadi/compute_parallel.odin`:
  - Default `requested == 0` to `hw.physical_cores` for memory-bandwidth-bound SIMD kernels (while preserving explicit `num_threads > 0` override).
  - Compute `parallel_min_length` from `hw.parallel_min_bytes / max(bytes_per_row, 1)` so narrow (`i8`/`u8`) and wide (`f64` / binary / cast) arrays parallelize according to actual byte volume.
- Pass explicit `bytes_per_row` from every kernel in `skadi/compute_parallel.odin`:
  - Unary reductions (`compute_sum_parallel`, `compute_min_parallel`, `compute_max_parallel`, `compute_min_max_parallel`, `compute_mean_parallel`, `compute_count_parallel`) and `compute_compare`: `type_byte_width(arr.type)`
  - `compute_filter_parallel`: `type_byte_width(arr.type) * 2`
  - Binary arithmetic / multi-array kernels (`add`, `sub`, `mul`, `div`): `type_byte_width(arr.type) * 3`
  - `cast` kernels: `type_byte_width(src.type) + type_byte_width(dst_type)`
  - `compute_take_parallel`: `type_byte_width(arr.type) * 2 + size_of(i64)`
- Update `_compute_morsels(length, nt: int, bytes_per_row := 8)` to size chunks so `chunk * bytes_per_row ~= hw.morsel_target_bytes` (aligned to SIMD/bitmap multiples of 64 elements and clamped to `MAX_MORSELS`), ensuring each morsel fits inside a single core's L2 cache.

### 3. L2-Resident Morsel Execution for Multi-Predicate Selection (`skadi/selection.odin`, `skadi/compare.odin`)
- Add L2-chunked multi-predicate execution (`compute_sel_2pred_sum` / morsel-chunked `Selection` workspace pipeline in `skadi/compare.odin` & `skadi/selection.odin`) that slices input arrays into `morsel_rows = hw.morsel_target_bytes / bytes_per_row` chunks (e.g., `16,384` rows = `128 KB` per `f64` column).
- Reuse a single pre-allocated `morsel_rows * size_of(i32)` (`~64 KB`) selection workspace across all morsels (or one `64 KB` workspace per physical worker thread in `_mt` mode), keeping both column slices and surviving indices 100% resident in L2 cache (`0` DRAM spills, `< 256 KB` allocated instead of `39.3 MB`).

---

## Non-Functional Requirements
- **Zero External Dependencies**: Linux sysfs parsing uses stack buffers (`core:os`) with zero heap allocations and clean fallbacks on non-Linux or restricted environments.
- **Compiler Compliance**: Clean compilation with `-vet -strict-style -disallow-do -warnings-as-errors`.
- **Determinism & Overrideability**: Tests can inject synthetic `Hardware_Config` profiles via `hardware_config_set` to deterministically test morsel math across arbitrary core counts and L2/L3 sizes.

---

## Acceptance Criteria
- [ ] `hardware_config_get()` accurately parses Linux sysfs cache `level` + `type` (`Data` for L1d, `Unified` for L2/L3) and deduplicates `(physical_package_id, core_id)` pairs (reporting `4` physical cores, `8` logical cores, `32 KB` L1d, `256 KB` L2, `6 MB` L3 on the host machine), and supports `hardware_config_set` / `hardware_config_reset` in unit tests.
- [ ] `_compute_pool` does not spuriously wake unused SMT worker threads when running with `physical_cores`.
- [ ] `_compute_morsels` and `_resolve_threads` adapt morsel row counts across all kernels using explicit `bytes_per_row` and `l2_bytes`.
- [ ] L2-morsel-chunked multi-predicate selection reduces `sel_2pred_sum_10m_f64` allocation from `39.3 MB` to `<= 0.25 MB` and improves latency.
- [ ] All unit tests in `tests/` pass with zero memory leaks.

---

## Out of Scope
- Asynchronous actor mailbox pipelines across independent stages (covered in Track `sleipnir_morsel_pipeline_20261115`).
