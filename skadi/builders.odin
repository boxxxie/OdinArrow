package skadi

import "core:mem"

// Primitive_Builder accumulates values of type T and produces an owned Array
// on finish(). T must be one of: bool, i8, i16, i32, i64, u8, u16, u32, u64, f32, f64.
//
// Internal storage uses raw buffers ([^]T) rather than [dynamic]T to
// eliminate the dynamic-array descriptor overhead on every append — direct
// indexed writes replace per-call bounds-check + length-load + length-store.
Primitive_Builder :: struct($T: typeid) {
	data:       [^]T,   // raw value buffer
	cap:        int,
	bitmap:     [^]u8,  // validity bitmap (0xFF-filled on first null); allocated lazily
	bm_cap:     int,
	null_count: int,
	length:     int,
	allocator:  mem.Allocator,
}

// Allocate a new builder with preallocated capacity.
builder_make :: proc($T: typeid, initial_cap := 64, allocator := context.allocator) -> Primitive_Builder(T) {
	init_cap := max(initial_cap, 1)
	assert(init_cap <= max(int) / max(size_of(T), 1), "builder_make: capacity overflow")
	// Values are fully overwritten before the array is read, so the data buffer
	// is left uninitialised; the bitmap is allocated lazily on the first null.
	data_bytes, data_err := mem.alloc_bytes_non_zeroed(init_cap * size_of(T), ARROW_ALIGNMENT, allocator)
	assert(data_err == .None, "builder_make: data allocation failed")
	return Primitive_Builder(T){
		data      = cast([^]T)raw_data(data_bytes),
		cap       = init_cap,
		allocator = allocator,
	}
}

// Append a non-null value.
builder_append :: #force_inline proc(b: ^Primitive_Builder($T), val: T) {
	if b.length >= b.cap { _builder_grow_data(b) }
	b.data[b.length] = val
	b.length += 1
}

// Append a null value.
builder_append_null :: #force_inline proc(b: ^Primitive_Builder($T)) {
	if b.length >= b.cap { _builder_grow_data(b) }
	byte_i := b.length >> 3
	if byte_i >= b.bm_cap {
		_builder_grow_bitmap(b, max(bitmap_byte_count(b.cap), byte_i + 1))
	}
	b.bitmap[byte_i] &= ~(1 << u8(b.length & 7))
	zero: T
	b.data[b.length] = zero
	b.null_count += 1
	b.length += 1
}

// Produce an immutable Array from the builder's accumulated values.
//
// For every non-bool type this is zero-copy: the builder's data and validity
// buffers are handed directly to the Array (no alloc + copy of the values),
// and the builder is left empty so it can be safely destroyed or reused (the
// next append re-grows from nil).  Bool still packs its 1-byte-per-value buffer
// into a bitmap, which requires a fresh allocation.
@(require_results)
builder_finish :: proc(
	b:         ^Primitive_Builder($T),
	allocator := context.allocator,
) -> (arr: Array, err: mem.Allocator_Error) {
	same_alloc := b.allocator.procedure == allocator.procedure && b.allocator.data == allocator.data

	// Validity bitmap — only materialised when there are nulls.
	bitmap_buf: Buffer
	if b.null_count > 0 {
		bm_size := bitmap_byte_count(b.length)
		active_bytes := (b.length + 7) / 8
		rem := uint(b.length) & 7
		if same_alloc {
			if b.bm_cap < bm_size {
				_builder_grow_bitmap(b, bm_size)
			}
			if rem != 0 && active_bytes > 0 {
				b.bitmap[active_bytes - 1] &= u8((1 << rem) - 1)
			}
			if bm_size > active_bytes {
				mem.zero(rawptr(b.bitmap[active_bytes:]), bm_size - active_bytes)
			}
			bitmap_buf = Buffer{
				data      = b.bitmap,
				size      = bm_size,
				capacity  = b.bm_cap,
				allocator = b.allocator,
			}
			b.bitmap = nil
			b.bm_cap = 0
		} else {
			bitmap_buf = buffer_make(bm_size, allocator) or_return
			copy_bytes := min(active_bytes, b.bm_cap)
			if copy_bytes > 0 && b.bitmap != nil {
				mem.copy_non_overlapping(rawptr(bitmap_buf.data), rawptr(b.bitmap), copy_bytes)
			}
			if active_bytes > copy_bytes {
				mem.set(rawptr(bitmap_buf.data[copy_bytes:]), 0xFF, active_bytes - copy_bytes)
			}
			if rem != 0 && active_bytes > 0 {
				bitmap_buf.data[active_bytes - 1] &= u8((1 << rem) - 1)
			}
		}
	} else if same_alloc && b.bitmap != nil {
		mem.free_with_size(rawptr(b.bitmap), b.bm_cap, b.allocator)
		b.bitmap = nil
		b.bm_cap = 0
	}

	// Data buffer.
	data_buf: Buffer
	when T == bool {
		// Bool arrays are bit-packed, so the [^]bool scratch can't be reused.
		n_data_bytes := bitmap_byte_count(b.length)
		buf, buf_err := buffer_make(n_data_bytes, allocator)
		if buf_err != nil { buffer_free(&bitmap_buf); err = buf_err; return }
		for i in 0..<b.length {
			if b.data[i] { buf.data[i >> 3] |= 1 << u8(i & 7) }
		}
		data_buf = buf
		if b.data != nil {
			mem.free_with_size(rawptr(b.data), b.cap * size_of(T), b.allocator)
			b.data = nil
			b.cap  = 0
		}
		if b.bitmap != nil {
			mem.free_with_size(rawptr(b.bitmap), b.bm_cap, b.allocator)
			b.bitmap = nil
			b.bm_cap = 0
		}
	} else {
		if same_alloc {
			if b.data == nil {
				buf, buf_err := buffer_make_uninit(0, b.allocator)
				if buf_err != nil { buffer_free(&bitmap_buf); err = buf_err; return }
				data_buf = buf
			} else {
				// Transfer ownership of the value buffer directly — no copy.
				data_buf = Buffer{
					data      = cast([^]u8)b.data,
					size      = b.length * size_of(T),
					capacity  = b.cap * size_of(T),
					allocator = b.allocator,
				}
				b.data = nil
				b.cap  = 0
			}
		} else {
			n_data_bytes := b.length * size_of(T)
			buf, buf_err := buffer_make_uninit(n_data_bytes, allocator)
			if buf_err != nil { buffer_free(&bitmap_buf); err = buf_err; return }
			if n_data_bytes > 0 && b.data != nil {
				mem.copy_non_overlapping(rawptr(buf.data), rawptr(b.data), n_data_bytes)
			}
			data_buf = buf
			if b.data != nil {
				mem.free_with_size(rawptr(b.data), b.cap * size_of(T), b.allocator)
				b.data = nil
				b.cap  = 0
			}
			if b.bitmap != nil {
				mem.free_with_size(rawptr(b.bitmap), b.bm_cap, b.allocator)
				b.bitmap = nil
				b.bm_cap = 0
			}
		}
	}

	arr = Array{
		type       = _data_type_for(T),
		length     = b.length,
		null_count = b.null_count,
		offset     = 0,
		buffers    = {bitmap_buf, data_buf, {}},
	}
	b.length     = 0
	b.null_count = 0
	b.bm_cap     = 0
	return
}

// Produce an immutable Array with an explicit DataType override (e.g. Decimal64_Type / Decimal128_Type).
@(require_results)
builder_finish_as :: proc(
	b:         ^Primitive_Builder($T),
	dt:        DataType,
	allocator := context.allocator,
) -> (arr: Array, err: mem.Allocator_Error) {
	assert(type_byte_width(dt) == size_of(T), "builder_finish_as: DataType byte width must match size_of(T)")
	arr, err = builder_finish(b, allocator)
	if err == nil {
		arr.type = dt
	}
	return
}

builder_reset :: proc(b: ^Primitive_Builder($T)) {
	if b.bitmap != nil { mem.set(rawptr(b.bitmap), 0xFF, b.bm_cap) }
	b.null_count = 0
	b.length     = 0
}

builder_destroy :: proc(b: ^Primitive_Builder($T)) {
	if b.data   != nil { mem.free_with_size(rawptr(b.data),   b.cap * size_of(T), b.allocator) }
	if b.bitmap != nil { mem.free_with_size(rawptr(b.bitmap), b.bm_cap,           b.allocator) }
	b^ = {}
}

// ── growth helpers ────────────────────────────────────────────────────────────

_builder_grow_data :: proc(b: ^Primitive_Builder($T)) {
	assert(b.cap <= max(int) / 2, "Primitive_Builder: capacity overflow")
	new_cap := max(b.cap * 2, 16)
	elem_sz := max(size_of(T), 1)
	assert(new_cap <= max(int) / elem_sz, "Primitive_Builder: byte size overflow")
	new_raw, err := mem.resize_non_zeroed(rawptr(b.data), b.cap * size_of(T), new_cap * size_of(T), ARROW_ALIGNMENT, b.allocator)
	assert(err == .None, "_builder_grow_data: allocation failed")
	b.data = cast([^]T)new_raw
	b.cap  = new_cap
}

_builder_grow_bitmap :: proc(b: ^Primitive_Builder($T), needed: int) {
	assert(needed <= max(int) - ARROW_ALIGNMENT, "Primitive_Builder: bitmap needed overflow")
	doubled := b.bm_cap * 2 if b.bm_cap <= max(int) / 2 else max(int) - ARROW_ALIGNMENT
	new_cap := align_up(max(doubled, needed), ARROW_ALIGNMENT)
	new_raw, err := mem.resize_non_zeroed(rawptr(b.bitmap), b.bm_cap, new_cap, ARROW_ALIGNMENT, b.allocator)
	assert(err == .None, "_builder_grow_bitmap: allocation failed")
	if new_cap > b.bm_cap {
		mem.set(rawptr((cast([^]u8)new_raw)[b.bm_cap:]), 0xFF, new_cap - b.bm_cap)
	}
	b.bitmap = cast([^]u8)new_raw
	b.bm_cap = new_cap
}

// ── type helpers ──────────────────────────────────────────────────────────────

_data_type_for :: proc($T: typeid) -> DataType {
	when T == bool { return Bool_Type{} }
	else when T == i8  { return Int8_Type{} }
	else when T == i16 { return Int16_Type{} }
	else when T == i32 { return Int32_Type{} }
	else when T == i64 { return Int64_Type{} }
	else when T == u8  { return UInt8_Type{} }
	else when T == u16 { return UInt16_Type{} }
	else when T == u32 { return UInt32_Type{} }
	else when T == u64 { return UInt64_Type{} }
	else when T == f32  { return Float32_Type{} }
	else when T == f64  { return Float64_Type{} }
	else when T == i128 { return Decimal128_Type{precision = 38, scale = 0} }
	else {
		#assert(false, "Primitive_Builder: unsupported type T")
		return {}
	}
}
