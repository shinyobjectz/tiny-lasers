# F2 vs node — concurrency envelope (Track A / J1)

**The pitch F2 actually proves is not speed — it is *isolation under concurrent load*.** F2 compiles untrusted
JS to native BEAM, so every request runs in its own preemptively-scheduled, resource-bounded process. On node's
single event loop, one genuinely-heavy (CPU-bound, synchronous) request blocks *everything*.

## Reproduce

```
node bench/concurrency/bench_node.js      # the node oracle (same handler logic)
mix run bench/concurrency/bench_f2.exs    # F2 (process-per-request)
```

## The honest envelope (measured; 10-core machine, 4000 requests, concurrency 50)

Same handler logic on both. LIGHT = a small parse+fold. HEAVY = a CPU-bound compute.

| workload | node — LIGHT p99 | F2 — LIGHT p99 | who wins |
|---|---|---|---|
| pure light | ~sub-ms, higher raw throughput | 0.02 ms | **node** (V8 is ~100× faster per-op) |
| 5% heavy, **fast** handler (~1 ms in V8) | 1.65 ms | ~0.6 ms | roughly even |
| 5% heavy, **genuine** handler (~16.8 ms) | **2,510 ms** | **0.63 ms** | **F2 (~4,000×)** |
| 20% heavy, genuine handler | worse (backlog grows unbounded) | 2.12 ms | **F2** |

### Read this honestly

1. **When all work is fast, node wins.** V8 is a JIT; F2 (AOT-to-BEAM, no JIT) is ~100× slower per operation.
   A pure-light or fast-handler workload has no reason to leave node.

2. **The moment a genuinely-heavy request shares the runtime with fast ones, node's fast endpoints collapse.**
   A 16.8 ms synchronous handler at just 5% of traffic drives node's LIGHT p99 to **2.5 seconds** (the event
   loop backs up faster than it drains). F2's LIGHT p99 stays at **0.63 ms** — a heavy request runs in its own
   process on its own scheduler and cannot touch the fast ones. And F2's advantage *grows*: it is flat as heavy
   duration and heavy fraction rise, while node's backlog deepens without bound.

3. **This is node's well-known event-loop-blocking problem.** Node *can* mitigate with `worker_threads` /
   Piscina / `cluster` — at the cost of explicit engineering (identify CPU work, marshal it to a worker, manage
   the pool) and a *fixed* pool that still saturates and still blocks 1/N of traffic per busy worker. F2 gets
   per-request isolation + preemption *for free*, because BEAM processes are ~KB and spawn in microseconds — you
   cannot afford a node process per request, but you can afford a BEAM one.

### The one-line version

> Node is faster per request; F2 is faster *under load with mixed request costs* — a slow request can't poison
> your fast ones. Real servers have both fast and slow endpoints, so the F2 property is the one that governs
> tail latency in production.
