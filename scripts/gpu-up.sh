#!/usr/bin/env bash
# One command: rented GPU nodes join the cluster.
#   VERDA_CLIENT_ID/SECRET must be exported (console → API keys)
#   ./scripts/gpu-up.sh [count]     # default 1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNT="${1:-1}"

# 1. local wireguard keys for gpu nodes (generated once, reused across rebuilds)
command -v wg >/dev/null || { echo "need wireguard-tools: brew install wireguard-tools"; exit 1; }
mkdir -p "$ROOT/.secrets/wg"
for i in $(seq 1 "$COUNT"); do
  k="$ROOT/.secrets/wg/gpu$i.key"
  if [ ! -f "$k" ]; then
    umask 077
    wg genkey > "$k"
    wg pubkey < "$k" > "$ROOT/.secrets/wg/gpu$i.pub"
    echo "generated wg key for gpu$i"
  fi
done

# 2. rent the machines
terraform -chdir="$ROOT/terraform/gpu" init -upgrade -input=false >/dev/null
terraform -chdir="$ROOT/terraform/gpu" apply -auto-approve -var "gpu_count=$COUNT"

# 3. hand the peers to the lab: every node dials out to every gpu
python3 - "$ROOT" "$COUNT" <<'EOF'
import json, subprocess, sys
root, count = sys.argv[1], int(sys.argv[2])
out = json.loads(subprocess.check_output(
    ["terraform", f"-chdir={root}/terraform/gpu", "output", "-json", "nodes"]))
peers = []
for name, n in sorted(out.items()):
    pub = open(f"{root}/.secrets/wg/{name}.pub").read().strip()
    peers.append({"name": name, "pubkey": pub,
                  "endpoint": f'{n["ip"]}:51820', "wg_ip": n["wg_ip"]})
with open(f"{root}/.secrets/wg/gpu-peers.json", "w") as f:
    json.dump({"gpu_peers": peers}, f, indent=2)
print("endpoints:", ", ".join(f'{p["name"]}={p["endpoint"]}' for p in peers))
EOF

cd "$ROOT/ansible" && ansible-playbook wireguard.yml -e "@../.secrets/wg/gpu-peers.json"

echo
echo "tunnel up — watching for nodes to join (Ctrl-C anytime):"
export KUBECONFIG="$ROOT/kubeconfig"
kubectl get nodes -w
