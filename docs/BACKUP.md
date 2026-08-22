# Backup & restore

What can be lost, what protects it, and the exact commands. The lab is
rebuildable by design, so backup here means **data**, never infrastructure —
infra is git + `make cluster`.

## What actually needs backing up

| Data | Why it matters | Protected by |
|------|----------------|--------------|
| etcd | the entire cluster state | k3s scheduled snapshots (below) |
| Longhorn volumes | Grafana, MinIO, later Qdrant/Neo4j | Longhorn backups → S3 (below) |
| MinIO `models` bucket | model weights | re-downloadable from HF; versioning later |
| git repo | everything else | GitHub is the backup |
| `.secrets/` | join token, MinIO root | tiny — keep a copy in your password manager |

## etcd snapshots

k3s snapshots etcd on every server at 00:00/12:00 by default, keeping 5, under
`/var/lib/rancher/k3s/server/db/snapshots/`. Manual snapshot + list:

```bash
vagrant ssh cp1 -c 'sudo k3s etcd-snapshot save --name pre-drill'
vagrant ssh cp1 -c 'sudo k3s etcd-snapshot ls'
```

Restore (the drill from TESTING.md, but for real — cluster state is rolled back):

```bash
# on every server: stop k3s
sudo systemctl stop k3s
# on cp1: restore and re-init the cluster from the snapshot
sudo k3s server --cluster-reset --cluster-reset-restore-path=<snapshot-path>
sudo systemctl start k3s
# cp2/cp3: wipe their db and rejoin as if new
sudo rm -rf /var/lib/rancher/k3s/server/db && sudo systemctl start k3s
```

Snapshots sit on the same disk they protect — fine against fat-fingered
deletes, useless against a dead VM. The fix is `etcd-s3: true` in the k3s
config pointing at off-cluster S3, which comes with the move to a cloud
provider (local MinIO can't be the target: it lives *inside* the cluster the
snapshot is supposed to resurrect).

## Longhorn volume backups

Longhorn separates **snapshots** (instant, local, same-disk caveat as etcd) from
**backups** (full copy shipped to an S3 backup target).

Current lab wiring — MinIO as the target (yes, MinIO-on-Longhorn backing up
Longhorn; acceptable for drills because a *restore* test proves the mechanism,
but it's not disaster recovery — see the same-cluster caveat above):

Set the backup target via GitOps (`gitops/apps/longhorn.yaml` values):

```yaml
defaultSettings:
  backupTarget: s3://longhorn-backups@us-east-1/
  backupTargetCredentialSecret: minio-root-creds
```

(the secret needs `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` keys — the
create-minio-secret script writes both spellings.)

Then per-volume, from the Longhorn UI (port-forward 8082) or CRD:
volume → Create Backup; restore is Backup → Restore to a new volume, then point
the PVC at it.

When a real GPU/cloud setup exists, the target flips to external object storage
(Hetzner, R2, S3) with one line in git — same S3 API, that's the whole point.

## MinIO / model weights

Model weights are cattle: re-pullable from Hugging Face at ~the same speed as
any restore. So the `models` bucket gets **no backup** — deliberate decision,
document it, move on. What WILL need protection later: fine-tuned adapters,
eval results, anything hand-made. For those:

```bash
mc mirror lab/models s3-external/alohomora-models     # one-off copy
mc version enable lab/models                          # object versioning
```

## Velero — the missing piece (planned)

Everything above is per-component. Velero is the cluster-level answer:
one tool that backs up API objects (all namespaces, CRDs included) plus PV
snapshots via CSI, on a schedule, to S3. The reason it's not installed yet is
sequencing, not oversight: Velero's value shows up when there's real state
worth restoring (Qdrant collections, Grafana dashboards people actually made,
gateway configs). The plan:

- install via GitOps (`vmware-tanzu/velero` chart) with the CSI snapshot plugin
- target: external S3 (not in-cluster MinIO — same-cluster caveat)
- schedule: nightly full-namespace backup of stateful namespaces, 7-day TTL
- drill: `velero backup create pre-upgrade --include-namespaces minio` before
  every k3s upgrade, and one full `velero restore` rehearsal into a scratch
  namespace — a backup that's never been restored is a rumor, not a backup

## The restore drills

Backups nobody restored don't count (see TESTING.md for the failure drills):

1. **etcd**: snapshot → `kubectl create deployment tmp` → restore snapshot →
   deployment gone = restore worked
2. **Longhorn**: write a file into a PVC → backup → delete volume → restore →
   file is back
3. **Full rebuild**: `make down && make cluster` + root-app apply — the
   ultimate restore test, everything except data returns from git
