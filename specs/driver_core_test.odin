package skadi_specs

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import oa "../skadi"

@(private="file")
g_temp_seq: u64

Spec_World :: struct {
	t:              ^testing.T,
	arrays:         map[string]oa.Array,
	retired_arrays: [dynamic]oa.Array,
	selections:     map[string]oa.Selection,
	str_dicts:      map[string]oa.Str_Dict_Array,
	schemas:        [dynamic]^oa.Schema,
	set_schemas:    map[string]^oa.Schema,
	batches:        map[string]oa.Record_Batch,
	batch_sets:     map[string][]oa.Record_Batch,
	aggs:           map[string]oa.Aggregates,
	csv_texts:      map[string]string,
	parquet_blobs:  map[string][]u8,
	temp_files:     [dynamic]string,
}

world_init :: proc(w: ^Spec_World, t: ^testing.T) {
	w^ = Spec_World{
		t              = t,
		arrays         = make(map[string]oa.Array),
		retired_arrays = make([dynamic]oa.Array),
		selections     = make(map[string]oa.Selection),
		str_dicts      = make(map[string]oa.Str_Dict_Array),
		schemas        = make([dynamic]^oa.Schema),
		set_schemas    = make(map[string]^oa.Schema),
		batches        = make(map[string]oa.Record_Batch),
		batch_sets     = make(map[string][]oa.Record_Batch),
		aggs           = make(map[string]oa.Aggregates),
		csv_texts      = make(map[string]string),
		parquet_blobs  = make(map[string][]u8),
		temp_files     = make([dynamic]string),
	}
}

world_destroy :: proc(w: ^Spec_World) {
	for _, &rb in w.batches {
		oa.record_batch_free(&rb)
	}
	delete(w.batches)

	for _, set in w.batch_sets {
		driver_free_batch_slice(set)
	}
	delete(w.batch_sets)
	delete(w.set_schemas)

	for _, &sel in w.selections {
		oa.selection_free(&sel)
	}
	delete(w.selections)

	for _, &d in w.str_dicts {
		oa.str_dict_free(&d)
	}
	delete(w.str_dicts)

	for _, &arr in w.arrays {
		oa.array_free(&arr)
	}
	delete(w.arrays)

	for &arr in w.retired_arrays {
		oa.array_free(&arr)
	}
	delete(w.retired_arrays)

	for sc in w.schemas {
		if sc != nil {
			oa.schema_free(sc)
			free(sc)
		}
	}
	delete(w.schemas)
	delete(w.aggs)

	for _, txt in w.csv_texts {
		delete(txt)
	}
	delete(w.csv_texts)

	for _, blob in w.parquet_blobs {
		delete(blob)
	}
	delete(w.parquet_blobs)

	for path in w.temp_files {
		_ = os.remove(path)
		delete(path)
	}
	delete(w.temp_files)
	free_all(context.temp_allocator)
	w^ = {}
}

driver_temp_path :: proc(w: ^Spec_World, label, ext: string) -> string {
	seq := sync.atomic_add(&g_temp_seq, 1)
	path := fmt.aprintf("%s/oa_spec_%d_%d_%s.%s", os.temp_dir(context.temp_allocator), os.get_pid(), seq, label, ext)
	append(&w.temp_files, path)
	return path
}

driver_verify_array_invariants :: proc(w: ^Spec_World, arr: oa.Array, loc := #caller_location) {
	check := arr
	if _, is_null := check.type.(oa.Null_Type); is_null {
		probe := check
		recounted := oa.array_recount_nulls(&probe)
		testing.expect_value(w.t, recounted, check.length, loc = loc)
		if check.null_count >= 0 {
			testing.expect_value(w.t, check.null_count, recounted, loc = loc)
		}
	} else if check.null_count >= 0 {
		cached := check.null_count
		probe := check
		testing.expect_value(w.t, oa.array_recount_nulls(&probe), cached, loc = loc)
	}
	if check.offset == 0 {
		for buf, bi in check.buffers {
			if buf.data != nil && buf.allocator.procedure != nil {
				testing.expectf(
					w.t,
					uintptr(buf.data) % oa.ARROW_ALIGNMENT == 0,
					"owned buffer[%d] must satisfy 64-byte Arrow alignment",
					bi,
					loc = loc,
				)
			}
		}
	}
}

driver_put_array :: proc(w: ^Spec_World, name: string, arr: oa.Array, loc := #caller_location) {
	if old, exists := w.arrays[name]; exists {
		append(&w.retired_arrays, old)
	}
	driver_verify_array_invariants(w, arr, loc)
	w.arrays[name] = arr
}

driver_put_selection :: proc(w: ^Spec_World, name: string, sel: oa.Selection) {
	if old, exists := w.selections[name]; exists {
		prev := old
		oa.selection_free(&prev)
	}
	w.selections[name] = sel
}

driver_put_str_dict :: proc(w: ^Spec_World, name: string, d: oa.Str_Dict_Array) {
	if old, exists := w.str_dicts[name]; exists {
		prev := old
		oa.str_dict_free(&prev)
	}
	w.str_dicts[name] = d
}

driver_put_batch :: proc(w: ^Spec_World, name: string, rb: oa.Record_Batch, loc := #caller_location) {
	if old, exists := w.batches[name]; exists {
		prev := old
		oa.record_batch_free(&prev)
	}
	for col in rb.columns {
		driver_verify_array_invariants(w, col, loc)
	}
	w.batches[name] = rb
}

driver_free_batch_slice :: proc(set: []oa.Record_Batch) {
	for i in 0 ..< len(set) {
		oa.record_batch_free(&set[i])
	}
	delete(set)
}

driver_put_batch_set :: proc(w: ^Spec_World, name: string, set: []oa.Record_Batch, loc := #caller_location) {
	if old, exists := w.batch_sets[name]; exists {
		driver_free_batch_slice(old)
	}
	for rb in set {
		for col in rb.columns {
			driver_verify_array_invariants(w, col, loc)
		}
	}
	w.batch_sets[name] = set
}

driver_release_batch_in_set :: proc(w: ^Spec_World, set_name: string, idx: int, loc := #caller_location) {
	set, ok := w.batch_sets[set_name]
	valid := ok && idx >= 0 && idx < len(set)
	testing.expect(w.t, valid, "invalid batch index", loc = loc)
	if !valid {
		return
	}
	oa.record_batch_free(&set[idx])
	set[idx] = {}
}

driver_get_batch_in_set :: proc(
	w:         ^Spec_World,
	set_name:  string,
	batch_idx: int,
	loc        := #caller_location,
) -> (^oa.Record_Batch, bool) {
	set, has_set := w.batch_sets[set_name]
	testing.expectf(w.t, has_set, "missing batch set %q", set_name, loc = loc)
	if !has_set {
		return nil, false
	}
	in_range := batch_idx >= 0 && batch_idx < len(set)
	testing.expectf(
		w.t,
		in_range,
		"batch index %d out of range [0, %d) in set %q",
		batch_idx,
		len(set),
		set_name,
		loc = loc,
	)
	if !in_range {
		return nil, false
	}
	return &set[batch_idx], true
}

driver_build_nullable_primitive :: proc(w: ^Spec_World, name: string, vals: []Maybe($T), loc := #caller_location) {
	b := oa.builder_make(T, len(vals))
	defer oa.builder_destroy(&b)
	for item in vals {
		if v, ok := item.?; ok {
			oa.builder_append(&b, v)
		} else {
			oa.builder_append_null(&b)
		}
	}
	arr, err := oa.builder_finish(&b)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, name, arr, loc)
}

driver_build_primitive :: proc(w: ^Spec_World, name: string, vals: []$T, loc := #caller_location) {
	b := oa.builder_make(T, len(vals))
	defer oa.builder_destroy(&b)
	for v in vals {
		oa.builder_append(&b, v)
	}
	arr, err := oa.builder_finish(&b)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, name, arr, loc)
}

driver_build_strings :: proc(w: ^Spec_World, name: string, vals: []string, loc := #caller_location) {
	b := oa.string_builder_make(len(vals))
	defer oa.string_builder_destroy(&b)
	for s in vals {
		oa.string_builder_append(&b, s)
	}
	arr, err := oa.string_builder_finish(&b)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, name, arr, loc)
}

driver_build_nullable_strings :: proc(w: ^Spec_World, name: string, vals: []Maybe(string), loc := #caller_location) {
	b := oa.string_builder_make(len(vals))
	defer oa.string_builder_destroy(&b)
	for item in vals {
		if s, ok := item.?; ok {
			oa.string_builder_append(&b, s)
		} else {
			oa.string_builder_append_null(&b)
		}
	}
	arr, err := oa.string_builder_finish(&b)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, name, arr, loc)
}

driver_build_masked_i32 :: proc(w: ^Spec_World, name: string, raw: []i32, valid: []bool, loc := #caller_location) {
	testing.expect_value(w.t, len(raw), len(valid), loc = loc)
	if len(raw) != len(valid) {
		return
	}
	n := len(raw)
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	for i in 0 ..< n {
		oa.builder_append(&b, raw[i])
	}
	arr, err := oa.builder_finish(&b)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	bm_bytes := oa.bitmap_byte_count(n)
	bm, bm_err := oa.buffer_make(bm_bytes)
	testing.expect_value(w.t, bm_err, nil, loc = loc)
	if bm_err != nil {
		oa.array_free(&arr)
		return
	}
	null_cnt := 0
	for i in 0 ..< n {
		if valid[i] {
			bm.data[i >> 3] |= 1 << u8(i & 7)
		} else {
			null_cnt += 1
		}
	}
	oa.buffer_free(&arr.buffers[0])
	arr.buffers[0] = bm
	arr.null_count = null_cnt
	driver_put_array(w, name, arr, loc)
}

driver_build_binary :: proc(w: ^Spec_World, name: string, vals: [][]u8, loc := #caller_location) {
	b := oa.binary_builder_make(len(vals))
	defer oa.binary_builder_destroy(&b)
	for item in vals {
		if item == nil {
			oa.binary_builder_append_null(&b)
		} else {
			oa.binary_builder_append(&b, item)
		}
	}
	arr, err := oa.binary_builder_finish(&b)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, name, arr, loc)
}

driver_build_large_strings :: proc(w: ^Spec_World, name: string, vals: []string, loc := #caller_location) {
	b := oa.large_string_builder_make(len(vals))
	defer oa.large_string_builder_destroy(&b)
	for s in vals {
		oa.large_string_builder_append(&b, s)
	}
	arr, err := oa.large_string_builder_finish(&b)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, name, arr, loc)
}

driver_build_null_column :: proc(w: ^Spec_World, name: string, length: int, loc := #caller_location) {
	arr := oa.Array{type = oa.Null_Type{}, length = length, null_count = -1}
	driver_put_array(w, name, arr, loc)
}

driver_build_nullable_large_strings :: proc(w: ^Spec_World, name: string, vals: []Maybe(string), loc := #caller_location) {
	b := oa.large_string_builder_make(len(vals))
	defer oa.large_string_builder_destroy(&b)
	for item in vals {
		if s, ok := item.?; ok {
			oa.large_string_builder_append(&b, s)
		} else {
			oa.large_string_builder_append_null(&b)
		}
	}
	arr, err := oa.large_string_builder_finish(&b)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, name, arr, loc)
}

driver_build_nullable_binary :: proc(w: ^Spec_World, name: string, vals: []Maybe([]u8), loc := #caller_location) {
	b := oa.binary_builder_make(len(vals))
	defer oa.binary_builder_destroy(&b)
	for item in vals {
		if bytes_val, ok := item.?; ok {
			oa.binary_builder_append(&b, bytes_val)
		} else {
			oa.binary_builder_append_null(&b)
		}
	}
	arr, err := oa.binary_builder_finish(&b)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, name, arr, loc)
}

driver_build_nullable_large_binary :: proc(w: ^Spec_World, name: string, vals: []Maybe([]u8), loc := #caller_location) {
	b := oa.large_binary_builder_make(len(vals))
	defer oa.large_binary_builder_destroy(&b)
	for item in vals {
		if bytes_val, ok := item.?; ok {
			oa.large_binary_builder_append(&b, bytes_val)
		} else {
			oa.large_binary_builder_append_null(&b)
		}
	}
	arr, err := oa.large_binary_builder_finish(&b)
	testing.expect_value(w.t, err, nil, loc = loc)
	if err != nil {
		return
	}
	driver_put_array(w, name, arr, loc)
}

driver_make_batch :: proc(w: ^Spec_World, batch_name: string, col_names: []string, loc := #caller_location) {
	fields := make([]oa.Field, len(col_names))
	defer delete(fields)
	cols := make([]oa.Array, len(col_names))
	defer delete(cols)

	for entry, i in col_names {
		field_name := entry
		array_label := entry
		if colon := strings.index_byte(entry, ':'); colon >= 0 {
			field_name = entry[:colon]
			array_label = entry[colon + 1:]
		}
		src, ok := &w.arrays[array_label]
		testing.expectf(w.t, ok, "missing array %q for column %q", array_label, field_name, loc = loc)
		if !ok {
			for prev in 0 ..< i {
				oa.array_free(&cols[prev])
			}
			return
		}
		fields[i] = oa.field_make(field_name, src.type)
		// Zero-allocator views intentionally skip array_copy to preserve non-zero offset for
		// sliced-batch specs; lifetime safety relies on world_destroy freeing w.batches
		// before w.arrays and w.retired_arrays.
		is_view := src.buffers[0].allocator.procedure == nil &&
			src.buffers[1].allocator.procedure == nil &&
			src.buffers[2].allocator.procedure == nil
		if is_view {
			cols[i] = src^
		} else {
			copied, err := oa.array_copy(src)
			testing.expect_value(w.t, err, nil, loc = loc)
			if err != nil {
				for prev in 0 ..< i {
					oa.array_free(&cols[prev])
				}
				return
			}
			cols[i] = copied
		}
	}

	sc_val, s_err := oa.schema_make(fields)
	testing.expect_value(w.t, s_err, nil, loc = loc)
	if s_err != nil {
		for &c in cols {
			oa.array_free(&c)
		}
		return
	}
	sc := new(oa.Schema)
	sc^ = sc_val
	append(&w.schemas, sc)

	rb, ok := oa.record_batch_make(sc, cols)
	testing.expect(w.t, ok, "record_batch_make must succeed", loc = loc)
	if !ok {
		for &c in cols {
			oa.array_free(&c)
		}
		return
	}
	driver_put_batch(w, batch_name, rb, loc)
}
