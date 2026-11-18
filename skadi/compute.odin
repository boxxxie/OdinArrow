package skadi

import "base:intrinsics"
import "base:runtime"
import "core:mem"

// ── sum ───────────────────────────────────────────────────────────────────────

// Sum of all non-null numeric elements, returned as f64.
// valid_count is the number of non-null elements that contributed.
compute_sum :: proc(arr: ^Array) -> (sum: f64, valid_count: int) {
	switch _ in arr.type {
	case Int8_Type:    return _sum_typed(arr, i8)
	case Int16_Type:   return _sum_typed(arr, i16)
	case Int32_Type:   return _sum_typed(arr, i32)
	case Int64_Type:   return _sum_typed(arr, i64)
	case UInt8_Type:   return _sum_typed(arr, u8)
	case UInt16_Type:  return _sum_typed(arr, u16)
	case UInt32_Type:  return _sum_typed(arr, u32)
	case UInt64_Type:  return _sum_typed(arr, u64)
	case Float32_Type: return _sum_typed(arr, f32)
	case Float64_Type: return _sum_typed(arr, f64)
	case Null_Type, Bool_Type,
	     Decimal64_Type, Decimal128_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_sum: type does not support numeric summation")
	}
	return
}

// ── null-aware run reducers ─────────────────────────────────────────────────────
//
// Reduce a contiguous, all-valid run of `n` elements. These let the null-aware
// aggregation paths process bitmap bytes that are 0xFF (8 valid in a row) with
// the SIMD kernels instead of testing one bit at a time.

_sum_run :: #force_inline proc(data: [^]$T, n: int) -> f64 {
	return _sum_typed_simd(data, n)
}

_min_run :: #force_inline proc(data: [^]$T, n: int) -> T {
	return _min_typed_simd(data, n)
}

_max_run :: #force_inline proc(data: [^]$T, n: int) -> T {
	return _max_typed_simd(data, n)
}

_min_max_run :: #force_inline proc(data: [^]$T, n: int) -> (lo: T, hi: T) {
	return _min_max_typed_simd(data, n)
}

_sum_typed :: #force_inline proc(arr: ^Array, $T: typeid) -> (sum: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	n    := arr.length
	if arr.buffers[0].data == nil {
		if n > 0 {
			sum = _sum_typed_simd(off == 0 ? data : data[off:], n)
		}
		valid_count = n
	} else {
		vbits := arr.buffers[0].data
		if off & 7 != 0 {
			// Unaligned slice offset: bitmap bytes don't line up with element
			// groups, so fall back to per-element.
			for i in 0..<n {
				if array_is_valid(arr, i) { sum += f64(data[off + i]); valid_count += 1 }
			}
		} else {
			// Coalesce all-valid (0xFF) bytes into runs reduced by the SIMD
			// kernel; skip all-null (0) bytes; bit-test only mixed bytes.
			bstart     := off >> 3
			full_bytes := n >> 3
			run_lo     := -1
			for byi in 0..<full_bytes {
				b_val := vbits[bstart + byi]
				if b_val == 0xFF {
					if run_lo < 0 { run_lo = byi << 3 }
					valid_count += 8
					continue
				}
				if run_lo >= 0 {
					sum += _sum_run(data[off + run_lo:], (byi << 3) - run_lo)
					run_lo = -1
				}
				if b_val != 0 {
					eb := off + (byi << 3)
					valid_count += int(intrinsics.count_ones(b_val))
					s0 := ((b_val & 0x01) != 0 ? f64(data[eb + 0]) : 0.0) + ((b_val & 0x02) != 0 ? f64(data[eb + 1]) : 0.0)
					s1 := ((b_val & 0x04) != 0 ? f64(data[eb + 2]) : 0.0) + ((b_val & 0x08) != 0 ? f64(data[eb + 3]) : 0.0)
					s2 := ((b_val & 0x10) != 0 ? f64(data[eb + 4]) : 0.0) + ((b_val & 0x20) != 0 ? f64(data[eb + 5]) : 0.0)
					s3 := ((b_val & 0x40) != 0 ? f64(data[eb + 6]) : 0.0) + ((b_val & 0x80) != 0 ? f64(data[eb + 7]) : 0.0)
					sum += (s0 + s1) + (s2 + s3)
				}
			}
			if run_lo >= 0 {
				sum += _sum_run(data[off + run_lo:], (full_bytes << 3) - run_lo)
			}
			for i := full_bytes << 3; i < n; i += 1 {
				if bitmap_get(vbits, off + i) { sum += f64(data[off + i]); valid_count += 1 }
			}
		}
	}
	return
}

// ── min / max ─────────────────────────────────────────────────────────────────

// Minimum of all non-null elements. Returns (0, 0) when all elements are null.
compute_min :: proc(arr: ^Array) -> (min_val: f64, valid_count: int) {
	switch _ in arr.type {
	case Int8_Type:    return _min_typed(arr, i8)
	case Int16_Type:   return _min_typed(arr, i16)
	case Int32_Type:   return _min_typed(arr, i32)
	case Int64_Type:   return _min_typed(arr, i64)
	case UInt8_Type:   return _min_typed(arr, u8)
	case UInt16_Type:  return _min_typed(arr, u16)
	case UInt32_Type:  return _min_typed(arr, u32)
	case UInt64_Type:  return _min_typed(arr, u64)
	case Float32_Type: return _min_typed(arr, f32)
	case Float64_Type: return _min_typed(arr, f64)
	case Null_Type, Bool_Type,
	     Decimal64_Type, Decimal128_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_min: type does not support ordering")
	}
	return
}

// Maximum of all non-null elements.
compute_max :: proc(arr: ^Array) -> (max_val: f64, valid_count: int) {
	switch _ in arr.type {
	case Int8_Type:    return _max_typed(arr, i8)
	case Int16_Type:   return _max_typed(arr, i16)
	case Int32_Type:   return _max_typed(arr, i32)
	case Int64_Type:   return _max_typed(arr, i64)
	case UInt8_Type:   return _max_typed(arr, u8)
	case UInt16_Type:  return _max_typed(arr, u16)
	case UInt32_Type:  return _max_typed(arr, u32)
	case UInt64_Type:  return _max_typed(arr, u64)
	case Float32_Type: return _max_typed(arr, f32)
	case Float64_Type: return _max_typed(arr, f64)
	case Null_Type, Bool_Type,
	     Decimal64_Type, Decimal128_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_max: type does not support ordering")
	}
	return
}

// Comparisons run in the native element type T (not f64): converting per
// element blocks integer SIMD and costs ~7x on large arrays. The single
// f64 conversion happens once, on the final result.
_min_typed :: #force_inline proc(arr: ^Array, $T: typeid) -> (min_val: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	n    := arr.length
	if n == 0 { return }
	best: T
	if arr.buffers[0].data == nil {
		best = _min_typed_simd(off == 0 ? data : data[off:], n)
		valid_count = n
	} else {
		vbits := arr.buffers[0].data
		if off & 7 != 0 {
			for i in 0..<n {
				if array_is_valid(arr, i) {
					v := data[off + i]
					if valid_count == 0 || v < best { best = v }
					valid_count += 1
				}
			}
		} else {
			bstart     := off >> 3
			full_bytes := n >> 3
			seen       := false
			run_lo     := -1
			for byi in 0..<full_bytes {
				b_val := vbits[bstart + byi]
				if b_val == 0xFF {
					if run_lo < 0 { run_lo = byi << 3 }
					valid_count += 8
					continue
				}
				if run_lo >= 0 {
					r := _min_run(data[off + run_lo:], (byi << 3) - run_lo)
					best = seen ? min(best, r) : r; seen = true
					run_lo = -1
				}
				if b_val != 0 {
					eb := byi << 3
					for k in 0..<8 {
						if (b_val >> uint(k)) & 1 == 1 {
							v := data[off + eb + k]
							best = seen ? min(best, v) : v; seen = true
							valid_count += 1
						}
					}
				}
			}
			if run_lo >= 0 {
				r := _min_run(data[off + run_lo:], (full_bytes << 3) - run_lo)
				best = seen ? min(best, r) : r; seen = true
			}
			for i := full_bytes << 3; i < n; i += 1 {
				if bitmap_get(vbits, off + i) {
					v := data[off + i]
					best = seen ? min(best, v) : v; seen = true
					valid_count += 1
				}
			}
		}
	}
	if valid_count > 0 { min_val = f64(best) }
	return
}

_max_typed :: #force_inline proc(arr: ^Array, $T: typeid) -> (max_val: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	n    := arr.length
	if n == 0 { return }
	best: T
	if arr.buffers[0].data == nil {
		best = _max_typed_simd(off == 0 ? data : data[off:], n)
		valid_count = n
	} else {
		vbits := arr.buffers[0].data
		if off & 7 != 0 {
			for i in 0..<n {
				if array_is_valid(arr, i) {
					v := data[off + i]
					if valid_count == 0 || v > best { best = v }
					valid_count += 1
				}
			}
		} else {
			bstart     := off >> 3
			full_bytes := n >> 3
			seen       := false
			run_lo     := -1
			for byi in 0..<full_bytes {
				b_val := vbits[bstart + byi]
				if b_val == 0xFF {
					if run_lo < 0 { run_lo = byi << 3 }
					valid_count += 8
					continue
				}
				if run_lo >= 0 {
					r := _max_run(data[off + run_lo:], (byi << 3) - run_lo)
					best = seen ? max(best, r) : r; seen = true
					run_lo = -1
				}
				if b_val != 0 {
					eb := byi << 3
					for k in 0..<8 {
						if (b_val >> uint(k)) & 1 == 1 {
							v := data[off + eb + k]
							best = seen ? max(best, v) : v; seen = true
							valid_count += 1
						}
					}
				}
			}
			if run_lo >= 0 {
				r := _max_run(data[off + run_lo:], (full_bytes << 3) - run_lo)
				best = seen ? max(best, r) : r; seen = true
			}
			for i := full_bytes << 3; i < n; i += 1 {
				if bitmap_get(vbits, off + i) {
					v := data[off + i]
					best = seen ? max(best, v) : v; seen = true
					valid_count += 1
				}
			}
		}
	}
	if valid_count > 0 { max_val = f64(best) }
	return
}

// ── min_max (single pass) ─────────────────────────────────────────────────────

// Min and max in one pass — ~2× faster than calling compute_min + compute_max.
compute_min_max :: proc(arr: ^Array) -> (min_val: f64, max_val: f64, valid_count: int) {
	switch _ in arr.type {
	case Int8_Type:    return _min_max_typed(arr, i8)
	case Int16_Type:   return _min_max_typed(arr, i16)
	case Int32_Type:   return _min_max_typed(arr, i32)
	case Int64_Type:   return _min_max_typed(arr, i64)
	case UInt8_Type:   return _min_max_typed(arr, u8)
	case UInt16_Type:  return _min_max_typed(arr, u16)
	case UInt32_Type:  return _min_max_typed(arr, u32)
	case UInt64_Type:  return _min_max_typed(arr, u64)
	case Float32_Type: return _min_max_typed(arr, f32)
	case Float64_Type: return _min_max_typed(arr, f64)
	case Null_Type, Bool_Type,
	     Decimal64_Type, Decimal128_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_min_max: type does not support ordering")
	}
	return
}

_min_max_typed :: #force_inline proc(arr: ^Array, $T: typeid) -> (min_val: f64, max_val: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	n    := arr.length
	if n == 0 { return }
	lo, hi: T
	if arr.buffers[0].data == nil {
		lo, hi = _min_max_typed_simd(off == 0 ? data : data[off:], n)
		valid_count = n
	} else {
		vbits := arr.buffers[0].data
		if off & 7 != 0 {
			for i in 0..<n {
				if array_is_valid(arr, i) {
					v := data[off + i]
					if valid_count == 0 || v < lo { lo = v }
					if valid_count == 0 || v > hi { hi = v }
					valid_count += 1
				}
			}
		} else {
			bstart     := off >> 3
			full_bytes := n >> 3
			seen       := false
			run_lo     := -1
			for byi in 0..<full_bytes {
				b_val := vbits[bstart + byi]
				if b_val == 0xFF {
					if run_lo < 0 { run_lo = byi << 3 }
					valid_count += 8
					continue
				}
				if run_lo >= 0 {
					rl, rh := _min_max_run(data[off + run_lo:], (byi << 3) - run_lo)
					if seen { lo = min(lo, rl); hi = max(hi, rh) } else { lo = rl; hi = rh; seen = true }
					run_lo = -1
				}
				if b_val != 0 {
					eb := byi << 3
					for k in 0..<8 {
						if (b_val >> uint(k)) & 1 == 1 {
							v := data[off + eb + k]
							if seen { if v < lo { lo = v }; if v > hi { hi = v } } else { lo = v; hi = v; seen = true }
							valid_count += 1
						}
					}
				}
			}
			if run_lo >= 0 {
				rl, rh := _min_max_run(data[off + run_lo:], (full_bytes << 3) - run_lo)
				if seen { lo = min(lo, rl); hi = max(hi, rh) } else { lo = rl; hi = rh; seen = true }
			}
			for i := full_bytes << 3; i < n; i += 1 {
				if bitmap_get(vbits, off + i) {
					v := data[off + i]
					if seen { if v < lo { lo = v }; if v > hi { hi = v } } else { lo = v; hi = v; seen = true }
					valid_count += 1
				}
			}
		}
	}
	if valid_count > 0 { min_val = f64(lo); max_val = f64(hi) }
	return
}

// ── mean ──────────────────────────────────────────────────────────────────────

// Mean of all non-null numeric elements. Returns (0, 0) when all null.
compute_mean :: proc(arr: ^Array) -> (mean: f64, valid_count: int) {
	sum: f64
	sum, valid_count = compute_sum(arr)
	if valid_count > 0 {
		mean = sum / f64(valid_count)
	}
	return
}

// ── count ─────────────────────────────────────────────────────────────────────

// Count total elements and non-null (valid) elements.
compute_count :: proc(arr: ^Array) -> (total: int, valid: int) {
	total = arr.length
	nc    := array_null_count(arr)
	valid  = total - nc
	return
}

// ── filter ────────────────────────────────────────────────────────────────────

// Apply a Bool mask to arr, returning a new Array with only the passing rows.
// mask must be Bool_Type and have the same length as arr.
// Null mask entries are treated as false (element excluded).
compute_filter :: proc(arr, mask: ^Array, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	assert(arr.length == mask.length, "compute_filter: length mismatch")
	_, is_bool := mask.type.(Bool_Type)
	assert(is_bool, "compute_filter: mask must be Bool type")

	switch _ in arr.type {
	case Int8_Type:         return _filter_typed(arr, mask, i8,   allocator)
	case Int16_Type:        return _filter_typed(arr, mask, i16,  allocator)
	case Int32_Type:        return _filter_typed(arr, mask, i32,  allocator)
	case Int64_Type:        return _filter_typed(arr, mask, i64,  allocator)
	case UInt8_Type:        return _filter_typed(arr, mask, u8,   allocator)
	case UInt16_Type:       return _filter_typed(arr, mask, u16,  allocator)
	case UInt32_Type:       return _filter_typed(arr, mask, u32,  allocator)
	case UInt64_Type:       return _filter_typed(arr, mask, u64,  allocator)
	case Float32_Type:      return _filter_typed(arr, mask, f32,  allocator)
	case Float64_Type:      return _filter_typed(arr, mask, f64,  allocator)
	case Decimal64_Type:    return _filter_typed(arr, mask, i64,  allocator)
	case Decimal128_Type:   return _filter_typed(arr, mask, i128, allocator)
	case Bool_Type:         return _filter_bool(arr, mask, allocator)
	case String_Type:       return _filter_string(arr, mask, allocator)
	case Binary_Type:       return _filter_binary(arr, mask, allocator)
	case Large_String_Type: return _filter_large_string(arr, mask, allocator)
	case Large_Binary_Type: return _filter_large_binary(arr, mask, allocator)
	case Null_Type:
		panic("compute_filter: unsupported source type")
	}
	return
}

_mask_passes :: #force_inline proc "contextless" (mask: ^Array, i: int) -> bool {
	return array_is_valid(mask, i) && bitmap_get(mask.buffers[1].data, mask.offset + i)
}

_filter_typed :: proc(arr, mask: ^Array, $T: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n         := arr.length
	mask_bits := mask.buffers[1].data
	arr_off   := arr.offset
	mask_off  := mask.offset

	// No-null fast path: skip the builder entirely — allocate exact output size and
	// write values directly. Avoids per-element bitmap maintenance and dynamic-array overhead.
	if arr.buffers[0].data == nil && mask.buffers[0].data == nil {
		out_count := _filter_count_bits(mask_bits, mask_off, n)
		data_buf  := buffer_make_uninit(out_count * size_of(T), allocator) or_return
		src  := cast([^]T)arr.buffers[1].data
		dst  := cast([^]T)data_buf.data
		out_i := 0
		if mask_off == 0 && out_count * 4 < n {
			// Sparse: visit only the set bits via tzcnt and gather their values —
			// work ∝ survivors, no per-bit branch. (Same selectivity hybrid as
			// compute_select; dense uses the byte loop below.)
			words   := cast([^]u64)mask_bits
			n_words := n / 64
			for w in 0..<n_words {
				bits := words[w]
				base := w * 64
				for bits != 0 {
					t := intrinsics.count_trailing_zeros(bits)
					dst[out_i] = src[arr_off + base + int(t)]
					out_i += 1
					bits &= bits - 1
				}
			}
			for i := n_words * 64; i < n; i += 1 {
				if bitmap_get(mask_bits, i) { dst[out_i] = src[arr_off + i]; out_i += 1 }
			}
		} else if mask_off == 0 {
			// Dense: byte-at-a-time via _BYTE_INDICES_LUT, skipping empty bytes.
			n_full := (n / 8) * 8
			for i := 0; i < n_full; i += 8 {
				b_val := mask_bits[i >> 3]
				if b_val == 0 { continue }
				if b_val == 0xFF {
					mem.copy_non_overlapping(rawptr(&dst[out_i]), rawptr(&src[arr_off + i]), 8 * size_of(T))
					out_i += 8
					continue
				}
				cnt       := int(intrinsics.count_ones(b_val))
				positions := _BYTE_INDICES_LUT[b_val]
				base      := arr_off + i
				for k in 0..<cnt {
					dst[out_i + k] = src[base + int(positions[k])]
				}
				out_i += cnt
			}
			for i := n_full; i < n; i += 1 {
				if bitmap_get(mask_bits, i) {
					dst[out_i] = src[arr_off + i]
					out_i += 1
				}
			}
		} else {
			for i in 0..<n {
				if bitmap_get(mask_bits, mask_off + i) {
					dst[out_i] = src[arr_off + i]
					out_i += 1
				}
			}
		}
		result = Array{
			type    = arr.type,
			length  = out_count,
			buffers = {{}, data_buf, {}},
		}
		return
	}

	// General path (source or mask has nulls): builder with upper-bound capacity.
	b := builder_make(T, n, allocator)
	defer builder_destroy(&b)
	for i in 0..<n {
		if _mask_passes(mask, i) {
			if array_is_null(arr, i) {
				builder_append_null(&b)
			} else {
				builder_append(&b, array_get(arr, i, T))
			}
		}
	}
	return builder_finish_as(&b, arr.type, allocator)
}

// Count set bits in mask_bits in the range [off, off+n).
_filter_count_bits :: proc "contextless" (mask_bits: [^]u8, off, n: int) -> int {
	if off == 0 {
		return bitmap_popcount(mask_bits, n)
	}
	count := 0
	for i in 0..<n {
		if bitmap_get(mask_bits, off + i) { count += 1 }
	}
	return count
}

_filter_bool :: proc(arr, mask: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	b := builder_make(bool, 0, allocator)
	defer builder_destroy(&b)
	for i in 0..<arr.length {
		if _mask_passes(mask, i) {
			if array_is_null(arr, i) {
				builder_append_null(&b)
			} else {
				builder_append(&b, array_get(arr, i, bool))
			}
		}
	}
	return builder_finish(&b, allocator)
}

_filter_string :: proc(arr, mask: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	return _filter_varlen(arr, mask, String_Type{}, allocator)
}

_filter_binary :: proc(arr, mask: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	return _filter_varlen(arr, mask, Binary_Type{}, allocator)
}

_filter_varlen :: proc(arr, mask: ^Array, dt: DataType, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n         := arr.length
	arr_off   := arr.offset
	src_bm    := arr.buffers[0].data
	src_off   := cast([^]i32)arr.buffers[1].data
	src_data  := arr.buffers[2].data
	mask_bm   := mask.buffers[0].data
	mask_bits := mask.buffers[1].data
	mask_off  := mask.offset

	out_len     := 0
	null_count  := 0
	total_bytes := 0
	byte_aligned := (arr_off & 7) == 0 && (mask_off & 7) == 0
	if byte_aligned {
		m_byte0 := mask_off >> 3
		a_byte0 := arr_off >> 3
		n_bytes := (n + 7) >> 3
		for bi in 0..<n_bytes {
			pass := mask_bits[m_byte0 + bi]
			if mask_bm != nil { pass &= mask_bm[m_byte0 + bi] }
			if bi == n_bytes - 1 {
				rem := uint(n) & 7
				if rem != 0 { pass &= u8((1 << rem) - 1) }
			}
			if pass == 0 { continue }
			cnt := int(intrinsics.count_ones(pass))
			out_len += cnt
			in_base := arr_off + (bi << 3)
			if src_bm == nil {
				positions := _BYTE_INDICES_LUT[pass]
				for k in 0..<cnt {
					a_idx := in_base + int(positions[k])
					slen  := int(src_off[a_idx + 1] - src_off[a_idx])
					if slen > int(max(i32)) - total_bytes {
						panic("_filter_varlen: data exceeds i32 offset limit")
					}
					total_bytes += slen
				}
			} else {
				ab := src_bm[a_byte0 + bi]
				valid_pass := pass & ab
				v_cnt := int(intrinsics.count_ones(valid_pass))
				null_count += cnt - v_cnt
				v_pos := _BYTE_INDICES_LUT[valid_pass]
				for k in 0..<v_cnt {
					a_idx := in_base + int(v_pos[k])
					slen  := int(src_off[a_idx + 1] - src_off[a_idx])
					if slen > int(max(i32)) - total_bytes {
						panic("_filter_varlen: data exceeds i32 offset limit")
					}
					total_bytes += slen
				}
			}
		}
	} else {
		for i in 0..<n {
			m_idx := mask_off + i
			if mask_bm != nil && !bitmap_get(mask_bm, m_idx) { continue }
			if !bitmap_get(mask_bits, m_idx) { continue }
			out_len += 1
			if src_bm != nil && !bitmap_get(src_bm, arr_off + i) {
				null_count += 1
			} else {
				a_idx := arr_off + i
				slen  := int(src_off[a_idx + 1] - src_off[a_idx])
				if slen > int(max(i32)) - total_bytes {
					panic("_filter_varlen: data exceeds i32 offset limit")
				}
				total_bytes += slen
			}
		}
	}

	bitmap_buf, off_buf, data_buf := _varlen_alloc_buffers(out_len, total_bytes, null_count, allocator) or_return
	dst_bm   := bitmap_buf.data
	dst_off  := cast([^]i32)off_buf.data
	dst_data := data_buf.data
	dst_off[0] = 0
	out_i     := 0
	write_pos := 0
	if byte_aligned {
		m_byte0 := mask_off >> 3
		a_byte0 := arr_off >> 3
		n_bytes := (n + 7) >> 3
		for bi in 0..<n_bytes {
			pass := mask_bits[m_byte0 + bi]
			if mask_bm != nil { pass &= mask_bm[m_byte0 + bi] }
			if bi == n_bytes - 1 {
				rem := uint(n) & 7
				if rem != 0 { pass &= u8((1 << rem) - 1) }
			}
			if pass == 0 { continue }
			cnt       := int(intrinsics.count_ones(pass))
			positions := _BYTE_INDICES_LUT[pass]
			in_base   := arr_off + (bi << 3)
			if dst_bm == nil {
				for k in 0..<cnt {
					a_idx   := in_base + int(positions[k])
					s_start := int(src_off[a_idx])
					s_end   := int(src_off[a_idx + 1])
					slen    := s_end - s_start
					if slen > 0 {
						mem.copy_non_overlapping(rawptr(&dst_data[write_pos]), rawptr(&src_data[s_start]), slen)
						write_pos += slen
					}
					dst_off[out_i + 1] = i32(write_pos)
					out_i += 1
				}
			} else {
				ab := src_bm[a_byte0 + bi]
				for k in 0..<cnt {
					bit := positions[k]
					if (ab >> bit) & 1 == 0 {
						dst_off[out_i + 1] = i32(write_pos)
					} else {
						a_idx   := in_base + int(bit)
						s_start := int(src_off[a_idx])
						s_end   := int(src_off[a_idx + 1])
						slen    := s_end - s_start
						if slen > 0 {
							mem.copy_non_overlapping(rawptr(&dst_data[write_pos]), rawptr(&src_data[s_start]), slen)
							write_pos += slen
						}
						dst_off[out_i + 1] = i32(write_pos)
						bitmap_set(dst_bm, out_i)
					}
					out_i += 1
				}
			}
		}
	} else {
		for i in 0..<n {
			m_idx := mask_off + i
			if mask_bm != nil && !bitmap_get(mask_bm, m_idx) { continue }
			if !bitmap_get(mask_bits, m_idx) { continue }
			if src_bm != nil && !bitmap_get(src_bm, arr_off + i) {
				dst_off[out_i + 1] = i32(write_pos)
			} else {
				a_idx   := arr_off + i
				s_start := int(src_off[a_idx])
				s_end   := int(src_off[a_idx + 1])
				slen    := s_end - s_start
				if slen > 0 {
					mem.copy_non_overlapping(rawptr(&dst_data[write_pos]), rawptr(&src_data[s_start]), slen)
					write_pos += slen
				}
				dst_off[out_i + 1] = i32(write_pos)
				if dst_bm != nil { bitmap_set(dst_bm, out_i) }
			}
			out_i += 1
		}
	}

	result = Array{
		type       = dt,
		length     = out_len,
		null_count = null_count,
		buffers    = {bitmap_buf, off_buf, data_buf},
	}
	return
}

_filter_large_string :: proc(arr, mask: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	b := large_string_builder_make(64, allocator)
	defer large_string_builder_destroy(&b)
	for i in 0..<arr.length {
		if _mask_passes(mask, i) {
			if array_is_null(arr, i) {
				large_string_builder_append_null(&b)
			} else {
				large_string_builder_append(&b, array_get_large_string(arr, i))
			}
		}
	}
	return large_string_builder_finish(&b, allocator)
}

_filter_large_binary :: proc(arr, mask: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	b := large_binary_builder_make(64, allocator)
	defer large_binary_builder_destroy(&b)
	for i in 0..<arr.length {
		if _mask_passes(mask, i) {
			if array_is_null(arr, i) {
				large_binary_builder_append_null(&b)
			} else {
				large_binary_builder_append(&b, array_get_large_binary(arr, i))
			}
		}
	}
	return large_binary_builder_finish(&b, allocator)
}

// ── take ──────────────────────────────────────────────────────────────────────

_TAKE_PREFETCH_DIST     :: 12
_TAKE_PREFETCH_LOCALITY :: 0

// Return a new array containing arr[indices[i]] for each i.
// indices must be Int64_Type or Int32_Type; out-of-range indices panic.
compute_take :: proc(arr, indices: ^Array, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	_, is_i64 := indices.type.(Int64_Type)
	_, is_i32 := indices.type.(Int32_Type)
	assert(is_i64 || is_i32, "compute_take: indices must be Int64_Type or Int32_Type")
	if is_i64 {
		return _compute_take_idx(arr, indices, i64, allocator)
	}
	return _compute_take_idx(arr, indices, i32, allocator)
}

_compute_take_idx :: proc(arr, indices: ^Array, $Idx: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	switch _ in arr.type {
	case Int8_Type:       return _take_primitive(arr, indices, i8,   Idx, allocator)
	case Int16_Type:      return _take_primitive(arr, indices, i16,  Idx, allocator)
	case Int32_Type:      return _take_primitive(arr, indices, i32,  Idx, allocator)
	case Int64_Type:      return _take_primitive(arr, indices, i64,  Idx, allocator)
	case UInt8_Type:      return _take_primitive(arr, indices, u8,   Idx, allocator)
	case UInt16_Type:     return _take_primitive(arr, indices, u16,  Idx, allocator)
	case UInt32_Type:     return _take_primitive(arr, indices, u32,  Idx, allocator)
	case UInt64_Type:     return _take_primitive(arr, indices, u64,  Idx, allocator)
	case Float32_Type:    return _take_primitive(arr, indices, f32,  Idx, allocator)
	case Float64_Type:    return _take_primitive(arr, indices, f64,  Idx, allocator)
	case Decimal64_Type:  return _take_primitive(arr, indices, i64,  Idx, allocator)
	case Decimal128_Type: return _take_primitive(arr, indices, i128, Idx, allocator)
	case Bool_Type:       return _take_bool(arr, indices, Idx, allocator)
	case String_Type:     return _take_string(arr, indices, Idx, allocator)
	case Binary_Type:     return _take_binary(arr, indices, Idx, allocator)
	case Null_Type, Large_String_Type, Large_Binary_Type:
		panic("compute_take: unsupported type")
	}
	return
}

// Fixed-width gather: dst[i] = src[idx[i]], straight into the output buffer with
// no builder. The no-null source path is a tight branchless loop; when the
// source has nulls, the value is still gathered (garbage tolerated for null
// slots) and the output validity bit is gathered alongside it. Index bounds are
// the caller's responsibility (same contract as array_get).
_take_primitive :: proc(arr, indices: ^Array, $T, $Idx: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n   := indices.length
	idx := (cast([^]Idx)indices.buffers[1].data)[indices.offset:]
	src := (cast([^]T)arr.buffers[1].data)[arr.offset:]

	data_buf := buffer_make_uninit(n * size_of(T), allocator) or_return
	dst := cast([^]T)data_buf.data

	src_bm := arr.buffers[0].data
	idx_bm := indices.buffers[0].data
	bitmap_buf: Buffer
	null_count := 0
	if src_bm == nil && idx_bm == nil {
		i := 0
		for ; i + _TAKE_PREFETCH_DIST + 8 <= n; i += 8 {
			#unroll for p in 0..<8 {
				intrinsics.prefetch_read_data(rawptr(&src[int(idx[i + _TAKE_PREFETCH_DIST + p])]), _TAKE_PREFETCH_LOCALITY)
			}
			j0 := int(idx[i])
			j1 := int(idx[i + 1])
			j2 := int(idx[i + 2])
			j3 := int(idx[i + 3])
			j4 := int(idx[i + 4])
			j5 := int(idx[i + 5])
			j6 := int(idx[i + 6])
			j7 := int(idx[i + 7])
			arr_u := u64(arr.length)
			if u64(j0) >= arr_u || u64(j1) >= arr_u || u64(j2) >= arr_u || u64(j3) >= arr_u ||
			   u64(j4) >= arr_u || u64(j5) >= arr_u || u64(j6) >= arr_u || u64(j7) >= arr_u {
				panic("compute_take: index out of bounds")
			}
			dst[i]     = src[j0]
			dst[i + 1] = src[j1]
			dst[i + 2] = src[j2]
			dst[i + 3] = src[j3]
			dst[i + 4] = src[j4]
			dst[i + 5] = src[j5]
			dst[i + 6] = src[j6]
			dst[i + 7] = src[j7]
		}
		for ; i < n; i += 1 {
			j := int(idx[i])
			if u64(j) >= u64(arr.length) {
				panic("compute_take: index out of bounds")
			}
			dst[i] = src[j]
		}
	} else {
		bm, bm_err := buffer_make(bitmap_byte_count(n), allocator)
		if bm_err != nil {
			buffer_free(&data_buf)
			return {}, bm_err
		}
		bitmap_buf = bm
		for i in 0..<n {
			if idx_bm != nil && !bitmap_get(idx_bm, indices.offset + i) {
				dst[i] = {}
				null_count += 1
				continue
			}
			j := int(idx[i])
			if u64(j) >= u64(arr.length) {
				panic("compute_take: index out of bounds")
			}
			dst[i] = src[j]
			if src_bm == nil || bitmap_get(src_bm, arr.offset + j) {
				bitmap_set(bitmap_buf.data, i)
			} else {
				null_count += 1
			}
		}
	}

	result = Array{
		type       = arr.type,
		length     = n,
		null_count = null_count,
		buffers    = {bitmap_buf, data_buf, {}},
	}
	return
}

// Bool gather stays on the builder path: values are bit-packed, so there is no
// contiguous [^]T to index into.
_take_bool :: proc(arr, indices: ^Array, $Idx: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n := indices.length
	b := builder_make(bool, n, allocator)
	defer builder_destroy(&b)
	for i in 0..<n {
		if array_is_null(indices, i) {
			builder_append_null(&b)
			continue
		}
		idx := int(array_get(indices, i, Idx))
		assert(idx >= 0 && idx < arr.length, "compute_take: index out of bounds")
		if array_is_null(arr, idx) {
			builder_append_null(&b)
		} else {
			builder_append(&b, array_get(arr, idx, bool))
		}
	}
	return builder_finish(&b, allocator)
}

_take_string :: proc(arr, indices: ^Array, $Idx: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	return _take_varlen(arr, indices, String_Type{}, Idx, allocator)
}

_take_binary :: proc(arr, indices: ^Array, $Idx: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	return _take_varlen(arr, indices, Binary_Type{}, Idx, allocator)
}

_take_varlen :: proc(arr, indices: ^Array, dt: DataType, $Idx: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n        := indices.length
	arr_off  := arr.offset
	src_bm   := arr.buffers[0].data
	src_off  := cast([^]i32)arr.buffers[1].data
	src_data := arr.buffers[2].data
	idx_bm   := indices.buffers[0].data
	idx_data := (cast([^]Idx)indices.buffers[1].data)[indices.offset:]
	idx_off  := indices.offset

	null_count  := 0
	total_bytes := 0
	for i in 0..<n {
		if idx_bm != nil && !bitmap_get(idx_bm, idx_off + i) {
			null_count += 1
			continue
		}
		j := int(idx_data[i])
		if u64(j) >= u64(arr.length) {
			panic("compute_take: index out of bounds")
		}
		if src_bm != nil && !bitmap_get(src_bm, arr_off + j) {
			null_count += 1
		} else {
			a_idx := arr_off + j
			slen  := int(src_off[a_idx + 1] - src_off[a_idx])
			if slen > int(max(i32)) - total_bytes {
				panic("_take_varlen: data exceeds i32 offset limit")
			}
			total_bytes += slen
		}
	}

	bitmap_buf, off_buf, data_buf := _varlen_alloc_buffers(n, total_bytes, null_count, allocator) or_return
	dst_bm   := bitmap_buf.data
	dst_off  := cast([^]i32)off_buf.data
	dst_data := data_buf.data
	dst_off[0] = 0
	write_pos := 0
	for i in 0..<n {
		if idx_bm != nil && !bitmap_get(idx_bm, idx_off + i) {
			dst_off[i + 1] = i32(write_pos)
			continue
		}
		j := int(idx_data[i])
		if src_bm != nil && !bitmap_get(src_bm, arr_off + j) {
			dst_off[i + 1] = i32(write_pos)
		} else {
			a_idx   := arr_off + j
			s_start := int(src_off[a_idx])
			s_end   := int(src_off[a_idx + 1])
			slen    := s_end - s_start
			if slen > 0 {
				mem.copy_non_overlapping(rawptr(&dst_data[write_pos]), rawptr(&src_data[s_start]), slen)
				write_pos += slen
			}
			dst_off[i + 1] = i32(write_pos)
			if dst_bm != nil { bitmap_set(dst_bm, i) }
		}
	}

	result = Array{
		type       = dt,
		length     = n,
		null_count = null_count,
		buffers    = {bitmap_buf, off_buf, data_buf},
	}
	return
}

// ── cast ──────────────────────────────────────────────────────────────────────

// Cast arr to a different numeric type.  Supports all numeric → numeric conversions.
// String and Bool types are not supported.
compute_cast :: proc(arr: ^Array, to: DataType, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	switch _ in to {
	case Int8_Type:    return _cast_to(arr, i8,  allocator)
	case Int16_Type:   return _cast_to(arr, i16, allocator)
	case Int32_Type:   return _cast_to(arr, i32, allocator)
	case Int64_Type:   return _cast_to(arr, i64, allocator)
	case UInt8_Type:   return _cast_to(arr, u8,  allocator)
	case UInt16_Type:  return _cast_to(arr, u16, allocator)
	case UInt32_Type:  return _cast_to(arr, u32, allocator)
	case UInt64_Type:  return _cast_to(arr, u64, allocator)
	case Float32_Type: return _cast_to(arr, f32, allocator)
	case Float64_Type: return _cast_to(arr, f64, allocator)
	case Null_Type, Bool_Type,
	     Decimal64_Type, Decimal128_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_cast: unsupported target type")
	}
	return
}

// Dispatch on the source type so the inner conversion loop is monomorphised on
// both From and To — a tight, vectorisable `dst[i] = To(src[i])` with no
// per-element type switch.
_cast_to :: proc(arr: ^Array, $To: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	switch _ in arr.type {
	case Int8_Type:    return _cast_impl(arr, i8,  To, allocator)
	case Int16_Type:   return _cast_impl(arr, i16, To, allocator)
	case Int32_Type:   return _cast_impl(arr, i32, To, allocator)
	case Int64_Type:   return _cast_impl(arr, i64, To, allocator)
	case UInt8_Type:   return _cast_impl(arr, u8,  To, allocator)
	case UInt16_Type:  return _cast_impl(arr, u16, To, allocator)
	case UInt32_Type:  return _cast_impl(arr, u32, To, allocator)
	case UInt64_Type:  return _cast_impl(arr, u64, To, allocator)
	case Float32_Type: return _cast_impl(arr, f32, To, allocator)
	case Float64_Type: return _cast_impl(arr, f64, To, allocator)
	case Null_Type, Bool_Type,
	     Decimal64_Type, Decimal128_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_cast: unsupported source type")
	}
	return
}

// Outputs at/above this size are written with non-temporal (streaming) stores:
// such a buffer won't stay cache-resident, so the usual read-for-ownership of its
// cache lines is wasted bandwidth. Smaller outputs keep normal stores so a
// consumer can read them while still hot. Only taken when inputs start at offset
// 0 (so the SIMD loads are naturally aligned).
_NT_STORE_MIN_BYTES :: 1 << 23 // 8 MiB

_cast_impl :: proc(arr: ^Array, $From, $To: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n := arr.length
	data_buf := buffer_make_uninit(n * size_of(To), allocator) or_return
	dst := cast([^]To)data_buf.data
	src := (cast([^]From)arr.buffers[1].data)[arr.offset:]
	start := 0
	K  :: 8
	VS :: #simd[K]From
	VD :: #simd[K]To
	if n * size_of(To) >= _NT_STORE_MIN_BYTES && (uintptr(dst) & uintptr(align_of(VD)-1)) == 0 {
		svp := cast([^]VS)src
		dvp := cast([^]VD)dst
		nv  := n / K
		for i in 0..<nv {
			intrinsics.non_temporal_store(&dvp[i], cast(VD)intrinsics.unaligned_load(&svp[i]))
		}
		intrinsics.atomic_thread_fence(.Seq_Cst)
		start = nv * K
	}
	for i in start..<n {
		dst[i] = To(src[i])
	}
	// Cast preserves null positions exactly — copy the validity bitmap wholesale.
	bitmap_buf, bm_err := _validity_copy(arr, allocator)
	if bm_err != nil {
		buffer_free(&data_buf)
		return {}, bm_err
	}
	result = Array{
		type       = _data_type_for(To),
		length     = n,
		null_count = array_null_count(arr),
		buffers    = {bitmap_buf, data_buf, {}},
	}
	return
}

// Build a fresh validity buffer for [arr.offset, arr.offset+length). Returns a
// zero-value Buffer when the input has no validity bitmap (all valid).
_validity_copy :: proc(arr: ^Array, allocator: mem.Allocator) -> (buf: Buffer, err: mem.Allocator_Error) {
	src := arr.buffers[0].data
	if src == nil { return }
	n := arr.length
	buf = buffer_make(bitmap_byte_count(n), allocator) or_return
	if arr.offset & 7 == 0 {
		n_bytes := (n + 7) / 8
		mem.copy(rawptr(buf.data), rawptr(src[arr.offset >> 3:]), n_bytes)
		rem := uint(n) & 7
		if rem != 0 && n_bytes > 0 {
			buf.data[n_bytes - 1] &= u8((1 << rem) - 1)
		}
	} else {
		for i in 0..<n {
			if bitmap_get(src, arr.offset + i) {
				bitmap_set(buf.data, i)
			}
		}
	}
	return
}

// ── arithmetic (element-wise) ─────────────────────────────────────────────────

Arithmetic_Op :: enum { Add, Sub, Mul, Div }

// Element-wise arithmetic on two numeric arrays of the same type.
// Result type matches the input type.  Null propagates: if either element is
// null the output element is null.
compute_arithmetic :: proc(left, right: ^Array, op: Arithmetic_Op, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	if left == nil || right == nil || left.type != right.type || left.length != right.length {
		return {}, .Invalid_Argument
	}
	switch op {
	case .Add: return _arith_op(left, right, .Add, allocator)
	case .Sub: return _arith_op(left, right, .Sub, allocator)
	case .Mul: return _arith_op(left, right, .Mul, allocator)
	case .Div: return _arith_op(left, right, .Div, allocator)
	}
	return
}

_arith_op :: proc(left, right: ^Array, $OP: Arithmetic_Op, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	switch _ in left.type {
	case Int8_Type:    return _arith_impl(left, right, i8,  OP, allocator)
	case Int16_Type:   return _arith_impl(left, right, i16, OP, allocator)
	case Int32_Type:   return _arith_impl(left, right, i32, OP, allocator)
	case Int64_Type:   return _arith_impl(left, right, i64, OP, allocator)
	case UInt8_Type:   return _arith_impl(left, right, u8,  OP, allocator)
	case UInt16_Type:  return _arith_impl(left, right, u16, OP, allocator)
	case UInt32_Type:  return _arith_impl(left, right, u32, OP, allocator)
	case UInt64_Type:  return _arith_impl(left, right, u64, OP, allocator)
	case Float32_Type: return _arith_impl(left, right, f32, OP, allocator)
	case Float64_Type: return _arith_impl(left, right, f64, OP, allocator)
	case Null_Type, Bool_Type,
	     Decimal64_Type, Decimal128_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_arithmetic: unsupported type")
	}
	return
}

// Monomorphised on both value type and op: the inner loop is a tight,
// vectorisable `dst[i] = l[i] OP r[i]` with no per-element branching. The
// validity bitmap is the AND of the two inputs (built only when nulls exist).
_arith_impl :: proc(left, right: ^Array, $T: typeid, $OP: Arithmetic_Op, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n := left.length
	data_buf := buffer_make_uninit(n * size_of(T), allocator) or_return
	dst := cast([^]T)data_buf.data
	l := (cast([^]T)left.buffers[1].data)[left.offset:]
	r := (cast([^]T)right.buffers[1].data)[right.offset:]
	lbm := left.buffers[0].data
	rbm := right.buffers[0].data
	has_nulls := lbm != nil || rbm != nil

	when OP == .Div && T != f32 && T != f64 {
		// Integer division traps on 0 and signed min(T) / -1, so never divide
		// unmasked null slots.
		if !has_nulls {
			for i in 0..<n {
				assert(r[i] != 0, "compute_div: integer division by zero")
				when T == i8 || T == i16 || T == i32 || T == i64 {
					if l[i] == min(T) && r[i] == -1 {
						dst[i] = min(T)
						continue
					}
				}
				dst[i] = l[i] / r[i]
			}
		} else {
			for i in 0..<n {
				if array_is_valid(left, i) && array_is_valid(right, i) {
					assert(r[i] != 0, "compute_div: integer division by zero")
					when T == i8 || T == i16 || T == i32 || T == i64 {
						if l[i] == min(T) && r[i] == -1 {
							dst[i] = min(T)
							continue
						}
					}
					dst[i] = l[i] / r[i]
				} else {
					dst[i] = 0
				}
			}
		}
	} else {
		start := 0
		when OP != .Div {
			K  :: 64 / size_of(T) // one cache line per store
			V  :: #simd[K]T
			if n * size_of(T) >= _NT_STORE_MIN_BYTES && (uintptr(dst) & uintptr(align_of(V)-1)) == 0 {
				lv := cast([^]V)l
				rv := cast([^]V)r
				dv := cast([^]V)dst
				nv := n / K
				for i in 0..<nv {
					vl := intrinsics.unaligned_load(&lv[i])
					vr := intrinsics.unaligned_load(&rv[i])
					v: V
					when      OP == .Add { v = vl + vr }
					else when OP == .Sub { v = vl - vr }
					else when OP == .Mul { v = vl * vr }
					intrinsics.non_temporal_store(&dv[i], v)
				}
				intrinsics.atomic_thread_fence(.Seq_Cst)
				start = nv * K
			}
		}
		for i in start..<n {
			when      OP == .Add { dst[i] = l[i] + r[i] }
			else when OP == .Sub { dst[i] = l[i] - r[i] }
			else when OP == .Mul { dst[i] = l[i] * r[i] }
			else when OP == .Div { dst[i] = l[i] / r[i] }
		}
	}

	// Validity: null propagates if either side is null. Skip entirely when
	// both inputs are fully valid (the common, hot path).
	bitmap_buf: Buffer
	null_count := 0
	if has_nulls {
		bm, bm_err := buffer_make(bitmap_byte_count(n), allocator)
		if bm_err != nil {
			buffer_free(&data_buf)
			return {}, bm_err
		}
		bitmap_buf = bm
		if left.offset == 0 && right.offset == 0 {
			n_bytes := (n + 7) / 8
			n_words := n_bytes / 8
			dst_bm  := bitmap_buf.data
			dst64   := cast([^]u64)dst_bm
			if lbm != nil && rbm != nil {
				l64 := cast([^]u64)lbm
				r64 := cast([^]u64)rbm
				for w in 0..<n_words {
					dst64[w] = intrinsics.unaligned_load(&l64[w]) & intrinsics.unaligned_load(&r64[w])
				}
				for bi := n_words * 8; bi < n_bytes; bi += 1 {
					dst_bm[bi] = lbm[bi] & rbm[bi]
				}
			} else {
				sbm := lbm != nil ? lbm : rbm
				if n_bytes > 0 {
					mem.copy_non_overlapping(rawptr(dst_bm), rawptr(sbm), n_bytes)
				}
			}
			if n_bytes > 0 {
				rem := uint(n) & 7
				if rem != 0 {
					dst_bm[n_bytes - 1] &= u8((1 << rem) - 1)
				}
			}
			null_count = n - bitmap_popcount(dst_bm, n)
		} else {
			for i in 0..<n {
				if array_is_valid(left, i) && array_is_valid(right, i) {
					bitmap_set(bitmap_buf.data, i)
				} else {
					null_count += 1
				}
			}
		}
	}

	result = Array{
		type       = _data_type_for(T),
		length     = n,
		null_count = null_count,
		buffers    = {bitmap_buf, data_buf, {}},
	}
	return
}

// Convenience wrappers.
compute_add :: proc(left, right: ^Array, allocator := context.allocator) -> (Array, mem.Allocator_Error) {
	return compute_arithmetic(left, right, .Add, allocator)
}
compute_sub :: proc(left, right: ^Array, allocator := context.allocator) -> (Array, mem.Allocator_Error) {
	return compute_arithmetic(left, right, .Sub, allocator)
}
compute_mul :: proc(left, right: ^Array, allocator := context.allocator) -> (Array, mem.Allocator_Error) {
	return compute_arithmetic(left, right, .Mul, allocator)
}
compute_div :: proc(left, right: ^Array, allocator := context.allocator) -> (Array, mem.Allocator_Error) {
	return compute_arithmetic(left, right, .Div, allocator)
}

// ── sort_indices ────────────────────────────────────────────────────────────────

// Return an Int64 array of indices that stably sorts `arr` in ascending order.
// Nulls are ordered last (Arrow's default). The result can be fed directly into
// compute_take to materialise the sorted array.
compute_sort_indices :: proc(arr: ^Array, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	switch _ in arr.type {
	case Int8_Type:    return _sort_indices_typed(arr, i8,  allocator)
	case Int16_Type:   return _sort_indices_typed(arr, i16, allocator)
	case Int32_Type:   return _sort_indices_typed(arr, i32, allocator)
	case Int64_Type:   return _sort_indices_typed(arr, i64, allocator)
	case UInt8_Type:   return _sort_indices_typed(arr, u8,  allocator)
	case UInt16_Type:  return _sort_indices_typed(arr, u16, allocator)
	case UInt32_Type:  return _sort_indices_typed(arr, u32, allocator)
	case UInt64_Type:  return _sort_indices_typed(arr, u64, allocator)
	case Float32_Type: return _sort_indices_typed(arr, f32, allocator)
	case Float64_Type: return _sort_indices_typed(arr, f64, allocator)
	case String_Type:  return _sort_indices_string(arr, allocator)
	case Bool_Type, Null_Type, Decimal64_Type, Decimal128_Type, Binary_Type,
	     Large_String_Type, Large_Binary_Type:
		panic("compute_sort_indices: unsupported type")
	}
	return
}

// Stable bottom-up merge sort over the index array. `less[i] < less[j]` is
// resolved by the caller-supplied ordering captured in `idx`; ties (including
// null/null) keep the lower original index, giving a stable result.
_sort_finish_indices :: proc(idx: []i64, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	b := builder_make(i64, max(len(idx), 1), allocator)
	defer builder_destroy(&b)
	for v in idx { builder_append(&b, v) }
	return builder_finish(&b, allocator)
}

// LSD radix sort of indices by integer key — O(n · size_of(T)) with cache-
// friendly sequential passes, versus the comparison merge sort's O(n log n)
// indirect comparisons. Used for null-free fixed-width integer columns. Keys and
// indices are permuted together each pass so reads stay sequential; signed keys
// are bias-encoded (flip the sign bit) so an unsigned byte radix yields signed
// order. Passes whose radix byte is constant are skipped (small-range columns).
_radix_sort_indices :: proc(arr: ^Array, $T: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	if arr.length <= int(max(i32)) {
		return _radix_sort_indices_impl(arr, T, u32, allocator)
	}
	return _radix_sort_indices_impl(arr, T, i64, allocator)
}

_radix_sort_indices_impl :: proc(arr: ^Array, $T, $Idx: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	n    := arr.length
	data := (cast([^]T)arr.buffers[1].data)[arr.offset:]

	when      size_of(T) == 1 { U :: u8 }
	else when size_of(T) == 2 { U :: u16 }
	else when size_of(T) == 4 { U :: u32 }
	else                      { U :: u64 }

	enc :: #force_inline proc(v: T) -> U {
		when      T == i8  { return (cast(u8) v) ~ 0x80 }
		else when T == i16 { return (cast(u16)v) ~ 0x8000 }
		else when T == i32 { return (cast(u32)v) ~ 0x8000_0000 }
		else when T == i64 { return (cast(u64)v) ~ 0x8000_0000_0000_0000 }
		else               { return U(v) }
	}

	data_buf := buffer_make_uninit(n * size_of(i64), allocator) or_return
	out_i64  := cast([^]i64)data_buf.data
	if n <= 1 {
		if n == 1 { out_i64[0] = 0 }
		result = Array{type = Int64_Type{}, length = n, null_count = 0, buffers = {{}, data_buf, {}}}
		return
	}

	keys := make([]U, n, context.temp_allocator)
	hist: [size_of(T)][256]int
	for i in 0..<n {
		k := enc(data[i])
		keys[i] = k
		#unroll for d in 0..<size_of(T) {
			hist[d][int((u64(k) >> uint(d * 8)) & 0xFF)] += 1
		}
	}

	active_passes: [size_of(T)]int
	n_active := 0
	first_key := keys[0]
	for d in 0..<size_of(T) {
		first_b := int((u64(first_key) >> uint(d * 8)) & 0xFF)
		if hist[d][first_b] == n { continue }
		active_passes[n_active] = d
		n_active += 1
	}

	if n_active == 0 {
		for i in 0..<n { out_i64[i] = i64(i) }
		result = Array{type = Int64_Type{}, length = n, null_count = 0, buffers = {{}, data_buf, {}}}
		return
	}

	if n_active == 1 {
		d := active_passes[0]
		sum := 0
		for c in 0..<256 {
			t := hist[d][c]
			hist[d][c] = sum
			sum += t
		}
		shift := uint(d) * 8
		for i in 0..<n {
			b := int((u64(keys[i]) >> shift) & 0xFF)
			p := hist[d][b]
			hist[d][b] = p + 1
			out_i64[p] = i64(i)
		}
		result = Array{type = Int64_Type{}, length = n, null_count = 0, buffers = {{}, data_buf, {}}}
		return
	}

	kbuf := make([]U,   n, context.temp_allocator)
	idx  := make([]Idx, n, context.temp_allocator)
	ibuf: []Idx
	if n_active >= 3 {
		ibuf = make([]Idx, n, context.temp_allocator)
	}

	sk, dk := keys, kbuf
	si, di: []Idx
	for ap in 0..<n_active {
		d := active_passes[ap]
		sum := 0
		for c in 0..<256 {
			t := hist[d][c]
			hist[d][c] = sum
			sum += t
		}
		shift := uint(d) * 8
		if ap == 0 {
			for i in 0..<n {
				k := sk[i]
				b := int((u64(k) >> shift) & 0xFF)
				p := hist[d][b]
				hist[d][b] = p + 1
				dk[p]  = k
				idx[p] = Idx(i)
			}
			sk, dk = dk, sk
			si, di = idx, ibuf
		} else if ap < n_active - 1 {
			for i in 0..<n {
				k := sk[i]
				b := int((u64(k) >> shift) & 0xFF)
				p := hist[d][b]
				hist[d][b] = p + 1
				dk[p] = k
				di[p] = si[i]
			}
			sk, dk = dk, sk
			si, di = di, si
		} else {
			for i in 0..<n {
				b := int((u64(sk[i]) >> shift) & 0xFF)
				p := hist[d][b]
				hist[d][b] = p + 1
				out_i64[p] = i64(si[i])
			}
		}
	}

	result = Array{type = Int64_Type{}, length = n, null_count = 0, buffers = {{}, data_buf, {}}}
	return
}

_sort_indices_typed :: proc(arr: ^Array, $T: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	n := arr.length
	when T != f32 && T != f64 {
		// Null-free integer columns: radix sort (floats keep the comparison
		// sort to avoid NaN / signed-zero ordering subtleties).
		if n > 1 && array_null_count(arr) == 0 {
			return _radix_sort_indices(arr, T, allocator)
		}
	}
	idx := make([]i64, n, context.temp_allocator)
	for i in 0..<n { idx[i] = i64(i) }
	if n <= 1 { return _sort_finish_indices(idx, allocator) }

	data      := cast([^]T)arr.buffers[1].data
	off       := arr.offset
	has_nulls := arr.null_count != 0
	vbits     := arr.buffers[0].data

	// a ≤ b under "nulls last, then ascending value (NaNs after finite/+Inf, before nulls), ties keep order".
	le :: #force_inline proc(data: [^]T, off: int, has_nulls: bool, vbits: [^]u8, ai, bi: i64) -> bool {
		if has_nulls && vbits != nil {
			an := !bitmap_get(vbits, off + int(ai))
			bn := !bitmap_get(vbits, off + int(bi))
			if an && bn { return true }   // both null → keep order
			if an       { return false }  // a null → after b
			if bn       { return true }   // b null → a before
		}
		av := data[off + int(ai)]
		bv := data[off + int(bi)]
		when T == f32 || T == f64 {
			a_nan := av != av
			b_nan := bv != bv
			if a_nan && b_nan { return true }  // preserve stability among NaNs
			if a_nan          { return false } // NaN after finite/+Inf
			if b_nan          { return true }
		}
		return av <= bv
	}

	tmp := make([]i64, n, context.temp_allocator)
	width := 1
	for width < n {
		i := 0
		for i < n {
			lo  := i
			mid := min(i + width, n)
			hi  := min(i + 2*width, n)
			a, b, k := lo, mid, lo
			for a < mid && b < hi {
				if le(data, off, has_nulls, vbits, idx[a], idx[b]) { tmp[k] = idx[a]; a += 1 }
				else                                               { tmp[k] = idx[b]; b += 1 }
				k += 1
			}
			for a < mid { tmp[k] = idx[a]; a += 1; k += 1 }
			for b < hi  { tmp[k] = idx[b]; b += 1; k += 1 }
			i += 2*width
		}
		copy(idx, tmp)
		width *= 2
	}
	return _sort_finish_indices(idx, allocator)
}

Str_Sort_Entry :: struct {
	prefix: u64,
	idx:    i32,
	slen:   i32, // -1 if null, else byte length >= 0
}

_Str_Sort_Entry :: Str_Sort_Entry

str_entry_prefix :: #force_inline proc "contextless" (bytes: [^]u8, s, e: int) -> u64 {
	slen := e - s
	if slen <= 0 { return 0 }
	if slen >= 8 {
		return intrinsics.byte_swap(intrinsics.unaligned_load(cast(^u64)&bytes[s]))
	}
	buf: [8]u8
	for k in 0..<slen { buf[k] = bytes[s + k] }
	return intrinsics.byte_swap(transmute(u64)buf)
}

_str_entry_prefix :: str_entry_prefix

_str_entry_le :: #force_inline proc(offsets: [^]i32, bytes: [^]u8, off: int, ea, eb: _Str_Sort_Entry) -> bool {
	if ea.prefix != eb.prefix {
		return ea.prefix < eb.prefix
	}
	if ea.slen <= 8 && eb.slen <= 8 {
		return ea.slen <= eb.slen
	}
	if ea.slen <= 8 { return true }
	if eb.slen <= 8 { return false }
	sa := int(offsets[off + int(ea.idx)])
	sb := int(offsets[off + int(eb.idx)])
	if sa == sb {
		return ea.slen <= eb.slen
	}
	as := string(bytes[sa + 8 : sa + int(ea.slen)])
	bs := string(bytes[sb + 8 : sb + int(eb.slen)])
	return as <= bs
}

_merge_sort_str_run :: proc(offsets: [^]i32, bytes: [^]u8, off: int, run, scratch: []_Str_Sort_Entry) {
	m := len(run)
	if m <= 16 {
		for i in 1..<m {
			key := run[i]
			j := i
			for j > 0 && !_str_entry_le(offsets, bytes, off, run[j - 1], key) {
				run[j] = run[j - 1]
				j -= 1
			}
			run[j] = key
		}
		return
	}
	width := 1
	src := run
	dst := scratch
	for width < m {
		i := 0
		for i < m {
			lo  := i
			mid := min(i + width, m)
			hi  := min(i + 2 * width, m)
			a, b, k := lo, mid, lo
			for a < mid && b < hi {
				if _str_entry_le(offsets, bytes, off, src[a], src[b]) { dst[k] = src[a]; a += 1 }
				else                                                  { dst[k] = src[b]; b += 1 }
				k += 1
			}
			for a < mid { dst[k] = src[a]; a += 1; k += 1 }
			for b < hi  { dst[k] = src[b]; b += 1; k += 1 }
			i += 2 * width
		}
		src, dst = dst, src
		width *= 2
	}
	if raw_data(src) != raw_data(run) {
		copy(run, src)
	}
}

_sort_indices_string :: proc(arr: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	n := arr.length
	if n <= 1 {
		data_buf := buffer_make_uninit(n * size_of(i64), allocator) or_return
		if n == 1 { (cast([^]i64)data_buf.data)[0] = 0 }
		return Array{type = Int64_Type{}, length = n, null_count = 0, buffers = {{}, data_buf, {}}}, .None
	}
	assert(n <= int(max(i32)), "_sort_indices_string: length exceeds i32")

	data_buf := buffer_make_uninit(n * size_of(i64), allocator) or_return
	dst := cast([^]i64)data_buf.data

	off       := arr.offset
	has_nulls := arr.null_count != 0
	vbits     := arr.buffers[0].data
	offsets   := cast([^]i32)arr.buffers[1].data
	bytes     := arr.buffers[2].data

	entries := make([]_Str_Sort_Entry, n, context.temp_allocator)
	tmp     := make([]_Str_Sort_Entry, n, context.temp_allocator)
	hist: [4][256]int
	n_valid := 0
	n_nulls := 0

	for i in 0..<n {
		if has_nulls && vbits != nil && !bitmap_get(vbits, off + i) {
			tmp[n_nulls] = _Str_Sort_Entry{ idx = i32(i), slen = -1 }
			n_nulls += 1
		} else {
			s := int(offsets[off + i])
			e := int(offsets[off + i + 1])
			p := _str_entry_prefix(bytes, s, e)
			entries[n_valid] = _Str_Sort_Entry{
				prefix = p,
				idx    = i32(i),
				slen   = i32(e - s),
			}
			p32 := u32(p >> 32)
			#unroll for d in 0..<4 {
				hist[d][int((p32 >> uint(d * 8)) & 0xFF)] += 1
			}
			n_valid += 1
		}
	}

	if n_nulls > 0 {
		for k in 0..<n_nulls {
			dst[n_valid + k] = i64(tmp[k].idx)
		}
	}

	if n_valid > 0 {
		src_e := entries[:n_valid]
		dst_e := tmp[:n_valid]
		if n_valid > 1 {
			for d in 0..<4 {
				skip := false
				for c in 0..<256 {
					if hist[d][c] == n_valid { skip = true; break }
				}
				if skip { continue }
				sum := 0
				for c in 0..<256 {
					t := hist[d][c]
					hist[d][c] = sum
					sum += t
				}
				shift := uint(d) * 8 + 32
				for i in 0..<n_valid {
					b := int((src_e[i].prefix >> shift) & 0xFF)
					pos := hist[d][b]
					hist[d][b] = pos + 1
					dst_e[pos] = src_e[i]
				}
				src_e, dst_e = dst_e, src_e
			}

			run_lo := 0
			for run_lo < n_valid {
				key_hi := u32(src_e[run_lo].prefix >> 32)
				run_hi := run_lo + 1
				for run_hi < n_valid && u32(src_e[run_hi].prefix >> 32) == key_hi {
					run_hi += 1
				}
				if run_hi - run_lo > 1 {
					already_sorted := true
					for k := run_lo + 1; k < run_hi; k += 1 {
						if !_str_entry_le(offsets, bytes, off, src_e[k - 1], src_e[k]) {
							already_sorted = false
							break
						}
					}
					if !already_sorted {
						_merge_sort_str_run(offsets, bytes, off, src_e[run_lo:run_hi], dst_e[run_lo:run_hi])
					}
				}
				run_lo = run_hi
			}
		}

		for i in 0..<n_valid {
			dst[i] = i64(src_e[i].idx)
		}
	}

	result = Array{type = Int64_Type{}, length = n, null_count = 0, buffers = {{}, data_buf, {}}}
	return
}

@(private="file")
_str_entry_le_stable :: #force_inline proc(offsets: [^]i32, bytes: [^]u8, off: int, ea, eb: Str_Sort_Entry) -> bool {
	if ea.prefix != eb.prefix {
		return ea.prefix < eb.prefix
	}
	if ea.slen <= 8 && eb.slen <= 8 {
		if ea.slen != eb.slen {
			return ea.slen < eb.slen
		}
		return ea.idx <= eb.idx
	}
	if ea.slen <= 8 { return true }
	if eb.slen <= 8 { return false }
	sa := int(offsets[off + int(ea.idx)])
	sb := int(offsets[off + int(eb.idx)])
	if sa == sb {
		if ea.slen != eb.slen {
			return ea.slen < eb.slen
		}
		return ea.idx <= eb.idx
	}
	as := string(bytes[sa + 8 : sa + int(ea.slen)])
	bs := string(bytes[sb + 8 : sb + int(eb.slen)])
	if as != bs {
		return as < bs
	}
	return ea.idx <= eb.idx
}

@(private="file")
_merge_sort_str_range_stable :: proc(offsets: [^]i32, bytes: [^]u8, off: int, run, tmp: []Str_Sort_Entry) {
	m := len(run)
	if m <= 1 { return }
	if m <= 16 {
		for i in 1..<m {
			v := run[i]
			j := i - 1
			for j >= 0 && !_str_entry_le_stable(offsets, bytes, off, run[j], v) {
				run[j + 1] = run[j]
				j -= 1
			}
			run[j + 1] = v
		}
		return
	}
	for start := 0; start < m; start += 16 {
		end := min(start + 16, m)
		for i := start + 1; i < end; i += 1 {
			v := run[i]
			j := i - 1
			for j >= start && !_str_entry_le_stable(offsets, bytes, off, run[j], v) {
				run[j + 1] = run[j]
				j -= 1
			}
			run[j + 1] = v
		}
	}
	src := run
	dst := tmp
	width := 16
	for width < m {
		i := 0
		for i < m {
			lo  := i
			mid := min(i + width, m)
			hi  := min(i + 2 * width, m)
			l, r, k := lo, mid, lo
			for l < mid && r < hi {
				if _str_entry_le_stable(offsets, bytes, off, src[l], src[r]) {
					dst[k] = src[l]
					l += 1
				} else {
					dst[k] = src[r]
					r += 1
				}
				k += 1
			}
			for l < mid {
				dst[k] = src[l]
				l += 1
				k += 1
			}
			for r < hi {
				dst[k] = src[r]
				r += 1
				k += 1
			}
			i += 2 * width
		}
		src, dst = dst, src
		width *= 2
	}
	if raw_data(src) != raw_data(run) {
		copy(run, src[:m])
	}
}

// Sort a bucket of packed (u64(key_u32) << 32) | u64(orig_idx) entries directly into out_i64.
// Only bytes with bits in rem_mask are radix-sorted; ties preserve ascending orig_idx.
radix_sort_bucket_u64 :: proc(entries, scratch: []u64, out_i64: []i64, rem_mask: u32) {
	m := len(entries)
	if m == 0 { return }
	assert(len(scratch) >= m && len(out_i64) >= m)

	if rem_mask == 0 {
		for i in 0..<m {
			out_i64[i] = i64(u32(entries[i]))
		}
		return
	}

	if m <= 32 {
		for i in 1..<m {
			v := entries[i]
			j := i - 1
			for j >= 0 && entries[j] > v {
				entries[j + 1] = entries[j]
				j -= 1
			}
			entries[j + 1] = v
		}
		for i in 0..<m {
			out_i64[i] = i64(u32(entries[i]))
		}
		return
	}

	if (rem_mask >> 11) == 0 {
		nbins := int(rem_mask) + 1
		hist11: [2048]u32 = ---
		for b in 0..<nbins {
			hist11[b] = 0
		}
		for i in 0..<m {
			b := u32(entries[i] >> 32) & rem_mask
			hist11[b] += 1
		}
		first_b := u32(entries[0] >> 32) & rem_mask
		if int(hist11[first_b]) == m {
			for i in 0..<m {
				out_i64[i] = i64(u32(entries[i]))
			}
			return
		}
		acc: u32 = 0
		for b in 0..<nbins {
			c := hist11[b]
			hist11[b] = acc
			acc += c
		}
		for i in 0..<m {
			v := entries[i]
			b := u32(v >> 32) & rem_mask
			pos := hist11[b]
			hist11[b] = pos + 1
			out_i64[pos] = i64(u32(v))
		}
		return
	}

	last_pass := -1
	for pass in 0..<4 {
		if (rem_mask & (u32(0xFF) << u32(pass * 8))) != 0 {
			last_pass = pass
		}
	}

	src := entries
	dst := scratch
	hist: [256]u32
	for pass in 0..=last_pass {
		shift := u32(pass * 8)
		if (rem_mask & (u32(0xFF) << shift)) == 0 { continue }

		hist = {}
		key_shift := u32(32) + shift
		for i in 0..<m {
			b := (src[i] >> key_shift) & 0xFF
			hist[b] += 1
		}
		first_b := (src[0] >> key_shift) & 0xFF
		if int(hist[first_b]) == m { continue }

		acc: u32 = 0
		for b in 0..<256 {
			c := hist[b]
			hist[b] = acc
			acc += c
		}
		if pass == last_pass {
			for i in 0..<m {
				v := src[i]
				b := (v >> key_shift) & 0xFF
				pos := hist[b]
				hist[b] = pos + 1
				out_i64[pos] = i64(u32(v))
			}
			return
		}
		for i in 0..<m {
			v := src[i]
			b := (v >> key_shift) & 0xFF
			pos := hist[b]
			hist[b] = pos + 1
			dst[pos] = v
		}
		src, dst = dst, src
	}

	for i in 0..<m {
		out_i64[i] = i64(u32(src[i]))
	}
}

// Sort a bucket of Arrow string entries using LSB radix passes on remaining prefix bytes
// plus stable merge-sort tie-breaking on equal prefixes, writing directly into out_i64.
string_sort_range_into :: proc(
	offsets: [^]i32,
	bytes: [^]u8,
	arr_off: int,
	entries, scratch: []Str_Sort_Entry,
	out_i64: []i64,
	prefix_bytes_done: u32 = 1,
) {
	m := len(entries)
	if m == 0 { return }
	assert(len(scratch) >= m && len(out_i64) >= m)

	if m == 1 {
		out_i64[0] = i64(entries[0].idx)
		return
	}

	if m <= 32 {
		for i in 1..<m {
			v := entries[i]
			j := i - 1
			for j >= 0 && !_str_entry_le_stable(offsets, bytes, arr_off, entries[j], v) {
				entries[j + 1] = entries[j]
				j -= 1
			}
			entries[j + 1] = v
		}
		for i in 0..<m {
			out_i64[i] = i64(entries[i].idx)
		}
		return
	}

	p0 := entries[0].prefix
	diff_p: u64 = 0
	for i in 1..<m {
		diff_p |= entries[i].prefix ~ p0
	}

	src := entries
	dst := scratch
	max_pass := prefix_bytes_done < 8 ? int(8 - prefix_bytes_done) : 0
	if diff_p != 0 && max_pass > 0 {
		hist: [256]u32
		offs: [256]u32
		for pass in 0..<max_pass {
			shift := u32(pass * 8)
			if ((diff_p >> shift) & 0xFF) == 0 { continue }

			hist = {}
			for i in 0..<m {
				b := (src[i].prefix >> shift) & 0xFF
				hist[b] += 1
			}
			first_b := (src[0].prefix >> shift) & 0xFF
			if int(hist[first_b]) == m { continue }

			acc: u32 = 0
			for b in 0..<256 {
				offs[b] = acc
				acc += hist[b]
			}
			for i in 0..<m {
				v := src[i]
				b := (v.prefix >> shift) & 0xFF
				pos := offs[b]
				offs[b] = pos + 1
				dst[pos] = v
			}
			src, dst = dst, src
		}
	}

	i := 0
	for i < m {
		rp := src[i].prefix
		slen0 := src[i].slen
		needs_tie := slen0 > 8
		prev_idx := src[i].idx
		monotonic_idx := true
		j := i + 1
		for j < m && src[j].prefix == rp {
			if src[j].slen != slen0 || src[j].slen > 8 {
				needs_tie = true
			}
			if src[j].idx < prev_idx {
				monotonic_idx = false
			}
			prev_idx = src[j].idx
			j += 1
		}
		if j - i > 1 && (needs_tie || !monotonic_idx) {
			already_sorted := true
			for k := i + 1; k < j; k += 1 {
				if !_str_entry_le_stable(offsets, bytes, arr_off, src[k - 1], src[k]) {
					already_sorted = false
					break
				}
			}
			if !already_sorted {
				_merge_sort_str_range_stable(offsets, bytes, arr_off, src[i:j], dst[i:j])
			}
		}
		i = j
	}

	for k in 0..<m {
		out_i64[k] = i64(src[k].idx)
	}
}
