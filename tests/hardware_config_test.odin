package skadi_tests

import "core:mem"
import "core:testing"
import oa "../skadi"

@(test)
test_parse_cache_size_bytes :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	v1, ok1 := oa.parse_cache_size_bytes("32K\n")
	testing.expect(t, ok1)
	testing.expect_value(t, v1, 32 * 1024)

	v2, ok2 := oa.parse_cache_size_bytes("256K")
	testing.expect(t, ok2)
	testing.expect_value(t, v2, 256 * 1024)

	v3, ok3 := oa.parse_cache_size_bytes("24M")
	testing.expect(t, ok3)
	testing.expect_value(t, v3, 24 * 1024 * 1024)

	v4, ok4 := oa.parse_cache_size_bytes("4096")
	testing.expect(t, ok4)
	testing.expect_value(t, v4, 4096)

	_, ok_empty := oa.parse_cache_size_bytes("")
	testing.expect(t, !ok_empty)

	_, ok_bad := oa.parse_cache_size_bytes("badK")
	testing.expect(t, !ok_bad)
}

@(test)
test_hardware_config_host_and_override :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	saved_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = saved_alloc
		check_no_leaks(t, &track)
	}

	host := oa.hardware_config_get()
	testing.expect(t, host.physical_cores >= 1)
	testing.expect(t, host.logical_cores >= host.physical_cores)
	testing.expect(t, host.l1d_bytes > 0)
	testing.expect(t, host.l2_bytes >= host.l1d_bytes)
	testing.expect(t, host.l3_bytes >= host.l2_bytes)
	testing.expect(t, host.morsel_target_bytes > 0)
	testing.expect(t, host.parallel_min_bytes > 0)

	oa.hardware_config_set(oa.Hardware_Config{
		physical_cores      = 4,
		logical_cores       = 8,
		l1d_bytes           = 32 * 1024,
		l2_bytes            = 256 * 1024,
		l3_bytes            = 8 * 1024 * 1024,
		morsel_target_bytes = 256 * 1024,
		parallel_min_bytes  = 256 * 1024,
	})
	defer oa.hardware_config_reset()

	// Tiny arrays must resolve to 1 thread regardless of byte width.
	testing.expect_value(t, oa.parallel_resolve_threads(0, 1000, 8), 1)

	// Large arrays default to physical core count (4) rather than SMT count (8).
	nt := oa.parallel_resolve_threads(0, 10_000_000, 8)
	testing.expect(t, nt >= 1 && nt <= 4)

	// Morsel row chunk size must scale inversely with bytes_per_row.
	c1, m1 := oa.parallel_compute_morsels(10_000_000, 4, 1)
	c4, m4 := oa.parallel_compute_morsels(10_000_000, 4, 4)
	c8, m8 := oa.parallel_compute_morsels(10_000_000, 4, 8)
	c24, m24 := oa.parallel_compute_morsels(10_000_000, 4, 24)

	testing.expect(t, m1 > 0 && m4 > 0 && m8 > 0 && m24 > 0)
	testing.expect(t, c24 <= c8 && c8 <= c4 && c4 <= c1)
}
