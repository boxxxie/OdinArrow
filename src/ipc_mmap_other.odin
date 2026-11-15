#+build !linux
#+build !darwin
package odinarrow

// Fallback stub for platforms without POSIX mmap support.
_ipc_map_file :: proc(path: string) -> (data: []u8, unmap: proc(_: []u8), ok: bool) {
	return nil, nil, false
}
