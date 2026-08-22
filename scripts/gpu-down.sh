#!/usr/bin/env bash
# Billing off: drain gpu nodes, destroy the VMs, drop the wireguard peers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="$ROOT/kubeconfig"

for n in $(kubectl get nodes -l node-role.kubernetes.io/gpu-worker=true -o name 2>/dev/null); do
  kubectl drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout=90s || true
  kubectl delete "$n"
done

terraform -chdir="$ROOT/terraform/gpu" destroy -auto-approve

rm -f "$ROOT/.secrets/wg/gpu-peers.json"
cd "$ROOT/ansible" && ansible-playbook wireguard.yml    # re-render without peers

echo "gpu nodes gone, billing stopped. weights are still in MinIO — next gpu-up is fast."
