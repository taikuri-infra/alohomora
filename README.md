# Alohomora — Unlock AI Infrastructure 🪄

A from-scratch, provider-agnostic Kubernetes AI platform: local 4-node cluster on the Mac,
elastic **rented-GPU nodes joining over WireGuard**, vLLM serving with real capacity testing.
Built as a hands-on learning project for AI-platform-engineer roles.

> *"It's leviOsa, not levioSA"* — and it's `nvidia.com/gpu: 1`, not a mock.

## Architecture

```
Mac (Vagrant + QEMU)                          Internet (rented GPU VM)
┌──────────────────────────────┐              ┌─────────────────────────┐
│  cp1  cp2  cp3   worker1     │  WireGuard   │  gpu1 (NVIDIA)          │
│  k3s HA (embedded etcd)      │◄────────────►│  k3s agent, tainted     │
│  Cilium (no kube-proxy)      │   tunnel     │  GPU Operator           │
│  Envoy AI Gateway            │              │  vLLM + model           │
│  MinIO (model weights)       │              │  (disposable node)      │
│  Prometheus / Grafana        │              └─────────────────────────┘
└──────────────────────────────┘              (+ gpu2 for scale-out test)
```

- **Cluster:** k3s HA (embedded etcd), 3 servers + 1 agent. kube-vip VIP: `192.168.105.210`.
  k3s runs stripped (`--flannel-backend=none --disable-network-policy --disable=servicelb
  --disable=traefik`) so **Cilium does everything** (kube-proxy replacement, LB-IPAM, Hubble).
  etcd never leaves the Mac. k3s over RKE2: lighter, simpler, and this ships to orgs as an
  open-source tool — low-friction install matters. Scales to 10+ GPU agents joining later.
- **GPU nodes:** full VMs with root (Lambda / DataCrunch / GCP spot — container rentals can't
  join as nodes). Join over WireGuard as tainted `gpu_worker` nodes. One stretched cluster.
- **GPU Operator** installs driver + container toolkit → node advertises `nvidia.com/gpu`.
- **Model weights live in MinIO** (S3 API) on the local cluster — GPU nodes stay disposable.
  vLLM *must* run on the GPU node (CUDA is local-only); everything else stays on the Mac.
- **AI Gateway: Envoy AI Gateway** — token-based quotas per consumer/org, model tiering
  (high tier → big Qwen, normal tier → small Qwen), provider fallback, and Gateway API
  Inference Extension (InferencePool: KV-cache/queue-depth-aware routing to vLLM replicas).
- **Capacity testing:** k6 + `vllm bench serve` against the OpenAI-compatible endpoint.
  Metrics that matter: TTFT, TPOT, tokens/sec, `num_requests_waiting`, `gpu_cache_usage_perc`.
  Scale-out = data parallelism (2 vLLM replicas), never tensor parallelism over WAN.

## Local lab

Requirements: Vagrant + `vagrant-qemu` plugin + QEMU (homebrew). Box: `perk/ubuntu-2204-arm64`.

One-time (vmnet needs root):

```bash
brew install socket_vmnet
sudo brew services start socket_vmnet
```

```bash
make up          # boot all 4 nodes
make status
make mesh-test   # verify inter-VM mesh network
make ssh-cp1
make down        # destroy everything (rebuilding is practice, not a setback)
```

Inter-VM networking uses **socket_vmnet** (same as Lima/Colima) — a shared L2 segment that the
Mac host is also on (`bridge100`, `192.168.105.1`), so `kubectl` works directly from the host.
Node IPs on `192.168.105.0/24` (static, high range to dodge vmnet DHCP), see `Vagrantfile`.
(QEMU multicast-socket mesh was tried first — mcast loopback doesn't work on macOS.)

## Gotchas (learned the hard way / by design)

- **MTU over WireGuard:** Cilium overlay inside WireGuard needs lowered MTU (~1280–1340)
  or you get mysterious hangs. Expected failure mode when GPU nodes join.
- **etcd must never span sites** — only workers stretch over the tunnel.
- vLLM concurrency limit = **KV-cache VRAM**, not CPU. Bigger model / longer context =
  fewer concurrent clients. This is the tradeoff the stress tests make visible.
- VirtualBox is not installed (and is rough on Apple Silicon) — the lab runs on QEMU+HVF.

## Roadmap

- [x] Phase 0 — repo scaffold, 4-node Vagrant lab, mesh network
- [ ] Phase 1 — k3s HA (embedded etcd) + kube-vip + Cilium (Ansible)
- [ ] Phase 2 — GitOps core: ArgoCD, cert-manager, Longhorn, MinIO
- [ ] Phase 3 — Observability: Prometheus/Grafana/Loki, default-deny NetworkPolicies
- [ ] Phase 4 — WireGuard hub + first rented GPU node joins (GPU Operator, `nvidia.com/gpu` visible)
- [ ] Phase 5 — vLLM serving (weights from MinIO), Envoy AI Gateway, model tiering
- [ ] Phase 6 — Capacity testing: k6 + vllm bench, find the saturation point, write it up
- [ ] Phase 7 — Scale-out: 2nd GPU node, InferencePool KV-cache-aware routing, scale-from-zero

Runbooks from every drill land in `docs/runbooks/` — those are the interview stories.
