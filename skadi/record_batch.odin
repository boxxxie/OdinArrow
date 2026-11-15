package skadi

import "base:intrinsics"
import "core:mem"

// Reference-counted file/mmap backing shared across zero-copy IPC batches.
_IPC_Backing :: struct {
	ref_count: int,
	data:      []u8,
	release:   proc(_: []u8),
	allocator: mem.Allocator,
}

// RecordBatch owns its column arrays. It borrows the Schema (does not free it).
// All columns must have the same length and match the schema's field count.
Record_Batch :: struct {
	schema:       ^Schema,
	columns:      []Array,
	length:       int,
	allocator:    mem.Allocator,
	_ipc_backing: ^_IPC_Backing,
}

// Shallow-copies the columns slice (Arrays share their underlying buffers).
// Returns ok=false if column count, lengths, or types do not match.
@(require_results)
record_batch_make :: proc(
	schema:  ^Schema,
	columns: []Array,
	allocator := context.allocator,
) -> (rb: Record_Batch, ok: bool) {
	if schema == nil { return {}, false }
	if len(columns) != len(schema.fields) { return {}, false }
	n := 0
	if len(columns) > 0 {
		n = columns[0].length
		for i in 0..<len(columns) {
			if columns[i].length != n { return {}, false }
			if columns[i].type != schema.fields[i].type { return {}, false }
		}
	}
	cols, err := make([]Array, len(columns), allocator)
	if err != nil { return {}, false }
	copy(cols, columns)
	return Record_Batch{
		schema    = schema,
		columns   = cols,
		length    = n,
		allocator = allocator,
	}, true
}

// Free owned column arrays and the columns slice. Does NOT free the Schema.
// View buffers (those that point into _ipc_backing) are no-ops in
// array_free; the shared backing block is released when the last batch drops it.
record_batch_free :: proc(rb: ^Record_Batch) {
	for i in 0..<len(rb.columns) {
		array_free(&rb.columns[i], rb.allocator)
	}
	delete(rb.columns, rb.allocator)
	if rb._ipc_backing != nil {
		backing := rb._ipc_backing
		if intrinsics.atomic_sub(&backing.ref_count, 1) == 1 {
			if backing.release != nil {
				backing.release(backing.data)
			} else {
				delete(backing.data, backing.allocator)
			}
			free(backing, backing.allocator)
		}
	}
	rb^ = {}
}

// Return a pointer to the column named `name`, or nil.
record_batch_column :: proc(rb: ^Record_Batch, name: string) -> ^Array {
	if rb == nil || rb.schema == nil { return nil }
	idx, ok := schema_field_index(rb.schema, name)
	if !ok { return nil }
	return &rb.columns[idx]
}

record_batch_column_at :: proc(rb: ^Record_Batch, i: int) -> ^Array {
	return &rb.columns[i]
}
