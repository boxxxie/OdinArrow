package skadi

import "base:intrinsics"
import "core:mem"
import "core:slice"

// _alloc_i32_slice_uninit allocates an uninitialized []i32 output buffer so
// callers writing every element (or a dense prefix) skip zero-initialization.
_alloc_i32_slice_uninit :: proc(n: int, allocator: mem.Allocator) -> []i32 {
	if n <= 0 { return nil }
	raw, err := mem.alloc_bytes_non_zeroed(n * size_of(i32), align_of(i32), allocator)
	if err != nil { return make([]i32, n, allocator) }
	return slice.from_ptr(cast([^]i32)raw_data(raw), n)
}

// Selection vectors (C2): the result of a predicate is a list of surviving row
// indices, not a freshly materialised array. Downstream kernels operate through
// the selection, so a query can filter once and then touch only the columns and
// rows it actually needs — instead of copying every column's surviving rows up
// front (what compute_filter / record-batch filter do).
//
// The payoff shows up with multi-column batches and multi-step pipelines: the
// selection is cheap (just indices), and materialisation/aggregation of each
// column happens lazily and independently.

Selection :: struct {
	indices:   []i32, // surviving row indices, ascending
	length:    int,
	capacity:  int,   // backing slice capacity in i32 elements (for exact in-place shrinks)
	allocator: mem.Allocator,
}

selection_free :: proc(s: ^Selection) {
	free_len := max(s.capacity, len(s.indices))
	if raw_data(s.indices) != nil && free_len > 0 && s.allocator.procedure != nil {
		mem.free_with_size(rawptr(raw_data(s.indices)), free_len * size_of(i32), s.allocator)
	}
	s^ = {}
}

// Build a selection from a Bool mask (null mask entries count as false). Does
// NOT touch any data column — only the mask.
compute_select :: proc(mask: ^Array, allocator := context.allocator) -> Selection {
	n     := mask.length
	mbits := mask.buffers[1].data
	moff  := mask.offset

	count := 0
	if mask.buffers[0].data == nil {
		count = _filter_count_bits(mbits, moff, n)
	} else {
		for i in 0..<n { if _mask_passes(mask, i) { count += 1 } }
	}

	idx := _alloc_i32_slice_uninit(count, allocator)
	if mask.buffers[0].data == nil && moff == 0 {
		// Two compress strategies, chosen by selectivity (we already counted):
		//  - sparse: visit only set bits via tzcnt (work ∝ survivors)
		//  - dense:  the byte-at-a-time loop, which skips empty bytes and has
		//            more ILP than the tzcnt loop's serial `bits &= bits-1` chain
		//            when ~half the bits are set.
		if count * 4 < n { _compress_sparse(mbits, n, idx) }
		else             { _compress_dense(mbits, n, idx) }
	} else {
		k := 0
		for i in 0..<n {
			if _mask_passes(mask, i) { idx[k] = i32(i); k += 1 }
		}
	}
	return Selection{ indices = idx, length = count, allocator = allocator }
}

// Sparse compress: read 64 bits at a time and visit ONLY the set bits via
// count-trailing-zeros (tzcnt). Work ∝ number of survivors. The bitmap is
// u64-addressable from byte 0 (Arrow buffers are 64-byte aligned).
_compress_sparse :: proc "contextless" (mbits: [^]u8, n: int, out: []i32) {
	k := 0
	words   := cast([^]u64)mbits
	n_words := n / 64
	for w in 0..<n_words {
		bits := intrinsics.unaligned_load(&words[w])
		base := w * 64
		for bits != 0 {
			t := intrinsics.count_trailing_zeros(bits)
			out[k] = i32(base + int(t))
			k += 1
			bits &= bits - 1
		}
	}
	for i := n_words * 64; i < n; i += 1 {
		if bitmap_get(mbits, i) { out[k] = i32(i); k += 1 }
	}
}

@(rodata)
_BYTE_INDICES_LUT := [256][8]u8{
	{0,0,0,0,0,0,0,0}, {0,0,0,0,0,0,0,0}, {1,0,0,0,0,0,0,0}, {0,1,0,0,0,0,0,0}, {2,0,0,0,0,0,0,0}, {0,2,0,0,0,0,0,0}, {1,2,0,0,0,0,0,0}, {0,1,2,0,0,0,0,0},
	{3,0,0,0,0,0,0,0}, {0,3,0,0,0,0,0,0}, {1,3,0,0,0,0,0,0}, {0,1,3,0,0,0,0,0}, {2,3,0,0,0,0,0,0}, {0,2,3,0,0,0,0,0}, {1,2,3,0,0,0,0,0}, {0,1,2,3,0,0,0,0},
	{4,0,0,0,0,0,0,0}, {0,4,0,0,0,0,0,0}, {1,4,0,0,0,0,0,0}, {0,1,4,0,0,0,0,0}, {2,4,0,0,0,0,0,0}, {0,2,4,0,0,0,0,0}, {1,2,4,0,0,0,0,0}, {0,1,2,4,0,0,0,0},
	{3,4,0,0,0,0,0,0}, {0,3,4,0,0,0,0,0}, {1,3,4,0,0,0,0,0}, {0,1,3,4,0,0,0,0}, {2,3,4,0,0,0,0,0}, {0,2,3,4,0,0,0,0}, {1,2,3,4,0,0,0,0}, {0,1,2,3,4,0,0,0},
	{5,0,0,0,0,0,0,0}, {0,5,0,0,0,0,0,0}, {1,5,0,0,0,0,0,0}, {0,1,5,0,0,0,0,0}, {2,5,0,0,0,0,0,0}, {0,2,5,0,0,0,0,0}, {1,2,5,0,0,0,0,0}, {0,1,2,5,0,0,0,0},
	{3,5,0,0,0,0,0,0}, {0,3,5,0,0,0,0,0}, {1,3,5,0,0,0,0,0}, {0,1,3,5,0,0,0,0}, {2,3,5,0,0,0,0,0}, {0,2,3,5,0,0,0,0}, {1,2,3,5,0,0,0,0}, {0,1,2,3,5,0,0,0},
	{4,5,0,0,0,0,0,0}, {0,4,5,0,0,0,0,0}, {1,4,5,0,0,0,0,0}, {0,1,4,5,0,0,0,0}, {2,4,5,0,0,0,0,0}, {0,2,4,5,0,0,0,0}, {1,2,4,5,0,0,0,0}, {0,1,2,4,5,0,0,0},
	{3,4,5,0,0,0,0,0}, {0,3,4,5,0,0,0,0}, {1,3,4,5,0,0,0,0}, {0,1,3,4,5,0,0,0}, {2,3,4,5,0,0,0,0}, {0,2,3,4,5,0,0,0}, {1,2,3,4,5,0,0,0}, {0,1,2,3,4,5,0,0},
	{6,0,0,0,0,0,0,0}, {0,6,0,0,0,0,0,0}, {1,6,0,0,0,0,0,0}, {0,1,6,0,0,0,0,0}, {2,6,0,0,0,0,0,0}, {0,2,6,0,0,0,0,0}, {1,2,6,0,0,0,0,0}, {0,1,2,6,0,0,0,0},
	{3,6,0,0,0,0,0,0}, {0,3,6,0,0,0,0,0}, {1,3,6,0,0,0,0,0}, {0,1,3,6,0,0,0,0}, {2,3,6,0,0,0,0,0}, {0,2,3,6,0,0,0,0}, {1,2,3,6,0,0,0,0}, {0,1,2,3,6,0,0,0},
	{4,6,0,0,0,0,0,0}, {0,4,6,0,0,0,0,0}, {1,4,6,0,0,0,0,0}, {0,1,4,6,0,0,0,0}, {2,4,6,0,0,0,0,0}, {0,2,4,6,0,0,0,0}, {1,2,4,6,0,0,0,0}, {0,1,2,4,6,0,0,0},
	{3,4,6,0,0,0,0,0}, {0,3,4,6,0,0,0,0}, {1,3,4,6,0,0,0,0}, {0,1,3,4,6,0,0,0}, {2,3,4,6,0,0,0,0}, {0,2,3,4,6,0,0,0}, {1,2,3,4,6,0,0,0}, {0,1,2,3,4,6,0,0},
	{5,6,0,0,0,0,0,0}, {0,5,6,0,0,0,0,0}, {1,5,6,0,0,0,0,0}, {0,1,5,6,0,0,0,0}, {2,5,6,0,0,0,0,0}, {0,2,5,6,0,0,0,0}, {1,2,5,6,0,0,0,0}, {0,1,2,5,6,0,0,0},
	{3,5,6,0,0,0,0,0}, {0,3,5,6,0,0,0,0}, {1,3,5,6,0,0,0,0}, {0,1,3,5,6,0,0,0}, {2,3,5,6,0,0,0,0}, {0,2,3,5,6,0,0,0}, {1,2,3,5,6,0,0,0}, {0,1,2,3,5,6,0,0},
	{4,5,6,0,0,0,0,0}, {0,4,5,6,0,0,0,0}, {1,4,5,6,0,0,0,0}, {0,1,4,5,6,0,0,0}, {2,4,5,6,0,0,0,0}, {0,2,4,5,6,0,0,0}, {1,2,4,5,6,0,0,0}, {0,1,2,4,5,6,0,0},
	{3,4,5,6,0,0,0,0}, {0,3,4,5,6,0,0,0}, {1,3,4,5,6,0,0,0}, {0,1,3,4,5,6,0,0}, {2,3,4,5,6,0,0,0}, {0,2,3,4,5,6,0,0}, {1,2,3,4,5,6,0,0}, {0,1,2,3,4,5,6,0},
	{7,0,0,0,0,0,0,0}, {0,7,0,0,0,0,0,0}, {1,7,0,0,0,0,0,0}, {0,1,7,0,0,0,0,0}, {2,7,0,0,0,0,0,0}, {0,2,7,0,0,0,0,0}, {1,2,7,0,0,0,0,0}, {0,1,2,7,0,0,0,0},
	{3,7,0,0,0,0,0,0}, {0,3,7,0,0,0,0,0}, {1,3,7,0,0,0,0,0}, {0,1,3,7,0,0,0,0}, {2,3,7,0,0,0,0,0}, {0,2,3,7,0,0,0,0}, {1,2,3,7,0,0,0,0}, {0,1,2,3,7,0,0,0},
	{4,7,0,0,0,0,0,0}, {0,4,7,0,0,0,0,0}, {1,4,7,0,0,0,0,0}, {0,1,4,7,0,0,0,0}, {2,4,7,0,0,0,0,0}, {0,2,4,7,0,0,0,0}, {1,2,4,7,0,0,0,0}, {0,1,2,4,7,0,0,0},
	{3,4,7,0,0,0,0,0}, {0,3,4,7,0,0,0,0}, {1,3,4,7,0,0,0,0}, {0,1,3,4,7,0,0,0}, {2,3,4,7,0,0,0,0}, {0,2,3,4,7,0,0,0}, {1,2,3,4,7,0,0,0}, {0,1,2,3,4,7,0,0},
	{5,7,0,0,0,0,0,0}, {0,5,7,0,0,0,0,0}, {1,5,7,0,0,0,0,0}, {0,1,5,7,0,0,0,0}, {2,5,7,0,0,0,0,0}, {0,2,5,7,0,0,0,0}, {1,2,5,7,0,0,0,0}, {0,1,2,5,7,0,0,0},
	{3,5,7,0,0,0,0,0}, {0,3,5,7,0,0,0,0}, {1,3,5,7,0,0,0,0}, {0,1,3,5,7,0,0,0}, {2,3,5,7,0,0,0,0}, {0,2,3,5,7,0,0,0}, {1,2,3,5,7,0,0,0}, {0,1,2,3,5,7,0,0},
	{4,5,7,0,0,0,0,0}, {0,4,5,7,0,0,0,0}, {1,4,5,7,0,0,0,0}, {0,1,4,5,7,0,0,0}, {2,4,5,7,0,0,0,0}, {0,2,4,5,7,0,0,0}, {1,2,4,5,7,0,0,0}, {0,1,2,4,5,7,0,0},
	{3,4,5,7,0,0,0,0}, {0,3,4,5,7,0,0,0}, {1,3,4,5,7,0,0,0}, {0,1,3,4,5,7,0,0}, {2,3,4,5,7,0,0,0}, {0,2,3,4,5,7,0,0}, {1,2,3,4,5,7,0,0}, {0,1,2,3,4,5,7,0},
	{6,7,0,0,0,0,0,0}, {0,6,7,0,0,0,0,0}, {1,6,7,0,0,0,0,0}, {0,1,6,7,0,0,0,0}, {2,6,7,0,0,0,0,0}, {0,2,6,7,0,0,0,0}, {1,2,6,7,0,0,0,0}, {0,1,2,6,7,0,0,0},
	{3,6,7,0,0,0,0,0}, {0,3,6,7,0,0,0,0}, {1,3,6,7,0,0,0,0}, {0,1,3,6,7,0,0,0}, {2,3,6,7,0,0,0,0}, {0,2,3,6,7,0,0,0}, {1,2,3,6,7,0,0,0}, {0,1,2,3,6,7,0,0},
	{4,6,7,0,0,0,0,0}, {0,4,6,7,0,0,0,0}, {1,4,6,7,0,0,0,0}, {0,1,4,6,7,0,0,0}, {2,4,6,7,0,0,0,0}, {0,2,4,6,7,0,0,0}, {1,2,4,6,7,0,0,0}, {0,1,2,4,6,7,0,0},
	{3,4,6,7,0,0,0,0}, {0,3,4,6,7,0,0,0}, {1,3,4,6,7,0,0,0}, {0,1,3,4,6,7,0,0}, {2,3,4,6,7,0,0,0}, {0,2,3,4,6,7,0,0}, {1,2,3,4,6,7,0,0}, {0,1,2,3,4,6,7,0},
	{5,6,7,0,0,0,0,0}, {0,5,6,7,0,0,0,0}, {1,5,6,7,0,0,0,0}, {0,1,5,6,7,0,0,0}, {2,5,6,7,0,0,0,0}, {0,2,5,6,7,0,0,0}, {1,2,5,6,7,0,0,0}, {0,1,2,5,6,7,0,0},
	{3,5,6,7,0,0,0,0}, {0,3,5,6,7,0,0,0}, {1,3,5,6,7,0,0,0}, {0,1,3,5,6,7,0,0}, {2,3,5,6,7,0,0,0}, {0,2,3,5,6,7,0,0}, {1,2,3,5,6,7,0,0}, {0,1,2,3,5,6,7,0},
	{4,5,6,7,0,0,0,0}, {0,4,5,6,7,0,0,0}, {1,4,5,6,7,0,0,0}, {0,1,4,5,6,7,0,0}, {2,4,5,6,7,0,0,0}, {0,2,4,5,6,7,0,0}, {1,2,4,5,6,7,0,0}, {0,1,2,4,5,6,7,0},
	{3,4,5,6,7,0,0,0}, {0,3,4,5,6,7,0,0}, {1,3,4,5,6,7,0,0}, {0,1,3,4,5,6,7,0}, {2,3,4,5,6,7,0,0}, {0,2,3,4,5,6,7,0}, {1,2,3,4,5,6,7,0}, {0,1,2,3,4,5,6,7},
}

// Dense compress: byte-at-a-time using _BYTE_INDICES_LUT, adding `base_idx` to
// each emitted row index and using AVX2 8-lane stores when 8 output slots remain.
@(enable_target_feature = _SIMD_TARGET_FEATURE)
_compress_chunk_offset :: proc "contextless" (mbits: [^]u8, chunk_len: int, out: []i32, base_idx: i32) -> int {
	if chunk_len <= 0 { return 0 }
	k := 0
	n_full := (chunk_len / 8) * 8
	out_len := len(out)
	out_ptr := raw_data(out)
	for i := 0; i < n_full; i += 8 {
		b := mbits[i >> 3]
		if b == 0 { continue }
		cnt := int(intrinsics.count_ones(b))
		positions := _BYTE_INDICES_LUT[b]
		if k + 8 <= out_len {
			V :: #simd[8]i32
			base := V(base_idx + i32(i))
			offs := #simd[8]i32{
				i32(positions[0]), i32(positions[1]), i32(positions[2]), i32(positions[3]),
				i32(positions[4]), i32(positions[5]), i32(positions[6]), i32(positions[7]),
			}
			intrinsics.unaligned_store(cast(^#simd[8]i32)&out_ptr[k], base + offs)
		} else {
			for j in 0..<cnt {
				out[k + j] = base_idx + i32(i + int(positions[j]))
			}
		}
		k += cnt
	}
	for i := n_full; i < chunk_len; i += 1 {
		if bitmap_get(mbits, i) {
			out[k] = base_idx + i32(i)
			k += 1
		}
	}
	return k
}

// Dense compress: byte-at-a-time using _BYTE_INDICES_LUT, scattering
// popcount(b) matching indices with AVX2 8-lane stores whenever 8 output slots remain.
_compress_dense :: proc "contextless" (mbits: [^]u8, n: int, out: []i32) {
	_ = _compress_chunk_offset(mbits, n, out, 0)
}

// ── aggregate through a selection (no materialisation) ──────────────────────

compute_sum_selection :: proc(arr: ^Array, sel: ^Selection) -> (sum: f64, valid_count: int) {
	switch _ in arr.type {
	case Int8_Type:    return _sum_selection_typed(arr, sel, i8)
	case Int16_Type:   return _sum_selection_typed(arr, sel, i16)
	case Int32_Type:   return _sum_selection_typed(arr, sel, i32)
	case Int64_Type:   return _sum_selection_typed(arr, sel, i64)
	case UInt8_Type:   return _sum_selection_typed(arr, sel, u8)
	case UInt16_Type:  return _sum_selection_typed(arr, sel, u16)
	case UInt32_Type:  return _sum_selection_typed(arr, sel, u32)
	case UInt64_Type:  return _sum_selection_typed(arr, sel, u64)
	case Float32_Type: return _sum_selection_typed(arr, sel, f32)
	case Float64_Type: return _sum_selection_typed(arr, sel, f64)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_sum_selection: type does not support numeric summation")
	}
	return
}

_sum_selection_typed :: #force_inline proc(arr: ^Array, sel: ^Selection, $T: typeid) -> (sum: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	if arr.buffers[0].data == nil {
		indices := sel.indices
		m := sel.length
		s0, s1, s2, s3: f64
		j := 0
		for ; j + 4 <= m; j += 4 {
			s0 += f64(data[off + int(indices[j])])
			s1 += f64(data[off + int(indices[j + 1])])
			s2 += f64(data[off + int(indices[j + 2])])
			s3 += f64(data[off + int(indices[j + 3])])
		}
		for ; j < m; j += 1 {
			s0 += f64(data[off + int(indices[j])])
		}
		sum = (s0 + s1) + (s2 + s3)
		valid_count = sel.length
	} else {
		for j in 0..<sel.length {
			i := int(sel.indices[j])
			if array_is_valid(arr, i) { sum += f64(data[off + i]); valid_count += 1 }
		}
	}
	return
}

// Number of selected rows.
compute_count_selection :: proc(sel: ^Selection) -> int { return sel.length }

compute_min_max_selection :: proc(arr: ^Array, sel: ^Selection) -> (min_val: f64, max_val: f64, valid_count: int) {
	switch _ in arr.type {
	case Int8_Type:    return _min_max_selection_typed(arr, sel, i8)
	case Int16_Type:   return _min_max_selection_typed(arr, sel, i16)
	case Int32_Type:   return _min_max_selection_typed(arr, sel, i32)
	case Int64_Type:   return _min_max_selection_typed(arr, sel, i64)
	case UInt8_Type:   return _min_max_selection_typed(arr, sel, u8)
	case UInt16_Type:  return _min_max_selection_typed(arr, sel, u16)
	case UInt32_Type:  return _min_max_selection_typed(arr, sel, u32)
	case UInt64_Type:  return _min_max_selection_typed(arr, sel, u64)
	case Float32_Type: return _min_max_selection_typed(arr, sel, f32)
	case Float64_Type: return _min_max_selection_typed(arr, sel, f64)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_min_max_selection: type does not support ordering")
	}
	return
}

_min_max_selection_typed :: #force_inline proc(arr: ^Array, sel: ^Selection, $T: typeid) -> (min_val: f64, max_val: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	has_nulls := arr.buffers[0].data != nil
	lo, hi, last_nan: T
	when T != f32 && T != f64 {
		_ = last_nan
	}
	seen := false
	// Phase 1: seed lo/hi with the first valid non-NaN element.
	j := 0
	for ; j < sel.length; j += 1 {
		i := int(sel.indices[j])
		if has_nulls && !array_is_valid(arr, i) { continue }
		v := data[off + i]
		valid_count += 1
		when T == f32 || T == f64 {
			if v != v { last_nan = v; continue }
		}
		lo = v
		hi = v
		seen = true
		j += 1
		break
	}
	// Phase 2: hot loop without per-row `v != v` or `seen` branches.
	// Phase 1 guarantees lo/hi are non-NaN for floats, so IEEE 754 `<`/`>`
	// evaluate to false for any subsequent NaN.
	for ; j < sel.length; j += 1 {
		i := int(sel.indices[j])
		if has_nulls && !array_is_valid(arr, i) { continue }
		v := data[off + i]
		valid_count += 1
		if v < lo { lo = v }
		if v > hi { hi = v }
	}
	if seen {
		min_val = f64(lo)
		max_val = f64(hi)
	} else if valid_count > 0 {
		when T == f32 || T == f64 {
			min_val = f64(last_nan)
			max_val = f64(last_nan)
		}
	}
	return
}

// ── materialise (the escape hatch: gather one column at the selected rows) ──

// Materialise an Array at the rows selected by `sel` (zero-widening 32-bit Selection gather).
compute_take_selection :: proc(arr: ^Array, sel: ^Selection, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	return selection_take(arr, sel, allocator)
}

selection_take :: proc(arr: ^Array, sel: ^Selection, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	switch _ in arr.type {
	case Int8_Type:    return _selection_take_typed(arr, sel, i8,  allocator)
	case Int16_Type:   return _selection_take_typed(arr, sel, i16, allocator)
	case Int32_Type:   return _selection_take_typed(arr, sel, i32, allocator)
	case Int64_Type:   return _selection_take_typed(arr, sel, i64, allocator)
	case UInt8_Type:   return _selection_take_typed(arr, sel, u8,  allocator)
	case UInt16_Type:  return _selection_take_typed(arr, sel, u16, allocator)
	case UInt32_Type:  return _selection_take_typed(arr, sel, u32, allocator)
	case UInt64_Type:  return _selection_take_typed(arr, sel, u64, allocator)
	case Float32_Type: return _selection_take_typed(arr, sel, f32, allocator)
	case Float64_Type: return _selection_take_typed(arr, sel, f64, allocator)
	case String_Type:  return _selection_take_string(arr, sel, allocator)
	case Bool_Type, Null_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("selection_take: unsupported type")
	}
	return
}

_selection_take_typed :: proc(arr: ^Array, sel: ^Selection, $T: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n    := sel.length
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	if arr.buffers[0].data == nil {
		buf  := buffer_make_uninit(n * size_of(T), allocator) or_return
		dst  := cast([^]T)buf.data
		src  := data[off:]
		idxs := raw_data(sel.indices)
		j    := 0
		for ; j + _TAKE_PREFETCH_DIST + 8 <= n; j += 8 {
			#unroll for p in 0..<8 {
				intrinsics.prefetch_read_data(rawptr(&src[int(idxs[j + _TAKE_PREFETCH_DIST + p])]), _TAKE_PREFETCH_LOCALITY)
			}
			j0 := int(idxs[j])
			j1 := int(idxs[j + 1])
			j2 := int(idxs[j + 2])
			j3 := int(idxs[j + 3])
			j4 := int(idxs[j + 4])
			j5 := int(idxs[j + 5])
			j6 := int(idxs[j + 6])
			j7 := int(idxs[j + 7])
			dst[j]     = src[j0]
			dst[j + 1] = src[j1]
			dst[j + 2] = src[j2]
			dst[j + 3] = src[j3]
			dst[j + 4] = src[j4]
			dst[j + 5] = src[j5]
			dst[j + 6] = src[j6]
			dst[j + 7] = src[j7]
		}
		for ; j < n; j += 1 {
			dst[j] = src[int(idxs[j])]
		}
		result = Array{ type = _data_type_for(T), length = n, buffers = {{}, buf, {}} }
		return
	}
	b := builder_make(T, n, allocator)
	defer builder_destroy(&b)
	for j in 0..<n {
		i := int(sel.indices[j])
		if array_is_null(arr, i) { builder_append_null(&b) } else { builder_append(&b, data[off + i]) }
	}
	return builder_finish(&b, allocator)
}

_selection_take_string :: proc(arr: ^Array, sel: ^Selection, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n        := sel.length
	arr_off  := arr.offset
	src_bm   := arr.buffers[0].data
	src_off  := cast([^]i32)arr.buffers[1].data
	src_data := arr.buffers[2].data

	null_count  := 0
	total_bytes := 0
	for j in 0..<n {
		i := int(sel.indices[j])
		if src_bm != nil && !bitmap_get(src_bm, arr_off + i) {
			null_count += 1
		} else {
			a_idx := arr_off + i
			slen := int(src_off[a_idx + 1] - src_off[a_idx])
			if slen > int(max(i32)) - total_bytes {
				panic("_selection_take_string: data exceeds i32 offset limit")
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
	for j in 0..<n {
		i := int(sel.indices[j])
		if src_bm != nil && !bitmap_get(src_bm, arr_off + i) {
			dst_off[j + 1] = i32(write_pos)
		} else {
			a_idx   := arr_off + i
			s_start := int(src_off[a_idx])
			s_end   := int(src_off[a_idx + 1])
			slen    := s_end - s_start
			if slen > 0 {
				mem.copy_non_overlapping(rawptr(&dst_data[write_pos]), rawptr(&src_data[s_start]), slen)
				write_pos += slen
			}
			dst_off[j + 1] = i32(write_pos)
			if dst_bm != nil { bitmap_set(dst_bm, j) }
		}
	}

	result = Array{
		type       = String_Type{},
		length     = n,
		null_count = null_count,
		buffers    = {bitmap_buf, off_buf, data_buf},
	}
	return
}

// Materialise every column of a batch at the selection (the eager equivalent of
// keeping a selection and gathering lazily — provided for comparison/when a
// dense batch is genuinely required).
record_batch_take :: proc(batch: ^Record_Batch, sel: ^Selection, allocator := context.allocator) -> (result: Record_Batch, ok: bool) {
	cols, alloc_err := make([]Array, len(batch.columns), allocator)
	if alloc_err != nil { return {}, false }
	for ci in 0..<len(batch.columns) {
		c, e := selection_take(&batch.columns[ci], sel, allocator)
		if e != nil {
			for k in 0..<ci { array_free(&cols[k], allocator) }
			delete(cols, allocator)
			return {}, false
		}
		cols[ci] = c
	}
	rb, made := record_batch_make(batch.schema, cols, allocator)
	if !made {
		for k in 0..<len(cols) { array_free(&cols[k], allocator) }
	}
	delete(cols, allocator)   // record_batch_make copied the slice (shares buffers)
	return rb, made
}
