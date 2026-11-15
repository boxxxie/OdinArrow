package skadi

import "core:mem"

// Run-end encoding (REE): a numeric column of `length` logical elements stored
// as `k` runs, where run i spans logical indices [run_ends[i-1], run_ends[i])
// and holds the value `values[i]`. run_ends is strictly increasing and
// run_ends[k-1] == length.
//
// This breaks the plain Arrow value-buffer layout, but it is the foundation for
// *encoding-aware* kernels: a sum/min/max over an REE column is O(runs), not
// O(length), and the column itself is k·(4+sizeof(T)) bytes instead of
// length·sizeof(T). For data with long runs (sorted, grouped, sparse, or
// constant-heavy columns) that is a large reduction in both time and memory —
// the kernels never touch the elements that the encoding already collapsed.

RLE_Array :: struct($T: typeid) {
	run_ends:   []i32, // strictly increasing exclusive ends; last == length
	values:     []T,   // one value per run
	run_valid:  []u8,  // nil when null_count == 0; bit i == 1 iff run i is valid
	length:     int,   // logical length
	null_count: int,   // logical null count across all null runs
	allocator:  mem.Allocator,
}

// ── builder ─────────────────────────────────────────────────────────────────

RLE_Builder :: struct($T: typeid) {
	run_ends:    [dynamic]i32,
	values:      [dynamic]T,
	run_is_null: [dynamic]bool,
	length:      int,
	null_count:  int,
}

rle_builder_make :: proc($T: typeid, initial_runs := 64, allocator := context.allocator) -> RLE_Builder(T) {
	return RLE_Builder(T){
		run_ends    = make([dynamic]i32,  0, initial_runs, allocator),
		values      = make([dynamic]T,    0, initial_runs, allocator),
		run_is_null = make([dynamic]bool, 0, initial_runs, allocator),
	}
}

// Append one logical value, coalescing with the current run if it is equal.
rle_append :: proc(b: ^RLE_Builder($T), v: T) {
	n := len(b.values)
	b.length += 1
	eq := false
	if n > 0 && !b.run_is_null[n-1] {
		when T == f32 || T == f64 {
			eq = b.values[n-1] == v || (v != v && b.values[n-1] != b.values[n-1])
		} else {
			eq = b.values[n-1] == v
		}
	}
	if eq {
		b.run_ends[n-1] = i32(b.length)   // extend the current run
	} else {
		append(&b.values, v)
		append(&b.run_ends, i32(b.length))
		append(&b.run_is_null, false)
	}
}

// Append one logical null, coalescing consecutive nulls into a single null run.
rle_append_null :: proc(b: ^RLE_Builder($T)) {
	n := len(b.values)
	b.length += 1
	b.null_count += 1
	if n > 0 && b.run_is_null[n-1] {
		b.run_ends[n-1] = i32(b.length)
	} else {
		zero: T
		append(&b.values, zero)
		append(&b.run_ends, i32(b.length))
		append(&b.run_is_null, true)
	}
}

rle_builder_finish :: proc(b: ^RLE_Builder($T), allocator := context.allocator) -> RLE_Array(T) {
	re := make([]i32, len(b.run_ends), allocator)
	vs := make([]T,   len(b.values),   allocator)
	copy(re, b.run_ends[:])
	copy(vs, b.values[:])
	var_bm: []u8
	if b.null_count > 0 {
		var_bm = make([]u8, (len(b.values) + 7) / 8, allocator)
		for is_null, idx in b.run_is_null {
			if !is_null {
				bitmap_set(raw_data(var_bm), idx)
			}
		}
	}
	return RLE_Array(T){
		run_ends   = re,
		values     = vs,
		run_valid  = var_bm,
		length     = b.length,
		null_count = b.null_count,
		allocator  = allocator,
	}
}

rle_builder_destroy :: proc(b: ^RLE_Builder($T)) {
	delete(b.run_ends)
	delete(b.values)
	delete(b.run_is_null)
	b^ = {}
}

rle_free :: proc(a: ^RLE_Array($T)) {
	delete(a.run_ends,  a.allocator)
	delete(a.values,    a.allocator)
	delete(a.run_valid, a.allocator)
	a^ = {}
}

@(private="file")
_rle_run_is_valid :: #force_inline proc "contextless" (a: ^RLE_Array($T), run_idx: int) -> bool {
	if a.run_valid == nil { return true }
	return bitmap_get(raw_data(a.run_valid), run_idx)
}

// ── encoding-aware kernels (O(runs)) ────────────────────────────────────────

rle_run_count :: proc(a: ^RLE_Array($T)) -> int { return len(a.values) }

// Number of bytes the encoded column occupies (vs length·sizeof(T) decoded).
rle_encoded_bytes :: proc(a: ^RLE_Array($T)) -> int {
	return len(a.run_ends) * size_of(i32) + len(a.values) * size_of(T) + len(a.run_valid)
}

// Sum of the logical column: Σ value_i · run_length_i, one multiply per run.
rle_sum :: proc(a: ^RLE_Array($T)) -> f64 {
	sum: f64
	prev := i32(0)
	for i in 0..<len(a.values) {
		if _rle_run_is_valid(a, i) {
			run_len := a.run_ends[i] - prev
			sum += f64(a.values[i]) * f64(run_len)
		}
		prev = a.run_ends[i]
	}
	return sum
}

// Min/Max of the logical column == min/max over the distinct run values, since
// every logical element equals one of them.
rle_min_max :: proc(a: ^RLE_Array($T)) -> (lo: f64, hi: f64, ok: bool) {
	if len(a.values) == 0 { return }
	mn, mx: T
	seen := false
	for i in 0..<len(a.values) {
		if !_rle_run_is_valid(a, i) { continue }
		v := a.values[i]
		if v != v { continue }
		if !seen {
			mn = v
			mx = v
			seen = true
		} else {
			if v < mn { mn = v }
			if v > mx { mx = v }
		}
	}
	if !seen { return }
	return f64(mn), f64(mx), true
}

// ── accessors / materialisation ─────────────────────────────────────────────

@(private="file")
_rle_find_run :: proc "contextless" (run_ends: []i32, i: int) -> int {
	lo, hi := 0, len(run_ends)
	for lo < hi {
		mid := (lo + hi) / 2
		if int(run_ends[mid]) <= i { lo = mid + 1 } else { hi = mid }
	}
	return lo
}

rle_is_null :: proc(a: ^RLE_Array($T), i: int) -> bool {
	assert(i >= 0 && i < a.length, "rle_is_null: out of bounds")
	if a.run_valid == nil { return false }
	return !_rle_run_is_valid(a, _rle_find_run(a.run_ends, i))
}

// Logical element at index i (binary search over run_ends).
rle_get :: proc(a: ^RLE_Array($T), i: int) -> T {
	assert(i >= 0 && i < a.length, "rle_get: out of bounds")
	run_idx := _rle_find_run(a.run_ends, i)
	assert(a.run_valid == nil || _rle_run_is_valid(a, run_idx), "rle_get: element is null")
	return a.values[run_idx]
}

// Like rle_get, but returns (val, false) when element i is null.
rle_try_get :: proc(a: ^RLE_Array($T), i: int) -> (val: T, valid: bool) {
	assert(i >= 0 && i < a.length, "rle_try_get: out of bounds")
	run_idx := _rle_find_run(a.run_ends, i)
	if !_rle_run_is_valid(a, run_idx) { return {}, false }
	return a.values[run_idx], true
}

// Expand the REE column back into a plain Arrow Array (the escape hatch when a
// dense representation is actually required).
rle_decode :: proc(a: ^RLE_Array($T), allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	data_buf := buffer_make(a.length * size_of(T), allocator) or_return
	bitmap_buf: Buffer
	if a.null_count > 0 {
		bm, bm_err := buffer_make(bitmap_byte_count(a.length), allocator)
		if bm_err != nil {
			buffer_free(&data_buf)
			return {}, bm_err
		}
		bitmap_buf = bm
	}
	dst := cast([^]T)data_buf.data
	prev := i32(0)
	for i in 0..<len(a.values) {
		v := a.values[i]
		valid := _rle_run_is_valid(a, i)
		for j in prev..<a.run_ends[i] {
			dst[j] = v
			if a.null_count > 0 && valid {
				bitmap_set(bitmap_buf.data, int(j))
			}
		}
		prev = a.run_ends[i]
	}
	arr = Array{
		type       = _data_type_for(T),
		length     = a.length,
		null_count = a.null_count,
		buffers    = {bitmap_buf, data_buf, {}},
	}
	return
}

// Run-end-encode a plain numeric Array (coalescing equal neighbours).
rle_encode :: proc(src: ^Array, $T: typeid, allocator := context.allocator) -> RLE_Array(T) {
	assert(src.type == _data_type_for(T), "rle_encode: source type mismatch")
	b := rle_builder_make(T, 64, allocator)
	defer rle_builder_destroy(&b)
	data := cast([^]T)src.buffers[1].data
	off  := src.offset
	has_nulls := src.buffers[0].data != nil
	for i in 0..<src.length {
		if has_nulls && array_is_null(src, i) {
			rle_append_null(&b)
		} else {
			rle_append(&b, data[off + i])
		}
	}
	return rle_builder_finish(&b, allocator)
}
