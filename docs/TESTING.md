# Infrastructure Testing & Drills

Every drill deliberately breaks something, observes the failure, and proves recovery.
Write findings into `docs/runbooks/` — a drill without a writeup didn't happen.

## Test levels

| Level | What | When |
|-------|------|------|
| Smoke | Network + node health after any bring-up | after every `make up` / rebuild |
| Drill | Deliberate failure injection | once per phase, and after big changes |
| Load  | Capacity testing against vLLM (k6, vllm bench) | Phase 6+ |

## Smoke tests

```bash
make mesh-test                      # 20/20 pings: node<->node + node<->host
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes                   # 4 nodes Ready
kubectl get --raw /readyz           # "ok" via the VIP (192.168.105.210)
kubectl get pods -A | grep -v Running | grep -v Completed   # should be empty
```

## Drill 1 — Control-plane failure (etcd quorum + VIP failover)

**Hypothesis:** with 3 servers, losing one keeps the API fully functional (reads AND writes);
the VIP moves within seconds if its holder dies.

```bash
# Terminal 1 — continuous observation:
watch kubectl get nodes

# Terminal 2 — power-cut cp2 (halt -f = no clean shutdown):
vagrant halt -f cp2
```

Verify while cp2 is down:

```bash
kubectl get nodes                          # cp2 NotReady, API still answering
kubectl create deployment drill-nginx --image=nginx   # WRITE to etcd must succeed
kubectl -n kube-system logs -l app.kubernetes.io/name=kube-vip-ds --tail=20
                                           # watch leader election if cp2 held the VIP
ping -c1 192.168.105.210                   # VIP alive on a surviving node
```

Recovery:

```bash
vagrant up cp2                             # etcd member rejoins, node back to Ready
kubectl delete deployment drill-nginx      # cleanup
```

**Harder variant:** `vagrant destroy -f cp2 && vagrant up cp2`, then re-run
`ansible-playbook site.yml` — a control-plane node burned to the ground and rebuilt.

**Expected failure to understand:** kill TWO servers → quorum lost (1/3) → API goes
read-only/down entirely. That's why it's 3, and why 2 servers are worse than 1.

## Drill 2 — GitOps drift correction (after Phase 2 sync is live)

```bash
kubectl -n minio edit deployment minio     # hand-edit something (e.g. replicas)
# watch ArgoCD revert it within the sync window — git is the only source of truth
kubectl -n longhorn-system delete namespace longhorn-system   # nuke a whole namespace
# watch ArgoCD resurrect it from git
```

## Drill 3 — Worker/storage failure (after Longhorn is live)

```bash
vagrant halt -f worker1                    # the only worker: workloads go Pending
vagrant up worker1                         # everything reschedules; Longhorn volume recovers
```

## Drill 4 — WireGuard/GPU node loss (Phase 4+)

Kill the WireGuard tunnel to a GPU node mid-inference: vLLM pod goes NotReady,
gateway fails over to the fallback model, queue drains when the node returns.
Also the MTU test lives here: Cilium-in-WireGuard needs MTU ~1280–1340.

## Load tests (Phase 6+)

- `vllm bench serve` — TTFT, TPOT, tokens/sec at increasing concurrency
- k6 against the OpenAI-compatible endpoint — find max concurrent clients before
  `num_requests_waiting` explodes and `gpu_cache_usage_perc` saturates
- Compare 1 GPU node vs 2 (data parallelism) — measure real scale-out efficiency
