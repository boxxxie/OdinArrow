package skadi

import "core:mem"

// Array is the central type: an immutable, nullable, typed column of values.
//
// Memory layout (matches Apache Arrow columnar format):
//   buffers[0] — validity bitmap (nil if null_count == 0; no nulls → omitted)
//   buffers[1] — data values (contiguous typed array, or bit-packed for Bool)
//   buffers[2] — reserved for Phase 3 (offsets for variable-length types)
//
// Zero-copy slicing: offset and length change; buffers are shared.
// Ownership: buffers with allocator.procedure == nil are NOT freed by array_free
// (this is set by array_slice so sliced arrays are safe to free independently).
Array :: struct {
	type:       DataType,
	length:     int,
	null_count: int,    // -1 = unknown; call array_null_count to recompute
	offset:     int,    // element offset into buffers (non-zero after slice)
	buffers:    [3]Buffer,
	children:   []Array, // Phase 4+: nested types
}

// True if element i is null.
array_is_null :: #force_inline proc "contextless" (arr: ^Array, i: int) -> bool {
	#partial switch _ in arr.type {
	case Null_Type:
		return true
	}
	bm := &arr.buffers[0]
	if bm.data == nil { return false }
	return !bitmap_get(bm.data, arr.offset + i)
}

// True if element i is valid (not null).
array_is_valid :: #force_inline proc "contextless" (arr: ^Array, i: int) -> bool {
	#partial switch _ in arr.type {
	case Null_Type:
		return false
	}
	bm := &arr.buffers[0]
	if bm.data == nil { return true }
	return bitmap_get(bm.data, arr.offset + i)
}

// Return the null count, recounting from the bitmap if the cached value is -1.
array_null_count :: proc(arr: ^Array) -> int {
	#partial switch _ in arr.type {
	case Null_Type:
		arr.null_count = arr.length
		return arr.length
	}
	if arr.null_count >= 0 { return arr.null_count }
	if arr.buffers[0].data == nil {
		arr.null_count = 0
		return 0
	}
	// Count set (valid) bits in the range [offset, offset+length)
	total  := bitmap_popcount(arr.buffers[0].data, arr.offset + arr.length)
	prefix := arr.offset > 0 ? bitmap_popcount(arr.buffers[0].data, arr.offset) : 0
	arr.null_count = arr.length - (total - prefix)
	return arr.null_count
}

// O(1) zero-copy slice into [from, to). The returned Array shares all buffers
// with the parent — do NOT call array_free on it while the parent is live.
// null_count is set to -1 (unknown); call array_null_count to recompute.
array_slice :: proc(arr: Array, from, to: int) -> Array {
	assert(from >= 0 && to <= arr.length && from <= to, "array_slice: out of bounds")
	result           := arr
	result.offset     = arr.offset + from
	result.length     = to - from
	result.null_count = -1
	// Clear allocators so array_free won't attempt to double-free shared buffers
	for &buf in result.buffers {
		buf.allocator = {}
	}
	return result
}

// Get element i as type T.
// For Bool arrays: T = bool (values are bit-packed; use bitmap_get).
// For all other primitive arrays: T must match the array's DataType.
// Out-of-bounds panics in debug builds; undefined behaviour in release.
array_get :: proc(arr: ^Array, i: int, $T: typeid) -> T {
	assert(i >= 0 && i < arr.length, "array_get: index out of bounds")
	idx := arr.offset + i
	when T == bool {
		return bitmap_get(arr.buffers[1].data, idx)
	} else {
		return (cast([^]T)arr.buffers[1].data)[idx]
	}
}

// Like array_get but also returns validity. Second return is false when null.
array_try_get :: proc(arr: ^Array, i: int, $T: typeid) -> (val: T, valid: bool) {
	valid = array_is_valid(arr, i)
	if valid {
		val = array_get(arr, i, T)
	}
	return
}

// Free all owned buffers. Children freed recursively.
// Safe to call on zero-value Array and on sliced arrays (shared buffers
// are skipped because their allocator.procedure == nil).
array_free :: proc(arr: ^Array, allocator := context.allocator) {
	for &buf in arr.buffers {
		buffer_free(&buf)
	}
	for &child in arr.children {
		array_free(&child, allocator)
	}
	if arr.children != nil {
		delete(arr.children, allocator)
	}
	arr^ = {}
}

// Recount nulls by scanning the bitmap. Forces arr.null_count >= 0.
// Equivalent to array_null_count but always scans (ignores the cache).
array_recount_nulls :: proc(arr: ^Array) -> int {
	#partial switch _ in arr.type {
	case Null_Type:
		arr.null_count = arr.length
		return arr.length
	}
	arr.null_count = -1
	return array_null_count(arr)
}

// Helper: copy an Array and its owned buffers into a new allocation.
// If src.offset > 0, the copied array is rebased to offset 0 with only the
// slice window [src.offset ..< src.offset + src.length) copied.
// Children are NOT deep-copied (Phase 4+ concern).
array_copy :: proc(src: ^Array, allocator := context.allocator) -> (dst: Array, err: mem.Allocator_Error) {
	if src.offset > 0 {
		return _array_copy_rebased(src, allocator)
	}
	dst = src^
	for i in 0..<3 {
		dst.buffers[i] = {}
	}
	for i in 0..<3 {
		if src.buffers[i].data != nil {
			buf, b_err := buffer_copy(&src.buffers[i], allocator)
			if b_err != nil {
				for j in 0..<i {
					buffer_free(&dst.buffers[j])
				}
				return {}, b_err
			}
			dst.buffers[i] = buf
		}
	}
	return
}

_array_copy_rebased :: proc(src: ^Array, allocator: mem.Allocator) -> (dst: Array, err: mem.Allocator_Error) {
	dst = src^
	dst.offset = 0
	for i in 0..<3 {
		dst.buffers[i] = {}
	}
	n := src.length
	off := src.offset

	// Copy validity bitmap shifted to bit 0.
	if src.buffers[0].data != nil && n > 0 {
		bm_bytes := bitmap_byte_count(n)
		bm_buf, b_err := buffer_make(bm_bytes, allocator)
		if b_err != nil { return {}, b_err }
		bm_slice := ([^]u8)(bm_buf.data)[:bm_bytes]
		src_bm := ([^]u8)(src.buffers[0].data)
		for i in 0..<n {
			bit_idx := off + i
			if (src_bm[bit_idx >> 3] & (1 << u32(bit_idx & 7))) != 0 {
				bm_slice[i >> 3] |= 1 << u32(i & 7)
			}
		}
		dst.buffers[0] = bm_buf
	}

	cleanup :: proc(d: ^Array) {
		for j in 0..<3 { buffer_free(&d.buffers[j]) }
	}

	switch t in src.type {
	case Null_Type:
		// No data buffers.
	case Bool_Type:
		if src.buffers[1].data != nil && n > 0 {
			data_bytes := bitmap_byte_count(n)
			dbuf, d_err := buffer_make(data_bytes, allocator)
			if d_err != nil { cleanup(&dst); return {}, d_err }
			dst_bits := ([^]u8)(dbuf.data)[:data_bytes]
			src_bits := ([^]u8)(src.buffers[1].data)
			for i in 0..<n {
				bit_idx := off + i
				if (src_bits[bit_idx >> 3] & (1 << u32(bit_idx & 7))) != 0 {
					dst_bits[i >> 3] |= 1 << u32(i & 7)
				}
			}
			dst.buffers[1] = dbuf
		}
	case String_Type, Binary_Type:
		if src.buffers[1].data != nil {
			src_offs := ([^]i32)(src.buffers[1].data)
			base := src_offs[off]
			end_off := src_offs[off + n]
			off_bytes := (n + 1) * size_of(i32)
			obuf, o_err := buffer_make(off_bytes, allocator)
			if o_err != nil { cleanup(&dst); return {}, o_err }
			dst_offs := ([^]i32)(obuf.data)
			for i in 0..=n {
				dst_offs[i] = src_offs[off + i] - base
			}
			dst.buffers[1] = obuf

			data_bytes := int(end_off - base)
			dbuf, d_err := buffer_make(data_bytes, allocator)
			if d_err != nil { cleanup(&dst); return {}, d_err }
			if data_bytes > 0 && src.buffers[2].data != nil {
				mem.copy(dbuf.data, rawptr(uintptr(src.buffers[2].data) + uintptr(base)), data_bytes)
			}
			dst.buffers[2] = dbuf
		}
	case Large_String_Type, Large_Binary_Type:
		if src.buffers[1].data != nil {
			src_offs := ([^]i64)(src.buffers[1].data)
			base := src_offs[off]
			end_off := src_offs[off + n]
			off_bytes := (n + 1) * size_of(i64)
			obuf, o_err := buffer_make(off_bytes, allocator)
			if o_err != nil { cleanup(&dst); return {}, o_err }
			dst_offs := ([^]i64)(obuf.data)
			for i in 0..=n {
				dst_offs[i] = src_offs[off + i] - base
			}
			dst.buffers[1] = obuf

			data_bytes := int(end_off - base)
			dbuf, d_err := buffer_make(data_bytes, allocator)
			if d_err != nil { cleanup(&dst); return {}, d_err }
			if data_bytes > 0 && src.buffers[2].data != nil {
				mem.copy(dbuf.data, rawptr(uintptr(src.buffers[2].data) + uintptr(base)), data_bytes)
			}
			dst.buffers[2] = dbuf
		}
	case Int8_Type, Int16_Type, Int32_Type, Int64_Type,
	     UInt8_Type, UInt16_Type, UInt32_Type, UInt64_Type,
	     Float32_Type, Float64_Type:
		elem_sz := 0
		#partial switch _ in src.type {
		case Int8_Type, UInt8_Type: elem_sz = 1
		case Int16_Type, UInt16_Type: elem_sz = 2
		case Int32_Type, UInt32_Type, Float32_Type: elem_sz = 4
		case Int64_Type, UInt64_Type, Float64_Type: elem_sz = 8
		}
		if src.buffers[1].data != nil && n > 0 && elem_sz > 0 {
			data_bytes := n * elem_sz
			dbuf, d_err := buffer_make(data_bytes, allocator)
			if d_err != nil { cleanup(&dst); return {}, d_err }
			mem.copy(dbuf.data, rawptr(uintptr(src.buffers[1].data) + uintptr(off * elem_sz)), data_bytes)
			dst.buffers[1] = dbuf
		}
	}
	return
}
