# Infrastructure Testing & Drills

Every drill deliberately breaks something, observes the failure, and proves recovery.
Write findings into `docs/runbooks/` — a drill without a writeup didn't happen.

## Test levels

| Level | What | When |
|-------|------|------|
| Smoke | Network + node health after any bring-up | after every `make up` / rebuild |
| Drill | Deliberate failure injection | after every milestone and big change |
| Load  | Capacity testing against vLLM (k6, vllm bench) | once vLLM is serving |

## Smoke tests

The 30-second whole-cluster check:

```bash
make mesh-test                      # 20/20 pings: node<->node + node<->host
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes                   # 4 nodes Ready
kubectl get --raw /readyz           # "ok" via the VIP (192.168.105.210)
kubectl get pods -A | grep -v Running | grep -v Completed   # should be empty
```

### Per-technology smoke tests

**k3s / etcd** — three servers, quorum, all members healthy:

```bash
kubectl get nodes -o wide                                   # 4 Ready, expected IPs
vagrant ssh cp1 -c 'sudo k3s etcd-snapshot save --name smoke && sudo ls /var/lib/rancher/k3s/server/db/snapshots/'
kubectl get --raw /livez?verbose | grep -v ok | head        # every check "ok"
```

**kube-vip** — the VIP answers and exactly one leader holds it:

```bash
ping -c1 192.168.105.210
kubectl -n kube-system logs -l app.kubernetes.io/name=kube-vip-ds --tail=5 | grep -i leader
```

**Cilium** — agents healthy on every node, no unmanaged endpoints:

```bash
kubectl -n kube-system exec ds/cilium -- cilium status --brief    # "OK"
kubectl -n kube-system exec ds/cilium -- cilium-health status | tail -8
kubectl get ciliumloadbalancerippool -o wide                      # lab-pool, IPs available
```

**Hubble** — flows are actually being observed:

```bash
kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
hubble observe --last 5 2>/dev/null || kubectl -n kube-system exec ds/cilium -- hubble observe --last 5
```

**ArgoCD** — every app Synced/Healthy, nothing drifting:

```bash
kubectl -n argocd get applications                          # all Synced/Healthy
kubectl -n argocd get app root -o jsonpath='{.status.sync.revision}'   # matches git HEAD
```

**Longhorn** — volumes attached, replicas healthy, and a real write:

```bash
kubectl -n longhorn-system get volumes.longhorn.io          # state: attached, robustness: healthy
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: smoke-pvc }
spec: { accessModes: [ReadWriteOnce], resources: { requests: { storage: 100Mi } } }
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/smoke-pvc --timeout=60s
kubectl delete pvc smoke-pvc                                # cleanup
```

**MinIO** — S3 API answers and the models bucket exists:

```bash
kubectl -n minio port-forward svc/minio 9000:9000 &
source .secrets/minio-root 2>/dev/null || true
mc alias set lab http://localhost:9000 "$rootUser" "$rootPassword" 2>/dev/null \
  || curl -s http://localhost:9000/minio/health/live -o /dev/null -w "S3 health: %{http_code}\n"
mc ls lab/                                                  # bucket: models
```

**Ingress (cilium)** — all UIs answer on their nip.io hostnames:

```bash
kubectl -n kube-system get svc cilium-ingress    # EXTERNAL-IP 192.168.105.231
for h in grafana prometheus alertmanager argocd hubble longhorn minio s3; do
  printf '%-14s ' "$h"
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 "http://$h.192.168.105.231.nip.io/"
done
# expect 200s (prometheus 302 → /graph, s3 403 = S3 API refusing anonymous — both fine)
```

**Prometheus / Grafana / Alertmanager** — targets up, datasource wired:

```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
curl -s 'localhost:9090/api/v1/query?query=up' | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(len(r), "targets up")'
curl -s 'localhost:9090/api/v1/query?query=count(node_uname_info)'   # expect 4 nodes
kubectl -n monitoring get pods | grep -v Running | grep -v NAME      # empty
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

## Drill 2 — GitOps drift correction (once ArgoCD sync is live)

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

## Drill 4 — WireGuard/GPU node loss (once a GPU node is attached)

Kill the WireGuard tunnel to a GPU node mid-inference: vLLM pod goes NotReady,
gateway fails over to the fallback model, queue drains when the node returns.
Also the MTU test lives here: Cilium-in-WireGuard needs MTU ~1280–1340.

## Load tests (once vLLM is serving)

- `vllm bench serve` — TTFT, TPOT, tokens/sec at increasing concurrency
- k6 against the OpenAI-compatible endpoint — find max concurrent clients before
  `num_requests_waiting` explodes and `gpu_cache_usage_perc` saturates
- Compare 1 GPU node vs 2 (data parallelism) — measure real scale-out efficiency
