package skadi

import "core:mem"
import "core:strings"

Field :: struct {
	name:     string,
	type:     DataType,
	nullable: bool,
}

Schema :: struct {
	fields:    []Field,
	allocator: mem.Allocator,
}

field_make :: proc(name: string, type: DataType, nullable := true) -> Field {
	return Field{name = name, type = type, nullable = nullable}
}

// Deep-copies field names so the schema owns its strings.
@(require_results)
schema_make :: proc(fields: []Field, allocator := context.allocator) -> (s: Schema, err: mem.Allocator_Error) {
	fs := make([]Field, len(fields), allocator) or_return
	for i in 0..<len(fields) {
		f := fields[i]
		name_copy, clone_err := strings.clone(f.name, allocator)
		if clone_err != nil {
			for j in 0..<i {
				delete(fs[j].name, allocator)
			}
			delete(fs, allocator)
			return {}, clone_err
		}
		fs[i] = Field{name = name_copy, type = f.type, nullable = f.nullable}
	}
	s = Schema{fields = fs, allocator = allocator}
	return
}

schema_free :: proc(s: ^Schema) {
	for i in 0..<len(s.fields) {
		delete(s.fields[i].name, s.allocator)
	}
	delete(s.fields, s.allocator)
	s^ = {}
}

// Returns the index of the named field, or (-1, false).
schema_field_index :: proc(s: ^Schema, name: string) -> (idx: int, ok: bool) {
	if s == nil { return -1, false }
	for i in 0..<len(s.fields) {
		if s.fields[i].name == name { return i, true }
	}
	return -1, false
}
