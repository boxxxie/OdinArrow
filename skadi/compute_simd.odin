package skadi

import "base:intrinsics"

// SIMD-accelerated inner reduction kernels across numeric widths.
// All procs assume caller has already applied arr.offset (`data[arr.offset:]`)
// and `n > 0` for min/max variants.
//
// Procs annotated with `@(enable_target_feature = _SIMD_TARGET_FEATURE)` enable AVX2
// on amd64 while allowing portable #simd codegen on other architectures (e.g. arm64),
// and are intentionally NOT `#force_inline` so the target feature stays scoped to the vector loop.
_SIMD_TARGET_FEATURE :: "avx2" when ODIN_ARCH == .amd64 else ""

// ── sum ───────────────────────────────────────────────────────────────────────

@(enable_target_feature = _SIMD_TARGET_FEATURE)
_sum_f64_simd :: proc "contextless" (data: [^]f64, n: int) -> f64 {
	V  :: #simd[4]f64
	vp := cast([^]V)data
	nv := n / 4

	a, b, c, d: V = {}, {}, {}, {}
	v4 := nv / 4
	for i in 0..<v4 {
		j := i * 4
		a += intrinsics.unaligned_load(&vp[j])
		b += intrinsics.unaligned_load(&vp[j + 1])
		c += intrinsics.unaligned_load(&vp[j + 2])
		d += intrinsics.unaligned_load(&vp[j + 3])
	}
	acc := a + b + c + d
	for i := v4 * 4; i < nv; i += 1 {
		acc += intrinsics.unaligned_load(&vp[i])
	}

	sum := intrinsics.simd_reduce_add_ordered(acc)
	for i := nv * 4; i < n; i += 1 { sum += data[i] }
	return sum
}

@(enable_target_feature = _SIMD_TARGET_FEATURE)
_sum_f32_simd :: proc "contextless" (data: [^]f32, n: int) -> f64 {
	V32 :: #simd[4]f32
	V64 :: #simd[4]f64
	vp  := cast([^]V32)data
	nv  := n / 4

	a, b: V64 = {}, {}
	v2 := nv / 2
	for i in 0..<v2 {
		j := i * 2
		a += cast(V64)intrinsics.unaligned_load(&vp[j])
		b += cast(V64)intrinsics.unaligned_load(&vp[j + 1])
	}
	acc := a + b
	for i := v2 * 2; i < nv; i += 1 {
		acc += cast(V64)intrinsics.unaligned_load(&vp[i])
	}

	sum := intrinsics.simd_reduce_add_ordered(acc)
	for i := nv * 4; i < n; i += 1 { sum += f64(data[i]) }
	return sum
}

@(enable_target_feature = _SIMD_TARGET_FEATURE)
_sum_sint_simd :: proc "contextless" (data: [^]$T, n: int) -> f64 {
	VT  :: #simd[4]T
	V64 :: #simd[4]i64
	vp  := cast([^]VT)data
	nv  := n / 4

	a, b, c, d: V64 = {}, {}, {}, {}
	v4 := nv / 4
	for i in 0..<v4 {
		j := i * 4
		a += cast(V64)intrinsics.unaligned_load(&vp[j])
		b += cast(V64)intrinsics.unaligned_load(&vp[j + 1])
		c += cast(V64)intrinsics.unaligned_load(&vp[j + 2])
		d += cast(V64)intrinsics.unaligned_load(&vp[j + 3])
	}
	acc := a + b + c + d
	for i := v4 * 4; i < nv; i += 1 {
		acc += cast(V64)intrinsics.unaligned_load(&vp[i])
	}
	sum := intrinsics.simd_reduce_add_ordered(acc)
	for i := nv * 4; i < n; i += 1 { sum += i64(data[i]) }
	return f64(sum)
}

@(enable_target_feature = _SIMD_TARGET_FEATURE)
_sum_uint_simd :: proc "contextless" (data: [^]$T, n: int) -> f64 {
	VT  :: #simd[4]T
	V64 :: #simd[4]u64
	vp  := cast([^]VT)data
	nv  := n / 4

	a, b, c, d: V64 = {}, {}, {}, {}
	v4 := nv / 4
	for i in 0..<v4 {
		j := i * 4
		a += cast(V64)intrinsics.unaligned_load(&vp[j])
		b += cast(V64)intrinsics.unaligned_load(&vp[j + 1])
		c += cast(V64)intrinsics.unaligned_load(&vp[j + 2])
		d += cast(V64)intrinsics.unaligned_load(&vp[j + 3])
	}
	acc := a + b + c + d
	for i := v4 * 4; i < nv; i += 1 {
		acc += cast(V64)intrinsics.unaligned_load(&vp[i])
	}
	sum := intrinsics.simd_reduce_add_ordered(acc)
	for i := nv * 4; i < n; i += 1 { sum += u64(data[i]) }
	return f64(sum)
}

_sum_typed_simd :: #force_inline proc "contextless" (data: [^]$T, n: int) -> f64 {
	when T == f64 {
		return _sum_f64_simd(data, n)
	} else when T == f32 {
		return _sum_f32_simd(data, n)
	} else when T == i8 || T == i16 || T == i32 {
		return _sum_sint_simd(data, n)
	} else when T == u8 || T == u16 || T == u32 {
		return _sum_uint_simd(data, n)
	} else {
		// i64 / u64: 4-way f64 accumulators avoid FP chain stall and integer wraparound.
		a0, a1, a2, a3: f64 = 0, 0, 0, 0
		i := 0
		for i + 4 <= n {
			a0 += f64(data[i]);     a1 += f64(data[i + 1])
			a2 += f64(data[i + 2]); a3 += f64(data[i + 3])
			i += 4
		}
		sum := a0 + a1 + a2 + a3
		for ; i < n; i += 1 { sum += f64(data[i]) }
		return sum
	}
}

// ── min / max ─────────────────────────────────────────────────────────────────

@(enable_target_feature = _SIMD_TARGET_FEATURE)
_min_typed_simd :: proc "contextless" (data: [^]$T, n: int) -> T {
	K  :: 32 / size_of(T)
	V  :: #simd[K]T
	vp := cast([^]V)data
	nv := n / K
	if nv > 0 {
		v0  := intrinsics.unaligned_load(&vp[0])
		lo0 := v0
		lo1 := v0
		i   := 1
		for i + 1 < nv {
			lo0 = intrinsics.simd_min(lo0, intrinsics.unaligned_load(&vp[i]))
			lo1 = intrinsics.simd_min(lo1, intrinsics.unaligned_load(&vp[i + 1]))
			i += 2
		}
		for ; i < nv; i += 1 {
			lo0 = intrinsics.simd_min(lo0, intrinsics.unaligned_load(&vp[i]))
		}
		best := intrinsics.simd_reduce_min(intrinsics.simd_min(lo0, lo1))
		for j := nv * K; j < n; j += 1 {
			best = min(best, data[j])
		}
		return best
	}
	best := data[0]
	for j in 1..<n {
		best = min(best, data[j])
	}
	return best
}

@(enable_target_feature = _SIMD_TARGET_FEATURE)
_max_typed_simd :: proc "contextless" (data: [^]$T, n: int) -> T {
	K  :: 32 / size_of(T)
	V  :: #simd[K]T
	vp := cast([^]V)data
	nv := n / K
	if nv > 0 {
		v0  := intrinsics.unaligned_load(&vp[0])
		hi0 := v0
		hi1 := v0
		i   := 1
		for i + 1 < nv {
			hi0 = intrinsics.simd_max(hi0, intrinsics.unaligned_load(&vp[i]))
			hi1 = intrinsics.simd_max(hi1, intrinsics.unaligned_load(&vp[i + 1]))
			i += 2
		}
		for ; i < nv; i += 1 {
			hi0 = intrinsics.simd_max(hi0, intrinsics.unaligned_load(&vp[i]))
		}
		best := intrinsics.simd_reduce_max(intrinsics.simd_max(hi0, hi1))
		for j := nv * K; j < n; j += 1 {
			best = max(best, data[j])
		}
		return best
	}
	best := data[0]
	for j in 1..<n {
		best = max(best, data[j])
	}
	return best
}

// ── min+max combined ──────────────────────────────────────────────────────────

@(enable_target_feature = _SIMD_TARGET_FEATURE)
_min_max_typed_simd :: proc "contextless" (data: [^]$T, n: int) -> (lo: T, hi: T) {
	K  :: 32 / size_of(T)
	V  :: #simd[K]T
	vp := cast([^]V)data
	nv := n / K
	if nv > 0 {
		v0  := intrinsics.unaligned_load(&vp[0])
		lo0 := v0; lo1 := v0
		hi0 := v0; hi1 := v0
		i   := 1
		for i + 1 < nv {
			vi0 := intrinsics.unaligned_load(&vp[i])
			vi1 := intrinsics.unaligned_load(&vp[i + 1])
			lo0 = intrinsics.simd_min(lo0, vi0)
			hi0 = intrinsics.simd_max(hi0, vi0)
			lo1 = intrinsics.simd_min(lo1, vi1)
			hi1 = intrinsics.simd_max(hi1, vi1)
			i += 2
		}
		for ; i < nv; i += 1 {
			vi := intrinsics.unaligned_load(&vp[i])
			lo0 = intrinsics.simd_min(lo0, vi)
			hi0 = intrinsics.simd_max(hi0, vi)
		}
		lo = intrinsics.simd_reduce_min(intrinsics.simd_min(lo0, lo1))
		hi = intrinsics.simd_reduce_max(intrinsics.simd_max(hi0, hi1))
		for j := nv * K; j < n; j += 1 {
			lo = min(lo, data[j])
			hi = max(hi, data[j])
		}
	} else {
		lo = data[0]; hi = data[0]
		for j in 1..<n {
			lo = min(lo, data[j])
			hi = max(hi, data[j])
		}
	}
	return
}
