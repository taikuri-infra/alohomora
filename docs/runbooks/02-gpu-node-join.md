# Joining a rented GPU node over WireGuard

The lab sits behind NAT; the GPU VM has a public IP. So the tunnel is dial-out:
every lab node initiates to the GPU's endpoint (keepalive 25s holds the NAT
mapping open), and the GPU VM just listens on udp/51820. No port-forwarding at
home, ever.

```
cp1     10.8.0.11 ─┐
cp2     10.8.0.12 ─┤  dial out ────────►  gpu1  10.8.0.31
cp3     10.8.0.13 ─┤  (keepalive 25s)     listens :51820/udp
worker1 10.8.0.21 ─┘                      public IP
```

Each lab node is a direct peer of the GPU node (real mesh, no hub node, no
single point of failure). The GPU's peer entries carry two AllowedIPs per lab
node: its WireGuard IP and its 192.168.105.x node IP — so k3s and Cilium VXLAN
traffic to node IPs routes through the tunnel.

## What's already in place (no GPU needed)

- `ansible/wireguard.yml` — wg0 on all four nodes, keys generated on-node,
  pubkeys collected to `.secrets/wg/`
- k3s server certs include the WG IPs (tls-san `10.8.0.11-13`) so the agent can
  trust the API through the tunnel
- `scripts/make-gpu-bootstrap.sh` — renders `.secrets/gpu1-bootstrap.sh` with
  the real pubkeys + join token baked in
- `gitops/apps/gpu-operator.yaml` — NVIDIA GPU Operator v26.7.0 synced and
  idle: its driver/toolkit/device-plugin daemonsets only land on nodes where
  NFD detects NVIDIA silicon. The moment a GPU node joins, everything happens
  by itself.

## Renting the VM — requirements

- **Full VM with root** (Lambda, DataCrunch, Scaleway, GCP/AWS spot). Container
  rentals (Vast.ai-style) cannot join a cluster as nodes.
- Ubuntu 22.04, any NVIDIA data-center/pro GPU (A4000 and up is fine for
  Qwen-7B-class models; A6000/L40S for headroom)
- udp/51820 reachable from the internet (check the provider's firewall/SG)
- Nothing else: no k8s, no drivers — the bootstrap + GPU Operator do everything

## The join — Terraform way (preferred)

Provider: **Verda** (ex-DataCrunch, Helsinki — `FIN-03`, lowest latency to the
lab). Official Terraform provider `verda-cloud/verda`; auth via
`VERDA_CLIENT_ID`/`VERDA_CLIENT_SECRET` env vars (console → API keys).

```bash
export VERDA_CLIENT_ID=... VERDA_CLIENT_SECRET=...
./scripts/gpu-up.sh 2        # rent 2 nodes, join both, watch kubectl get nodes -w
./scripts/gpu-down.sh        # drain + destroy + drop peers — billing stops
```

What gpu-up does: generates local wg keys for gpuN (once) → `terraform apply`
(`terraform/gpu/`: instance + ssh key + startup script per node; cloud-init has
the wg private key, lab pubkeys and join token baked in — zero interactive key
exchange) → writes `.secrets/wg/gpu-peers.json` from terraform outputs → runs
the wireguard playbook so every lab node dials every GPU. Spot instances:
`-var is_spot=true` in `terraform/gpu/` for deep discounts.

Defaults: `1A6000.10V` (RTX A6000 48GB — $0.61/h on-demand, $0.31/h **spot, which is
the default**; 2-node session ≈ $0.62/h), image with preinstalled driver
(`ubuntu-24.04-cuda-12.8-open-docker`) — which is why the GPU Operator runs
with `driver.enabled=false` and only wires the toolkit into k3s containerd.

## The join — manual way (any provider)

```bash
# 1. on the Mac — render the bootstrap (contains secrets, lives in .secrets/):
./scripts/make-gpu-bootstrap.sh

# 2. copy & run on the fresh VM:
scp .secrets/gpu1-bootstrap.sh root@<GPU_IP>:
ssh root@<GPU_IP> 'bash gpu1-bootstrap.sh'
#    → installs wireguard (listener) + k3s agent (retries until tunnel is up)
#    → prints the GPU's wireguard PUBLIC KEY at the end

# 3. on the Mac — point every lab node at the GPU:
cd ansible
ansible-playbook wireguard.yml -e gpu_pubkey=<KEY_FROM_STEP_2> -e gpu_endpoint=<GPU_IP>:51820

# 4. watch it join:
kubectl get nodes -w                       # gpu1 appears, Ready
kubectl get pods -n gpu-operator -w        # driver/toolkit/plugin land on gpu1
kubectl describe node gpu1 | grep nvidia.com/gpu   # ← the money line: nvidia.com/gpu: 1
```

The node arrives labeled (`alohomora.dev/tier=gpu` — kubelet may NOT self-assign
`node-role.kubernetes.io/*` labels, an anti-privilege-escalation rule; add the cosmetic
role after join: `kubectl label node gpu1 node-role.kubernetes.io/gpu-worker=true`) and tainted (`nvidia.com/gpu=present:NoSchedule`) —
nothing schedules there except pods that explicitly tolerate the taint (GPU
Operator operands do; vLLM will).

## Teardown (the point of the whole design)

```bash
kubectl drain gpu1 --ignore-daemonsets --delete-emptydir-data
kubectl delete node gpu1
# destroy the VM at the provider — billing stops
cd ansible && ansible-playbook wireguard.yml    # re-render configs without the peer
```

Nothing of value lived on the node: weights are in MinIO, state is in git.
Rent, join, serve, destroy — that's the elastic-GPU story.

## Expected failure modes (watch for these)

- **MTU**: wg0 runs MTU 1340 everywhere; Cilium VXLAN inside the tunnel needs
  the lowered value or connections hang mysteriously mid-stream. If pod-to-pod
  to gpu1 stalls while node pings work: it's this. `cilium status` + check
  route MTUs.
- **k3s TLS**: if the agent logs certificate errors against `10.8.0.11`, the
  tls-san rollout didn't reach that server — re-run `k3s-config-update.yml`.
- **Provider firewall**: agent joins but pods can't talk → udp/51820 fine but
  check nothing else is filtered inside the tunnel (it shouldn't be — VXLAN
  rides inside wg).
