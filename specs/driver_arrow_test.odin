package skadi_specs

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import oa "../skadi"
import c2p "../examples/csv_to_parquet"
import p2c "../examples/parquet_to_csv"

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

driver_put_csv_text :: proc(w: ^Spec_World, name, content: string) {
	if old, exists := w.csv_texts[name]; exists {
		delete(old)
	}
	w.csv_texts[name] = strings.clone(content)
}

driver_put_parquet_blob :: proc(w: ^Spec_World, name: string, data: []u8) {
	if old, exists := w.parquet_blobs[name]; exists {
		delete(old)
	}
	w.parquet_blobs[name] = slice.clone(data)
}

driver_put_array :: proc(w: ^Spec_World, name: string, arr: oa.Array, loc := #caller_location) {
	if old, exists := w.arrays[name]; exists {
		append(&w.retired_arrays, old)
	}
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
		testing.expect_value(w.t, oa.array_recount_nulls(&check), cached, loc = loc)
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
	w.arrays[name] = check
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

driver_put_batch :: proc(w: ^Spec_World, name: string, rb: oa.Record_Batch) {
	if old, exists := w.batches[name]; exists {
		prev := old
		oa.record_batch_free(&prev)
	}
	w.batches[name] = rb
}

driver_free_batch_slice :: proc(set: []oa.Record_Batch) {
	for i in 0 ..< len(set) {
		oa.record_batch_free(&set[i])
	}
	delete(set)
}

driver_put_batch_set :: proc(w: ^Spec_World, name: string, set: []oa.Record_Batch) {
	if old, exists := w.batch_sets[name]; exists {
		driver_free_batch_slice(old)
	}
	w.batch_sets[name] = set
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

driver_ipc_file_roundtrip :: proc(
	w:           ^Spec_World,
	set_name:    string,
	batch_names: []string,
	use_mmap     := true,
	loc          := #caller_location,
) {
	testing.expect(w.t, len(batch_names) > 0, "need at least one batch", loc = loc)
	if len(batch_names) == 0 {
		return
	}
	in_batches := make([]oa.Record_Batch, len(batch_names))
	defer delete(in_batches)
	for bname, i in batch_names {
		rb, ok := w.batches[bname]
		testing.expectf(w.t, ok, "missing batch %q", bname, loc = loc)
		if !ok {
			return
		}
		in_batches[i] = rb
	}
	path := driver_temp_path(w, set_name, "arrow")
	wrote := oa.ipc_write_file(path, in_batches[0].schema, in_batches)
	testing.expect(w.t, wrote, "ipc_write_file failed", loc = loc)
	if !wrote {
		return
	}

	sc, out_batches, read_ok := oa.ipc_read_file(path, use_mmap = use_mmap)
	testing.expect(w.t, read_ok, "ipc_read_file failed", loc = loc)
	if !read_ok {
		if sc != nil {
			oa.schema_free(sc)
			free(sc)
		}
		delete(out_batches)
		return
	}
	if sc != nil {
		append(&w.schemas, sc)
		w.set_schemas[set_name] = sc
	}
	driver_put_batch_set(w, set_name, out_batches)
}

driver_ipc_schema_only_roundtrip :: proc(
	w:                 ^Spec_World,
	set_name:          string,
	schema_from_batch: string,
	use_mmap           := true,
	loc                := #caller_location,
) {
	rb, ok := w.batches[schema_from_batch]
	testing.expectf(w.t, ok, "missing batch %q for schema", schema_from_batch, loc = loc)
	if !ok {
		return
	}
	path := driver_temp_path(w, set_name, "arrow")
	wrote := oa.ipc_write_file(path, rb.schema, nil)
	testing.expect(w.t, wrote, "schema-only ipc_write_file failed", loc = loc)
	if !wrote {
		return
	}

	sc, out_batches, read_ok := oa.ipc_read_file(path, use_mmap = use_mmap)
	testing.expect(w.t, read_ok, "schema-only ipc_read_file failed", loc = loc)
	if !read_ok {
		if sc != nil {
			oa.schema_free(sc)
			free(sc)
		}
		delete(out_batches)
		return
	}
	if sc != nil {
		append(&w.schemas, sc)
		w.set_schemas[set_name] = sc
	}
	driver_put_batch_set(w, set_name, out_batches)
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

driver_ipc_stream_roundtrip :: proc(
	w:           ^Spec_World,
	set_name:    string,
	batch_names: []string,
	loc          := #caller_location,
) {
	testing.expect(w.t, len(batch_names) > 0, "need at least one batch", loc = loc)
	if len(batch_names) == 0 {
		return
	}
	in_batches := make([]oa.Record_Batch, len(batch_names))
	defer delete(in_batches)
	for bname, i in batch_names {
		rb, ok := w.batches[bname]
		testing.expectf(w.t, ok, "missing batch %q", bname, loc = loc)
		if !ok {
			return
		}
		in_batches[i] = rb
	}
	path := driver_temp_path(w, set_name, "arrows")
	wrote := oa.ipc_write_stream(path, in_batches[0].schema, in_batches)
	testing.expect(w.t, wrote, "ipc_write_stream failed", loc = loc)
	if !wrote {
		return
	}

	sc, out_batches, read_ok := oa.ipc_read_stream(path)
	testing.expect(w.t, read_ok, "ipc_read_stream failed", loc = loc)
	if !read_ok {
		if sc != nil {
			oa.schema_free(sc)
			free(sc)
		}
		delete(out_batches)
		return
	}
	if sc != nil {
		append(&w.schemas, sc)
		w.set_schemas[set_name] = sc
	}
	driver_put_batch_set(w, set_name, out_batches)
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
	driver_put_batch(w, batch_name, rb)
}

driver_csv_parquet_roundtrip :: proc(
	w:               ^Spec_World,
	csv_input:       string,
	read_buf_bytes:  int,
	max_rows_per_rg: int,
	loc              := #caller_location,
) -> (string, bool) {
	in_csv := driver_temp_path(w, "in", "csv")
	pq_path := driver_temp_path(w, "mid", "parquet")
	out_csv := driver_temp_path(w, "out", "csv")

	w_err := os.write_entire_file(in_csv, transmute([]u8)csv_input)
	testing.expect_value(w.t, w_err, nil, loc = loc)
	if w_err != nil {
		return "", false
	}

	_, _, c2p_err := c2p.csv_to_parquet_stream(
		in_csv,
		pq_path,
		64 * 1024 * 1024,
		buf_size_override = read_buf_bytes,
		max_rows_override = max_rows_per_rg,
	)
	testing.expect_value(w.t, c2p_err, nil, loc = loc)
	if c2p_err != nil {
		return "", false
	}

	_, _, p2c_err := p2c.parquet_to_csv_stream(
		pq_path,
		out_csv,
		64 * 1024 * 1024,
		chunk_rows_override = max_rows_per_rg,
	)
	testing.expect_value(w.t, p2c_err, nil, loc = loc)
	if p2c_err != nil {
		return "", false
	}

	csv_bytes, rd_err := os.read_entire_file(out_csv, context.temp_allocator)
	testing.expect_value(w.t, rd_err, nil, loc = loc)
	if rd_err != nil {
		return "", false
	}
	return string(csv_bytes), true
}

Parquet_Col_Encoding :: enum {
	Plain,
	Dictionary,
}

Parquet_RG_I32_Spec :: struct {
	encoding: Parquet_Col_Encoding,
	nullable: bool,
	dict:     []i32,
	values:   []Maybe(i32),
}

Parquet_RG_Str_Spec :: struct {
	encoding: Parquet_Col_Encoding,
	nullable: bool,
	dict:     []string,
	values:   []Maybe(string),
}

@(private="file")
_pq_append_i32_le :: proc(dst: ^[dynamic]u8, v: i32) {
	u := u32(v)
	append(dst, u8(u), u8(u >> 8), u8(u >> 16), u8(u >> 24))
}

@(private="file")
_pq_append_varint :: proc(dst: ^[dynamic]u8, v: u64) {
	u := v
	for u >= 0x80 {
		append(dst, u8(u & 0x7F) | 0x80)
		u >>= 7
	}
	append(dst, u8(u))
}

@(private="file")
_pq_bit_width :: proc(n_distinct: int) -> int {
	if n_distinct <= 1 {
		return 0
	}
	bw := 0
	v := n_distinct - 1
	for v > 0 {
		bw += 1
		v >>= 1
	}
	return bw
}

@(private="file")
_pq_append_bitpacked :: proc(dst: ^[dynamic]u8, vals: []int, bw: int) {
	if bw == 0 || len(vals) == 0 {
		return
	}
	groups := (len(vals) + 7) / 8
	_pq_append_varint(dst, u64((groups << 1) | 1))
	start := len(dst^)
	resize(dst, start + groups * bw)
	for v, idx in vals {
		for b in 0 ..< bw {
			if ((v >> uint(b)) & 1) == 1 {
				tbit := idx * bw + b
				dst[start + tbit / 8] |= u8(1 << uint(tbit % 8))
			}
		}
	}
}

@(private="file")
_pq_write_dict_page_hdr :: proc(dst: ^[dynamic]u8, n_vals: int, payload_len: int) {
	tw := c2p.tw_make()
	defer c2p.tw_destroy(&tw)
	prev: i32 = 0
	c2p.tw_field_i32(&tw, 1, p2c.PPAGE_DICT, &prev)
	c2p.tw_field_i32(&tw, 2, i32(payload_len), &prev)
	c2p.tw_field_i32(&tw, 3, i32(payload_len), &prev)
	c2p.tw_field(&tw, 7, c2p.TW_STRUCT, &prev)
	{
		p2: i32 = 0
		c2p.tw_field_i32(&tw, 1, i32(n_vals), &p2)
		c2p.tw_field_i32(&tw, 2, 0, &p2) // PLAIN
		c2p.tw_stop(&tw)
	}
	c2p.tw_stop(&tw)
	append(dst, ..c2p.tw_bytes(&tw))
}

@(private="file")
_pq_write_data_page_hdr :: proc(dst: ^[dynamic]u8, n_vals: int, payload_len: int, enc: Parquet_Col_Encoding, nullable: bool) {
	tw := c2p.tw_make()
	defer c2p.tw_destroy(&tw)
	prev: i32 = 0
	c2p.tw_field_i32(&tw, 1, p2c.PPAGE_DATA, &prev)
	c2p.tw_field_i32(&tw, 2, i32(payload_len), &prev)
	c2p.tw_field_i32(&tw, 3, i32(payload_len), &prev)
	c2p.tw_field(&tw, 5, c2p.TW_STRUCT, &prev)
	{
		p2: i32 = 0
		c2p.tw_field_i32(&tw, 1, i32(n_vals), &p2)
		c2p.tw_field_i32(&tw, 2, enc == .Dictionary ? i32(2) : i32(0), &p2)
		c2p.tw_field_i32(&tw, 3, nullable ? i32(3) : i32(0), &p2)
		c2p.tw_field_i32(&tw, 4, i32(0), &p2)
		c2p.tw_stop(&tw)
	}
	c2p.tw_stop(&tw)
	append(dst, ..c2p.tw_bytes(&tw))
}

@(private="file")
_pq_Chunk_Layout :: struct {
	has_dict:   bool,
	dict_off:   i64,
	data_off:   i64,
	total_sz:   i64,
	num_values: i64,
}

driver_build_parquet_two_col_fixture :: proc(
	w:            ^Spec_World,
	name:         string,
	id_col_name:  string,
	str_col_name: string,
	id_rgs:       []Parquet_RG_I32_Spec,
	str_rgs:      []Parquet_RG_Str_Spec,
	loc           := #caller_location,
) {
	testing.expect_value(w.t, len(id_rgs), len(str_rgs), loc = loc)
	if len(id_rgs) != len(str_rgs) || len(id_rgs) == 0 {
		return
	}

	n_rgs := len(id_rgs)
	id_nullable := false
	str_nullable := false
	for rg in id_rgs {
		if rg.nullable {
			id_nullable = true
		}
	}
	for rg in str_rgs {
		if rg.nullable {
			str_nullable = true
		}
	}

	buf := make([dynamic]u8, 0, 1024, context.temp_allocator)
	append(&buf, 'P', 'A', 'R', '1')

	id_layouts := make([]_pq_Chunk_Layout, n_rgs, context.temp_allocator)
	str_layouts := make([]_pq_Chunk_Layout, n_rgs, context.temp_allocator)
	rg_rows := make([]i64, n_rgs, context.temp_allocator)
	total_rows: i64 = 0

	for r in 0 ..< n_rgs {
		id_spec := id_rgs[r]
		str_spec := str_rgs[r]
		testing.expect_value(w.t, len(id_spec.values), len(str_spec.values), loc = loc)
		if len(id_spec.values) != len(str_spec.values) {
			return
		}
		n := len(id_spec.values)
		rg_rows[r] = i64(n)
		total_rows += i64(n)

		// Column 0: INT32
		{
			chunk_start := i64(len(buf))
			dict_off: i64 = 0
			has_dict := id_spec.encoding == .Dictionary
			if has_dict {
				dict_off = i64(len(buf))
				dp := make([dynamic]u8, 0, len(id_spec.dict) * 4, context.temp_allocator)
				for dv in id_spec.dict {
					_pq_append_i32_le(&dp, dv)
				}
				_pq_write_dict_page_hdr(&buf, len(id_spec.dict), len(dp))
				append(&buf, ..dp[:])
			}

			data_off := i64(len(buf))
			payload := make([dynamic]u8, 0, 64, context.temp_allocator)
			if id_nullable {
				def_bits := make([]int, n, context.temp_allocator)
				for mv, idx in id_spec.values {
					_, is_val := mv.?
					def_bits[idx] = is_val ? 1 : 0
				}
				def_bytes := make([dynamic]u8, 0, 16, context.temp_allocator)
				_pq_append_bitpacked(&def_bytes, def_bits, 1)
				_pq_append_i32_le(&payload, i32(len(def_bytes)))
				append(&payload, ..def_bytes[:])
			}
			if has_dict {
				indices := make([dynamic]int, 0, n, context.temp_allocator)
				for mv, row_i in id_spec.values {
					if v, is_val := mv.?; is_val {
						code, found := slice.linear_search(id_spec.dict, v)
						testing.expectf(
							w.t,
							found,
							"RG %d INT32 value %d at row %d not found in dictionary %v",
							r,
							v,
							row_i,
							id_spec.dict,
							loc = loc,
						)
						append(&indices, found ? code : 0)
					}
				}
				bw := _pq_bit_width(len(id_spec.dict))
				append(&payload, u8(bw))
				_pq_append_bitpacked(&payload, indices[:], bw)
			} else {
				for mv in id_spec.values {
					if v, is_val := mv.?; is_val {
						_pq_append_i32_le(&payload, v)
					}
				}
			}
			_pq_write_data_page_hdr(&buf, n, len(payload), id_spec.encoding, id_nullable)
			append(&buf, ..payload[:])

			id_layouts[r] = _pq_Chunk_Layout{
				has_dict   = has_dict,
				dict_off   = dict_off,
				data_off   = data_off,
				total_sz   = i64(len(buf)) - chunk_start,
				num_values = i64(n),
			}
		}

		// Column 1: BYTE_ARRAY
		{
			chunk_start := i64(len(buf))
			dict_off: i64 = 0
			has_dict := str_spec.encoding == .Dictionary
			if has_dict {
				dict_off = i64(len(buf))
				dp := make([dynamic]u8, 0, 64, context.temp_allocator)
				for ds in str_spec.dict {
					_pq_append_i32_le(&dp, i32(len(ds)))
					append(&dp, ..transmute([]u8)ds)
				}
				_pq_write_dict_page_hdr(&buf, len(str_spec.dict), len(dp))
				append(&buf, ..dp[:])
			}

			data_off := i64(len(buf))
			payload := make([dynamic]u8, 0, 64, context.temp_allocator)
			if str_nullable {
				def_bits := make([]int, n, context.temp_allocator)
				for mv, idx in str_spec.values {
					_, is_val := mv.?
					def_bits[idx] = is_val ? 1 : 0
				}
				def_bytes := make([dynamic]u8, 0, 16, context.temp_allocator)
				_pq_append_bitpacked(&def_bytes, def_bits, 1)
				_pq_append_i32_le(&payload, i32(len(def_bytes)))
				append(&payload, ..def_bytes[:])
			}
			if has_dict {
				indices := make([dynamic]int, 0, n, context.temp_allocator)
				for mv, row_i in str_spec.values {
					if s, is_val := mv.?; is_val {
						code, found := slice.linear_search(str_spec.dict, s)
						testing.expectf(
							w.t,
							found,
							"RG %d string value %q at row %d not found in dictionary %v",
							r,
							s,
							row_i,
							str_spec.dict,
							loc = loc,
						)
						append(&indices, found ? code : 0)
					}
				}
				bw := _pq_bit_width(len(str_spec.dict))
				append(&payload, u8(bw))
				_pq_append_bitpacked(&payload, indices[:], bw)
			} else {
				for mv in str_spec.values {
					if s, is_val := mv.?; is_val {
						_pq_append_i32_le(&payload, i32(len(s)))
						append(&payload, ..transmute([]u8)s)
					}
				}
			}
			_pq_write_data_page_hdr(&buf, n, len(payload), str_spec.encoding, str_nullable)
			append(&buf, ..payload[:])

			str_layouts[r] = _pq_Chunk_Layout{
				has_dict   = has_dict,
				dict_off   = dict_off,
				data_off   = data_off,
				total_sz   = i64(len(buf)) - chunk_start,
				num_values = i64(n),
			}
		}
	}

	ft := c2p.tw_make()
	defer c2p.tw_destroy(&ft)
	{
		prev: i32 = 0
		c2p.tw_field_i32(&ft, 1, 2, &prev)
		c2p.tw_field_list_begin(&ft, 2, c2p.TW_STRUCT, 3, &prev)
		{
			pr: i32 = 0
			c2p.tw_field_string(&ft, 4, "schema", &pr)
			c2p.tw_field_i32(&ft, 5, 2, &pr)
			c2p.tw_stop(&ft)
		}
		{
			p0: i32 = 0
			c2p.tw_field_i32(&ft, 1, p2c.PTYPE_INT32, &p0)
			c2p.tw_field_i32(&ft, 3, id_nullable ? p2c.REP_OPTIONAL : p2c.REP_REQUIRED, &p0)
			c2p.tw_field_string(&ft, 4, id_col_name, &p0)
			c2p.tw_stop(&ft)
		}
		{
			p1: i32 = 0
			c2p.tw_field_i32(&ft, 1, p2c.PTYPE_BYTE_ARRAY, &p1)
			c2p.tw_field_i32(&ft, 3, str_nullable ? p2c.REP_OPTIONAL : p2c.REP_REQUIRED, &p1)
			c2p.tw_field_string(&ft, 4, str_col_name, &p1)
			c2p.tw_field_i32(&ft, 6, 0, &p1) // UTF8
			c2p.tw_stop(&ft)
		}
		c2p.tw_field_i64(&ft, 3, total_rows, &prev)
		c2p.tw_field_list_begin(&ft, 4, c2p.TW_STRUCT, n_rgs, &prev)
		for r in 0 ..< n_rgs {
			il := id_layouts[r]
			sl := str_layouts[r]
			prg: i32 = 0
			c2p.tw_field_list_begin(&ft, 1, c2p.TW_STRUCT, 2, &prg)
			// Column 0 metadata
			{
				pcc: i32 = 0
				c2p.tw_field_i64(&ft, 2, il.has_dict ? il.dict_off : il.data_off, &pcc)
				c2p.tw_field(&ft, 3, c2p.TW_STRUCT, &pcc)
				{
					pcm: i32 = 0
					c2p.tw_field_i32(&ft, 1, p2c.PTYPE_INT32, &pcm)
					c2p.tw_field_list_begin(&ft, 2, c2p.TW_I32, 1, &pcm)
					c2p.tw_i32(&ft, il.has_dict ? 2 : 0)
					c2p.tw_field_list_begin(&ft, 3, c2p.TW_BINARY, 1, &pcm)
					c2p.tw_varint(&ft, u64(len(id_col_name)))
					append(&ft.buf, ..transmute([]u8)id_col_name)
					c2p.tw_field_i32(&ft, 4, 0, &pcm)
					c2p.tw_field_i64(&ft, 5, il.num_values, &pcm)
					c2p.tw_field_i64(&ft, 6, il.total_sz, &pcm)
					c2p.tw_field_i64(&ft, 7, il.total_sz, &pcm)
					c2p.tw_field_i64(&ft, 9, il.data_off, &pcm)
					if il.has_dict {
						c2p.tw_field_i64(&ft, 11, il.dict_off, &pcm)
					}
					c2p.tw_stop(&ft)
				}
				c2p.tw_stop(&ft)
			}
			// Column 1 metadata
			{
				pcc: i32 = 0
				c2p.tw_field_i64(&ft, 2, sl.has_dict ? sl.dict_off : sl.data_off, &pcc)
				c2p.tw_field(&ft, 3, c2p.TW_STRUCT, &pcc)
				{
					pcm: i32 = 0
					c2p.tw_field_i32(&ft, 1, p2c.PTYPE_BYTE_ARRAY, &pcm)
					c2p.tw_field_list_begin(&ft, 2, c2p.TW_I32, 1, &pcm)
					c2p.tw_i32(&ft, sl.has_dict ? 2 : 0)
					c2p.tw_field_list_begin(&ft, 3, c2p.TW_BINARY, 1, &pcm)
					c2p.tw_varint(&ft, u64(len(str_col_name)))
					append(&ft.buf, ..transmute([]u8)str_col_name)
					c2p.tw_field_i32(&ft, 4, 0, &pcm)
					c2p.tw_field_i64(&ft, 5, sl.num_values, &pcm)
					c2p.tw_field_i64(&ft, 6, sl.total_sz, &pcm)
					c2p.tw_field_i64(&ft, 7, sl.total_sz, &pcm)
					c2p.tw_field_i64(&ft, 9, sl.data_off, &pcm)
					if sl.has_dict {
						c2p.tw_field_i64(&ft, 11, sl.dict_off, &pcm)
					}
					c2p.tw_stop(&ft)
				}
				c2p.tw_stop(&ft)
			}
			c2p.tw_field_i64(&ft, 2, il.total_sz + sl.total_sz, &prg)
			c2p.tw_field_i64(&ft, 3, rg_rows[r], &prg)
			c2p.tw_stop(&ft)
		}
		c2p.tw_stop(&ft)
	}
	ft_bytes := c2p.tw_bytes(&ft)
	append(&buf, ..ft_bytes)
	_pq_append_i32_le(&buf, i32(len(ft_bytes)))
	append(&buf, 'P', 'A', 'R', '1')

	driver_put_parquet_blob(w, name, buf[:])
}

driver_parquet_blob_to_csv :: proc(
	w:                  ^Spec_World,
	dst_csv_name:       string,
	pq_blob_name:       string,
	max_rows_per_chunk: int,
	loc                 := #caller_location,
) {
	blob, ok := w.parquet_blobs[pq_blob_name]
	testing.expectf(w.t, ok, "missing parquet fixture %q", pq_blob_name, loc = loc)
	if !ok {
		return
	}

	pq_path := driver_temp_path(w, pq_blob_name, "parquet")
	out_csv := driver_temp_path(w, dst_csv_name, "csv")

	w_err := os.write_entire_file(pq_path, blob)
	testing.expect_value(w.t, w_err, nil, loc = loc)
	if w_err != nil {
		return
	}

	_, _, p2c_err := p2c.parquet_to_csv_stream(
		pq_path,
		out_csv,
		64 * 1024 * 1024,
		chunk_rows_override = max_rows_per_chunk,
	)
	testing.expect_value(w.t, p2c_err, nil, loc = loc)
	if p2c_err != nil {
		return
	}

	csv_bytes, rd_err := os.read_entire_file(out_csv, context.temp_allocator)
	testing.expect_value(w.t, rd_err, nil, loc = loc)
	if rd_err != nil {
		return
	}
	driver_put_csv_text(w, dst_csv_name, string(csv_bytes))
}
