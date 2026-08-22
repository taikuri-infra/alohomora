// k6 load test against any OpenAI-compatible endpoint (llama.cpp now, vLLM later).
//
//   k6 run -e BASE_URL=http://192.168.105.230:8000 -e MODEL=qwen-small \
//     scripts/load/chat-completions.js
//
// Stages ramp concurrency up until the server saturates. Watch alongside:
//   - k6 output: p95 duration, req/s, errors
//   - Grafana: llamacpp:requests_deferred (queue), prompt/predicted tokens/s
import http from "k6/http";
import { check, sleep } from "k6";
import { Trend, Counter } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://192.168.105.230:8000";
const MODEL = __ENV.MODEL || "qwen-small";

const completionTokens = new Counter("llm_completion_tokens");
const tokensPerSec = new Trend("llm_tokens_per_second");

export const options = {
  scenarios: {
    ramp: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: "30s", target: 2 },
        { duration: "60s", target: 4 },   // = --parallel slots
        { duration: "60s", target: 8 },   // 2x slots: queueing begins
        { duration: "30s", target: 16 },  // saturation: watch latency explode
      ],
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.05"],
  },
};

// /no_think: qwen3 is a thinking model — without it, small max_tokens
// budgets get eaten by <think> and content comes back empty
const prompts = [
  "/no_think Explain what etcd quorum means in three sentences.",
  "/no_think Write a haiku about load balancers.",
  "/no_think What is the difference between a Deployment and a DaemonSet?",
  "/no_think Summarize why model weights should live in object storage.",
];

export default function () {
  const payload = JSON.stringify({
    model: MODEL,
    messages: [{ role: "user", content: prompts[Math.floor(Math.random() * prompts.length)] }],
    max_tokens: 96,
  });

  const res = http.post(`${BASE_URL}/v1/chat/completions`, payload, {
    headers: { "Content-Type": "application/json" },
    timeout: "120s",
  });

  const ok = check(res, {
    "status 200": (r) => r.status === 200,
    "has content": (r) => {
      try {
        const m = JSON.parse(r.body).choices[0].message;
        return (m.content || m.reasoning_content || "").length > 0;
      } catch { return false; }
    },
  });

  if (ok) {
    const usage = JSON.parse(res.body).usage;
    if (usage && usage.completion_tokens) {
      completionTokens.add(usage.completion_tokens);
      tokensPerSec.add(usage.completion_tokens / (res.timings.duration / 1000));
    }
  } else {
    sleep(2);   // back off on failure — don't hammer a dying server with instant retries
  }
  sleep(0.5);   // think time
}
