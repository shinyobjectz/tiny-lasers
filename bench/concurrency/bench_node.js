// Node oracle for the F2 concurrency benchmark (Track A / J1). SAME handler logic as bench_f2.exs, run on node's
// single event loop — the default model for a JS server. Run: node bench/concurrency/bench_node.js
//
// It measures LIGHT-request latency under a mixed load. When a genuinely-heavy (CPU-bound, synchronous) request
// runs, it blocks the event loop; requests that arrive during it queue, and under sustained load the backlog
// makes fast-endpoint latency collapse. (Node CAN mitigate with worker_threads / cluster — at the cost of
// explicit engineering and a FIXED pool that still saturates; F2 is immune by construction: process per request.)

const hr = () => Number(process.hrtime.bigint()) / 1e6;

function light() {
  let s = 0;
  const p = "a,bb,ccc,dddd".split(",");
  for (let j = 0; j < p.length; j++) s += p[j].length;
  return s;
}
function heavy(iters) {
  let s = 0;
  for (let j = 0; j < iters; j++) s += Math.sqrt(j) * 1.0001;
  return s;
}
function pct(xs, p) {
  const s = xs.slice().sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.round(p * s.length))].toFixed(2);
}

// Fire N requests on a steady arrival schedule; a fraction are heavy. Latency = (when it finished) − (intended
// arrival) = queue-wait (head-of-line blocking) + handler time.
function bench(label, N, heavyFrac, heavyIters, arrivalGapMs) {
  return new Promise((resolve) => {
    const lights = [];
    let pending = N;
    const start = hr();
    for (let k = 0; k < N; k++) {
      const kind = heavyFrac > 0 && k % Math.round(1 / heavyFrac) === 0 ? "heavy" : "light";
      const intended = k * arrivalGapMs;
      setTimeout(() => {
        if (kind === "heavy") heavy(heavyIters);
        else light();
        const latency = hr() - start - intended;
        if (kind === "light") lights.push(latency);
        if (--pending === 0) {
          console.log(`${label}: LIGHT p50=${pct(lights, 0.5)} p99=${pct(lights, 0.99)} p999=${pct(lights, 0.999)}ms`);
          resolve();
        }
      }, intended);
    }
  });
}

(async () => {
  let t = hr(); heavy(300000); const h1 = (hr() - t).toFixed(2);
  t = hr(); heavy(30000000); const h2 = (hr() - t).toFixed(1);
  console.log(`NODE heavy-handler durations: 300K-sqrt=${h1}ms (fast in V8)  30M-sqrt=${h2}ms (genuinely heavy)`);
  await bench("  5%-heavy (fast 300K handler)   ", 4000, 0.05, 300000, 0.2);
  await bench("  5%-heavy (genuine 30M handler) ", 4000, 0.05, 30000000, 0.2);
})();
