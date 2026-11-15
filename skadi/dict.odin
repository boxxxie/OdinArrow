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

str_dict_free :: proc(d: ^Str_Dict_Array) {
	array_free(&d.dict, d.allocator)
	delete(d.codes, d.allocator)
	d^ = {}
}

n_dict :: proc(d: ^Str_Dict_Array) -> int { return d.dict.length }

str_dict_is_null :: #force_inline proc(d: ^Str_Dict_Array, i: int) -> bool {
	assert(i >= 0 && i < d.length, "str_dict_is_null: out of bounds")
	return d.codes[i] < 0
}

// Dictionary-encode a plain Arrow string array (deduplicating values).
str_dict_encode :: proc(src: ^Array, allocator := context.allocator) -> Str_Dict_Array {
	_, is_str := src.type.(String_Type)
	assert(is_str, "str_dict_encode: source must be String_Type")
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	n := src.length
	lookup := make(map[string]i32, 1 << 8, context.temp_allocator)
	defer delete(lookup)

	codes := make([]i32, n, allocator)
	db := string_builder_make(64, allocator)
	null_count := 0
	for i in 0..<n {
		if array_is_null(src, i) {
			codes[i] = DICT_NULL_CODE
			null_count += 1
			continue
		}
		s := array_get_string(src, i)
		code, ok := lookup[s]
		if !ok {
			code = i32(db.length)
			string_builder_append(&db, s)
			lookup[s] = code
		}
		codes[i] = code
	}
	dict, _ := string_builder_finish(&db, allocator)
	string_builder_destroy(&db)
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
	switch _ in weights.type {
	case Int8_Type:    _str_dict_group_sum_typed(d, weights, out, i8)
	case Int16_Type:   _str_dict_group_sum_typed(d, weights, out, i16)
	case Int32_Type:   _str_dict_group_sum_typed(d, weights, out, i32)
	case Int64_Type:   _str_dict_group_sum_typed(d, weights, out, i64)
	case UInt8_Type:   _str_dict_group_sum_typed(d, weights, out, u8)
	case UInt16_Type:  _str_dict_group_sum_typed(d, weights, out, u16)
	case UInt32_Type:  _str_dict_group_sum_typed(d, weights, out, u32)
	case UInt64_Type:  _str_dict_group_sum_typed(d, weights, out, u64)
	case Float32_Type: _str_dict_group_sum_typed(d, weights, out, f32)
	case Float64_Type: _str_dict_group_sum_typed(d, weights, out, f64)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("str_dict_group_sum: weights must be numeric")
	}
	return out
}

@(private="file")
_str_dict_group_sum_typed :: proc(d: ^Str_Dict_Array, weights: ^Array, out: []f64, $T: typeid) {
	wdata := cast([^]T)weights.buffers[1].data
	woff := weights.offset
	w_nulls := weights.buffers[0].data != nil
	n := min(d.length, weights.length)
	for i in 0..<n {
		c := d.codes[i]
		if c < 0 { continue }
		if w_nulls && !array_is_valid(weights, i) { continue }
		out[c] += f64(wdata[woff + i])
	}
}

// Expand back into a plain Arrow string array.
str_dict_decode :: proc(d: ^Str_Dict_Array, allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	b := string_builder_make(d.length, allocator)
	defer string_builder_destroy(&b)
	for i in 0..<d.length {
		if d.codes[i] < 0 {
			string_builder_append_null(&b)
		} else {
			string_builder_append(&b, array_get_string(&d.dict, int(d.codes[i])))
		}
	}
	return string_builder_finish(&b, allocator)
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
	delete(d.dictionary, d.allocator)
	delete(d.codes, d.allocator)
	d^ = {}
}

dict_size :: proc(d: ^Dict_Array($T)) -> int { return len(d.dictionary) }

dict_is_null :: #force_inline proc(d: ^Dict_Array($T), i: int) -> bool {
	assert(i >= 0 && i < d.length, "dict_is_null: out of bounds")
	return d.codes[i] < 0
}

dict_encode :: proc(src: ^Array, $T: typeid, allocator := context.allocator) -> Dict_Array(T) {
	assert(src.type == _data_type_for(T), "dict_encode: source type mismatch")
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	n := src.length
	data := cast([^]T)src.buffers[1].data
	off := src.offset
	lookup := make(map[T]i32, 1 << 8, context.temp_allocator)
	defer delete(lookup)

	codes := make([]i32, n, allocator)
	dyn := make([dynamic]T, 0, 64, context.temp_allocator)
	defer delete(dyn)
	null_count := 0
	has_nan := false
	nan_code := DICT_NULL_CODE
	_ = has_nan; _ = nan_code

	for i in 0..<n {
		if array_is_null(src, i) {
			codes[i] = DICT_NULL_CODE
			null_count += 1
			continue
		}
		v := data[off + i]
		when T == f32 || T == f64 {
			if v != v {
				if !has_nan {
					nan_code = i32(len(dyn))
					append(&dyn, v)
					has_nan = true
				}
				codes[i] = nan_code
				continue
			}
		}
		code, ok := lookup[v]
		if !ok {
			code = i32(len(dyn))
			append(&dyn, v)
			lookup[v] = code
		}
		codes[i] = code
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
	if len(d.dictionary) == 0 { return }
	mn, mx: T
	seen := false
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
	buf := buffer_make(d.length * size_of(T), allocator) or_return
	dst := cast([^]T)buf.data
	for c, i in d.codes { dst[i] = d.dictionary[c] }
	arr = Array{ type = _data_type_for(T), length = d.length, buffers = {{}, buf, {}} }
	return
}
