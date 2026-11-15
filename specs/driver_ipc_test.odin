package skadi_specs

import "core:testing"
import oa "../skadi"

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
		driver_free_batch_slice(out_batches)
		return
	}
	if sc != nil {
		append(&w.schemas, sc)
		w.set_schemas[set_name] = sc
	}
	driver_put_batch_set(w, set_name, out_batches, loc)
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
		driver_free_batch_slice(out_batches)
		return
	}
	if sc != nil {
		append(&w.schemas, sc)
		w.set_schemas[set_name] = sc
	}
	driver_put_batch_set(w, set_name, out_batches, loc)
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
		driver_free_batch_slice(out_batches)
		return
	}
	if sc != nil {
		append(&w.schemas, sc)
		w.set_schemas[set_name] = sc
	}
	driver_put_batch_set(w, set_name, out_batches, loc)
}
