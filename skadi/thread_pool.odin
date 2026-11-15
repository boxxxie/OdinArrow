package skadi

import "base:runtime"
import "core:os"
import "core:sync"
import "core:thread"

// A process-lifetime worker pool for the parallel compute kernels. Workers are
// created once (lazily) and parked on a condition variable, so each parallel
// call is a broadcast + barrier instead of spawning and tearing down threads
// (~50µs per call). One partition is assigned per worker (work is already
// chunked by the caller), so there is no task queue or work stealing.
//
// Usage model is single-caller: the compute kernels are invoked from one thread
// at a time (no nested or concurrent parallelism), which keeps the barrier logic
// simple — a job is fully complete before the next one starts.
//
// The pool's own threads/slices are allocated on the raw heap, not the caller's
// context allocator, so they never show up as "leaks" in a tracking allocator
// (e.g. the test runner): the pool is a singleton that lives until process exit.

_Pool_Worker :: struct {
	pool:      ^_Compute_Pool,
	id:        int,
	work_cond: sync.Cond, // dedicated per-worker condvar avoids waking idle SMT threads
}

_Compute_Pool :: struct {
	workers:        []^thread.Thread,
	wdata:          []_Pool_Worker,
	n:              int, // number of worker threads (== logical cores)

	submit:         sync.Mutex, // serialises whole jobs so concurrent callers don't clash
	mutex:          sync.Mutex,
	done_cond:      sync.Cond, // wakes the caller when the job is complete

	gen:            u64, // job generation; workers wait for it to advance
	job:            proc(ctx: rawptr, idx: int),
	ctx:            rawptr,
	job_n:          int, // total morsels in the current job
	active_workers: int, // participating background workers (w.id < active_workers)
	next_idx:       int, // atomic morsel counter claimed by workers and caller
	completed:      int, // background workers finished in the current job
	shutdown:       bool,
}

@(private) g_pool:      _Compute_Pool
@(private) g_pool_once: sync.Once

_pool_get :: proc() -> ^_Compute_Pool {
	sync.once_do(&g_pool_once, _pool_init)
	return &g_pool
}

@(private)
_pool_init :: proc() {
	// Keep the pool's allocations off any caller's (tracking) allocator.
	context.allocator = runtime.heap_allocator()

	n := os.get_processor_core_count()
	if n < 1 { n = 1 }
	g_pool.n       = n
	g_pool.workers = make([]^thread.Thread, n)
	g_pool.wdata   = make([]_Pool_Worker, n)
	for i in 0..<n {
		g_pool.wdata[i] = _Pool_Worker{ pool = &g_pool, id = i }
		g_pool.workers[i] = thread.create_and_start_with_poly_data(&g_pool.wdata[i], _pool_worker)
	}
}

@(private)
_pool_worker :: proc(w: ^_Pool_Worker) {
	p := w.pool
	last_gen := u64(0)
	for {
		sync.mutex_lock(&p.mutex)
		for (p.gen == last_gen || w.id >= p.active_workers) && !p.shutdown {
			sync.cond_wait(&w.work_cond, &p.mutex)
		}
		if p.shutdown {
			sync.mutex_unlock(&p.mutex)
			return
		}
		last_gen = p.gen
		job      := p.job
		ctx      := p.ctx
		n_tasks  := p.job_n
		sync.mutex_unlock(&p.mutex)

		for {
			idx := sync.atomic_add(&p.next_idx, 1)
			if idx >= n_tasks { break }
			job(ctx, idx)
		}
		free_all(context.temp_allocator)
		sync.mutex_lock(&p.mutex)
		p.completed += 1
		if p.completed == p.active_workers {
			sync.cond_signal(&p.done_cond)
		}
		sync.mutex_unlock(&p.mutex)
	}
}

// Run job(ctx, i) for i in 0..<total_tasks across up to nt threads (up to
// nt-1 pool workers plus the calling thread) using atomic morsel claiming, and
// block until all tasks complete. nt <= 1 runs inline on the calling thread.
_pool_run :: proc(nt: int, job: proc(ctx: rawptr, idx: int), ctx: rawptr, n_tasks := -1) {
	total_tasks := n_tasks if n_tasks >= 0 else nt
	if total_tasks <= 0 { return }
	if nt <= 1 || total_tasks == 1 {
		for i in 0..<total_tasks {
			job(ctx, i)
		}
		return
	}
	p := _pool_get()
	active_w := min(nt - 1, p.n, total_tasks - 1)
	if active_w <= 0 {
		for i in 0..<total_tasks {
			job(ctx, i)
		}
		return
	}

	// One job uses the pool, so serialise whole jobs: concurrent callers
	// (e.g. the multi-threaded test runner) each take the pool in turn rather
	// than clobbering the shared job/gen/completed state.
	sync.mutex_lock(&p.submit)
	defer sync.mutex_unlock(&p.submit)

	sync.mutex_lock(&p.mutex)
	p.job            = job
	p.ctx            = ctx
	p.job_n          = total_tasks
	p.active_workers = active_w
	p.completed      = 0
	sync.atomic_store(&p.next_idx, 0)
	p.gen           += 1
	for i in 0..<active_w {
		sync.cond_signal(&p.wdata[i].work_cond)
	}
	sync.mutex_unlock(&p.mutex)

	for {
		idx := sync.atomic_add(&p.next_idx, 1)
		if idx >= total_tasks { break }
		job(ctx, idx)
	}

	sync.mutex_lock(&p.mutex)
	for p.completed < active_w {
		sync.cond_wait(&p.done_cond, &p.mutex)
	}
	sync.mutex_unlock(&p.mutex)
}

// The pool is a process-lifetime singleton: its workers park until the program
// exits, when the OS reclaims them along with the heap-allocated bookkeeping.
// The `shutdown` flag is read by the workers so an explicit teardown entry
// point could be added later.
