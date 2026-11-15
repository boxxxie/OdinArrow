package skadi

import "core:fmt"
import "core:os"
import "core:sync"

// Hardware topology and CPU cache parameters discovered at runtime from Linux
// sysfs (or overridden deterministically for tests) so morsel sizing and worker
// parallelism adapt automatically to L1d/L2/L3 caches and physical cores.
Hardware_Config :: struct {
	physical_cores:      int,
	logical_cores:       int,
	l1d_bytes:           int,
	l2_bytes:            int,
	l3_bytes:            int,
	morsel_target_bytes: int,
	parallel_min_bytes:  int,
}

@(private="file") g_hw_once:     sync.Once
@(private="file") g_hw_mutex:    sync.Mutex
@(private="file") g_hw_detected: Hardware_Config
@(private="file") g_hw_override: Hardware_Config
@(private="file") g_hw_has_ovr:  bool

// Parse a sysfs cache size string (e.g., "32K", "512K", "16384K", "6M", "32768") into bytes.
parse_cache_size_bytes :: proc "contextless" (raw: string) -> (bytes: int, ok: bool) {
	s := _trim_ascii_ws(raw)
	if len(s) == 0 { return 0, false }

	mul := 1
	last := s[len(s) - 1]
	digits := s
	if last == 'K' || last == 'k' {
		mul = 1024
		digits = s[:len(s) - 1]
	} else if last == 'M' || last == 'm' {
		mul = 1024 * 1024
		digits = s[:len(s) - 1]
	} else if last == 'G' || last == 'g' {
		mul = 1024 * 1024 * 1024
		digits = s[:len(s) - 1]
	}
	if len(digits) == 0 { return 0, false }

	val := 0
	for c in digits {
		if c < '0' || c > '9' { return 0, false }
		digit := int(c - '0')
		if val > (max(int) - digit) / 10 { return 0, false }
		val = val * 10 + digit
	}
	if val <= 0 || val > max(int) / mul { return 0, false }
	return val * mul, true
}

@(private="file")
_trim_ascii_ws :: proc "contextless" (s: string) -> string {
	start := 0
	end   := len(s)
	for start < end {
		c := s[start]
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' { break }
		start += 1
	}
	for end > start {
		c := s[end - 1]
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' { break }
		end -= 1
	}
	return s[start:end]
}

@(private="file")
_parse_nonneg_int :: proc "contextless" (raw: string) -> (val: int, ok: bool) {
	s := _trim_ascii_ws(raw)
	if len(s) == 0 { return 0, false }
	v := 0
	for c in s {
		if c < '0' || c > '9' { return 0, false }
		d := int(c - '0')
		if v > (max(int) - d) / 10 { return 0, false }
		v = v * 10 + d
	}
	return v, true
}

@(private="file")
_read_sysfs_small :: proc(path: string, buf: []u8) -> (string, bool) {
	f, err := os.open(path)
	if err != nil { return "", false }
	defer os.close(f)
	n, r_err := os.read(f, buf)
	if r_err != nil || n <= 0 { return "", false }
	return _trim_ascii_ws(string(buf[:n])), true
}

// Discover CPU core topology and L1d/L2/L3 cache sizes from Linux sysfs using
// stack buffers (zero heap allocations).
@(private="file")
_detect_hardware_config :: proc() -> Hardware_Config {
	logical := max(os.get_processor_core_count(), 1)
	l1d     := 0
	l2      := 0
	l3      := 0

	path_buf: [128]u8
	val_buf:  [64]u8

	for idx in 0..<8 {
		lvl_path := fmt.bprintf(path_buf[:], "/sys/devices/system/cpu/cpu0/cache/index%d/level", idx)
		lvl_str, lvl_ok := _read_sysfs_small(lvl_path, val_buf[:])
		if !lvl_ok { break }
		lvl, l_ok := _parse_nonneg_int(lvl_str)
		if !l_ok { continue }

		type_path := fmt.bprintf(path_buf[:], "/sys/devices/system/cpu/cpu0/cache/index%d/type", idx)
		ctype, t_ok := _read_sysfs_small(type_path, val_buf[:])
		if !t_ok { continue }

		sz_path := fmt.bprintf(path_buf[:], "/sys/devices/system/cpu/cpu0/cache/index%d/size", idx)
		sz_str, s_ok := _read_sysfs_small(sz_path, val_buf[:])
		if !s_ok { continue }
		sz_bytes, b_ok := parse_cache_size_bytes(sz_str)
		if !b_ok { continue }

		if lvl == 1 && ctype == "Data" && l1d == 0 {
			l1d = sz_bytes
		} else if lvl == 2 && (ctype == "Unified" || ctype == "Data") && l2 == 0 {
			l2 = sz_bytes
		} else if lvl == 3 && (ctype == "Unified" || ctype == "Data") && l3 == 0 {
			l3 = sz_bytes
		}
	}

	// Deduplicate (physical_package_id, core_id) across logical CPUs so SMT siblings
	// and multi-socket topologies count true physical cores accurately.
	seen_pairs: [256][2]i32
	n_seen := 0
	max_scan := min(max(logical * 2, 32), len(seen_pairs))
	for cpu in 0..<max_scan {
		pkg_path  := fmt.bprintf(path_buf[:], "/sys/devices/system/cpu/cpu%d/topology/physical_package_id", cpu)
		core_path := fmt.bprintf(path_buf[:], "/sys/devices/system/cpu/cpu%d/topology/core_id", cpu)

		pkg_str, p_ok := _read_sysfs_small(pkg_path, val_buf[:])
		if !p_ok { continue }
		core_str, c_ok := _read_sysfs_small(core_path, val_buf[:])
		if !c_ok { continue }

		pkg_id,  pi_ok := _parse_nonneg_int(pkg_str)
		core_id, ci_ok := _parse_nonneg_int(core_str)
		if !pi_ok || !ci_ok { continue }

		pair := [2]i32{i32(pkg_id), i32(core_id)}
		dup := false
		for j in 0..<n_seen {
			if seen_pairs[j] == pair { dup = true; break }
		}
		if !dup && n_seen < len(seen_pairs) {
			seen_pairs[n_seen] = pair
			n_seen += 1
		}
	}

	physical := clamp(n_seen, 1, logical) if n_seen > 0 else logical
	if l1d <= 0 { l1d = 32 * 1024 }
	if l2  <= 0 { l2  = 256 * 1024 }
	if l3  <= 0 { l3  = 6 * 1024 * 1024 }

	return Hardware_Config{
		physical_cores      = physical,
		logical_cores       = logical,
		l1d_bytes           = l1d,
		l2_bytes            = l2,
		l3_bytes            = l3,
		morsel_target_bytes = clamp(l2 / 2, 64 * 1024, 256 * 1024),
		parallel_min_bytes  = clamp(l3 / 8, 512 * 1024, 1024 * 1024),
	}
}

@(private="file")
_init_hw_once :: proc() {
	g_hw_detected = _detect_hardware_config()
}

// Return the active hardware topology & cache configuration (cached after first call).
hardware_config_get :: proc() -> Hardware_Config {
	sync.once_do(&g_hw_once, _init_hw_once)
	sync.mutex_lock(&g_hw_mutex)
	defer sync.mutex_unlock(&g_hw_mutex)
	if g_hw_has_ovr { return g_hw_override }
	return g_hw_detected
}

// Override the active hardware configuration (intended for unit tests).
hardware_config_set :: proc(cfg: Hardware_Config) {
	sync.once_do(&g_hw_once, _init_hw_once)
	sync.mutex_lock(&g_hw_mutex)
	g_hw_override = cfg
	g_hw_has_ovr  = true
	sync.mutex_unlock(&g_hw_mutex)
}

// Clear any test override and restore runtime-detected hardware configuration.
hardware_config_reset :: proc() {
	sync.once_do(&g_hw_once, _init_hw_once)
	sync.mutex_lock(&g_hw_mutex)
	g_hw_has_ovr  = false
	g_hw_override = {}
	sync.mutex_unlock(&g_hw_mutex)
}
