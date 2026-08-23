#!/usr/bin/env bash
# Renders a ready-to-run bootstrap script for a rented GPU VM.
# Reads lab WireGuard pubkeys + the k3s join token from .secrets/ (never in git).
#
#   ./scripts/make-gpu-bootstrap.sh          # → .secrets/gpu1-bootstrap.sh
#   scp .secrets/gpu1-bootstrap.sh root@GPU_VM_IP:
#   ssh root@GPU_VM_IP 'bash gpu1-bootstrap.sh'   # prints the GPU's wg pubkey
#   cd ansible && ansible-playbook wireguard.yml -e gpu_pubkey=... -e gpu_endpoint=GPU_VM_IP:51820
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for f in cp1 cp2 cp3 worker1; do
  [ -f "$ROOT/.secrets/wg/$f.pub" ] || { echo "missing $ROOT/.secrets/wg/$f.pub — run: cd ansible && ansible-playbook wireguard.yml"; exit 1; }
done
TOKEN="$(cat "$ROOT/.secrets/k3s-token")"
K3S_VERSION="v1.36.3+k3s1"          # pin to the lab's version — no skew

OUT="$ROOT/.secrets/gpu1-bootstrap.sh"
umask 077
cat > "$OUT" <<EOF
#!/usr/bin/env bash
# Alohomora GPU node bootstrap — run as root on a fresh Ubuntu 22.04 GPU VM.
# Installs WireGuard (listener) + joins the cluster as a tainted k3s agent.
set -euo pipefail

echo "== wireguard =="
apt-get update -qq && apt-get install -y -qq wireguard
umask 077
[ -f /etc/wireguard/privatekey ] || wg genkey > /etc/wireguard/privatekey
wg pubkey < /etc/wireguard/privatekey > /etc/wireguard/publickey

cat > /etc/wireguard/wg0.conf <<WG
[Interface]
PrivateKey = \$(cat /etc/wireguard/privatekey)
Address = 10.8.0.31/24
ListenPort = 51820
MTU = 1340

# lab peers are behind NAT: no Endpoint here — THEY dial US, keepalive holds the door
[Peer]
# cp1
PublicKey = $(cat "$ROOT/.secrets/wg/cp1.pub")
AllowedIPs = 10.8.0.11/32, 192.168.105.211/32
[Peer]
# cp2
PublicKey = $(cat "$ROOT/.secrets/wg/cp2.pub")
AllowedIPs = 10.8.0.12/32, 192.168.105.212/32
[Peer]
# cp3
PublicKey = $(cat "$ROOT/.secrets/wg/cp3.pub")
AllowedIPs = 10.8.0.13/32, 192.168.105.213/32
[Peer]
# worker1
PublicKey = $(cat "$ROOT/.secrets/wg/worker1.pub")
AllowedIPs = 10.8.0.21/32, 192.168.105.221/32
WG

systemctl enable --now wg-quick@wg0
systemctl restart wg-quick@wg0

echo "== k3s agent =="
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<K3S
server: https://10.8.0.11:6443
token: "$TOKEN"
node-ip: 10.8.0.31
node-label:
  - alohomora.dev/tier=gpu
node-taint:
  - nvidia.com/gpu=present:NoSchedule
K3S

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - agent || true

echo
echo "=================================================================="
echo "GPU node WireGuard public key (give this to the lab):"
cat /etc/wireguard/publickey
echo
echo "Next, on the Mac:"
echo "  cd ~/codes/DoTech/alohomora/ansible"
echo "  ansible-playbook wireguard.yml -e gpu_pubkey=\$(cat /etc/wireguard/publickey) -e gpu_endpoint=<THIS_VM_PUBLIC_IP>:51820"
echo "k3s agent will connect as soon as the tunnel comes up (it retries)."
echo "=================================================================="
EOF
chmod +x "$OUT"
echo "rendered: $OUT"
echo "contains the k3s token + lab pubkeys — keep it in .secrets/, never commit."
