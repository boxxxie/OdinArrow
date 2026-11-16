package skadi

import "core:mem"

// Buffer_Pool is a free-list allocator that retains freed blocks (bucketed by
// size) and hands them back on the next allocation of the same size, instead of
// returning them to the OS. Reused blocks keep their pages resident, so a
// build → free → build loop avoids re-faulting fresh pages every time — the same
// reuse strategy Arrow's memory pool relies on to make repeated construction
// cheap.
//
// Use it by passing buffer_pool_allocator(&pool) as the builder's allocator.
//
// Not thread-safe: use one pool per thread (builders are single-threaded).
// All blocks are released by buffer_pool_destroy.

Buffer_Pool :: struct {
	backing:          mem.Allocator,
	free_list:        map[_Pool_Key][dynamic]rawptr, // (size, align) -> stack of free user pointers
	bases:            [dynamic]^_Pool_Header,        // every live backing block (for destroy & O(1) eviction)
	large_lru:        [dynamic]^_Pool_Header,        // cached >4 MB blocks in FIFO/LRU order
	free_large_bytes: int,                           // total cached bytes in large_lru
	hits:             u64,                           // blocks served from free_list or in-place resize
	misses:           u64,                           // fresh blocks allocated from backing allocator
}

@(private="file")
_Pool_Key :: struct {
	size:  int,
	align: int,
}

@(private="file")
_Pool_Header :: struct {
	size:     int,    // bucket capacity in bytes
	align:    int,    // bucket alignment in bytes
	base:     rawptr, // backing allocation start
	base_idx: int,    // index in pool.bases
}

@(private="file")
_POOL_HDR :: size_of(_Pool_Header)

@(private="file")
_next_power_of_two :: proc "contextless" (x: int) -> int {
	if x <= 1 { return 1 }
	max_pow := 1 << uint(8 * size_of(int) - 2)
	if x > max_pow { return x }
	v := x - 1
	v |= v >> 1
	v |= v >> 2
	v |= v >> 4
	v |= v >> 8
	v |= v >> 16
	when size_of(int) == 8 {
		v |= v >> 32
	}
	return v + 1
}

buffer_pool_init :: proc(pool: ^Buffer_Pool, backing := context.allocator) {
	pool.backing = backing
	// Bookkeeping always lives in the backing allocator, never context.allocator:
	// callers commonly set context.allocator to this very pool, and routing the
	// pool's own metadata through itself is reentrant (use-after-free).
	pool.free_list = make(map[_Pool_Key][dynamic]rawptr, 16, backing)
	pool.bases     = make([dynamic]^_Pool_Header, 0, 0, backing)
	pool.large_lru = make([dynamic]^_Pool_Header, 0, 0, backing)
}

// Release every block the pool ever allocated, plus its bookkeeping.
buffer_pool_destroy :: proc(pool: ^Buffer_Pool) {
	for h in pool.bases {
		mem.free(h.base, pool.backing)
	}
	delete(pool.bases)
	delete(pool.large_lru)
	for _, stack in pool.free_list {
		delete(stack)
	}
	delete(pool.free_list)
	pool^ = {}
}

buffer_pool_allocator :: proc(pool: ^Buffer_Pool) -> mem.Allocator {
	return mem.Allocator{procedure = _buffer_pool_proc, data = pool}
}

@(private="file")
_buffer_pool_proc :: proc(
	allocator_data: rawptr, mode: mem.Allocator_Mode,
	size, alignment: int, old_memory: rawptr, old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	pool := cast(^Buffer_Pool)allocator_data

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		ptr, err := _pool_get(pool, size, alignment)
		if err != .None { return nil, err }
		if size == 0 { return nil, .None }
		if mode == .Alloc { mem.zero(ptr, size) }
		return (cast([^]byte)ptr)[:size], .None

	case .Free:
		if old_memory != nil { _pool_put(pool, old_memory) }
		return nil, .None

	case .Free_All:
		// A pool keeps memory owned for reuse; nothing is returned to the OS
		// until buffer_pool_destroy. Treat Free_All as a no-op.
		return nil, .None

	case .Resize, .Resize_Non_Zeroed:
		ptr, err := _pool_resize(pool, old_memory, old_size, size, alignment, mode == .Resize)
		if err != .None { return nil, err }
		if size == 0 { return nil, .None }
		return (cast([^]byte)ptr)[:size], .None

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Free_All, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, .None

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .None
}

@(private="file")
LARGE_BUCKET_THRESHOLD  :: 4 * 1024 * 1024   // 4 MB
@(private="file")
LARGE_BUCKET_STEP       :: 256 * 1024        // 256 KB
@(private="file")
_MAX_CACHED_LARGE_BYTES :: 128 * 1024 * 1024 // cap retained >4 MB free blocks at 128 MB

// Bucketing policy: power-of-two up to 4 MB for fast small/medium reuse, then
// 256 KB step alignment above 4 MB so large payloads (e.g., 11 MB or 20 MB) do
// not round up 2x to the next power of two.
@(private="file")
_bucket_size :: proc "contextless" (size: int) -> int {
	clamped := max(size, ARROW_ALIGNMENT)
	if clamped <= LARGE_BUCKET_THRESHOLD {
		return _next_power_of_two(clamped)
	}
	return align_up(clamped, LARGE_BUCKET_STEP)
}

@(private="file")
_pool_unlink_and_free :: proc(pool: ^Buffer_Pool, h: ^_Pool_Header) {
	idx := h.base_idx
	last := len(pool.bases) - 1
	if idx != last {
		moved := pool.bases[last]
		pool.bases[idx] = moved
		moved.base_idx = idx
	}
	pop(&pool.bases)
	mem.free(h.base, pool.backing)
}

@(private="file")
_pool_pop_specific_free :: proc(pool: ^Buffer_Pool, h: ^_Pool_Header) {
	key := _Pool_Key{size = h.size, align = h.align}
	stack, ok := pool.free_list[key]
	if !ok { return }
	user := rawptr(uintptr(h) + uintptr(_POOL_HDR))
	for i := len(stack) - 1; i >= 0; i -= 1 {
		if stack[i] == user {
			unordered_remove(&stack, i)
			break
		}
	}
	if len(stack) == 0 {
		delete(stack)
		delete_key(&pool.free_list, key)
	} else {
		pool.free_list[key] = stack
	}
}

@(private="file")
_pool_remove_large_lru :: proc(pool: ^Buffer_Pool, h: ^_Pool_Header) {
	for entry, i in pool.large_lru {
		if entry == h {
			ordered_remove(&pool.large_lru, i)
			pool.free_large_bytes -= h.size
			return
		}
	}
}

// Hand back a block of at least `size` bytes (reused if one is free), with the
// user pointer aligned to `effective_align` and bucketed by `(bucket_size, effective_align)`.
@(private="file")
_pool_get :: proc(pool: ^Buffer_Pool, size, alignment: int) -> (rawptr, mem.Allocator_Error) {
	if size == 0 { return nil, .None }
	effective_align := _next_power_of_two(max(alignment, align_of(_Pool_Header)))
	bucket_size := _bucket_size(size)
	key := _Pool_Key{size = bucket_size, align = effective_align}
	if stack, ok := pool.free_list[key]; ok && len(stack) > 0 {
		user := stack[len(stack) - 1]
		pop(&stack)
		if len(stack) == 0 {
			delete(stack)
			delete_key(&pool.free_list, key)
		} else {
			pool.free_list[key] = stack
		}
		if bucket_size > LARGE_BUCKET_THRESHOLD {
			h := (^_Pool_Header)(rawptr(uintptr(user) - uintptr(_POOL_HDR)))
			_pool_remove_large_lru(pool, h)
		}
		pool.hits += 1
		return user, .None
	}
	if bucket_size > LARGE_BUCKET_THRESHOLD && len(pool.large_lru) > 0 {
		max_slack := bucket_size + bucket_size / 4
		best_idx := -1
		best_sz  := max(int)
		for h, i in pool.large_lru {
			if h.align == effective_align && h.size >= bucket_size && h.size <= max_slack && h.size < best_sz {
				best_sz  = h.size
				best_idx = i
			}
		}
		if best_idx >= 0 {
			h := pool.large_lru[best_idx]
			ordered_remove(&pool.large_lru, best_idx)
			pool.free_large_bytes -= h.size
			_pool_pop_specific_free(pool, h)
			pool.hits += 1
			return rawptr(uintptr(h) + uintptr(_POOL_HDR)), .None
		}
	}
	total := _POOL_HDR + effective_align + bucket_size
	raw, err := mem.alloc_bytes_non_zeroed(total, effective_align, pool.backing)
	if err != .None || raw == nil { return nil, .Out_Of_Memory }
	base := raw_data(raw)
	au   := uintptr(effective_align)
	user := (uintptr(base) + uintptr(_POOL_HDR) + au - 1) & ~(au - 1)
	header := (^_Pool_Header)(rawptr(user - uintptr(_POOL_HDR)))
	header.size     = bucket_size
	header.align    = effective_align
	header.base     = base
	header.base_idx = len(pool.bases)
	append(&pool.bases, header)
	pool.misses += 1
	return rawptr(user), .None
}

@(private="file")
_pool_put :: proc(pool: ^Buffer_Pool, user: rawptr) {
	header := (^_Pool_Header)(rawptr(uintptr(user) - uintptr(_POOL_HDR)))
	if header.size > LARGE_BUCKET_THRESHOLD {
		if header.size > _MAX_CACHED_LARGE_BYTES {
			_pool_unlink_and_free(pool, header)
			return
		}
		for len(pool.large_lru) > 0 && pool.free_large_bytes + header.size > _MAX_CACHED_LARGE_BYTES {
			victim := pool.large_lru[0]
			ordered_remove(&pool.large_lru, 0)
			pool.free_large_bytes -= victim.size
			_pool_pop_specific_free(pool, victim)
			_pool_unlink_and_free(pool, victim)
		}
		append(&pool.large_lru, header)
		pool.free_large_bytes += header.size
	}
	key := _Pool_Key{size = header.size, align = header.align}
	s, ok := pool.free_list[key]
	if !ok {
		// New bucket — back its stack with the pool's backing allocator so
		// appends never reenter the pool via context.allocator.
		s = make([dynamic]rawptr, 0, 0, pool.backing)
	}
	append(&s, user)
	pool.free_list[key] = s
}

@(private="file")
_pool_resize :: proc(pool: ^Buffer_Pool, old_memory: rawptr, old_size, new_size, alignment: int, zeroed: bool) -> (rawptr, mem.Allocator_Error) {
	if old_memory == nil {
		p, err := _pool_get(pool, new_size, alignment)
		if err != .None { return nil, err }
		if zeroed && new_size > 0 { mem.zero(p, new_size) }
		return p, .None
	}
	if new_size == 0 {
		_pool_put(pool, old_memory)
		return nil, .None
	}
	header   := (^_Pool_Header)(rawptr(uintptr(old_memory) - uintptr(_POOL_HDR)))
	capacity := header.size
	safe_old := clamp(old_size, 0, capacity)
	req_align := uintptr(max(alignment, 1))
	if new_size <= capacity && uintptr(old_memory) % req_align == 0 {
		if zeroed && new_size > safe_old {
			mem.zero(rawptr(uintptr(old_memory) + uintptr(safe_old)), new_size - safe_old)
		}
		pool.hits += 1
		return old_memory, .None
	}
	// Grow: take a bigger block, copy the live bytes, recycle the old one.
	p, err := _pool_get(pool, new_size, alignment)
	if err != .None { return nil, err }
	keep := min(safe_old, new_size)
	if keep > 0 { mem.copy(p, old_memory, keep) }
	if zeroed && new_size > keep {
		mem.zero(rawptr(uintptr(p) + uintptr(keep)), new_size - keep)
	}
	_pool_put(pool, old_memory)
	return p, .None
}
