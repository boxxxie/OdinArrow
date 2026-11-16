package skadi

import "base:runtime"
import "core:mem"

// Dictionary encoding for low-cardinality string columns: the distinct values
// are stored once in a `dict` string array, and each logical element is an i32
// `code` indexing into it.
//
// The encoding-aware payoff is group-by / value_counts: the codes ARE the group
// ids, so counting occurrences is an integer histogram over the codes — O(n)
// integer increments with no string hashing or comparison at all. The same idea
// extends to grouped aggregation (sum a second column bucketed by code). This is
// what columnar engines exploit when a column arrives dictionary-encoded from
// storage (Parquet stores columns this way), where the encode cost is already
// paid and amortised across many queries.
//
// Separate type (not in the Arrow Array union); transcoded at an Arrow boundary.

DICT_NULL_CODE :: i32(-1)

Str_Dict_Array :: struct {
	dict:       Array, // string Array of the distinct non-null values
	codes:      []i32, // dictionary index per element, or DICT_NULL_CODE (-1)
	length:     int,
	null_count: int,
	allocator:  mem.Allocator,
}

String_Dict_Array :: Str_Dict_Array

str_dict_free :: proc(d: ^Str_Dict_Array) {
	array_free(&d.dict, d.allocator)
	if d.allocator.procedure != nil {
		delete(d.codes, d.allocator)
	}
	d^ = {}
}

// O(1) zero-copy slice of `d` over `[from, to)`. Shares dictionary and codes with parent.
str_dict_slice :: proc(d: Str_Dict_Array, from, to: int) -> Str_Dict_Array {
	assert(from >= 0 && to <= d.length && from <= to, "str_dict_slice: out of bounds")
	sub_codes := d.codes[from:to]
	nc := 0
	if d.null_count > 0 {
		for c in sub_codes {
			if c < 0 { nc += 1 }
		}
	}
	return Str_Dict_Array{
		dict       = array_slice(d.dict, 0, d.dict.length),
		codes      = sub_codes,
		length     = to - from,
		null_count = nc,
		allocator  = {},
	}
}

n_dict :: proc(d: ^Str_Dict_Array) -> int { return d.dict.length }

str_dict_is_null :: #force_inline proc(d: ^Str_Dict_Array, i: int) -> bool {
	assert(i >= 0 && i < d.length, "str_dict_is_null: out of bounds")
	return d.codes[i] < 0
}

@(private="file")
_Dict_Slot :: struct {
	hash: u32,
	code: i32,
}

@(private="file")
_str_fnv1a :: #force_inline proc "contextless" (s: string) -> u32 {
	h := u32(2166136261)
	for b in transmute([]u8)s {
		h = (h ~ u32(b)) * 16777619
	}
	return h
}

@(private="file")
_dict_slots_alloc :: proc(cap: int, allocator: mem.Allocator) -> []_Dict_Slot {
	slots := make([]_Dict_Slot, cap, allocator)
	for &sl in slots { sl.code = DICT_NULL_CODE }
	return slots
}

@(private="file")
_dict_slots_grow :: proc(old: []_Dict_Slot, allocator: mem.Allocator) -> []_Dict_Slot {
	new_cap := len(old) * 2
	mask := u32(new_cap - 1)
	new_slots := _dict_slots_alloc(new_cap, allocator)
	for sl in old {
		if sl.code < 0 { continue }
		p := int(sl.hash & mask)
		for new_slots[p].code >= 0 {
			p = (p + 1) & int(mask)
		}
		new_slots[p] = sl
	}
	delete(old, allocator)
	return new_slots
}

// Dictionary-encode a plain Arrow string array (deduplicating values).
str_dict_encode :: proc(src: ^Array, allocator := context.allocator) -> Str_Dict_Array {
	_, is_str := src.type.(String_Type)
	assert(is_str, "str_dict_encode: source must be String_Type")
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	n        := src.length
	src_bm   := src.buffers[0].data
	src_off  := cast([^]i32)src.buffers[1].data
	src_data := src.buffers[2].data
	off      := src.offset

	slots := _dict_slots_alloc(256, context.temp_allocator)
	defer delete(slots, context.temp_allocator)

	codes := make([]i32, n, allocator)
	db := string_builder_make(64, allocator)
	defer string_builder_destroy(&db)

	null_count := 0
	has_last   := false
	last_s     := ""
	last_code  := DICT_NULL_CODE

	for i in 0..<n {
		if src_bm != nil && !bitmap_get(src_bm, off + i) {
			codes[i] = DICT_NULL_CODE
			null_count += 1
			continue
		}
		s0 := int(src_off[off + i])
		s1 := int(src_off[off + i + 1])
		s  := s0 == s1 ? "" : transmute(string)src_data[s0:s1]

		if has_last && s == last_s {
			codes[i] = last_code
			continue
		}

		h := _str_fnv1a(s)
		mask := len(slots) - 1
		p := int(h) & mask
		code := DICT_NULL_CODE
		for {
			sl := slots[p]
			if sl.code < 0 {
				if db.length * 2 >= len(slots) {
					slots = _dict_slots_grow(slots, context.temp_allocator)
					mask  = len(slots) - 1
					p     = int(h) & mask
					for slots[p].code >= 0 { p = (p + 1) & mask }
				}
				code = i32(db.length)
				string_builder_append(&db, s)
				slots[p] = _Dict_Slot{ hash = h, code = code }
				break
			}
			if sl.hash == h {
				d0 := int(db.offsets[sl.code])
				d1 := int(db.offsets[sl.code + 1])
				cand := d0 == d1 ? "" : transmute(string)db.data[d0:d1]
				if cand == s {
					code = sl.code
					break
				}
			}
			p = (p + 1) & mask
		}
		codes[i]  = code
		has_last  = true
		last_s    = s
		last_code = code
	}

	dict, _ := string_builder_finish(&db, allocator)
	return Str_Dict_Array{
		dict       = dict,
		codes      = codes,
		length     = n,
		null_count = null_count,
		allocator  = allocator,
	}
}

// Zero-copy view of logical element i.
str_dict_get :: proc(d: ^Str_Dict_Array, i: int) -> string {
	assert(i >= 0 && i < d.length, "str_dict_get: out of bounds")
	c := d.codes[i]
	assert(c >= 0, "str_dict_get: element is null")
	return array_get_string(&d.dict, int(c))
}

str_dict_try_get :: proc(d: ^Str_Dict_Array, i: int) -> (val: string, valid: bool) {
	assert(i >= 0 && i < d.length, "str_dict_try_get: out of bounds")
	c := d.codes[i]
	if c < 0 { return "", false }
	return array_get_string(&d.dict, int(c)), true
}

// ── encoding-aware kernels ──────────────────────────────────────────────────

// value_counts: occurrences of each dictionary entry. counts[c] is the number
// of logical elements whose value is dict[c]. Pure integer histogram over the
// codes — no string work.
str_dict_value_counts :: proc(d: ^Str_Dict_Array, allocator := context.allocator) -> []i64 {
	counts := make([]i64, d.dict.length, allocator)
	for c in d.codes {
		if c >= 0 { counts[c] += 1 }
	}
	return counts
}

// group-by sum: sum the parallel numeric column `weights` bucketed by this
// column's dictionary code. out[c] = Σ weights[i] where codes[i] == c.
str_dict_group_sum :: proc(d: ^Str_Dict_Array, weights: ^Array, allocator := context.allocator) -> []f64 {
	out := make([]f64, d.dict.length, allocator)
	_codes_group_sum_dispatch(d.codes[:d.length], weights, out)
	return out
}

@(private="file")
_codes_group_sum_dispatch :: proc(codes: []i32, weights: ^Array, out: []f64) {
	switch _ in weights.type {
	case Int8_Type:    _codes_group_sum_typed(codes, weights, out, i8)
	case Int16_Type:   _codes_group_sum_typed(codes, weights, out, i16)
	case Int32_Type:   _codes_group_sum_typed(codes, weights, out, i32)
	case Int64_Type:   _codes_group_sum_typed(codes, weights, out, i64)
	case UInt8_Type:   _codes_group_sum_typed(codes, weights, out, u8)
	case UInt16_Type:  _codes_group_sum_typed(codes, weights, out, u16)
	case UInt32_Type:  _codes_group_sum_typed(codes, weights, out, u32)
	case UInt64_Type:  _codes_group_sum_typed(codes, weights, out, u64)
	case Float32_Type: _codes_group_sum_typed(codes, weights, out, f32)
	case Float64_Type: _codes_group_sum_typed(codes, weights, out, f64)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("dict_group_sum: weights must be numeric")
	}
}

@(private="file")
_codes_group_sum_typed :: proc(codes: []i32, weights: ^Array, out: []f64, $T: typeid) {
	wdata := cast([^]T)weights.buffers[1].data
	woff := weights.offset
	w_nulls := weights.buffers[0].data != nil
	n := min(len(codes), weights.length)
	for i in 0..<n {
		c := codes[i]
		if c < 0 { continue }
		if w_nulls && !array_is_valid(weights, i) { continue }
		out[c] += f64(wdata[woff + i])
	}
}

// Expand back into a plain Arrow string array.
str_dict_decode :: proc(d: ^Str_Dict_Array, allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	n         := d.length
	d_off     := d.dict.offset
	dict_off  := cast([^]i32)d.dict.buffers[1].data
	dict_data := d.dict.buffers[2].data

	null_count  := 0
	total_bytes := 0
	for i in 0..<n {
		c := d.codes[i]
		if c < 0 {
			null_count += 1
		} else {
			di   := d_off + int(c)
			slen := int(dict_off[di + 1] - dict_off[di])
			assert(slen <= int(max(i32)) - total_bytes, "str_dict_decode: data exceeds i32 offset limit")
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
		c := d.codes[i]
		if c < 0 {
			dst_off[i + 1] = i32(write_pos)
		} else {
			di      := d_off + int(c)
			s_start := int(dict_off[di])
			s_end   := int(dict_off[di + 1])
			slen    := s_end - s_start
			if slen > 0 {
				mem.copy_non_overlapping(rawptr(&dst_data[write_pos]), rawptr(&dict_data[s_start]), slen)
				write_pos += slen
			}
			dst_off[i + 1] = i32(write_pos)
			if dst_bm != nil { bitmap_set(dst_bm, i) }
		}
	}

	arr = Array{
		type       = String_Type{},
		length     = n,
		null_count = null_count,
		buffers    = {bitmap_buf, off_buf, data_buf},
	}
	return
}

// ── generic numeric dictionary ──────────────────────────────────────────────

Dict_Array :: struct($T: typeid) {
	dictionary: []T,
	codes:      []i32, // dictionary index per element, or DICT_NULL_CODE (-1)
	length:     int,
	null_count: int,
	allocator:  mem.Allocator,
}

dict_free :: proc(d: ^Dict_Array($T)) {
	if d.allocator.procedure != nil {
		delete(d.dictionary, d.allocator)
		delete(d.codes, d.allocator)
	}
	d^ = {}
}

// O(1) zero-copy slice of numeric `Dict_Array(T)` over `[from, to)`.
dict_slice :: proc(d: Dict_Array($T), from, to: int) -> Dict_Array(T) {
	assert(from >= 0 && to <= d.length && from <= to, "dict_slice: out of bounds")
	sub_codes := d.codes[from:to]
	nc := 0
	if d.null_count > 0 {
		for c in sub_codes {
			if c < 0 { nc += 1 }
		}
	}
	return Dict_Array(T){
		dictionary = d.dictionary,
		codes      = sub_codes,
		length     = to - from,
		null_count = nc,
		allocator  = {},
	}
}

dict_size :: proc(d: ^Dict_Array($T)) -> int { return len(d.dictionary) }

dict_is_null :: #force_inline proc(d: ^Dict_Array($T), i: int) -> bool {
	assert(i >= 0 && i < d.length, "dict_is_null: out of bounds")
	return d.codes[i] < 0
}

@(private="file")
_num_hash :: #force_inline proc "contextless" (v: $T) -> u32 {
	h: u64
	when T == f32 {
		norm := v == 0 ? f32(0) : v
		h = u64(transmute(u32)norm)
	} else when T == f64 {
		norm := v == 0 ? f64(0) : v
		h = transmute(u64)norm
	} else when T == u64 {
		h = v
	} else {
		h = u64(v)
	}
	h ~= h >> 33
	h *= 0xff51afd7ed558ccd
	h ~= h >> 33
	return u32(h)
}

dict_encode :: proc(src: ^Array, $T: typeid, allocator := context.allocator) -> Dict_Array(T) {
	assert(src.type == _data_type_for(T), "dict_encode: source type mismatch")
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	n := src.length
	when T == u8 {
		data := src.buffers[1].data
	} else {
		data := cast([^]T)src.buffers[1].data
	}
	src_bm := src.buffers[0].data
	off    := src.offset

	slots := _dict_slots_alloc(256, context.temp_allocator)
	defer delete(slots, context.temp_allocator)

	codes := make([]i32, n, allocator)
	dyn := make([dynamic]T, 0, 64, context.temp_allocator)
	defer delete(dyn)
	null_count := 0
	nan_code   := DICT_NULL_CODE
	has_last   := false
	last_v:     T
	last_code  := DICT_NULL_CODE

	for i in 0..<n {
		if src_bm != nil && !bitmap_get(src_bm, off + i) {
			codes[i] = DICT_NULL_CODE
			null_count += 1
			continue
		}
		v := data[off + i]
		when T == f32 || T == f64 {
			if v != v {
				if nan_code < 0 {
					nan_code = i32(len(dyn))
					append(&dyn, v)
				}
				codes[i] = nan_code
				continue
			}
		} else {
			_ = nan_code
		}

		if has_last && v == last_v {
			codes[i] = last_code
			continue
		}

		h := _num_hash(v)
		mask := len(slots) - 1
		p := int(h) & mask
		code := DICT_NULL_CODE
		for {
			sl := slots[p]
			if sl.code < 0 {
				if len(dyn) * 2 >= len(slots) {
					slots = _dict_slots_grow(slots, context.temp_allocator)
					mask  = len(slots) - 1
					p     = int(h) & mask
					for slots[p].code >= 0 { p = (p + 1) & mask }
				}
				code = i32(len(dyn))
				append(&dyn, v)
				slots[p] = _Dict_Slot{ hash = h, code = code }
				break
			}
			if sl.hash == h && dyn[sl.code] == v {
				code = sl.code
				break
			}
			p = (p + 1) & mask
		}
		codes[i]  = code
		has_last  = true
		last_v    = v
		last_code = code
	}
	dict := make([]T, len(dyn), allocator)
	copy(dict, dyn[:])
	return Dict_Array(T){
		dictionary = dict,
		codes      = codes,
		length     = n,
		null_count = null_count,
		allocator  = allocator,
	}
}

dict_get :: proc(d: ^Dict_Array($T), i: int) -> T {
	assert(i >= 0 && i < d.length, "dict_get: out of bounds")
	c := d.codes[i]
	assert(c >= 0, "dict_get: element is null")
	return d.dictionary[c]
}

dict_try_get :: proc(d: ^Dict_Array($T), i: int) -> (val: T, valid: bool) {
	assert(i >= 0 && i < d.length, "dict_try_get: out of bounds")
	c := d.codes[i]
	if c < 0 { return {}, false }
	return d.dictionary[c], true
}

// value_counts: integer histogram over the codes.
dict_value_counts :: proc(d: ^Dict_Array($T), allocator := context.allocator) -> []i64 {
	counts := make([]i64, len(d.dictionary), allocator)
	for c in d.codes {
		if c >= 0 { counts[c] += 1 }
	}
	return counts
}

// Group-by sum for numeric `Dict_Array(T)`: `out[c] = Σ weights[i]` where `codes[i] == c`.
dict_group_sum :: proc(d: ^Dict_Array($T), weights: ^Array, allocator := context.allocator) -> []f64 {
	out := make([]f64, len(d.dictionary), allocator)
	_codes_group_sum_dispatch(d.codes[:d.length], weights, out)
	return out
}

// Sum via a histogram over the (narrow) codes plus a weighted sum over the
// dictionary — reads sizeof(i32)·n instead of sizeof(T)·n.
dict_sum :: proc(d: ^Dict_Array($T)) -> f64 {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	counts := make([]i64, len(d.dictionary), context.temp_allocator)
	defer delete(counts, context.temp_allocator)
	for c in d.codes {
		if c >= 0 { counts[c] += 1 }
	}
	sum: f64
	for v, ci in d.dictionary {
		if counts[ci] > 0 {
			sum += f64(v) * f64(counts[ci])
		}
	}
	return sum
}

// Min/Max over the dictionary values — O(n_dict), independent of length.
dict_min_max :: proc(d: ^Dict_Array($T)) -> (lo: f64, hi: f64, ok: bool) {
	if len(d.dictionary) == 0 || d.length <= d.null_count { return }
	mn, mx: T
	seen := false
	if d.allocator.procedure == nil {
		for c in d.codes[:d.length] {
			if c < 0 { continue }
			v := d.dictionary[c]
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
	for v in d.dictionary {
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

dict_decode :: proc(d: ^Dict_Array($T), allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	if d.null_count > 0 {
		b := builder_make(T, d.length, allocator)
		defer builder_destroy(&b)
		for c in d.codes {
			if c < 0 {
				builder_append_null(&b)
			} else {
				builder_append(&b, d.dictionary[c])
			}
		}
		return builder_finish(&b, allocator)
	}
	buf := buffer_make_uninit(d.length * size_of(T), allocator) or_return
	dst := cast([^]T)buf.data
	for c, i in d.codes { dst[i] = d.dictionary[c] }
	arr = Array{ type = _data_type_for(T), length = d.length, buffers = {{}, buf, {}} }
	return
}
