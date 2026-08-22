# Alohomora — Unlock AI Infrastructure 🪄

Open-source AI infrastructure you can actually run yourself. A k3s cluster on your own
machine, rented GPU servers joining over WireGuard when you need them, vLLM behind a real
AI gateway, and load tests that tell you exactly how many concurrent users your GPUs can
handle before they fall over.

> *"It's leviOsa, not levioSA"* — and it's `nvidia.com/gpu: 1`, not a mock.

## Why this exists

Most "LLMs on Kubernetes" tutorials either mock the GPU or assume you own a DGX. Neither
is real life. The interesting problems start when your GPU is a rented VM on the other
side of the internet: how does it join the cluster, what breaks inside the tunnel, where
do the model weights live so the GPU node stays disposable, and what actually happens
when 200 clients hit vLLM at the same time. That's what this repo digs into — and
everything is automated, so tearing it all down and rebuilding is routine, not a setback.

## Architecture

```
Your machine (Vagrant + QEMU)                 Internet (rented GPU VM)
┌──────────────────────────────┐              ┌─────────────────────────┐
│  cp1  cp2  cp3   worker1     │  WireGuard   │  gpu1 (NVIDIA)          │
│  k3s HA (embedded etcd)      │◄────────────►│  k3s agent, tainted     │
│  Cilium (no kube-proxy)      │   tunnel     │  GPU Operator           │
│  Envoy AI Gateway            │              │  vLLM + model           │
│  MinIO (model weights)       │              │  (disposable node)      │
│  Prometheus / Grafana        │              └─────────────────────────┘
└──────────────────────────────┘              (+ gpu2 to test scale-out)
```

- **Cluster:** k3s HA with embedded etcd, 3 servers + 1 agent, kube-vip floating VIP for
  the API (`192.168.105.210`). k3s runs stripped down (`--flannel-backend=none
  --disable-kube-proxy --disable servicelb,traefik`) so Cilium handles everything:
  kube-proxy replacement, LB-IPAM, Hubble observability. etcd never leaves your machine.
- **GPU nodes** are full VMs with root access (Lambda, DataCrunch, GCP spot — container
  rentals can't join a cluster). They connect over WireGuard as tainted k3s agents.
  One stretched cluster, not multi-cluster. NVIDIA GPU Operator handles drivers.
- **Model weights live in MinIO** on the local cluster. vLLM itself has to run on the GPU
  node (CUDA is local-only), but it pulls weights from S3 at startup — which is exactly
  what makes GPU nodes disposable.
- **Gateway:** Envoy AI Gateway. Token-based quotas per consumer, model tiering (premium
  orgs get the big Qwen, others get the small one), provider fallback, and Gateway API
  Inference Extension for KV-cache-aware routing across vLLM replicas.
- **Scaling:** across GPU nodes it's data parallelism — full vLLM replicas behind the
  gateway. Tensor parallelism over a WAN tunnel is a trap; don't.
- **GitOps:** ArgoCD app-of-apps. The only thing ever installed by hand is ArgoCD itself.

## Running it

You need Vagrant, QEMU and the vagrant-qemu plugin. On macOS also socket_vmnet
(vmnet needs root, hence the sudo):

```bash
brew install qemu vagrant socket_vmnet
vagrant plugin install vagrant-qemu
sudo brew services start socket_vmnet
```

Then:

```bash
make cluster                        # VMs + k3s + Cilium + kube-vip, start to finish
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes                   # 4 nodes, Ready
```

`make mesh-test` checks the inter-VM network, `make down` destroys everything.
The exact bring-up log with all commands is in
[docs/runbooks/00-bootstrap-local-cluster.md](docs/runbooks/00-bootstrap-local-cluster.md),
and [docs/TESTING.md](docs/TESTING.md) has the failure drills.

Inter-VM networking runs over socket_vmnet (the same mechanism Lima and Colima use) —
a shared L2 segment that your Mac is also on, so kubectl talks to the VIP directly.
QEMU's multicast socket networking was the first attempt; it silently drops packets on
macOS. Node IPs sit high in the subnet to stay clear of the vmnet DHCP range.

## Status

- [x] local lab: 4 VMs, k3s HA, Cilium kube-proxy-free, kube-vip VIP — verified
- [x] GitOps tree: ArgoCD app-of-apps with cert-manager, Longhorn, MinIO
- [x] monitoring: kube-prometheus-stack (Grafana, Alertmanager); Loki/Tempo deferred
- [x] CPU serving tier: llama.cpp + Qwen3-0.6B, weights cached in MinIO, behind a
      Cilium LoadBalancer — first k6 capacity test done
      ([the writeup](docs/runbooks/01-first-capacity-test.md) is worth reading)
- [x] ingress: Cilium ingress controller, every UI on a `*.nip.io` hostname over one
      shared LB IP — zero port-forwards ([docs/OPERATIONS.md](docs/OPERATIONS.md))
- [ ] default-deny network policies
- [ ] WireGuard hub + first rented GPU node, GPU Operator, `nvidia.com/gpu` in the cluster
- [ ] vLLM serving weights from MinIO, Envoy AI Gateway, model tiering
- [ ] load testing: k6 + vllm bench, find the real saturation point
- [ ] second GPU node: KV-cache-aware routing, scale-from-zero provisioner

## Things that will save you a day

- **MTU inside WireGuard:** Cilium's overlay needs a lowered MTU (~1280–1340) inside the
  tunnel or you get connections that mysteriously hang.
- **etcd must never span sites.** Only workers stretch over the tunnel. Quorum over a WAN
  is how you lose a cluster.
- vLLM's concurrency ceiling is **KV-cache VRAM**, not CPU. Bigger model or longer
  context = fewer concurrent clients. The load tests make this visible.
- Secrets never touch git: the k3s join token and MinIO credentials are generated into a
  gitignored `.secrets/` directory. Vault + External Secrets comes later.
- On Apple Silicon forget VirtualBox; QEMU + HVF via vagrant-qemu works fine.
