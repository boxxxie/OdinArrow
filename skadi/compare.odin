package skadi

import "base:intrinsics"
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

// Compare 8 contiguous elements against the scalar → packed mask byte (branchless).
@(private="file")
_cmp8 :: #force_inline proc "contextless" (data: [^]$T, base: int, s: T, $OP: Compare_Op) -> u8 {
	b := u8(0)
	#unroll for k in 0..<8 {
		if _apply_native(data[base + k], s, OP) {
			b |= 1 << uint(k)
		}
	}
	return b
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
	buf := buffer_make(bitmap_byte_count(n), allocator) or_return
	if arr.buffers[0].data == nil {
		switch op {
		case .Gt: _compare_mono(data, off, n, thresh, buf.data, .Gt)
		case .Ge: _compare_mono(data, off, n, thresh, buf.data, .Ge)
		case .Lt: _compare_mono(data, off, n, thresh, buf.data, .Lt)
		case .Le: _compare_mono(data, off, n, thresh, buf.data, .Le)
		case .Eq: _compare_mono(data, off, n, thresh, buf.data, .Eq)
		case .Ne: _compare_mono(data, off, n, thresh, buf.data, .Ne)
		}
	} else {
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
_compare_mono :: proc "contextless" (data: [^]$T, off, n: int, s: T, out: [^]u8, $OP: Compare_Op) {
	when T == f64 {
		V  :: #simd[8]f64
		sv := V(s)
		vp := cast([^]V)(data[off:])
		nv := n / 8
		for i in 0..<nv {
			v := intrinsics.unaligned_load(&vp[i])
			m: #simd[8]u64
			when      OP == .Gt { m = intrinsics.simd_lanes_gt(v, sv) }
			else when OP == .Ge { m = intrinsics.simd_lanes_ge(v, sv) }
			else when OP == .Lt { m = intrinsics.simd_lanes_lt(v, sv) }
			else when OP == .Le { m = intrinsics.simd_lanes_le(v, sv) }
			else when OP == .Eq { m = intrinsics.simd_lanes_eq(v, sv) }
			else                { m = intrinsics.simd_lanes_ne(v, sv) }
			out[i] = transmute(u8)intrinsics.simd_extract_msbs(m)
		}
		for i := nv * 8; i < n; i += 1 {
			if _apply_native(data[off + i], s, OP) { out[i >> 3] |= 1 << u8(i & 7) }
		}
	} else {
		n_full := (n / 8) * 8
		for i := 0; i < n_full; i += 8 { out[i >> 3] = _cmp8(data, off + i, s, OP) }
		for i := n_full; i < n; i += 1 {
			if _apply_native(data[off + i], s, OP) { out[i >> 3] |= 1 << u8(i & 7) }
		}
	}
}

// ── first predicate → selection ─────────────────────────────────────────────

compute_select_compare :: proc(arr: ^Array, op: Compare_Op, scalar: f64, allocator := context.allocator) -> Selection {
	mask, err := compute_compare(arr, op, scalar, allocator)
	if err != nil { return Selection{ allocator = allocator } }
	defer array_free(&mask, allocator)
	return compute_select(&mask, allocator)
}

compute_select_compare_i64 :: proc(arr: ^Array, op: Compare_Op, scalar: i64, allocator := context.allocator) -> Selection {
	mask, err := compute_compare_i64(arr, op, scalar, allocator)
	if err != nil { return Selection{ allocator = allocator } }
	defer array_free(&mask, allocator)
	return compute_select(&mask, allocator)
}

// ── refine a selection by another predicate (evaluated at survivors only) ───

selection_refine_compare :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: f64, allocator := context.allocator) -> Selection {
	switch _ in arr.type {
	case Int8_Type:    return _refine_compare_int_f64(sel, arr, op, scalar, i8,  allocator)
	case Int16_Type:   return _refine_compare_int_f64(sel, arr, op, scalar, i16, allocator)
	case Int32_Type:   return _refine_compare_int_f64(sel, arr, op, scalar, i32, allocator)
	case Int64_Type:   return _refine_compare_int_f64(sel, arr, op, scalar, i64, allocator)
	case UInt8_Type:   return _refine_compare_int_f64(sel, arr, op, scalar, u8,  allocator)
	case UInt16_Type:  return _refine_compare_int_f64(sel, arr, op, scalar, u16, allocator)
	case UInt32_Type:  return _refine_compare_int_f64(sel, arr, op, scalar, u32, allocator)
	case UInt64_Type:  return _refine_compare_int_f64(sel, arr, op, scalar, u64, allocator)
	case Float32_Type: return _refine_compare_float_f64(sel, arr, op, scalar, f32, allocator)
	case Float64_Type: return _refine_compare_float_f64(sel, arr, op, scalar, f64, allocator)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("selection_refine_compare: type does not support ordering")
	}
	return {}
}

selection_refine_compare_i64 :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: i64, allocator := context.allocator) -> Selection {
	switch _ in arr.type {
	case Int8_Type:    return _refine_compare_int_i64(sel, arr, op, scalar, i8,  allocator)
	case Int16_Type:   return _refine_compare_int_i64(sel, arr, op, scalar, i16, allocator)
	case Int32_Type:   return _refine_compare_int_i64(sel, arr, op, scalar, i32, allocator)
	case Int64_Type:   return _refine_compare_int_i64(sel, arr, op, scalar, i64, allocator)
	case UInt8_Type:   return _refine_compare_int_i64(sel, arr, op, scalar, u8,  allocator)
	case UInt16_Type:  return _refine_compare_int_i64(sel, arr, op, scalar, u16, allocator)
	case UInt32_Type:  return _refine_compare_int_i64(sel, arr, op, scalar, u32, allocator)
	case UInt64_Type:  return _refine_compare_int_i64(sel, arr, op, scalar, u64, allocator)
	case Float32_Type: return _refine_compare_float_i64(sel, arr, op, scalar, f32, allocator)
	case Float64_Type: return _refine_compare_float_i64(sel, arr, op, scalar, f64, allocator)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("selection_refine_compare_i64: type does not support ordering")
	}
	return {}
}

@(private="file")
_refine_const :: proc(sel: ^Selection, arr: ^Array, mode: _Const_Cmp, allocator: mem.Allocator) -> Selection {
	if mode == .All_False {
		return Selection{ indices = make([]i32, 0, allocator), length = 0, allocator = allocator }
	}
	has_nulls := arr.buffers[0].data != nil
	out := make([]i32, sel.length, allocator)
	if !has_nulls {
		copy(out, sel.indices[:sel.length])
		return Selection{ indices = out, length = sel.length, allocator = allocator }
	}
	k := 0
	for j in 0..<sel.length {
		i := int(sel.indices[j])
		if array_is_valid(arr, i) {
			out[k] = sel.indices[j]
			k += 1
		}
	}
	return Selection{ indices = out[:k], length = k, allocator = allocator }
}

@(private="file")
_refine_compare_native :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, thresh: $T, allocator: mem.Allocator) -> Selection {
	data := cast([^]T)arr.buffers[1].data
	off := arr.offset
	has_nulls := arr.buffers[0].data != nil
	out := make([]i32, sel.length, allocator)
	k := 0
	for j in 0..<sel.length {
		i := int(sel.indices[j])
		if has_nulls && !array_is_valid(arr, i) { continue }
		if _apply_native_rt(data[off + i], op, thresh) {
			out[k] = sel.indices[j]
			k += 1
		}
	}
	return Selection{ indices = out[:k], length = k, allocator = allocator }
}

@(private="file")
_refine_compare_int_f64 :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: f64, $T: typeid, allocator: mem.Allocator) -> Selection {
	mode, cmp_op, thresh := _int_vs_f64_plan(scalar, op, T)
	if mode != .Dynamic { return _refine_const(sel, arr, mode, allocator) }
	return _refine_compare_native(sel, arr, cmp_op, thresh, allocator)
}

@(private="file")
_refine_compare_int_i64 :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: i64, $T: typeid, allocator: mem.Allocator) -> Selection {
	mode, thresh := _int_vs_i64_plan(scalar, op, T)
	if mode != .Dynamic { return _refine_const(sel, arr, mode, allocator) }
	return _refine_compare_native(sel, arr, op, thresh, allocator)
}

@(private="file")
_refine_compare_float_f64 :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: f64, $T: typeid, allocator: mem.Allocator) -> Selection {
	data := cast([^]T)arr.buffers[1].data
	off := arr.offset
	has_nulls := arr.buffers[0].data != nil
	out := make([]i32, sel.length, allocator)
	k := 0
	for j in 0..<sel.length {
		i := int(sel.indices[j])
		if has_nulls && !array_is_valid(arr, i) { continue }
		if _apply_native_rt(f64(data[off + i]), op, scalar) {
			out[k] = sel.indices[j]
			k += 1
		}
	}
	return Selection{ indices = out[:k], length = k, allocator = allocator }
}

@(private="file")
_refine_compare_float_i64 :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: i64, $T: typeid, allocator: mem.Allocator) -> Selection {
	data := cast([^]T)arr.buffers[1].data
	off := arr.offset
	has_nulls := arr.buffers[0].data != nil
	out := make([]i32, sel.length, allocator)
	k := 0
	for j in 0..<sel.length {
		i := int(sel.indices[j])
		if has_nulls && !array_is_valid(arr, i) { continue }
		if _cmp_f64_vs_i64(f64(data[off + i]), op, scalar) {
			out[k] = sel.indices[j]
			k += 1
		}
	}
	return Selection{ indices = out[:k], length = k, allocator = allocator }
}
