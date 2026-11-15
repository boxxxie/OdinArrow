package skadi_tests

import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"
import oa "../skadi"

@(private="file")
g_ipc_test_seq: u64

ipc_test_temp_path :: proc(label, ext: string) -> string {
	seq := sync.atomic_add(&g_ipc_test_seq, 1)
	return fmt.aprintf("%s/oa_test_%d_%d_%s.%s", os.temp_dir(context.temp_allocator), os.get_pid(), seq, label, ext)
}

// ── helpers ───────────────────────────────────────────────────────────────────

make_i32_array :: proc(vals: []i32) -> oa.Array {
	b := oa.builder_make(i32, len(vals))
	defer oa.builder_destroy(&b)
	for v in vals { oa.builder_append(&b, v) }
	arr, err := oa.builder_finish(&b)
	assert(err == nil)
	return arr
}

make_string_array :: proc(vals: []string) -> oa.Array {
	b := oa.string_builder_make(len(vals))
	defer oa.string_builder_destroy(&b)
	for v in vals { oa.string_builder_append(&b, v) }
	arr, err := oa.string_builder_finish(&b)
	assert(err == nil)
	return arr
}

// Security (A4): a file with a corrupt out-of-bounds string offset must be
// rejected when validation is on, and the unsafe batch must not be returned.
@(test)
test_ipc_rejects_bad_offsets :: proc(t: ^testing.T) {
	good := ipc_test_temp_path("goodoff", "arrow")
	bad  := ipc_test_temp_path("badoff", "arrow")
	defer {
		os.remove(good); delete(good)
		os.remove(bad);  delete(bad)
	}

	fields := []oa.Field{oa.field_make("s", oa.String_Type{})}
	schema, sc_err := oa.schema_make(fields)
	testing.expect_value(t, sc_err, nil)
	defer oa.schema_free(&schema)
	col := make_string_array([]string{"alpha", "beta", "gamma"})  // offsets [0,5,9,14]
	batch, rb_ok := oa.record_batch_make(&schema, []oa.Array{col})
	testing.expect(t, rb_ok)
	defer oa.record_batch_free(&batch)
	testing.expect(t, oa.ipc_write_file(good, &schema, []oa.Record_Batch{batch}))

	data, _ := os.read_entire_file(good, context.allocator)
	defer delete(data)
	// locate the i32 offsets buffer [0,5,9,14] and push the last offset OOB
	pat := []u8{0,0,0,0, 5,0,0,0, 9,0,0,0, 14,0,0,0}
	pos := -1
	search: for i in 0..<len(data)-len(pat)+1 {
		for j in 0..<len(pat) { if data[i+j] != pat[j] { continue search } }
		pos = i; break
	}
	testing.expect(t, pos >= 0, "offsets pattern not found in file")
	data[pos+12]=0xFF; data[pos+13]=0xFF; data[pos+14]=0xFF; data[pos+15]=0x7F  // 14 -> 0x7FFFFFFF
	_ = os.write_entire_file(bad, data)

	// validate (default) → corrupt batch rejected, not returned
	sc, batches, ok := oa.ipc_read_file(bad)
	testing.expect(t, ok)
	testing.expect_value(t, len(batches), 0)
	oa.schema_free(sc); free(sc); delete(batches)

	// validate=false → the (unsafe) batch is returned, proving the check matters
	sc2, batches2, ok2 := oa.ipc_read_file(bad, validate=false)
	testing.expect(t, ok2)
	testing.expect_value(t, len(batches2), 1)
	oa.schema_free(sc2); free(sc2)
	for bx in batches2 { bc := bx; oa.record_batch_free(&bc) }
	delete(batches2)
}

// A1/A3: structural-fuzz — mutating or truncating a valid file must never crash
// the reader, valid input must round-trip cleanly, magic corruptions and strict
// truncations must fail cleanly.
@(test)
test_ipc_fuzz_no_crash :: proc(t: ^testing.T) {
	fields := []oa.Field{oa.field_make("i", oa.Int32_Type{}), oa.field_make("s", oa.String_Type{})}
	schema, sc_err := oa.schema_make(fields)
	testing.expect_value(t, sc_err, nil)
	defer oa.schema_free(&schema)
	ic := make_i32_array([]i32{1, 2, 3, 4, 5})
	scol := make_string_array([]string{"a", "bb", "ccc", "dddd", "eeeee"})
	batch, rb_ok := oa.record_batch_make(&schema, []oa.Array{ic, scol})
	testing.expect(t, rb_ok)
	defer oa.record_batch_free(&batch)

	fp := ipc_test_temp_path("fuzz", "arrow")
	defer { os.remove(fp); delete(fp) }
	testing.expect(t, oa.ipc_write_file(fp, &schema, []oa.Record_Batch{batch}), "ipc_write_file must succeed")
	orig, orig_err := os.read_entire_file(fp, context.allocator)
	testing.expect_value(t, orig_err, nil)
	defer delete(orig)
	if orig_err != nil || len(orig) == 0 {
		return
	}

	free_result :: proc(sc: ^oa.Schema, batches: []oa.Record_Batch) {
		if sc != nil { oa.schema_free(sc); free(sc) }
		for bx in batches { bc := bx; oa.record_batch_free(&bc) }
		delete(batches)
	}

	// 1. Baseline: unmutated file must parse cleanly and match all rows.
	{
		sc0, bs0, ok0 := oa.ipc_read_file(fp)
		testing.expect(t, ok0, "unmutated IPC file must read cleanly")
		if ok0 {
			testing.expect_value(t, len(bs0), 1)
			if len(bs0) == 1 && sc0 != nil {
				testing.expect_value(t, len(sc0.fields), 2)
				testing.expect_value(t, bs0[0].length, 5)
				want_s := []string{"a", "bb", "ccc", "dddd", "eeeee"}
				for row in 0 ..< 5 {
					testing.expect_value(t, oa.array_get(&bs0[0].columns[0], row, i32), i32(row + 1))
					testing.expect_value(t, oa.array_get_string(&bs0[0].columns[1], row), want_s[row])
				}
			}
		}
		free_result(sc0, bs0)
	}

	// 2. Leading and trailing ARROW1 magic corruptions must be rejected.
	if len(orig) >= 12 {
		bad_buf := make([]u8, len(orig))
		defer delete(bad_buf)
		for pos in ([]int{0, len(orig) - 1}) {
			copy(bad_buf, orig)
			bad_buf[pos] ~= 0xFF
			testing.expect_value(t, os.write_entire_file(fp, bad_buf), nil)
			sc, bs, ok := oa.ipc_read_file(fp)
			testing.expectf(t, !ok, "corrupted magic at byte %d must fail", pos)
			free_result(sc, bs)
		}
	}

	// 3. Deterministic 1- and 2-byte random mutations: never crash, never leak.
	rng: u64 = 0x1234_5678_9abc_def1
	next :: proc(s: ^u64) -> u64 { s^ = s^*6364136223846793005 + 1442695040888963407; return (s^ >> 17) }
	mut_buf := make([]u8, len(orig))
	defer delete(mut_buf)
	for _ in 0..<1500 {
		copy(mut_buf, orig)
		mut_buf[int(next(&rng) % u64(len(orig)))] = u8(next(&rng))
		mut_buf[int(next(&rng) % u64(len(orig)))] = u8(next(&rng))
		if os.write_entire_file(fp, mut_buf) != nil { continue }
		sc, bs, _ := oa.ipc_read_file(fp)
		free_result(sc, bs)
	}

	// 4. Every strict prefix truncation must fail; full length must succeed.
	for cut in 0..<len(orig) {
		if os.write_entire_file(fp, orig[:cut]) != nil { continue }
		sc, bs, ok := oa.ipc_read_file(fp)
		testing.expectf(t, !ok, "strict truncation cut=%d/%d unexpectedly succeeded", cut, len(orig))
		free_result(sc, bs)
	}
	testing.expect_value(t, os.write_entire_file(fp, orig), nil)
	sc_full, bs_full, ok_full := oa.ipc_read_file(fp)
	testing.expect(t, ok_full, "restored full IPC file must read cleanly")
	free_result(sc_full, bs_full)
}

// ── Pattern E: Magic & Bounds Unit Coverage ──────────────────────────────────

@(test)
test_ipc_rejects_corrupt_tail_magic :: proc(t: ^testing.T) {
	good := ipc_test_temp_path("good_magic", "arrow")
	bad  := ipc_test_temp_path("bad_magic", "arrow")
	defer {
		os.remove(good)
		delete(good)
		os.remove(bad)
		delete(bad)
	}

	fields := []oa.Field{oa.field_make("n", oa.Int32_Type{})}
	schema, sc_err := oa.schema_make(fields)
	testing.expect_value(t, sc_err, nil)
	defer oa.schema_free(&schema)
	col := make_i32_array([]i32{1, 2, 3})
	batch, rb_ok := oa.record_batch_make(&schema, []oa.Array{col})
	testing.expect(t, rb_ok)
	defer oa.record_batch_free(&batch)
	testing.expect(t, oa.ipc_write_file(good, &schema, []oa.Record_Batch{batch}))

	data, err := os.read_entire_file(good, context.allocator)
	testing.expect_value(t, err, nil)
	defer delete(data)
	if err != nil || len(data) < 6 {
		return
	}

	copy(data[len(data) - 6:], "CORRUP")
	write_err := os.write_entire_file(bad, data)
	testing.expect_value(t, write_err, nil)
	if write_err != nil {
		return
	}

	sc, batches, ok := oa.ipc_read_file(bad)
	testing.expect(t, !ok, "file with corrupt tail magic must be rejected")
	if ok {
		if sc != nil {
			oa.schema_free(sc)
			free(sc)
		}
		for bx in batches {
			bc := bx
			oa.record_batch_free(&bc)
		}
		delete(batches)
	}
}

@(test)
test_ipc_stream_duplicate_schema_no_leak :: proc(t: ^testing.T) {
	s1  := ipc_test_temp_path("dup_s1", "arrows")
	s2  := ipc_test_temp_path("dup_s2", "arrows")
	dup := ipc_test_temp_path("dup_schema", "arrows")
	defer {
		os.remove(s1)
		delete(s1)
		os.remove(s2)
		delete(s2)
		os.remove(dup)
		delete(dup)
	}

	fields := []oa.Field{oa.field_make("val", oa.Int32_Type{})}
	schema, sc_err := oa.schema_make(fields)
	testing.expect_value(t, sc_err, nil)
	defer oa.schema_free(&schema)

	col1 := make_i32_array([]i32{10, 20})
	b1, rb_ok := oa.record_batch_make(&schema, []oa.Array{col1})
	testing.expect(t, rb_ok)
	defer oa.record_batch_free(&b1)

	testing.expect(t, oa.ipc_write_stream(s1, &schema, nil))
	testing.expect(t, oa.ipc_write_stream(s2, &schema, []oa.Record_Batch{b1}))

	s1_bytes, err1 := os.read_entire_file(s1, context.allocator)
	testing.expect_value(t, err1, nil)
	defer delete(s1_bytes)
	s2_bytes, err2 := os.read_entire_file(s2, context.allocator)
	testing.expect_value(t, err2, nil)
	defer delete(s2_bytes)
	if err1 != nil || err2 != nil || len(s1_bytes) < 8 {
		return
	}

	// Strip s1's 8-byte EOS marker so s2's Schema message directly follows s1's Schema message.
	schema_msg := s1_bytes[:len(s1_bytes) - 8]
	combined := make([]u8, len(schema_msg) + len(s2_bytes))
	defer delete(combined)
	copy(combined[:len(schema_msg)], schema_msg)
	copy(combined[len(schema_msg):], s2_bytes)
	testing.expect_value(t, os.write_entire_file(dup, combined), nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer check_no_leaks(t, &track)
	{
		old_alloc := context.allocator
		defer context.allocator = old_alloc
		context.allocator = mem.tracking_allocator(&track)
		sc, batches, ok := oa.ipc_read_stream(dup)
		testing.expect(t, ok, "duplicate-schema stream must remain readable")
		if ok {
			testing.expect_value(t, len(batches), 1)
			if len(batches) == 1 {
				testing.expect_value(t, batches[0].length, 2)
				if batches[0].length == 2 {
					c0 := oa.record_batch_column_at(&batches[0], 0)
					testing.expect_value(t, oa.array_get(c0, 0, i32), i32(10))
					testing.expect_value(t, oa.array_get(c0, 1, i32), i32(20))
				}
			}
		}
		if sc != nil {
			oa.schema_free(sc)
			free(sc)
		}
		for bx in batches {
			bc := bx
			oa.record_batch_free(&bc)
		}
		delete(batches)
	}
}

@(test)
test_ipc_bool_view_does_not_overread_past_byte_length :: proc(t: ^testing.T) {
	path := ipc_test_temp_path("bool_view_bounds", "arrow")
	defer {
		_ = os.remove(path)
		delete(path)
	}

	valid_canary: [128]u8
	bool_canary:  [128]u8
	for i in 0 ..< len(valid_canary) {
		valid_canary[i] = 0xAA
		bool_canary[i]  = 0xCC
	}
	valid_canary[0] = 0b0000_0101 // [valid, null, valid]
	bool_canary[0]  = 0b0000_0001 // [true, false, false]

	col := oa.Array{
		type       = oa.Bool_Type{},
		length     = 3,
		null_count = 1,
		buffers    = {
			oa.Buffer{data = raw_data(valid_canary[:1]), size = 1, capacity = 1},
			oa.Buffer{data = raw_data(bool_canary[:1]),  size = 1, capacity = 1},
			{},
		},
	}

	fields := []oa.Field{oa.field_make("flag", oa.Bool_Type{})}
	schema, s_err := oa.schema_make(fields)
	testing.expect_value(t, s_err, nil)
	defer oa.schema_free(&schema)

	rb, rb_ok := oa.record_batch_make(&schema, []oa.Array{col})
	testing.expect(t, rb_ok)
	if !rb_ok {
		return
	}
	defer oa.record_batch_free(&rb)

	testing.expect(t, oa.ipc_write_file(path, &schema, []oa.Record_Batch{rb}))

	raw, rd_err := os.read_entire_file(path, context.allocator)
	testing.expect_value(t, rd_err, nil)
	defer delete(raw)
	testing.expect_value(t, bytes.index(raw, []u8{0xAA, 0xAA, 0xAA, 0xAA}), -1)
	testing.expect_value(t, bytes.index(raw, []u8{0xCC, 0xCC, 0xCC, 0xCC}), -1)

	sc2, batches, ok := oa.ipc_read_file(path, use_mmap = false)
	testing.expect(t, ok)
	defer {
		if sc2 != nil {
			oa.schema_free(sc2)
			free(sc2)
		}
		for &b in batches {
			oa.record_batch_free(&b)
		}
		delete(batches)
	}
	if ok && len(batches) == 1 {
		out_col := oa.record_batch_column_at(&batches[0], 0)
		testing.expect_value(t, oa.array_get(out_col, 0, bool), true)
		testing.expect(t, oa.array_is_null(out_col, 1))
		testing.expect_value(t, oa.array_get(out_col, 2, bool), false)
	}
}

@(test)
test_ipc_stream_record_batch_before_schema_no_leak :: proc(t: ^testing.T) {
	s1  := ipc_test_temp_path("no_schema_s1", "arrows")
	s2  := ipc_test_temp_path("no_schema_s2", "arrows")
	bad := ipc_test_temp_path("no_schema_bad", "arrows")
	defer {
		_ = os.remove(s1);  delete(s1)
		_ = os.remove(s2);  delete(s2)
		_ = os.remove(bad); delete(bad)
	}

	fields := []oa.Field{oa.field_make("val", oa.Int32_Type{})}
	schema, sc_err := oa.schema_make(fields)
	testing.expect_value(t, sc_err, nil)
	defer oa.schema_free(&schema)

	col := make_i32_array([]i32{1, 2})
	rb, rb_ok := oa.record_batch_make(&schema, []oa.Array{col})
	testing.expect(t, rb_ok)
	defer oa.record_batch_free(&rb)

	testing.expect(t, oa.ipc_write_stream(s1, &schema, nil))
	testing.expect(t, oa.ipc_write_stream(s2, &schema, []oa.Record_Batch{rb}))

	s1_bytes, err1 := os.read_entire_file(s1, context.allocator)
	testing.expect_value(t, err1, nil)
	defer delete(s1_bytes)
	s2_bytes, err2 := os.read_entire_file(s2, context.allocator)
	testing.expect_value(t, err2, nil)
	defer delete(s2_bytes)
	if err1 != nil || err2 != nil || len(s1_bytes) < 8 || len(s2_bytes) <= len(s1_bytes) - 8 {
		return
	}

	schema_msg_len := len(s1_bytes) - 8
	batch_only := s2_bytes[schema_msg_len:]
	testing.expect_value(t, os.write_entire_file(bad, batch_only), nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer check_no_leaks(t, &track)
	{
		old_alloc := context.allocator
		defer context.allocator = old_alloc
		context.allocator = mem.tracking_allocator(&track)
		sc, batches, ok := oa.ipc_read_stream(bad, validate = false)
		testing.expect(t, !ok, "stream with RecordBatch before Schema must fail")
		if sc != nil {
			oa.schema_free(sc)
			free(sc)
		}
		for &b in batches {
			oa.record_batch_free(&b)
		}
		delete(batches)
	}
}

// Mutates every FlatBuffers Field table whose type_type discriminant is `_IPC_TYPE_INT`
// (2) inside the given Arrow buffer to `new_disc` (e.g. 0 = NONE, 8 = Date).
@(private="file")
patch_ipc_int_type_discriminant :: proc(buf: []u8, field_name: string, new_disc: u8) -> int {
	// Field table layout written by _ipc_write_schema_subtree:
	//   vtable: [vt_size:u16][obj_size:u16][name_voff:u16][nullable_voff:u16][type_type_voff:u16]...
	//   table:  [soffset:i32] ... [type_type:u8] ...
	// Locate the FlatBuffer string [len:u32][field_name] and find the Field table
	// whose name slot points to it.
	pat := make([]u8, 4 + len(field_name), context.temp_allocator)
	n := u32(len(field_name))
	pat[0] = u8(n); pat[1] = u8(n >> 8); pat[2] = u8(n >> 16); pat[3] = u8(n >> 24)
	copy(pat[4:], transmute([]u8)field_name)

	patched := 0
	for str_off := 0; str_off <= len(buf) - len(pat); str_off += 1 {
		if !bytes.equal(buf[str_off:str_off + len(pat)], pat) {
			continue
		}
		// Scan for 4-byte uoffset forward references to str_off
		for ref_pos := 4; ref_pos <= str_off - 4; ref_pos += 1 {
			rel := int(i32(buf[ref_pos]) | i32(buf[ref_pos+1])<<8 | i32(buf[ref_pos+2])<<16 | i32(buf[ref_pos+3])<<24)
			if ref_pos + rel != str_off {
				continue
			}
			for tbl := max(0, ref_pos - 16); tbl < ref_pos; tbl += 1 {
				if tbl + 4 > len(buf) { continue }
				soff := int(i32(buf[tbl]) | i32(buf[tbl+1])<<8 | i32(buf[tbl+2])<<16 | i32(buf[tbl+3])<<24)
				vt := tbl - soff
				if vt < 0 || vt + 10 > len(buf) { continue }
				vt_size := int(u16(buf[vt]) | u16(buf[vt+1])<<8)
				if vt_size < 10 || vt + vt_size > len(buf) { continue }
				name_vo := int(u16(buf[vt+4]) | u16(buf[vt+5])<<8)
				disc_vo := int(u16(buf[vt+8]) | u16(buf[vt+9])<<8)
				if name_vo > 0 && tbl + name_vo == ref_pos && disc_vo > 0 && tbl + disc_vo < len(buf) {
					if buf[tbl + disc_vo] == 2 { // _IPC_TYPE_INT
						buf[tbl + disc_vo] = new_disc
						patched += 1
					}
				}
			}
		}
	}
	return patched
}

@(test)
test_ipc_rejects_unknown_type_discriminant_no_leak :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	good_file   := ipc_test_temp_path("unk_good", "arrow")
	bad_file    := ipc_test_temp_path("unk_bad", "arrow")
	good_stream := ipc_test_temp_path("unk_good", "arrows")
	bad_stream  := ipc_test_temp_path("unk_bad", "arrows")
	defer {
		_ = os.remove(good_file);   delete(good_file)
		_ = os.remove(bad_file);    delete(bad_file)
		_ = os.remove(good_stream); delete(good_stream)
		_ = os.remove(bad_stream);  delete(bad_stream)
	}

	fields := []oa.Field{
		oa.field_make("unk_col_0", oa.Int32_Type{}),
		oa.field_make("tail_str",  oa.String_Type{}),
	}
	schema, sc_err := oa.schema_make(fields)
	testing.expect_value(t, sc_err, nil)
	defer oa.schema_free(&schema)

	c0 := make_i32_array([]i32{10, 20})
	c1 := make_string_array([]string{"x", "yy"})
	rb, rb_ok := oa.record_batch_make(&schema, []oa.Array{c0, c1})
	testing.expect(t, rb_ok)
	defer oa.record_batch_free(&rb)

	testing.expect(t, oa.ipc_write_file(good_file, &schema, []oa.Record_Batch{rb}))
	testing.expect(t, oa.ipc_write_stream(good_stream, &schema, []oa.Record_Batch{rb}))

	file_bytes, f_err := os.read_entire_file(good_file, context.temp_allocator)
	testing.expect_value(t, f_err, nil)
	stream_bytes, s_err := os.read_entire_file(good_stream, context.temp_allocator)
	testing.expect_value(t, s_err, nil)
	if f_err != nil || s_err != nil {
		return
	}

	// Test both _IPC_TYPE_NONE (0) and Date (8) in both file and stream formats
	for new_disc in ([]u8{0, 8}) {
		f_mut := make([]u8, len(file_bytes), context.temp_allocator)
		copy(f_mut, file_bytes)
		n_f := patch_ipc_int_type_discriminant(f_mut, "unk_col_0", new_disc)
		testing.expect(t, n_f >= 1, "expected to patch at least one Field discriminant in IPC file")
		testing.expect_value(t, os.write_entire_file(bad_file, f_mut), nil)

		s_mut := make([]u8, len(stream_bytes), context.temp_allocator)
		copy(s_mut, stream_bytes)
		n_s := patch_ipc_int_type_discriminant(s_mut, "unk_col_0", new_disc)
		testing.expect(t, n_s >= 1, "expected to patch at least one Field discriminant in IPC stream")
		testing.expect_value(t, os.write_entire_file(bad_stream, s_mut), nil)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer check_no_leaks(t, &track)
		{
			old_alloc := context.allocator
			defer context.allocator = old_alloc
			context.allocator = mem.tracking_allocator(&track)

			sc1, bs1, ok1 := oa.ipc_read_file(bad_file, use_mmap = false)
			testing.expect(t, !ok1, "IPC file with unknown type discriminant must be rejected")
			if ok1 {
				if sc1 != nil { oa.schema_free(sc1); free(sc1) }
				for &b in bs1 { oa.record_batch_free(&b) }
				delete(bs1)
			}

			sc2, bs2, ok2 := oa.ipc_read_stream(bad_stream, use_mmap = false)
			testing.expect(t, !ok2, "IPC stream with unknown type discriminant must be rejected")
			if ok2 {
				if sc2 != nil { oa.schema_free(sc2); free(sc2) }
				for &b in bs2 { oa.record_batch_free(&b) }
				delete(bs2)
			}
		}
	}
}
