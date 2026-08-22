# First capacity test — CPU fallback model

Three k6 runs against `qwen-small` (llama.cpp, Qwen3-0.6B Q8, 4 slots, worker1:
4 vCPU / 8GB) through the Cilium LoadBalancer. Ramp: 2 → 4 → 8 → 16 VUs over 3
minutes. Full history in git; this is what happened and what it taught.

## Run 1 — the server died

96.9% failures. `kubectl describe pod` → **OOMKilled, exit 137**: the memory
limit was 4Gi, and `--ctx-size 8192` × 4 slots of KV cache plus HTTP buffers
under concurrent load crossed it. Two knock-on lessons:

- The concurrency ceiling of an LLM server is **context memory**, not CPU.
  Same law vLLM follows on GPUs with VRAM — witnessed here at toy scale.
- After the kill, k6 (no backoff) hammered the restarting pod at ~100 req/s of
  instant connection-refused, which made recovery look worse than it was.
  Clients without backoff are part of the outage, not observers of it.

Fixes: ctx 8192→4096, memory limit 4→6Gi, `--threads 3` (one core left for
kubelet/probes), k6 gets 2s backoff-on-failure + 0.5s think time.

## Run 2 — the test lied

0 failures, but `has content` failed on every response: **Qwen3 is a thinking
model** — with `max_tokens: 64` the entire budget went into `<think>` and
`content` came back empty. The failed check triggered the new backoff every
iteration, so the "load test" was actually a 1.5 req/s trickle. Lesson:
validate what the model actually returns before trusting green/red checks.
Fix: `/no_think` in prompts, accept `reasoning_content`, max_tokens 96.

## Run 3 — real numbers

| Metric | Value |
|---|---|
| Requests completed | 403 (95.5% ok; 18 timeouts at the 16-VU peak) |
| Latency med / p95 / max | 1.25s / 3.27s / **19.75s** (the queue tail) |
| Per-request decode speed | ~71 tok/s median |
| Aggregate throughput at peak | ~250 tok/s, ~165 completion tok/s sustained |
| Memory | 3.58GB steady — no OOM, survived the full ramp |

Prometheus during the 8-VU stage: `requests_processing = 4` (all slots busy),
`requests_deferred = 1` (queue starts) — saturation begins exactly at slot
count, as designed.

## The capacity statement

The CPU fallback tier serves **4 concurrent clients comfortably** (~1.3s
median), degrades gracefully to ~8 (queueing, p95 ~3s), and stretches to
multi-second tails beyond that — but **stays alive**. That last property is
what run 1 lacked and is worth more than any throughput number.

Next: the same ramp against real vLLM on a rented GPU node — same script, same
dashboards, orders of magnitude more tokens/s. That comparison is the point of
the whole exercise.
