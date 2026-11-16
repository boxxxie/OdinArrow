package skadi

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"

// Comparison predicates and selection refinement. The point is conjunctive
// (AND) queries: with selections, each successive predicate is evaluated only on
// the rows that survived the previous one — so a selective first predicate makes
// every later predicate (and the final gather) touch far fewer rows.
//
// The comparison itself is monomorphised on the operator ($OP, a comptime
// constant) so the inner loop is a single branchless comparison the compiler can
// vectorise — a runtime `op` switch in the loop would block that entirely.

Compare_Op :: enum { Gt, Ge, Lt, Le, Eq, Ne }

@(private="file")
_Const_Cmp :: enum u8 { Dynamic, All_False, All_True }

@(private="file")
_apply_native :: #force_inline proc "contextless" (a, b: $T, $OP: Compare_Op) -> bool {
	when      OP == .Gt { return a >  b }
	else when OP == .Ge { return a >= b }
	else when OP == .Lt { return a <  b }
	else when OP == .Le { return a <= b }
	else when OP == .Eq { return a == b }
	else                { return a != b }
}

@(private="file")
_apply_native_rt :: #force_inline proc "contextless" (a: $T, op: Compare_Op, b: T) -> bool {
	switch op {
	case .Gt: return a >  b
	case .Ge: return a >= b
	case .Lt: return a <  b
	case .Le: return a <= b
	case .Eq: return a == b
	case .Ne: return a != b
	}
	return false
}

// Reduce comparing integer elements `v: T` against an `f64` scalar `s` to either a
// constant outcome or an exact native `T` threshold comparison.
_int_vs_f64_plan :: proc "contextless" (s: f64, op: Compare_Op, $T: typeid) -> (mode: _Const_Cmp, cmp_op: Compare_Op, thresh: T) {
	if math.is_nan(s) {
		return (op == .Ne ? .All_True : .All_False), op, 0
	}
	below_min := false
	above_max := false
	when T == i64 {
		// -2^63 and +2^63 are exact in IEEE-754 f64; every i64 satisfies -2^63 <= v < 2^63.
		below_min = s < -9223372036854775808.0
		above_max = s >=  9223372036854775808.0
	} else when T == u64 {
		// +2^64 is exact in IEEE-754 f64; every u64 satisfies 0 <= v < 2^64.
		below_min = s < 0.0
		above_max = s >= 18446744073709551616.0
	} else {
		below_min = s < f64(min(T))
		above_max = s > f64(max(T))
	}

	if below_min {
		#partial switch op {
		case .Gt, .Ge, .Ne: return .All_True, op, 0
		case: return .All_False, op, 0
		}
	}
	if above_max {
		#partial switch op {
		case .Lt, .Le, .Ne: return .All_True, op, 0
		case: return .All_False, op, 0
		}
	}

	fl := math.floor(s)
	cl := math.ceil(s)
	switch op {
	case .Eq:
		if fl != s { return .All_False, .Eq, 0 }
		return .Dynamic, .Eq, T(fl)
	case .Ne:
		if fl != s { return .All_True, .Ne, 0 }
		return .Dynamic, .Ne, T(fl)
	case .Gt: return .Dynamic, .Gt, T(fl)
	case .Le: return .Dynamic, .Le, T(fl)
	case .Ge: return .Dynamic, .Ge, T(cl)
	case .Lt: return .Dynamic, .Lt, T(cl)
	}
	return .All_False, op, 0
}

_int_vs_i64_plan :: proc "contextless" (s: i64, op: Compare_Op, $T: typeid) -> (mode: _Const_Cmp, thresh: T) {
	when T == u8 || T == u16 || T == u32 || T == u64 {
		if s < 0 {
			#partial switch op {
			case .Gt, .Ge, .Ne: return .All_True, 0
			case: return .All_False, 0
			}
		}
		if u64(s) > u64(max(T)) {
			#partial switch op {
			case .Lt, .Le, .Ne: return .All_True, 0
			case: return .All_False, 0
			}
		}
		return .Dynamic, T(u64(s))
	} else {
		if s < i64(min(T)) {
			#partial switch op {
			case .Gt, .Ge, .Ne: return .All_True, 0
			case: return .All_False, 0
			}
		}
		if s > i64(max(T)) {
			#partial switch op {
			case .Lt, .Le, .Ne: return .All_True, 0
			case: return .All_False, 0
			}
		}
		return .Dynamic, T(s)
	}
}

_int_vs_u64_plan :: proc "contextless" (s: u64, op: Compare_Op, $T: typeid) -> (mode: _Const_Cmp, thresh: T) {
	if s > u64(max(T)) {
		#partial switch op {
		case .Lt, .Le, .Ne: return .All_True, 0
		case: return .All_False, 0
		}
	}
	return .Dynamic, T(s)
}

// Exact comparison of IEEE-754 f64 `fv` against `s: i64` without rounding `s`.
_cmp_f64_vs_i64 :: proc "contextless" (fv: f64, op: Compare_Op, s: i64) -> bool {
	if math.is_nan(fv) { return op == .Ne }
	if fv < -9223372036854775808.0 { return op == .Lt || op == .Le || op == .Ne }
	if fv >=  9223372036854775808.0 { return op == .Gt || op == .Ge || op == .Ne }
	fl := i64(math.floor(fv))
	cl := i64(math.ceil(fv))
	if fl == cl { return _apply_native_rt(fl, op, s) }
	switch op {
	case .Eq: return false
	case .Ne: return true
	case .Lt, .Le: return cl <= s
	case .Gt, .Ge: return fl >= s
	}
	return false
}

_cmp_f64_vs_u64 :: proc "contextless" (fv: f64, op: Compare_Op, s: u64) -> bool {
	if math.is_nan(fv) { return op == .Ne }
	if fv < 0.0 { return op == .Lt || op == .Le || op == .Ne }
	if fv >= 18446744073709551616.0 { return op == .Gt || op == .Ge || op == .Ne }
	fl := u64(math.floor(fv))
	cl := u64(math.ceil(fv))
	if fl == cl { return _apply_native_rt(fl, op, s) }
	switch op {
	case .Eq: return false
	case .Ne: return true
	case .Lt, .Le: return cl <= s
	case .Gt, .Ge: return fl >= s
	}
	return false
}

// ── compute_compare → Bool mask ─────────────────────────────────────────────

compute_compare :: proc(arr: ^Array, op: Compare_Op, scalar: f64, allocator := context.allocator) -> (mask: Array, err: mem.Allocator_Error) {
	switch _ in arr.type {
	case Int8_Type:    return _compare_int_f64(arr, op, scalar, i8,  allocator)
	case Int16_Type:   return _compare_int_f64(arr, op, scalar, i16, allocator)
	case Int32_Type:   return _compare_int_f64(arr, op, scalar, i32, allocator)
	case Int64_Type:   return _compare_int_f64(arr, op, scalar, i64, allocator)
	case UInt8_Type:   return _compare_int_f64(arr, op, scalar, u8,  allocator)
	case UInt16_Type:  return _compare_int_f64(arr, op, scalar, u16, allocator)
	case UInt32_Type:  return _compare_int_f64(arr, op, scalar, u32, allocator)
	case UInt64_Type:  return _compare_int_f64(arr, op, scalar, u64, allocator)
	case Float32_Type: return _compare_float_f64(arr, op, scalar, f32, allocator)
	case Float64_Type: return _compare_float_f64(arr, op, scalar, f64, allocator)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_compare: type does not support ordering")
	}
	return
}

compute_compare_i64 :: proc(arr: ^Array, op: Compare_Op, scalar: i64, allocator := context.allocator) -> (mask: Array, err: mem.Allocator_Error) {
	switch _ in arr.type {
	case Int8_Type:    return _compare_int_i64(arr, op, scalar, i8,  allocator)
	case Int16_Type:   return _compare_int_i64(arr, op, scalar, i16, allocator)
	case Int32_Type:   return _compare_int_i64(arr, op, scalar, i32, allocator)
	case Int64_Type:   return _compare_int_i64(arr, op, scalar, i64, allocator)
	case UInt8_Type:   return _compare_int_i64(arr, op, scalar, u8,  allocator)
	case UInt16_Type:  return _compare_int_i64(arr, op, scalar, u16, allocator)
	case UInt32_Type:  return _compare_int_i64(arr, op, scalar, u32, allocator)
	case UInt64_Type:  return _compare_int_i64(arr, op, scalar, u64, allocator)
	case Float32_Type: return _compare_float_i64(arr, op, scalar, f32, allocator)
	case Float64_Type: return _compare_float_i64(arr, op, scalar, f64, allocator)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_compare_i64: type does not support ordering")
	}
	return
}

compute_compare_u64 :: proc(arr: ^Array, op: Compare_Op, scalar: u64, allocator := context.allocator) -> (mask: Array, err: mem.Allocator_Error) {
	switch _ in arr.type {
	case Int8_Type:    return _compare_int_u64(arr, op, scalar, i8,  allocator)
	case Int16_Type:   return _compare_int_u64(arr, op, scalar, i16, allocator)
	case Int32_Type:   return _compare_int_u64(arr, op, scalar, i32, allocator)
	case Int64_Type:   return _compare_int_u64(arr, op, scalar, i64, allocator)
	case UInt8_Type:   return _compare_int_u64(arr, op, scalar, u8,  allocator)
	case UInt16_Type:  return _compare_int_u64(arr, op, scalar, u16, allocator)
	case UInt32_Type:  return _compare_int_u64(arr, op, scalar, u32, allocator)
	case UInt64_Type:  return _compare_int_u64(arr, op, scalar, u64, allocator)
	case Float32_Type: return _compare_float_u64(arr, op, scalar, f32, allocator)
	case Float64_Type: return _compare_float_u64(arr, op, scalar, f64, allocator)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_compare_u64: type does not support ordering")
	}
	return
}

@(private="file")
_emit_const_mask :: proc(arr: ^Array, mode: _Const_Cmp, allocator: mem.Allocator) -> (mask: Array, err: mem.Allocator_Error) {
	n := arr.length
	buf := buffer_make(bitmap_byte_count(n), allocator) or_return
	if mode == .All_True {
		if arr.buffers[0].data == nil {
			bitmap_set_all(buf.data, n)
		} else {
			for i in 0..<n {
				if array_is_valid(arr, i) {
					bitmap_set(buf.data, i)
				}
			}
		}
	}
	mask = Array{ type = Bool_Type{}, length = n, buffers = {{}, buf, {}} }
	return
}

@(private="file")
_compare_native :: proc(arr: ^Array, op: Compare_Op, thresh: $T, allocator: mem.Allocator) -> (mask: Array, err: mem.Allocator_Error) {
	n := arr.length
	data := cast([^]T)arr.buffers[1].data
	off := arr.offset
	nbytes := bitmap_byte_count(n)
	buf: Buffer
	if arr.buffers[0].data == nil {
		buf = buffer_make_uninit(nbytes, allocator) or_return
		// Zero only the partial tail bytes where _compare_mono uses `|=`.
		when size_of(T) <= 2 {
			tail_start := (n / 16) * 2
		} else {
			tail_start := n / 8
		}
		for b := tail_start; b < nbytes; b += 1 {
			buf.data[b] = 0
		}
		switch op {
		case .Gt: _compare_mono(data, off, n, thresh, buf.data, .Gt)
		case .Ge: _compare_mono(data, off, n, thresh, buf.data, .Ge)
		case .Lt: _compare_mono(data, off, n, thresh, buf.data, .Lt)
		case .Le: _compare_mono(data, off, n, thresh, buf.data, .Le)
		case .Eq: _compare_mono(data, off, n, thresh, buf.data, .Eq)
		case .Ne: _compare_mono(data, off, n, thresh, buf.data, .Ne)
		}
	} else {
		buf = buffer_make(nbytes, allocator) or_return
		for i in 0..<n {
			if array_is_valid(arr, i) && _apply_native_rt(data[off + i], op, thresh) {
				buf.data[i >> 3] |= 1 << u8(i & 7)
			}
		}
	}
	mask = Array{ type = Bool_Type{}, length = n, buffers = {{}, buf, {}} }
	return
}

@(private="file")
_compare_int_f64 :: proc(arr: ^Array, op: Compare_Op, scalar: f64, $T: typeid, allocator: mem.Allocator) -> (mask: Array, err: mem.Allocator_Error) {
	mode, cmp_op, thresh := _int_vs_f64_plan(scalar, op, T)
	if mode != .Dynamic { return _emit_const_mask(arr, mode, allocator) }
	return _compare_native(arr, cmp_op, thresh, allocator)
}

@(private="file")
_compare_int_i64 :: proc(arr: ^Array, op: Compare_Op, scalar: i64, $T: typeid, allocator: mem.Allocator) -> (mask: Array, err: mem.Allocator_Error) {
	mode, thresh := _int_vs_i64_plan(scalar, op, T)
	if mode != .Dynamic { return _emit_const_mask(arr, mode, allocator) }
	return _compare_native(arr, op, thresh, allocator)
}

@(private="file")
_compare_int_u64 :: proc(arr: ^Array, op: Compare_Op, scalar: u64, $T: typeid, allocator: mem.Allocator) -> (mask: Array, err: mem.Allocator_Error) {
	mode, thresh := _int_vs_u64_plan(scalar, op, T)
	if mode != .Dynamic { return _emit_const_mask(arr, mode, allocator) }
	return _compare_native(arr, op, thresh, allocator)
}

@(private="file")
_compare_float_f64 :: proc(arr: ^Array, op: Compare_Op, scalar: f64, $T: typeid, allocator: mem.Allocator) -> (mask: Array, err: mem.Allocator_Error) {
	when T == f64 {
		return _compare_native(arr, op, scalar, allocator)
	} else {
		if arr.buffers[0].data == nil {
			switch op {
			case .Gt: return _compare_f32_f64_dense(arr, scalar, .Gt, allocator)
			case .Ge: return _compare_f32_f64_dense(arr, scalar, .Ge, allocator)
			case .Lt: return _compare_f32_f64_dense(arr, scalar, .Lt, allocator)
			case .Le: return _compare_f32_f64_dense(arr, scalar, .Le, allocator)
			case .Eq: return _compare_f32_f64_dense(arr, scalar, .Eq, allocator)
			case .Ne: return _compare_f32_f64_dense(arr, scalar, .Ne, allocator)
			}
		}
		n := arr.length
		data := cast([^]f32)arr.buffers[1].data
		off := arr.offset
		buf := buffer_make(bitmap_byte_count(n), allocator) or_return
		for i in 0..<n {
			if array_is_valid(arr, i) && _apply_native_rt(f64(data[off + i]), op, scalar) {
				buf.data[i >> 3] |= 1 << u8(i & 7)
			}
		}
		mask = Array{ type = Bool_Type{}, length = n, buffers = {{}, buf, {}} }
		return
	}
}

@(private="file")
_compare_f32_f64_dense :: proc(arr: ^Array, s: f64, $OP: Compare_Op, allocator: mem.Allocator) -> (mask: Array, err: mem.Allocator_Error) {
	n := arr.length
	data := (cast([^]f32)arr.buffers[1].data)[arr.offset:]
	buf := buffer_make(bitmap_byte_count(n), allocator) or_return
	out := buf.data
	i := 0
	for i + 8 <= n {
		b := u8(0)
		#unroll for k in 0..<8 {
			if _apply_native(f64(data[i + k]), s, OP) {
				b |= 1 << uint(k)
			}
		}
		out[i >> 3] = b
		i += 8
	}
	for ; i < n; i += 1 {
		if _apply_native(f64(data[i]), s, OP) {
			out[i >> 3] |= 1 << u8(i & 7)
		}
	}
	mask = Array{ type = Bool_Type{}, length = n, buffers = {{}, buf, {}} }
	return
}

@(private="file")
_compare_float_i64 :: proc(arr: ^Array, op: Compare_Op, scalar: i64, $T: typeid, allocator: mem.Allocator) -> (mask: Array, err: mem.Allocator_Error) {
	n := arr.length
	data := cast([^]T)arr.buffers[1].data
	off := arr.offset
	buf := buffer_make(bitmap_byte_count(n), allocator) or_return
	for i in 0..<n {
		if array_is_valid(arr, i) && _cmp_f64_vs_i64(f64(data[off + i]), op, scalar) {
			buf.data[i >> 3] |= 1 << u8(i & 7)
		}
	}
	mask = Array{ type = Bool_Type{}, length = n, buffers = {{}, buf, {}} }
	return
}

@(private="file")
_compare_float_u64 :: proc(arr: ^Array, op: Compare_Op, scalar: u64, $T: typeid, allocator: mem.Allocator) -> (mask: Array, err: mem.Allocator_Error) {
	n := arr.length
	data := cast([^]T)arr.buffers[1].data
	off := arr.offset
	buf := buffer_make(bitmap_byte_count(n), allocator) or_return
	for i in 0..<n {
		if array_is_valid(arr, i) && _cmp_f64_vs_u64(f64(data[off + i]), op, scalar) {
			buf.data[i >> 3] |= 1 << u8(i & 7)
		}
	}
	mask = Array{ type = Bool_Type{}, length = n, buffers = {{}, buf, {}} }
	return
}

@(private="file")
_simd_cmp_bits :: #force_inline proc "contextless" (v, sv: $V, $OP: Compare_Op, $Out: typeid) -> Out {
	when      OP == .Gt { return transmute(Out)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_gt(v, sv)) }
	else when OP == .Ge { return transmute(Out)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_ge(v, sv)) }
	else when OP == .Lt { return transmute(Out)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_lt(v, sv)) }
	else when OP == .Le { return transmute(Out)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_le(v, sv)) }
	else when OP == .Eq { return transmute(Out)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_eq(v, sv)) }
	else                { return transmute(Out)intrinsics.simd_extract_msbs(intrinsics.simd_lanes_ne(v, sv)) }
}

@(private="file", enable_target_feature = _SIMD_TARGET_FEATURE)
_compare_mono :: proc "contextless" (data: [^]$T, off, n: int, s: T, out: [^]u8, $OP: Compare_Op) {
	when T == i8 || T == u8 || T == i16 || T == u16 {
		V  :: #simd[16]T
		sv := V(s)
		vp := cast([^]V)(data[off:])
		nv := n / 16
		for i in 0..<nv {
			v    := intrinsics.unaligned_load(&vp[i])
			bits := _simd_cmp_bits(v, sv, OP, u16)
			intrinsics.unaligned_store(cast(^u16)&out[i * 2], bits)
		}
		for i := nv * 16; i < n; i += 1 {
			if _apply_native(data[off + i], s, OP) { out[i >> 3] |= 1 << u8(i & 7) }
		}
	} else when size_of(T) == 8 {
		// i64, u64, f64 -> two 256-bit #simd[4]T chunks per packed mask byte.
		V  :: #simd[4]T
		sv := V(s)
		vp := cast([^]V)(data[off:])
		nv := n / 8
		for i in 0..<nv {
			v0    := intrinsics.unaligned_load(&vp[i * 2])
			v1    := intrinsics.unaligned_load(&vp[i * 2 + 1])
			bits0 := _simd_cmp_bits(v0, sv, OP, u8)
			bits1 := _simd_cmp_bits(v1, sv, OP, u8)
			out[i] = bits0 | (bits1 << 4)
		}
		for i := nv * 8; i < n; i += 1 {
			if _apply_native(data[off + i], s, OP) { out[i >> 3] |= 1 << u8(i & 7) }
		}
	} else {
		// i32, u32, f32 → 8 lanes per packed mask byte.
		V  :: #simd[8]T
		sv := V(s)
		vp := cast([^]V)(data[off:])
		nv := n / 8
		for i in 0..<nv {
			v     := intrinsics.unaligned_load(&vp[i])
			out[i] = _simd_cmp_bits(v, sv, OP, u8)
		}
		for i := nv * 8; i < n; i += 1 {
			if _apply_native(data[off + i], s, OP) { out[i >> 3] |= 1 << u8(i & 7) }
		}
	}
}

// ── stack-chunked first predicate → selection ───────────────────────────────

// AND validity bits for `arr[start_row : start_row + chunk_len]` into `mask_bits`.
@(private="file")
_and_validity_chunk :: proc "contextless" (mask_bits: [^]u8, arr: ^Array, start_row, chunk_len: int) {
	bm := arr.buffers[0].data
	if bm == nil || chunk_len <= 0 { return }
	bm_size    := arr.buffers[0].size
	bit_start  := arr.offset + start_row
	bit_off    := uint(bit_start) & 7
	byte_start := bit_start >> 3
	n_bytes    := (chunk_len + 7) / 8
	if bit_off == 0 {
		w := 0
		for ; w + 8 <= n_bytes && byte_start + w + 8 <= bm_size; w += 8 {
			m := intrinsics.unaligned_load(cast(^u64)&mask_bits[w])
			v := intrinsics.unaligned_load(cast(^u64)&bm[byte_start + w])
			intrinsics.unaligned_store(cast(^u64)&mask_bits[w], m & v)
		}
		for ; w < n_bytes; w += 1 {
			vb: u8 = bm[byte_start + w] if (byte_start + w < bm_size) else 0
			mask_bits[w] &= vb
		}
		return
	}
	for b in 0..<n_bytes {
		lo: u8 = bm[byte_start + b]     if (byte_start + b     < bm_size) else 0
		hi: u8 = bm[byte_start + b + 1] if (byte_start + b + 1 < bm_size) else 0
		mask_bits[b] &= u8((u16(lo) | (u16(hi) << 8)) >> bit_off)
	}
}

@(private="file")
_fill_chunk_mask_native :: proc "contextless" (
	data:       [^]$T,
	off:        int,
	chunk_len:  int,
	thresh:     T,
	op:         Compare_Op,
	arr:        ^Array,
	start_row:  int,
	mask_bits:  [^]u8,
) {
	nbytes := bitmap_byte_count(chunk_len)
	when size_of(T) <= 2 {
		tail_start := (chunk_len / 16) * 2
	} else {
		tail_start := chunk_len / 8
	}
	for b := tail_start; b < nbytes; b += 1 {
		mask_bits[b] = 0
	}
	switch op {
	case .Gt: _compare_mono(data, off + start_row, chunk_len, thresh, mask_bits, .Gt)
	case .Ge: _compare_mono(data, off + start_row, chunk_len, thresh, mask_bits, .Ge)
	case .Lt: _compare_mono(data, off + start_row, chunk_len, thresh, mask_bits, .Lt)
	case .Le: _compare_mono(data, off + start_row, chunk_len, thresh, mask_bits, .Le)
	case .Eq: _compare_mono(data, off + start_row, chunk_len, thresh, mask_bits, .Eq)
	case .Ne: _compare_mono(data, off + start_row, chunk_len, thresh, mask_bits, .Ne)
	}
	_and_validity_chunk(mask_bits, arr, start_row, chunk_len)
}

@(private="file")
_fill_chunk_mask_f32_f64 :: proc "contextless" (
	data:       [^]f32,
	off:        int,
	chunk_len:  int,
	s:          f64,
	op:         Compare_Op,
	arr:        ^Array,
	start_row:  int,
	mask_bits:  [^]u8,
) {
	base := off + start_row
	nbytes := bitmap_byte_count(chunk_len)
	for b in (chunk_len / 8)..<nbytes { mask_bits[b] = 0 }
	i := 0
	for i + 8 <= chunk_len {
		b := u8(0)
		#unroll for k in 0..<8 {
			if _apply_native_rt(f64(data[base + i + k]), op, s) {
				b |= 1 << uint(k)
			}
		}
		mask_bits[i >> 3] = b
		i += 8
	}
	for ; i < chunk_len; i += 1 {
		if _apply_native_rt(f64(data[base + i]), op, s) {
			mask_bits[i >> 3] |= 1 << u8(i & 7)
		}
	}
	_and_validity_chunk(mask_bits, arr, start_row, chunk_len)
}

@(private="file")
_fill_chunk_mask_float_i64 :: proc "contextless" (
	data:       [^]$T,
	off:        int,
	chunk_len:  int,
	scalar:     i64,
	op:         Compare_Op,
	arr:        ^Array,
	start_row:  int,
	mask_bits:  [^]u8,
) {
	base := off + start_row
	nbytes := bitmap_byte_count(chunk_len)
	for b in 0..<nbytes { mask_bits[b] = 0 }
	for i in 0..<chunk_len {
		if _cmp_f64_vs_i64(f64(data[base + i]), op, scalar) {
			mask_bits[i >> 3] |= 1 << u8(i & 7)
		}
	}
	_and_validity_chunk(mask_bits, arr, start_row, chunk_len)
}

@(private="file")
_select_compare_const :: proc(arr: ^Array, mode: _Const_Cmp, out_into: []i32, into_mode: bool, allocator: mem.Allocator) -> Selection {
	alloc := allocator if !into_mode else mem.Allocator{}
	n := arr.length
	if mode == .All_False || n <= 0 {
		return Selection{ length = 0, allocator = alloc }
	}
	has_nulls := arr.buffers[0].data != nil
	if !has_nulls {
		out := out_into if into_mode else _alloc_i32_slice_uninit(n, allocator)
		for i in 0..<n { out[i] = i32(i) }
		return Selection{ indices = out[:n], length = n, capacity = len(out) if !into_mode else 0, allocator = alloc }
	}
	bm := arr.buffers[0].data
	if into_mode {
		k := 0
		for i in 0..<n {
			if bitmap_get(bm, arr.offset + i) { out_into[k] = i32(i); k += 1 }
		}
		return Selection{ indices = out_into[:k], length = k }
	}
	count := 0
	for i in 0..<n {
		if bitmap_get(bm, arr.offset + i) { count += 1 }
	}
	out := _alloc_i32_slice_uninit(count, allocator)
	k := 0
	for i in 0..<n {
		if bitmap_get(bm, arr.offset + i) { out[k] = i32(i); k += 1 }
	}
	return Selection{ indices = out, length = count, capacity = len(out), allocator = allocator }
}

@(private="file")
_select_compare_native :: proc(arr: ^Array, op: Compare_Op, thresh: $T, out_into: []i32, into_mode: bool, allocator: mem.Allocator) -> Selection {
	n := arr.length
	if n <= 0 {
		return Selection{ length = 0, allocator = allocator if !into_mode else mem.Allocator{} }
	}
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	if into_mode {
		mask_buf: [512]u8
		k := 0
		for chunk_start := 0; chunk_start < n; chunk_start += 4096 {
			chunk_len := min(4096, n - chunk_start)
			_fill_chunk_mask_native(data, off, chunk_len, thresh, op, arr, chunk_start, &mask_buf[0])
			k += _compress_chunk_offset(&mask_buf[0], chunk_len, out_into[k:], i32(chunk_start))
		}
		return Selection{ indices = out_into[:k], length = k }
	}
	if n <= 16_384 {
		mask_buf: [2048]u8
		_fill_chunk_mask_native(data, off, n, thresh, op, arr, 0, &mask_buf[0])
		count := _filter_count_bits(&mask_buf[0], 0, n)
		idx   := _alloc_i32_slice_uninit(count, allocator)
		if count > 0 {
			_ = _compress_chunk_offset(&mask_buf[0], n, idx, 0)
		}
		return Selection{ indices = idx, length = count, capacity = len(idx), allocator = allocator }
	}
	mask_buf: [512]u8
	total := 0
	for chunk_start := 0; chunk_start < n; chunk_start += 4096 {
		chunk_len := min(4096, n - chunk_start)
		_fill_chunk_mask_native(data, off, chunk_len, thresh, op, arr, chunk_start, &mask_buf[0])
		total += _filter_count_bits(&mask_buf[0], 0, chunk_len)
	}
	idx := _alloc_i32_slice_uninit(total, allocator)
	if total == 0 {
		return Selection{ indices = idx, length = 0, capacity = len(idx), allocator = allocator }
	}
	k := 0
	for chunk_start := 0; chunk_start < n; chunk_start += 4096 {
		chunk_len := min(4096, n - chunk_start)
		_fill_chunk_mask_native(data, off, chunk_len, thresh, op, arr, chunk_start, &mask_buf[0])
		k += _compress_chunk_offset(&mask_buf[0], chunk_len, idx[k:], i32(chunk_start))
	}
	return Selection{ indices = idx[:k], length = k, capacity = len(idx), allocator = allocator }
}

@(private="file")
_select_compare_f32_f64 :: proc(arr: ^Array, op: Compare_Op, scalar: f64, out_into: []i32, into_mode: bool, allocator: mem.Allocator) -> Selection {
	n := arr.length
	if n <= 0 {
		return Selection{ length = 0, allocator = allocator if !into_mode else mem.Allocator{} }
	}
	data := cast([^]f32)arr.buffers[1].data
	off  := arr.offset
	if into_mode {
		mask_buf: [512]u8
		k := 0
		for chunk_start := 0; chunk_start < n; chunk_start += 4096 {
			chunk_len := min(4096, n - chunk_start)
			_fill_chunk_mask_f32_f64(data, off, chunk_len, scalar, op, arr, chunk_start, &mask_buf[0])
			k += _compress_chunk_offset(&mask_buf[0], chunk_len, out_into[k:], i32(chunk_start))
		}
		return Selection{ indices = out_into[:k], length = k }
	}
	if n <= 16_384 {
		mask_buf: [2048]u8
		_fill_chunk_mask_f32_f64(data, off, n, scalar, op, arr, 0, &mask_buf[0])
		count := _filter_count_bits(&mask_buf[0], 0, n)
		idx   := _alloc_i32_slice_uninit(count, allocator)
		if count > 0 { _ = _compress_chunk_offset(&mask_buf[0], n, idx, 0) }
		return Selection{ indices = idx, length = count, capacity = len(idx), allocator = allocator }
	}
	mask_buf: [512]u8
	total := 0
	for chunk_start := 0; chunk_start < n; chunk_start += 4096 {
		chunk_len := min(4096, n - chunk_start)
		_fill_chunk_mask_f32_f64(data, off, chunk_len, scalar, op, arr, chunk_start, &mask_buf[0])
		total += _filter_count_bits(&mask_buf[0], 0, chunk_len)
	}
	idx := _alloc_i32_slice_uninit(total, allocator)
	if total == 0 {
		return Selection{ indices = idx, length = 0, capacity = len(idx), allocator = allocator }
	}
	k := 0
	for chunk_start := 0; chunk_start < n; chunk_start += 4096 {
		chunk_len := min(4096, n - chunk_start)
		_fill_chunk_mask_f32_f64(data, off, chunk_len, scalar, op, arr, chunk_start, &mask_buf[0])
		k += _compress_chunk_offset(&mask_buf[0], chunk_len, idx[k:], i32(chunk_start))
	}
	return Selection{ indices = idx[:k], length = k, capacity = len(idx), allocator = allocator }
}

@(private="file")
_select_compare_float_i64 :: proc(arr: ^Array, op: Compare_Op, scalar: i64, $T: typeid, allocator: mem.Allocator) -> Selection {
	n := arr.length
	if n <= 0 { return Selection{ allocator = allocator } }
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	if n <= 16_384 {
		mask_buf: [2048]u8
		_fill_chunk_mask_float_i64(data, off, n, scalar, op, arr, 0, &mask_buf[0])
		count := _filter_count_bits(&mask_buf[0], 0, n)
		idx   := _alloc_i32_slice_uninit(count, allocator)
		if count > 0 { _ = _compress_chunk_offset(&mask_buf[0], n, idx, 0) }
		return Selection{ indices = idx, length = count, capacity = len(idx), allocator = allocator }
	}
	mask_buf: [512]u8
	total := 0
	for chunk_start := 0; chunk_start < n; chunk_start += 4096 {
		chunk_len := min(4096, n - chunk_start)
		_fill_chunk_mask_float_i64(data, off, chunk_len, scalar, op, arr, chunk_start, &mask_buf[0])
		total += _filter_count_bits(&mask_buf[0], 0, chunk_len)
	}
	idx := _alloc_i32_slice_uninit(total, allocator)
	if total == 0 { return Selection{ indices = idx, length = 0, capacity = len(idx), allocator = allocator } }
	k := 0
	for chunk_start := 0; chunk_start < n; chunk_start += 4096 {
		chunk_len := min(4096, n - chunk_start)
		_fill_chunk_mask_float_i64(data, off, chunk_len, scalar, op, arr, chunk_start, &mask_buf[0])
		k += _compress_chunk_offset(&mask_buf[0], chunk_len, idx[k:], i32(chunk_start))
	}
	return Selection{ indices = idx[:k], length = k, capacity = len(idx), allocator = allocator }
}

@(private="file")
_select_compare_int_f64 :: proc(arr: ^Array, op: Compare_Op, scalar: f64, $T: typeid, out_into: []i32, into_mode: bool, allocator: mem.Allocator) -> Selection {
	mode, cmp_op, thresh := _int_vs_f64_plan(scalar, op, T)
	if mode != .Dynamic { return _select_compare_const(arr, mode, out_into, into_mode, allocator) }
	return _select_compare_native(arr, cmp_op, thresh, out_into, into_mode, allocator)
}

@(private="file")
_select_compare_int_i64 :: proc(arr: ^Array, op: Compare_Op, scalar: i64, $T: typeid, allocator: mem.Allocator) -> Selection {
	mode, thresh := _int_vs_i64_plan(scalar, op, T)
	if mode != .Dynamic { return _select_compare_const(arr, mode, nil, false, allocator) }
	return _select_compare_native(arr, op, thresh, nil, false, allocator)
}

// Zero-allocation predicate evaluation writing surviving row indices into caller-owned `out_indices`.
compute_select_compare_into :: proc(arr: ^Array, op: Compare_Op, scalar: f64, out_indices: []i32) -> Selection {
	assert(len(out_indices) >= arr.length, "compute_select_compare_into: output slice smaller than array length")
	switch _ in arr.type {
	case Int8_Type:    return _select_compare_int_f64(arr, op, scalar, i8,  out_indices, true, {})
	case Int16_Type:   return _select_compare_int_f64(arr, op, scalar, i16, out_indices, true, {})
	case Int32_Type:   return _select_compare_int_f64(arr, op, scalar, i32, out_indices, true, {})
	case Int64_Type:   return _select_compare_int_f64(arr, op, scalar, i64, out_indices, true, {})
	case UInt8_Type:   return _select_compare_int_f64(arr, op, scalar, u8,  out_indices, true, {})
	case UInt16_Type:  return _select_compare_int_f64(arr, op, scalar, u16, out_indices, true, {})
	case UInt32_Type:  return _select_compare_int_f64(arr, op, scalar, u32, out_indices, true, {})
	case UInt64_Type:  return _select_compare_int_f64(arr, op, scalar, u64, out_indices, true, {})
	case Float32_Type: return _select_compare_f32_f64(arr, op, scalar,      out_indices, true, {})
	case Float64_Type: return _select_compare_native(arr, op, scalar,       out_indices, true, {})
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_select_compare_into: type does not support ordering")
	}
	return {}
}

compute_select_compare :: proc(arr: ^Array, op: Compare_Op, scalar: f64, allocator := context.allocator) -> Selection {
	switch _ in arr.type {
	case Int8_Type:    return _select_compare_int_f64(arr, op, scalar, i8,  nil, false, allocator)
	case Int16_Type:   return _select_compare_int_f64(arr, op, scalar, i16, nil, false, allocator)
	case Int32_Type:   return _select_compare_int_f64(arr, op, scalar, i32, nil, false, allocator)
	case Int64_Type:   return _select_compare_int_f64(arr, op, scalar, i64, nil, false, allocator)
	case UInt8_Type:   return _select_compare_int_f64(arr, op, scalar, u8,  nil, false, allocator)
	case UInt16_Type:  return _select_compare_int_f64(arr, op, scalar, u16, nil, false, allocator)
	case UInt32_Type:  return _select_compare_int_f64(arr, op, scalar, u32, nil, false, allocator)
	case UInt64_Type:  return _select_compare_int_f64(arr, op, scalar, u64, nil, false, allocator)
	case Float32_Type: return _select_compare_f32_f64(arr, op, scalar,      nil, false, allocator)
	case Float64_Type: return _select_compare_native(arr, op, scalar,       nil, false, allocator)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_select_compare: type does not support ordering")
	}
	return Selection{ allocator = allocator }
}

compute_select_compare_i64 :: proc(arr: ^Array, op: Compare_Op, scalar: i64, allocator := context.allocator) -> Selection {
	switch _ in arr.type {
	case Int8_Type:    return _select_compare_int_i64(arr, op, scalar, i8,  allocator)
	case Int16_Type:   return _select_compare_int_i64(arr, op, scalar, i16, allocator)
	case Int32_Type:   return _select_compare_int_i64(arr, op, scalar, i32, allocator)
	case Int64_Type:   return _select_compare_int_i64(arr, op, scalar, i64, allocator)
	case UInt8_Type:   return _select_compare_int_i64(arr, op, scalar, u8,  allocator)
	case UInt16_Type:  return _select_compare_int_i64(arr, op, scalar, u16, allocator)
	case UInt32_Type:  return _select_compare_int_i64(arr, op, scalar, u32, allocator)
	case UInt64_Type:  return _select_compare_int_i64(arr, op, scalar, u64, allocator)
	case Float32_Type: return _select_compare_float_i64(arr, op, scalar, f32, allocator)
	case Float64_Type: return _select_compare_float_i64(arr, op, scalar, f64, allocator)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_select_compare_i64: type does not support ordering")
	}
	return Selection{ allocator = allocator }
}

// ── refine a selection by another predicate (evaluated at survivors only) ───

selection_refine_compare :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: f64, allocator := context.allocator) -> Selection {
	out := _alloc_i32_slice_uninit(sel.length, allocator)
	k   := _refine_compare_f64_into(sel, arr, op, scalar, out)
	return Selection{ indices = out[:k], length = k, capacity = len(out), allocator = allocator }
}

selection_refine_compare_i64 :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: i64, allocator := context.allocator) -> Selection {
	out := _alloc_i32_slice_uninit(sel.length, allocator)
	k   := _refine_compare_i64_into(sel, arr, op, scalar, out)
	return Selection{ indices = out[:k], length = k, capacity = len(out), allocator = allocator }
}

// Refine `sel` in place without allocating a second index buffer (0 heap allocs).
selection_refine_compare_inplace :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: f64) {
	if sel.capacity == 0 { sel.capacity = len(sel.indices) }
	k := _refine_compare_f64_into(sel, arr, op, scalar, sel.indices)
	sel.indices = sel.indices[:k]
	sel.length  = k
}

// Refine `sel` in place against an `i64` scalar without allocating a second index buffer.
selection_refine_compare_i64_inplace :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: i64) {
	if sel.capacity == 0 { sel.capacity = len(sel.indices) }
	k := _refine_compare_i64_into(sel, arr, op, scalar, sel.indices)
	sel.indices = sel.indices[:k]
	sel.length  = k
}

@(private="file")
_refine_compare_f64_into :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: f64, out: []i32) -> int {
	switch _ in arr.type {
	case Int8_Type:    return _refine_compare_int_f64_into(sel, arr, op, scalar, i8,  out)
	case Int16_Type:   return _refine_compare_int_f64_into(sel, arr, op, scalar, i16, out)
	case Int32_Type:   return _refine_compare_int_f64_into(sel, arr, op, scalar, i32, out)
	case Int64_Type:   return _refine_compare_int_f64_into(sel, arr, op, scalar, i64, out)
	case UInt8_Type:   return _refine_compare_int_f64_into(sel, arr, op, scalar, u8,  out)
	case UInt16_Type:  return _refine_compare_int_f64_into(sel, arr, op, scalar, u16, out)
	case UInt32_Type:  return _refine_compare_int_f64_into(sel, arr, op, scalar, u32, out)
	case UInt64_Type:  return _refine_compare_int_f64_into(sel, arr, op, scalar, u64, out)
	case Float32_Type: return _refine_compare_dispatch_into(sel, arr, op, scalar, f32, out)
	case Float64_Type: return _refine_compare_dispatch_into(sel, arr, op, scalar, f64, out)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("selection_refine_compare: type does not support ordering")
	}
	return 0
}

@(private="file")
_refine_compare_i64_into :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: i64, out: []i32) -> int {
	switch _ in arr.type {
	case Int8_Type:    return _refine_compare_int_i64_into(sel, arr, op, scalar, i8,  out)
	case Int16_Type:   return _refine_compare_int_i64_into(sel, arr, op, scalar, i16, out)
	case Int32_Type:   return _refine_compare_int_i64_into(sel, arr, op, scalar, i32, out)
	case Int64_Type:   return _refine_compare_int_i64_into(sel, arr, op, scalar, i64, out)
	case UInt8_Type:   return _refine_compare_int_i64_into(sel, arr, op, scalar, u8,  out)
	case UInt16_Type:  return _refine_compare_int_i64_into(sel, arr, op, scalar, u16, out)
	case UInt32_Type:  return _refine_compare_int_i64_into(sel, arr, op, scalar, u32, out)
	case UInt64_Type:  return _refine_compare_int_i64_into(sel, arr, op, scalar, u64, out)
	case Float32_Type: return _refine_compare_float_i64_into(sel, arr, op, scalar, f32, out)
	case Float64_Type: return _refine_compare_float_i64_into(sel, arr, op, scalar, f64, out)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("selection_refine_compare_i64: type does not support ordering")
	}
	return 0
}

@(private="file")
_refine_const_into :: proc(sel: ^Selection, arr: ^Array, mode: _Const_Cmp, out: []i32) -> int {
	if mode == .All_False { return 0 }
	has_nulls := arr.buffers[0].data != nil
	if !has_nulls {
		if raw_data(out) != raw_data(sel.indices) && sel.length > 0 {
			copy(out[:sel.length], sel.indices[:sel.length])
		}
		return sel.length
	}
	k := 0
	for j in 0..<sel.length {
		i := int(sel.indices[j])
		if array_is_valid(arr, i) {
			out[k] = sel.indices[j]
			k += 1
		}
	}
	return k
}

@(private="file")
_refine_compare_mono_into :: proc(sel: ^Selection, arr: ^Array, thresh: $Cmp, $Val: typeid, $OP: Compare_Op, out: []i32) -> int {
	n := sel.length
	if n == 0 { return 0 }
	d := (cast([^]Val)arr.buffers[1].data)[arr.offset:]
	out_ptr := raw_data(out)
	in_ptr  := raw_data(sel.indices)
	k := 0
	if arr.buffers[0].data == nil {
		// 4-way unrolled branchless selection: reads i0..i3 before stores, and
		// k <= j always holds so in-place (out_ptr == in_ptr) is alias-safe.
		j := 0
		for ; j + 4 <= n; j += 4 {
			i0 := in_ptr[j]
			i1 := in_ptr[j + 1]
			i2 := in_ptr[j + 2]
			i3 := in_ptr[j + 3]
			v0 := Cmp(d[int(i0)])
			v1 := Cmp(d[int(i1)])
			v2 := Cmp(d[int(i2)])
			v3 := Cmp(d[int(i3)])
			m0 := int(_apply_native(v0, thresh, OP))
			m1 := int(_apply_native(v1, thresh, OP))
			m2 := int(_apply_native(v2, thresh, OP))
			m3 := int(_apply_native(v3, thresh, OP))
			out_ptr[k] = i0; k += m0
			out_ptr[k] = i1; k += m1
			out_ptr[k] = i2; k += m2
			out_ptr[k] = i3; k += m3
		}
		for ; j < n; j += 1 {
			idx := in_ptr[j]
			m := int(_apply_native(Cmp(d[int(idx)]), thresh, OP))
			out_ptr[k] = idx
			k += m
		}
		return k
	}
	for j in 0..<n {
		idx := in_ptr[j]
		if !array_is_valid(arr, int(idx)) { continue }
		if _apply_native(Cmp(d[int(idx)]), thresh, OP) {
			out_ptr[k] = idx
			k += 1
		}
	}
	return k
}

@(private="file")
_refine_compare_dispatch_into :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, thresh: $Cmp, $Val: typeid, out: []i32) -> int {
	switch op {
	case .Gt: return _refine_compare_mono_into(sel, arr, thresh, Val, .Gt, out)
	case .Ge: return _refine_compare_mono_into(sel, arr, thresh, Val, .Ge, out)
	case .Lt: return _refine_compare_mono_into(sel, arr, thresh, Val, .Lt, out)
	case .Le: return _refine_compare_mono_into(sel, arr, thresh, Val, .Le, out)
	case .Eq: return _refine_compare_mono_into(sel, arr, thresh, Val, .Eq, out)
	case .Ne: return _refine_compare_mono_into(sel, arr, thresh, Val, .Ne, out)
	}
	return 0
}

@(private="file")
_refine_compare_int_f64_into :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: f64, $T: typeid, out: []i32) -> int {
	mode, cmp_op, thresh := _int_vs_f64_plan(scalar, op, T)
	if mode != .Dynamic { return _refine_const_into(sel, arr, mode, out) }
	return _refine_compare_dispatch_into(sel, arr, cmp_op, thresh, T, out)
}

@(private="file")
_refine_compare_int_i64_into :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: i64, $T: typeid, out: []i32) -> int {
	mode, thresh := _int_vs_i64_plan(scalar, op, T)
	if mode != .Dynamic { return _refine_const_into(sel, arr, mode, out) }
	return _refine_compare_dispatch_into(sel, arr, op, thresh, T, out)
}

@(private="file")
_refine_compare_float_i64_into :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: i64, $T: typeid, out: []i32) -> int {
	data := cast([^]T)arr.buffers[1].data
	off := arr.offset
	has_nulls := arr.buffers[0].data != nil
	k := 0
	for j in 0..<sel.length {
		i := int(sel.indices[j])
		if has_nulls && !array_is_valid(arr, i) { continue }
		if _cmp_f64_vs_i64(f64(data[off + i]), op, scalar) {
			out[k] = sel.indices[j]
			k += 1
		}
	}
	return k
}

// ── L1d/L2-resident u16 morsel kernels & 2-predicate filter + sum ─────────────

MORSEL_MAX_ROWS :: 16_384

@(private="file")
_SEL2_MAX_MORSEL :: MORSEL_MAX_ROWS

@(private="file", enable_target_feature = _SIMD_TARGET_FEATURE)
_morsel_select_f64_u16_mono :: proc "contextless" (
	data:    [^]f64,
	row_len: int,
	scalar:  f64,
	out_u16: []u16,
	$OP:     Compare_Op,
) -> int {
	V :: #simd[4]f64
	sv      := V(scalar)
	vp      := cast([^]V)data
	out_ptr := raw_data(out_u16)
	out_len := len(out_u16)
	k       := 0
	i       := 0
	for ; i + 8 <= row_len; i += 8 {
		vi := i >> 2
		v0 := intrinsics.unaligned_load(&vp[vi])
		v1 := intrinsics.unaligned_load(&vp[vi + 1])
		m0 := _simd_cmp_bits(v0, sv, OP, u8)
		m1 := _simd_cmp_bits(v1, sv, OP, u8)
		b  := m0 | (m1 << 4)
		if b != 0 {
			cnt       := int(intrinsics.count_ones(b))
			positions := _BYTE_INDICES_LUT[b]
			if k + 8 <= out_len {
				U :: #simd[8]u16
				base := U(u16(i))
				offs := U{
					u16(positions[0]), u16(positions[1]), u16(positions[2]), u16(positions[3]),
					u16(positions[4]), u16(positions[5]), u16(positions[6]), u16(positions[7]),
				}
				intrinsics.unaligned_store(cast(^U)&out_ptr[k], base + offs)
			} else {
				for j in 0..<cnt {
					out_ptr[k + j] = u16(i + int(positions[j]))
				}
			}
			k += cnt
		}
	}
	for ; i < row_len; i += 1 {
		if _apply_native(data[i], scalar, OP) {
			out_ptr[k] = u16(i)
			k += 1
		}
	}
	return k
}

@(private="file")
_compare_bounds_fail :: proc "contextless" (msg: string) -> ! {
	context = runtime.default_context()
	panic(msg)
}

// Compact `u16` morsel Predicate 1: evaluates `arr[row_start : row_start + row_len]`
// against `scalar` and writes surviving local offsets `0 ..< row_len` to `out_u16`.
morsel_select_compare_f64_u16 :: proc "contextless" (
	arr:       ^Array,
	op:        Compare_Op,
	scalar:    f64,
	row_start: int,
	row_len:   int,
	out_u16:   []u16,
) -> int {
	when ODIN_DEBUG {
		if row_len < 0 || row_len > MORSEL_MAX_ROWS || len(out_u16) < row_len {
			_compare_bounds_fail("morsel_select_compare_f64_u16: row_len out of bounds")
		}
	}
	rlen := min(row_len, min(len(out_u16), MORSEL_MAX_ROWS))
	if rlen <= 0 { return 0 }
	data := (cast([^]f64)arr.buffers[1].data)[arr.offset + row_start:]
	switch op {
	case .Gt: return _morsel_select_f64_u16_mono(data, rlen, scalar, out_u16, .Gt)
	case .Ge: return _morsel_select_f64_u16_mono(data, rlen, scalar, out_u16, .Ge)
	case .Lt: return _morsel_select_f64_u16_mono(data, rlen, scalar, out_u16, .Lt)
	case .Le: return _morsel_select_f64_u16_mono(data, rlen, scalar, out_u16, .Le)
	case .Eq: return _morsel_select_f64_u16_mono(data, rlen, scalar, out_u16, .Eq)
	case .Ne: return _morsel_select_f64_u16_mono(data, rlen, scalar, out_u16, .Ne)
	}
	return 0
}

@(private="file")
_refine_u16_mono :: #force_inline proc "contextless" (
	data:   [^]f64,
	ptr:    [^]u16,
	n:      int,
	thresh: f64,
	$OP:    Compare_Op,
) -> int {
	k := 0
	j := 0
	for ; j + 4 <= n; j += 4 {
		i0 := ptr[j]
		i1 := ptr[j + 1]
		i2 := ptr[j + 2]
		i3 := ptr[j + 3]
		m0 := int(_apply_native(data[int(i0)], thresh, OP))
		m1 := int(_apply_native(data[int(i1)], thresh, OP))
		m2 := int(_apply_native(data[int(i2)], thresh, OP))
		m3 := int(_apply_native(data[int(i3)], thresh, OP))
		ptr[k] = i0; k += m0
		ptr[k] = i1; k += m1
		ptr[k] = i2; k += m2
		ptr[k] = i3; k += m3
	}
	for ; j < n; j += 1 {
		idx := ptr[j]
		m   := int(_apply_native(data[int(idx)], thresh, OP))
		ptr[k] = idx
		k += m
	}
	return k
}

// Compact `u16` morsel Predicate 2: refines `indices_u16[:count]` in place on `arr[row_start:]`.
morsel_refine_compare_f64_u16 :: proc "contextless" (
	arr:         ^Array,
	op:          Compare_Op,
	scalar:      f64,
	row_start:   int,
	indices_u16: []u16,
	count:       int,
) -> int {
	if count <= 0 { return 0 }
	data := (cast([^]f64)arr.buffers[1].data)[arr.offset + row_start:]
	ptr  := raw_data(indices_u16)
	switch op {
	case .Gt: return _refine_u16_mono(data, ptr, count, scalar, .Gt)
	case .Ge: return _refine_u16_mono(data, ptr, count, scalar, .Ge)
	case .Lt: return _refine_u16_mono(data, ptr, count, scalar, .Lt)
	case .Le: return _refine_u16_mono(data, ptr, count, scalar, .Le)
	case .Eq: return _refine_u16_mono(data, ptr, count, scalar, .Eq)
	case .Ne: return _refine_u16_mono(data, ptr, count, scalar, .Ne)
	}
	return 0
}

// Sum selected `f64` elements indexed by compact `u16` local morsel offsets.
morsel_sum_f64_u16 :: proc "contextless" (
	arr:         ^Array,
	row_start:   int,
	indices_u16: []u16,
	count:       int,
) -> f64 {
	if count <= 0 { return 0 }
	data := (cast([^]f64)arr.buffers[1].data)[arr.offset + row_start:]
	ptr  := raw_data(indices_u16)
	s0, s1, s2, s3: f64
	j := 0
	for ; j + 4 <= count; j += 4 {
		s0 += data[int(ptr[j])]
		s1 += data[int(ptr[j + 1])]
		s2 += data[int(ptr[j + 2])]
		s3 += data[int(ptr[j + 3])]
	}
	for ; j < count; j += 1 {
		s0 += data[int(ptr[j])]
	}
	return (s0 + s1) + (s2 + s3)
}

// Sum, min, and max of selected `f64` elements indexed by compact `u16` local morsel offsets.
morsel_agg_f64_u16 :: proc "contextless" (
	arr:         ^Array,
	row_start:   int,
	indices_u16: []u16,
	count:       int,
) -> (sum: f64, min_val: f64, max_val: f64) {
	if count <= 0 { return 0, 0, 0 }
	data    := (cast([^]f64)arr.buffers[1].data)[arr.offset + row_start:]
	ptr     := raw_data(indices_u16)
	v_first := data[int(ptr[0])]
	lo0, lo1, lo2, lo3 := v_first, v_first, v_first, v_first
	hi0, hi1, hi2, hi3 := v_first, v_first, v_first, v_first
	s0, s1, s2, s3: f64
	j := 0
	for ; j + 4 <= count; j += 4 {
		v0 := data[int(ptr[j])]
		v1 := data[int(ptr[j + 1])]
		v2 := data[int(ptr[j + 2])]
		v3 := data[int(ptr[j + 3])]
		s0 += v0
		s1 += v1
		s2 += v2
		s3 += v3
		if v0 < lo0 { lo0 = v0 }
		if v1 < lo1 { lo1 = v1 }
		if v2 < lo2 { lo2 = v2 }
		if v3 < lo3 { lo3 = v3 }
		if v0 > hi0 { hi0 = v0 }
		if v1 > hi1 { hi1 = v1 }
		if v2 > hi2 { hi2 = v2 }
		if v3 > hi3 { hi3 = v3 }
	}
	for ; j < count; j += 1 {
		v := data[int(ptr[j])]
		s0 += v
		if v < lo0 { lo0 = v }
		if v > hi0 { hi0 = v }
	}
	if lo1 < lo0 { lo0 = lo1 }
	if lo3 < lo2 { lo2 = lo3 }
	if lo2 < lo0 { lo0 = lo2 }
	if hi1 > hi0 { hi0 = hi1 }
	if hi3 > hi2 { hi2 = hi3 }
	if hi2 > hi0 { hi0 = hi2 }
	return (s0 + s1) + (s2 + s3), lo0, hi0
}

@(private="file")
_sel2pred_range_f64_fast :: proc(
	col_a: ^Array,
	op1:   Compare_Op,
	s1:    f64,
	col_b: ^Array,
	op2:   Compare_Op,
	s2:    f64,
	from:  int,
	to:    int,
	step:  int,
) -> (sum: f64, valid_count: int) {
	scratch_u16: [_SEL2_MAX_MORSEL]u16 = ---
	chunk_step := clamp(step, 1, _SEL2_MAX_MORSEL)
	for pos := from; pos < to; pos += chunk_step {
		rlen := min(chunk_step, to - pos)
		k1   := morsel_select_compare_f64_u16(col_a, op1, s1, pos, rlen, scratch_u16[:])
		if k1 > 0 {
			k2 := morsel_refine_compare_f64_u16(col_b, op2, s2, pos, scratch_u16[:], k1)
			if k2 > 0 {
				sum         += morsel_sum_f64_u16(col_a, pos, scratch_u16[:], k2)
				valid_count += k2
			}
		}
	}
	return
}

@(private="file")
_sel2pred_range_fallback :: proc(
	col_a: ^Array,
	op1:   Compare_Op,
	s1:    f64,
	col_b: ^Array,
	op2:   Compare_Op,
	s2:    f64,
	from:  int,
	to:    int,
	step:  int,
) -> (sum: f64, valid_count: int) {
	workspace: [_SEL2_MAX_MORSEL]i32 = ---
	chunk_step := clamp(step, 1, _SEL2_MAX_MORSEL)
	for pos := from; pos < to; pos += chunk_step {
		end     := min(pos + chunk_step, to)
		a_slice := array_slice(col_a^, pos, end)
		b_slice := array_slice(col_b^, pos, end)
		sel     := compute_select_compare_into(&a_slice, op1, s1, workspace[:end - pos])
		selection_refine_compare_inplace(&sel, &b_slice, op2, s2)
		if sel.length > 0 {
			msum, mvalid := compute_sum_selection(&a_slice, &sel)
			sum         += msum
			valid_count += mvalid
		}
	}
	return
}

@(private="file")
_sel2pred_range :: proc(
	col_a: ^Array,
	op1:   Compare_Op,
	s1:    f64,
	col_b: ^Array,
	op2:   Compare_Op,
	s2:    f64,
	from:  int,
	to:    int,
	step:  int,
) -> (sum: f64, valid_count: int) {
	_, is_a_f64 := col_a.type.(Float64_Type)
	_, is_b_f64 := col_b.type.(Float64_Type)
	if is_a_f64 && is_b_f64 && col_a.buffers[0].data == nil && col_b.buffers[0].data == nil {
		return _sel2pred_range_f64_fast(col_a, op1, s1, col_b, op2, s2, from, to, step)
	}
	return _sel2pred_range_fallback(col_a, op1, s1, col_b, op2, s2, from, to, step)
}

// Evaluate `sum(col_a) WHERE col_a <op1> s1 AND col_b <op2> s2` over L1d/L2-resident
// morsels using a 32 KB `u16` L1d workspace on null-free `f64` columns (falling back
// to `i32` `Selection` for nullable/other types) with 0 heap allocations.
// Note: `allocator` is retained for API compatibility and is unused.
compute_sel_2pred_sum :: proc(
	col_a:     ^Array,
	op1:       Compare_Op,
	s1:        f64,
	col_b:     ^Array,
	op2:       Compare_Op,
	s2:        f64,
	allocator := context.allocator,
) -> (sum: f64, valid_count: int) {
	assert(col_a != nil && col_b != nil && col_a.length == col_b.length, "compute_sel_2pred_sum: column lengths must match")
	n := col_a.length
	if n <= 0 { return 0, 0 }

	hw          := hardware_config_get()
	bpr         := max(type_byte_width(col_a.type) + type_byte_width(col_b.type), 8)
	morsel_rows := clamp((hw.morsel_target_bytes / bpr + 63) &~ 63, 4096, _SEL2_MAX_MORSEL)
	_ = allocator
	return _sel2pred_range(col_a, op1, s1, col_b, op2, s2, 0, n, morsel_rows)
}

@(private="file")
_Sel2Pred_Task :: struct {
	col_a:       ^Array,
	col_b:       ^Array,
	op1:         Compare_Op,
	s1:          f64,
	op2:         Compare_Op,
	s2:          f64,
	from:        int,
	to:          int,
	morsel_step: int,
	sum:         f64,
	valid:       int,
}

@(private="file")
_sel2pred_job :: proc(ctx: rawptr, idx: int) {
	t := &(cast([^]_Sel2Pred_Task)ctx)[idx]
	t.sum, t.valid = _sel2pred_range(
		t.col_a, t.op1, t.s1,
		t.col_b, t.op2, t.s2,
		t.from, t.to, t.morsel_step,
	)
}

// Multi-threaded L1d/L2-resident 2-predicate selection + sum over physical cores
// using per-worker stack morsel buffers (0 heap allocations).
compute_sel_2pred_sum_parallel :: proc(
	col_a:       ^Array,
	op1:         Compare_Op,
	s1:          f64,
	col_b:       ^Array,
	op2:         Compare_Op,
	s2:          f64,
	num_threads := 0,
) -> (sum: f64, valid_count: int) {
	assert(col_a != nil && col_b != nil && col_a.length == col_b.length, "compute_sel_2pred_sum_parallel: column lengths must match")
	n := col_a.length
	if n <= 0 { return 0, 0 }

	hw          := hardware_config_get()
	bpr         := max(type_byte_width(col_a.type) + type_byte_width(col_b.type), 8)
	morsel_step := clamp((hw.morsel_target_bytes / bpr + 63) &~ 63, 4096, _SEL2_MAX_MORSEL)
	nt          := _resolve_threads(num_threads, n, bpr)
	if nt <= 1 {
		return _sel2pred_range(col_a, op1, s1, col_b, op2, s2, 0, n, morsel_step)
	}

	chunk, n_morsels := _compute_morsels(n, nt, bpr)
	tasks_buf: [MAX_MORSELS]_Sel2Pred_Task
	tasks := tasks_buf[:n_morsels]
	for i in 0..<n_morsels {
		from := i * chunk
		to   := min(from + chunk, n)
		tasks[i] = _Sel2Pred_Task{
			col_a       = col_a,
			col_b       = col_b,
			op1         = op1,
			s1          = s1,
			op2         = op2,
			s2          = s2,
			from        = from,
			to          = to,
			morsel_step = morsel_step,
		}
	}
	_pool_run(nt, _sel2pred_job, raw_data(tasks), n_morsels)
	for i in 0..<n_morsels {
		sum         += tasks[i].sum
		valid_count += tasks[i].valid
	}
	return
}
