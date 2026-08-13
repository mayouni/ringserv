# The N-worker concurrency model — phase-1 benchmark note

*The roadmap's phase-1 risk gate: the blueprint's concurrency model
(N isolated RingStates, one per worker thread, no sharing) had to be
proven or replaced before anything is built on it. It is proven —
within the limits stated below.*

## The experiment

`ringserv bench-workers` (src/bench.zig, committed, rerunnable):
each worker thread owns a private `RingState`, runs 200 evaluations
of a mixed workload (loops, list building, string building), and
verifies every evaluation's checksum through a per-thread hook. Any
cross-thread interference shows up as a wrong checksum or a crash.

## Results (2026-08-05, Windows 11, 12 logical cores, ReleaseFast)

| threads | evals/sec | scaling | verified |
|---:|---:|---:|---|
| 1 | 1,964 | ×1.00 | OK |
| 2 | 3,505 | ×1.78 | OK |
| 4 | 6,014 | ×3.06 | OK |
| 8 | ~9,500 (stable across runs) | ×4.8–5.0 | OK |
| 16 | 10,179 | ×5.18 | OK |

No crashes and no result corruption in any run, including repeat
runs at 8 workers and the 16-worker oversubscription round.

## Reading the numbers

- **The model stands**: isolated states run concurrently and
  correctly. Nothing shared, nothing corrupted — the VM's
  state-encapsulation held under real parallelism.
- **~2,000 evals/sec/worker** for a non-trivial workload is far above
  the phase-2 need (each service call is roughly one eval of this
  size or smaller).
- **Scaling flattens past 4 workers** (×3.06 at 4, ~×5 at 8–16).
  The suspects, in order: the shared C-allocator under 8-way
  allocation pressure (Ring allocates heavily), physical-core count
  (this machine's 12 logical cores are not 12 P-cores), and cache
  pressure. A per-worker allocator arena is the known lever if
  phase 2 load tests want more; not spent now.

## What this does NOT prove

- Absence of every data race — this is an empirical gate. It should
  be re-run long (hours) before 0.9, and under a race detector on
  Linux (TSan builds of the VM) in phase 8.
- Anything about `ring_state_init` called concurrently — the bench
  initializes states inside each thread and it held; but the phase-2
  server will initialize workers sequentially at boot anyway, out of
  caution.
- Thread-safety of any single state used from two threads. That is
  not the model, and nothing may ever assume it.

## Consequence for phase 2

The HTTP core feeds N workers, each owning one resident RingState;
requests are dispatched to idle workers; services stay stateless by
contract (state lives in SQLite). Worker count defaults to physical
cores, capped by measurement, configurable in `Serv()`.
