#+build !linux
#+build !darwin
package skadi

// Fallback stub for platforms without POSIX mmap/writev support.
import "core:os"

_IPC_IOVec_Len :: uint
_IPC_IOVec :: struct {
	iov_base: rawptr,
	iov_len:  _IPC_IOVec_Len,
}

_ipc_writev_all :: proc(f: ^os.File, iovs: []_IPC_IOVec) -> (written_total: i64, ok: bool) {
	for iov in iovs {
		if iov.iov_len == 0 { continue }
		buf := (cast([^]u8)iov.iov_base)[:int(iov.iov_len)]
		written := 0
		for written < len(buf) {
			n, err := os.write(f, buf[written:])
			if err != nil || n <= 0 { return written_total, false }
			written += n
			written_total += i64(n)
		}
	}
	return written_total, true
}

_ipc_map_file :: proc(path: string) -> (data: []u8, unmap: proc(_: []u8), ok: bool) {
	return nil, nil, false
}
