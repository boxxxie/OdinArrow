package skadi

import "base:intrinsics"
import "base:runtime"
import "core:mem"

// ── String_Builder ────────────────────────────────────────────────────────────
//
// Produces Arrow UTF-8 (i32-offset) arrays.
// Buffer layout: [validity_bitmap, i32_offsets, utf8_bytes]
//
// offsets always contains length+1 values; it is pre-seeded with [0].

// Internal storage uses raw buffers (like Primitive_Builder) rather than
// [dynamic] so each append is a direct indexed write + memcpy instead of going
// through the dynamic-array runtime. finish() then hands those buffers straight
// to the Array (zero-copy). `offsets` always holds length+1 entries with
// offsets[0] == 0.
_Var_Builder :: struct($Offset: typeid) {
	data:       [^]u8,    // raw payload bytes
	data_len:   int,
	data_cap:   int,
	offsets:    [^]Offset, // length+1 valid entries; offsets[0] == 0
	off_cap:    int,      // capacity in Offset elements
	bitmap:     [^]u8,    // validity (0xFF-filled on first null); allocated lazily
	bm_cap:     int,
	null_count: int,
	length:     int,
	allocator:  mem.Allocator,
}

String_Builder       :: struct { using raw: _Var_Builder(i32) }
Binary_Builder       :: struct { using raw: _Var_Builder(i32) }
Large_String_Builder :: struct { using raw: _Var_Builder(i64) }
Large_Binary_Builder :: struct { using raw: _Var_Builder(i64) }

// ── String_Builder ────────────────────────────────────────────────────────────
//
// Produces Arrow UTF-8 (i32-offset) arrays.
// Buffer layout: [validity_bitmap, i32_offsets, utf8_bytes]

string_builder_make :: proc(initial_cap := 64, allocator := context.allocator, initial_data_cap := -1) -> String_Builder {
	return String_Builder{ raw = _vb_make(i32, initial_cap, initial_data_cap, allocator) }
}

string_builder_reserve_data :: #force_inline proc(b: ^String_Builder, total_bytes: int) {
	if total_bytes > b.data_cap { _vb_grow_data(&b.raw, total_bytes) }
}

string_builder_append :: #force_inline proc(b: ^String_Builder, s: string) {
	_vb_append(&b.raw, transmute([]u8)s)
}

string_builder_append_null :: #force_inline proc(b: ^String_Builder) {
	_vb_append_null(&b.raw)
}

// Zero-copy: hands the data/offsets/validity buffers directly to the Array and
// leaves the builder empty (re-grows from nil on the next append).
@(require_results)
string_builder_finish :: proc(b: ^String_Builder, allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	return _vb_finish(&b.raw, String_Type{}, allocator)
}

string_builder_reset :: proc(b: ^String_Builder) {
	_vb_reset(&b.raw)
}

string_builder_destroy :: proc(b: ^String_Builder) {
	_vb_destroy(&b.raw)
}

// ── Binary_Builder ────────────────────────────────────────────────────────────
// Identical to String_Builder except produces Binary_Type arrays.

binary_builder_make :: proc(initial_cap := 64, allocator := context.allocator, initial_data_cap := -1) -> Binary_Builder {
	return Binary_Builder{ raw = _vb_make(i32, initial_cap, initial_data_cap, allocator) }
}

binary_builder_reserve_data :: #force_inline proc(b: ^Binary_Builder, total_bytes: int) {
	if total_bytes > b.data_cap { _vb_grow_data(&b.raw, total_bytes) }
}

binary_builder_append :: #force_inline proc(b: ^Binary_Builder, bytes: []u8) {
	_vb_append(&b.raw, bytes)
}

binary_builder_append_null :: #force_inline proc(b: ^Binary_Builder) {
	_vb_append_null(&b.raw)
}

binary_builder_reset :: proc(b: ^Binary_Builder) {
	_vb_reset(&b.raw)
}

@(require_results)
binary_builder_finish :: proc(b: ^Binary_Builder, allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	return _vb_finish(&b.raw, Binary_Type{}, allocator)
}

binary_builder_destroy :: proc(b: ^Binary_Builder) {
	_vb_destroy(&b.raw)
}

// ── Large_String_Builder ──────────────────────────────────────────────────────
// Produces Arrow LargeUtf8 (i64-offset) arrays, lifting the 2 GiB total-bytes limit.
// Buffer layout: [validity_bitmap, i64_offsets, utf8_bytes]

large_string_builder_make :: proc(initial_cap := 64, allocator := context.allocator, initial_data_cap := -1) -> Large_String_Builder {
	return Large_String_Builder{ raw = _vb_make(i64, initial_cap, initial_data_cap, allocator) }
}

large_string_builder_reserve_data :: #force_inline proc(b: ^Large_String_Builder, total_bytes: int) {
	if total_bytes > b.data_cap { _vb_grow_data(&b.raw, total_bytes) }
}

large_string_builder_append :: #force_inline proc(b: ^Large_String_Builder, s: string) {
	_vb_append(&b.raw, transmute([]u8)s)
}

large_string_builder_append_null :: #force_inline proc(b: ^Large_String_Builder) {
	_vb_append_null(&b.raw)
}

@(require_results)
large_string_builder_finish :: proc(b: ^Large_String_Builder, allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	return _vb_finish(&b.raw, Large_String_Type{}, allocator)
}

large_string_builder_reset :: proc(b: ^Large_String_Builder) {
	_vb_reset(&b.raw)
}

large_string_builder_destroy :: proc(b: ^Large_String_Builder) {
	_vb_destroy(&b.raw)
}

// ── Large_Binary_Builder ──────────────────────────────────────────────────────
// Identical to Large_String_Builder except produces Large_Binary_Type arrays.

large_binary_builder_make :: proc(initial_cap := 64, allocator := context.allocator, initial_data_cap := -1) -> Large_Binary_Builder {
	return Large_Binary_Builder{ raw = _vb_make(i64, initial_cap, initial_data_cap, allocator) }
}

large_binary_builder_reserve_data :: #force_inline proc(b: ^Large_Binary_Builder, total_bytes: int) {
	if total_bytes > b.data_cap { _vb_grow_data(&b.raw, total_bytes) }
}

large_binary_builder_append :: #force_inline proc(b: ^Large_Binary_Builder, bytes: []u8) {
	_vb_append(&b.raw, bytes)
}

large_binary_builder_append_null :: #force_inline proc(b: ^Large_Binary_Builder) {
	_vb_append_null(&b.raw)
}

large_binary_builder_reset :: proc(b: ^Large_Binary_Builder) {
	_vb_reset(&b.raw)
}

@(require_results)
large_binary_builder_finish :: proc(b: ^Large_Binary_Builder, allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	return _vb_finish(&b.raw, Large_Binary_Type{}, allocator)
}

large_binary_builder_destroy :: proc(b: ^Large_Binary_Builder) {
	_vb_destroy(&b.raw)
}

// ── shared parametric implementation ──────────────────────────────────────────

_vb_make :: proc($Offset: typeid, initial_cap: int, initial_data_cap: int, allocator: mem.Allocator) -> _Var_Builder(Offset) {
	init_cap := max(initial_cap, 1)
	assert(init_cap <= max(int) / 8, "_vb_make: capacity overflow")
	data_cap := initial_data_cap if initial_data_cap >= 0 else init_cap * 8
	when Offset == i32 {
		data_cap = min(data_cap, int(max(i32)))
	}
	off_cap := init_cap + 1
	assert(off_cap <= max(int) / size_of(Offset), "_vb_make: offsets capacity overflow")
	data_ptr: [^]u8
	if data_cap > 0 {
		data_bytes, data_err := mem.alloc_bytes_non_zeroed(data_cap, ARROW_ALIGNMENT, allocator)
		assert(data_err == .None, "_vb_make: data allocation failed")
		data_ptr = raw_data(data_bytes)
	}
	off_bytes, off_err := mem.alloc_bytes_non_zeroed(off_cap * size_of(Offset), ARROW_ALIGNMENT, allocator)
	assert(off_err == .None, "_vb_make: offsets allocation failed")
	b := _Var_Builder(Offset){
		data      = data_ptr,
		data_cap  = data_cap,
		offsets   = cast([^]Offset)raw_data(off_bytes),
		off_cap   = off_cap,
		allocator = allocator,
	}
	b.offsets[0] = 0
	return b
}

_vb_append :: #force_inline proc(b: ^_Var_Builder($Offset), bytes: []u8) {
	n := len(bytes)
	when Offset == i32 {
		if n > int(max(i32)) - b.data_len {
			panic("var_length builder: data exceeds i32 offset limit")
		}
	} else {
		if n > max(int) - b.data_len {
			panic("var_length builder: data length overflow")
		}
	}
	if n > b.data_cap - b.data_len { _vb_grow_data(b, b.data_len + n) }
	if b.length + 1 >= b.off_cap   { _vb_grow_offsets(b) }
	if n > 0 { mem.copy_non_overlapping(rawptr(&b.data[b.data_len]), rawptr(raw_data(bytes)), n) }
	b.data_len += n
	b.offsets[b.length + 1] = Offset(b.data_len)
	b.length += 1
}

_vb_append_null :: #force_inline proc(b: ^_Var_Builder($Offset)) {
	if b.length + 1 >= b.off_cap { _vb_grow_offsets(b) }
	byte_i := b.length >> 3
	if byte_i >= b.bm_cap {
		_vb_grow_bitmap(b, max(bitmap_byte_count(b.off_cap), byte_i + 1))
	}
	b.bitmap[byte_i] &= ~(1 << u8(b.length & 7))
	b.offsets[b.length + 1] = Offset(b.data_len)
	b.null_count += 1
	b.length += 1
}

_vb_finish :: proc(b: ^_Var_Builder($Offset), data_type: DataType, allocator: mem.Allocator) -> (arr: Array, err: mem.Allocator_Error) {
	same_alloc := b.allocator.procedure == allocator.procedure && b.allocator.data == allocator.data
	if same_alloc {
		if b.offsets == nil {
			off_bytes, off_err := mem.alloc(ARROW_ALIGNMENT, ARROW_ALIGNMENT, b.allocator)
			if off_err != .None {
				return {}, off_err
			}
			b.offsets = cast([^]Offset)off_bytes
			b.off_cap = ARROW_ALIGNMENT / size_of(Offset)
			b.offsets[0] = 0
		}
		if b.data == nil {
			data_bytes, data_err := mem.alloc_bytes_non_zeroed(ARROW_ALIGNMENT, ARROW_ALIGNMENT, b.allocator)
			if data_err != .None {
				return {}, data_err
			}
			b.data = raw_data(data_bytes)
			b.data_cap = ARROW_ALIGNMENT
		}
		bitmap_buf: Buffer
		if b.null_count > 0 {
			bm_size := bitmap_byte_count(b.length)
			if b.bm_cap < bm_size {
				_vb_grow_bitmap(b, bm_size)
			}
			active_bytes := (b.length + 7) / 8
			rem := uint(b.length) & 7
			if rem != 0 && active_bytes > 0 {
				b.bitmap[active_bytes - 1] &= u8((1 << rem) - 1)
			}
			if bm_size > active_bytes {
				mem.zero(rawptr(b.bitmap[active_bytes:]), bm_size - active_bytes)
			}
			bitmap_buf = Buffer{ data = b.bitmap, size = bm_size, capacity = b.bm_cap, allocator = b.allocator }
			b.bitmap = nil
			b.bm_cap = 0
		} else if b.bitmap != nil {
			mem.free_with_size(rawptr(b.bitmap), b.bm_cap, b.allocator)
			b.bitmap = nil
			b.bm_cap = 0
		}
		off_buf := Buffer{
			data      = cast([^]u8)b.offsets,
			size      = (b.length + 1) * size_of(Offset),
			capacity  = b.off_cap * size_of(Offset),
			allocator = b.allocator,
		}
		b.offsets = nil
		b.off_cap = 0
		data_buf := Buffer{ data = b.data, size = b.data_len, capacity = b.data_cap, allocator = b.allocator }
		b.data = nil
		b.data_cap = 0

		arr = Array{
			type       = data_type,
			length     = b.length,
			null_count = b.null_count,
			offset     = 0,
			buffers    = {bitmap_buf, off_buf, data_buf},
		}
		b.length     = 0
		b.data_len   = 0
		b.null_count = 0
		return
	}

	bitmap_buf: Buffer
	if b.null_count > 0 {
		bm_size := bitmap_byte_count(b.length)
		bitmap_buf = buffer_make(bm_size, allocator) or_return
		active_bytes := (b.length + 7) / 8
		if active_bytes > 0 && b.bitmap != nil {
			mem.copy_non_overlapping(rawptr(bitmap_buf.data), rawptr(b.bitmap), active_bytes)
		}
		rem := uint(b.length) & 7
		if rem != 0 && active_bytes > 0 {
			bitmap_buf.data[active_bytes - 1] &= u8((1 << rem) - 1)
		}
	}

	off_size := (b.length + 1) * size_of(Offset)
	off_buf, off_err := buffer_make_uninit(off_size, allocator)
	if off_err != .None {
		buffer_free(&bitmap_buf)
		return {}, off_err
	}
	if b.offsets != nil {
		mem.copy_non_overlapping(rawptr(off_buf.data), rawptr(b.offsets), off_size)
	} else {
		(cast([^]Offset)off_buf.data)[0] = 0
	}

	data_buf, data_err := buffer_make_uninit(b.data_len, allocator)
	if data_err != .None {
		buffer_free(&bitmap_buf)
		buffer_free(&off_buf)
		return {}, data_err
	}
	if b.data_len > 0 && b.data != nil {
		mem.copy_non_overlapping(rawptr(data_buf.data), rawptr(b.data), b.data_len)
	}

	if b.data    != nil { mem.free_with_size(rawptr(b.data),    b.data_cap,                b.allocator) }
	if b.offsets != nil { mem.free_with_size(rawptr(b.offsets), b.off_cap * size_of(Offset), b.allocator) }
	if b.bitmap  != nil { mem.free_with_size(rawptr(b.bitmap),  b.bm_cap,                  b.allocator) }
	b.data       = nil
	b.data_cap   = 0
	b.offsets    = nil
	b.off_cap    = 0
	b.bitmap     = nil
	b.bm_cap     = 0

	arr = Array{
		type       = data_type,
		length     = b.length,
		null_count = b.null_count,
		offset     = 0,
		buffers    = {bitmap_buf, off_buf, data_buf},
	}
	b.length     = 0
	b.data_len   = 0
	b.null_count = 0
	return
}

_vb_reset :: proc(b: ^_Var_Builder($Offset)) {
	if b.bitmap != nil && b.null_count > 0 { mem.set(rawptr(b.bitmap), 0xFF, b.bm_cap) }
	b.data_len   = 0
	b.null_count = 0
	b.length     = 0
	if b.offsets != nil { b.offsets[0] = 0 }
}

_vb_destroy :: proc(b: ^_Var_Builder($Offset)) {
	if b.data    != nil { mem.free_with_size(rawptr(b.data),    b.data_cap,                b.allocator) }
	if b.offsets != nil { mem.free_with_size(rawptr(b.offsets), b.off_cap * size_of(Offset), b.allocator) }
	if b.bitmap  != nil { mem.free_with_size(rawptr(b.bitmap),  b.bm_cap,                  b.allocator) }
	b^ = {}
}

_vb_grow_data :: proc(b: ^_Var_Builder($Offset), needed: int) {
	when Offset == i32 {
		if needed < b.data_len || needed > int(max(i32)) {
			panic("var_length builder: data exceeds i32 offset limit")
		}
	} else {
		if needed < b.data_len {
			panic("var_length builder: data length overflow")
		}
	}
	doubled := b.data_cap * 2 if b.data_cap <= max(int) / 2 else max(int)
	new_cap := max(doubled, needed, ARROW_ALIGNMENT)
	when Offset == i32 {
		new_cap = min(new_cap, int(max(i32)))
	}
	if b.data_len == 0 {
		if b.data != nil {
			mem.free_with_size(rawptr(b.data), b.data_cap, b.allocator)
		}
		raw, err := mem.alloc_bytes_non_zeroed(new_cap, ARROW_ALIGNMENT, b.allocator)
		assert(err == .None, "_vb_grow_data: allocation failed")
		b.data     = raw_data(raw)
		b.data_cap = new_cap
		return
	}
	new_raw, err := mem.resize_non_zeroed(rawptr(b.data), b.data_cap, new_cap, ARROW_ALIGNMENT, b.allocator)
	assert(err == .None, "_vb_grow_data: allocation failed")
	b.data     = cast([^]u8)new_raw
	b.data_cap = new_cap
}

_vb_grow_offsets :: proc(b: ^_Var_Builder($Offset)) {
	assert(b.off_cap <= max(int) / 2, "var_length builder: offsets capacity overflow")
	new_cap := max(b.off_cap * 2, 16)
	assert(new_cap <= max(int) / size_of(Offset), "var_length builder: offsets byte overflow")
	new_raw, err := mem.resize_non_zeroed(rawptr(b.offsets), b.off_cap * size_of(Offset), new_cap * size_of(Offset), ARROW_ALIGNMENT, b.allocator)
	assert(err == .None, "_vb_grow_offsets: allocation failed")
	if b.off_cap == 0 { (cast([^]Offset)new_raw)[0] = 0 }
	b.offsets = cast([^]Offset)new_raw
	b.off_cap = new_cap
}

_vb_grow_bitmap :: proc(b: ^_Var_Builder($Offset), needed: int) {
	assert(needed <= max(int) - ARROW_ALIGNMENT, "var_length builder: bitmap needed overflow")
	doubled := b.bm_cap * 2 if b.bm_cap <= max(int) / 2 else max(int) - ARROW_ALIGNMENT
	new_cap := align_up(max(doubled, needed), ARROW_ALIGNMENT)
	new_raw, err := mem.resize_non_zeroed(rawptr(b.bitmap), b.bm_cap, new_cap, ARROW_ALIGNMENT, b.allocator)
	assert(err == .None, "_vb_grow_bitmap: allocation failed")
	if new_cap > b.bm_cap {
		mem.set(rawptr((cast([^]u8)new_raw)[b.bm_cap:]), 0xFF, new_cap - b.bm_cap)
	}
	b.bitmap = cast([^]u8)new_raw
	b.bm_cap = new_cap
}

// ── Array accessors ───────────────────────────────────────────────────────────

@(private="file")
_vb_bounds_fail :: proc "contextless" (msg: string) -> ! {
	context = runtime.default_context()
	panic(msg)
}

// Zero-copy string view. Valid only while the Array is alive. Does NOT copy.
array_get_string :: #force_inline proc "contextless" (arr: ^Array, i: int) -> string {
	when ODIN_DEBUG {
		if i < 0 || i >= arr.length { _vb_bounds_fail("array_get_string: out of bounds") }
	}
	offsets := cast([^]i32)arr.buffers[1].data
	idx     := arr.offset + i
	start   := int(offsets[idx])
	end     := int(offsets[idx + 1])
	if start == end { return "" }
	return transmute(string)arr.buffers[2].data[start:end]
}

// Zero-copy binary slice. Valid only while the Array is alive. Does NOT copy.
array_get_binary :: #force_inline proc "contextless" (arr: ^Array, i: int) -> []u8 {
	when ODIN_DEBUG {
		if i < 0 || i >= arr.length { _vb_bounds_fail("array_get_binary: out of bounds") }
	}
	offsets := cast([^]i32)arr.buffers[1].data
	idx     := arr.offset + i
	start   := int(offsets[idx])
	end     := int(offsets[idx + 1])
	if start == end { return nil }
	return arr.buffers[2].data[start:end]
}

// Zero-copy string view into a LargeUtf8 (i64-offset) array. Does NOT copy.
array_get_large_string :: #force_inline proc "contextless" (arr: ^Array, i: int) -> string {
	when ODIN_DEBUG {
		if i < 0 || i >= arr.length { _vb_bounds_fail("array_get_large_string: out of bounds") }
	}
	offsets := cast([^]i64)arr.buffers[1].data
	idx     := arr.offset + i
	start   := int(offsets[idx])
	end     := int(offsets[idx + 1])
	if start == end { return "" }
	return transmute(string)arr.buffers[2].data[start:end]
}

// Zero-copy binary slice from a LargeBinary (i64-offset) array. Does NOT copy.
array_get_large_binary :: #force_inline proc "contextless" (arr: ^Array, i: int) -> []u8 {
	when ODIN_DEBUG {
		if i < 0 || i >= arr.length { _vb_bounds_fail("array_get_large_binary: out of bounds") }
	}
	offsets := cast([^]i64)arr.buffers[1].data
	idx     := arr.offset + i
	start   := int(offsets[idx])
	end     := int(offsets[idx + 1])
	if start == end { return nil }
	return arr.buffers[2].data[start:end]
}

// Hoisted zero-overhead view over a String_Type array for tight inner loops.
String_Array_View :: struct {
	offsets:     [^]i32,
	data:        [^]u8,
	null_bitmap: [^]u8,
	offset:      int,
	length:      int,
	null_count:  int,
}

array_string_view :: #force_inline proc "contextless" (arr: ^Array) -> String_Array_View {
	has_bm := arr.null_count != 0 && arr.buffers[0].data != nil
	return String_Array_View{
		offsets     = cast([^]i32)arr.buffers[1].data,
		data        = arr.buffers[2].data,
		null_bitmap = arr.buffers[0].data if has_bm else nil,
		offset      = arr.offset,
		length      = arr.length,
		null_count  = arr.null_count,
	}
}

string_view_is_null :: #force_inline proc "contextless" (v: ^String_Array_View, i: int) -> bool {
	return v.null_bitmap != nil && !bitmap_get(v.null_bitmap, v.offset + i)
}

string_view_len :: #force_inline proc "contextless" (v: ^String_Array_View, i: int) -> int {
	idx := v.offset + i
	return int(v.offsets[idx + 1] - v.offsets[idx])
}

string_view_get :: #force_inline proc "contextless" (v: ^String_Array_View, i: int) -> string {
	idx   := v.offset + i
	start := int(v.offsets[idx])
	end   := int(v.offsets[idx + 1])
	return transmute(string)v.data[start:end]
}

// Sum byte lengths of all valid elements using 64-bit word-wise validity scanning.
string_view_sum_lengths :: proc "contextless" (v: ^String_Array_View) -> i64 {
	n := v.length
	if n <= 0 { return 0 }
	if v.null_bitmap == nil || v.null_count == 0 {
		return i64(v.offsets[v.offset + n] - v.offsets[v.offset])
	}
	total: i64 = 0
	if v.offset == 0 {
		words := cast([^]u64)v.null_bitmap
		n_words := n / 64
		for w_idx in 0..<n_words {
			w := intrinsics.unaligned_load(&words[w_idx])
			base := w_idx * 64
			if w == ~u64(0) {
				total += i64(v.offsets[base + 64] - v.offsets[base])
			} else if w != 0 {
				for bits := w; bits != 0; bits &= bits - 1 {
					bit := int(intrinsics.count_trailing_zeros(bits))
					idx := base + bit
					total += i64(v.offsets[idx + 1] - v.offsets[idx])
				}
			}
		}
		for i := n_words * 64; i < n; i += 1 {
			if bitmap_get(v.null_bitmap, i) {
				total += i64(v.offsets[i + 1] - v.offsets[i])
			}
		}
		return total
	}
	for i in 0..<n {
		if bitmap_get(v.null_bitmap, v.offset + i) {
			idx := v.offset + i
			total += i64(v.offsets[idx + 1] - v.offsets[idx])
		}
	}
	return total
}

// Allocate the three buffers for a known-size i32-offset variable-length array
// (`String_Type` or `Binary_Type`). When `null_count == 0`, no validity bitmap is
// allocated (`bitmap_buf.data == nil`).
_varlen_alloc_buffers :: proc(
	out_len, total_bytes, null_count: int,
	allocator: mem.Allocator,
) -> (bitmap_buf, off_buf, data_buf: Buffer, err: mem.Allocator_Error) {
	if null_count > 0 {
		bitmap_buf = buffer_make(bitmap_byte_count(out_len), allocator) or_return
	}
	off_buf, err = buffer_make_uninit((out_len + 1) * size_of(i32), allocator)
	if err != nil {
		buffer_free(&bitmap_buf)
		return {}, {}, {}, err
	}
	data_buf, err = buffer_make_uninit(total_bytes, allocator)
	if err != nil {
		buffer_free(&bitmap_buf)
		buffer_free(&off_buf)
		return {}, {}, {}, err
	}
	return bitmap_buf, off_buf, data_buf, .None
}
