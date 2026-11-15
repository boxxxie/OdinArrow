#+build linux, darwin
package skadi

// Memory mapping for the zero-copy IPC reader (unix).
//
// mmap the file read-only so its pages fault in lazily on access — the reader
// exposes columns as views into the mapping and never streams the whole file
// through a read syscall, matching how Arrow C++/PyArrow read IPC files.

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

_IPC_IOVec     :: posix.iovec
_IPC_IOVec_Len :: c.size_t

_ipc_writev_all :: proc(f: ^os.File, iovs: []_IPC_IOVec) -> (written_total: i64, ok: bool) {
	raw_fd := os.fd(f)
	if raw_fd == ~uintptr(0) { return 0, false }
	fd := posix.FD(raw_fd)
	rem_iovs := iovs
	for len(rem_iovs) > 0 {
		n := posix.writev(fd, raw_data(rem_iovs), c.int(len(rem_iovs)))
		if n < 0 {
			if posix.errno() == .EINTR { continue }
			return written_total, false
		}
		if n == 0 { return written_total, false }
		written_total += i64(n)
		rem_iovs = _ipc_advance_iovecs(rem_iovs, int(n))
	}
	return written_total, true
}

// Map `path` read-only. Returns the mapped bytes, a matching unmap proc, and
// ok=true on success. On failure ok=false (the caller falls back to a read).
_ipc_map_file :: proc(path: string) -> (data: []u8, unmap: proc(_: []u8), ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cpath, posix.O_Flags{})   // empty flags == O_RDONLY
	if fd < 0 { return }
	defer posix.close(fd)

	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK { return }
	size := int(st.st_size)
	if size <= 0 { return }

	addr := posix.mmap(nil, c.size_t(size), {.READ}, {.PRIVATE}, fd, 0)
	if addr == posix.MAP_FAILED { return }

	data  = (cast([^]u8)addr)[:size]
	unmap = _ipc_unmap
	ok    = true
	return
}

_ipc_unmap :: proc(data: []u8) {
	if len(data) > 0 { posix.munmap(raw_data(data), c.size_t(len(data))) }
}
