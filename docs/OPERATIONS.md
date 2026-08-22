# Operating the stack

How to reach, inspect, start and stop every moving part. Assumes
`export KUBECONFIG=$PWD/kubeconfig` from the repo root.

## The map

All web UIs sit behind the cilium ingress controller on one shared LB IP
(`192.168.105.231`); nip.io turns that into hostnames with zero DNS setup.

| Component | How to reach it |
|-----------|-----------------|
| Kubernetes API | VIP `https://192.168.105.210:6443` (kubeconfig points here) |
| **AI Gateway (OpenAI API)** | `http://192.168.105.232/v1` — the front door; routes by model name |
| qwen-small direct | `http://192.168.105.230:8000/v1` (bypasses gateway — debugging only) |
| Grafana | http://grafana.192.168.105.231.nip.io |
| Prometheus | http://prometheus.192.168.105.231.nip.io |
| Alertmanager | http://alertmanager.192.168.105.231.nip.io |
| ArgoCD | http://argocd.192.168.105.231.nip.io |
| Hubble UI | http://hubble.192.168.105.231.nip.io |
| Longhorn UI | http://longhorn.192.168.105.231.nip.io |
| MinIO console | http://minio.192.168.105.231.nip.io |
| MinIO S3 API | http://s3.192.168.105.231.nip.io (apps use `minio.minio.svc:9000`) |
| Node SSH | `192.168.105.211-213, .221` — `make ssh-cp1` etc., or plain ssh |

Ingress manifests: `gitops/platform/ingress/`. HTTP-only for now; TLS arrives
with cert-manager + a real domain.

**Security stance, stated explicitly:** these URLs are plaintext HTTP and some
UIs (Prometheus, Alertmanager, Hubble, Longhorn) have no auth of their own.
That's acceptable *only* because `192.168.105.0/24` is a host-only bridge —
reachable from this machine alone, not from the LAN or internet. The moment
anything gets a public IP (Hetzner move, GPU node), the rule flips: TLS via
cert-manager, SSO/oauth2-proxy in front of authless UIs, and nothing exposed
by default. Don't copy this pattern onto a routable network.

LoadBalancer IPs from the Cilium pool (`192.168.105.230-239`) will replace most
port-forwards once services get `type: LoadBalancer` — the Mac reaches those IPs
directly over the vmnet bridge.

## Port-forward fallback (only if ingress is down)

```bash
kubectl -n argocd         port-forward svc/argo-cd-argocd-server 8080:443 &
kubectl -n kube-system    port-forward svc/hubble-ui 8081:80 &
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8082:80 &
kubectl -n minio          port-forward svc/minio-console 9001:9001 &
kubectl -n minio          port-forward svc/minio 9000:9000 &
kubectl -n monitoring     port-forward svc/monitoring-grafana 3000:80 &
kubectl -n monitoring     port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
kubectl -n monitoring     port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &
```

Kill them all: `pkill -f "kubectl.*port-forward"`

## Credentials

| What | Where |
|------|-------|
| ArgoCD admin | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| MinIO root | `.secrets/minio-root` (gitignored, created by `scripts/create-minio-secret.sh`) |
| Grafana admin | `kubectl -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' \| base64 -d` (user: `admin`) |
| k3s join token | `.secrets/k3s-token` (gitignored, generated on first ansible run) |
| Node SSH keys | `.vagrant/machines/<node>/qemu/private_key` |

## Whole-lab on/off

```bash
vagrant halt                # stop all VMs, state survives (RAM freed)
vagrant up                  # bring them back — k3s auto-starts, cluster reassembles
make down                   # DESTROY everything (vagrant destroy -f)
make cluster                # full rebuild from nothing: VMs + ansible
```

After `vagrant up` from a halt, give it ~2 minutes: etcd needs quorum (2 of 3
servers up) before the API answers, then pods restart on their own. Longhorn
volumes reattach automatically.

## Per-component on/off

Everything below ArgoCD is GitOps-managed: **"off" means telling ArgoCD, not
kubectl delete** (self-heal would resurrect it — that's the point of drill 2).

```bash
# stop something temporarily: scale down AND pause self-heal for that app
kubectl -n argocd patch app monitoring --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'      # pause auto-sync
kubectl -n monitoring scale deploy monitoring-grafana --replicas=0

# resume
kubectl -n argocd patch app monitoring --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

# remove something permanently: delete its file from gitops/apps/ and push.
git rm gitops/apps/<thing>.yaml && git commit -m "remove <thing>" && git push
# root app prunes it from the cluster within the sync window (~3 min)
```

k3s itself (on a node, via ssh):

```bash
sudo systemctl status k3s        # servers: k3s | agents: k3s-agent
sudo systemctl restart k3s
sudo journalctl -u k3s -f        # the single most useful log on a node
```

## Where data lives

| Data | Location | Survives `vagrant halt`? | Survives `make down`? |
|------|----------|--------------------------|----------------------|
| etcd (cluster state) | `/var/lib/rancher/k3s/server/db` on cp1-3 | yes | **no** |
| Longhorn volumes | `/var/lib/longhorn` on worker1 | yes | **no** |
| MinIO objects | Longhorn volume `minio` | yes | **no** |
| Git (the source of truth) | GitHub | yes | yes |
| Secrets | `.secrets/` on the Mac | yes | yes |

That last column is the whole GitOps argument: `make down && make cluster` +
re-running `scripts/create-minio-secret.sh` + one `kubectl apply -f
gitops/bootstrap/root-app.yaml` rebuilds everything except data — and data
backup is what [BACKUP.md](BACKUP.md) is about.
