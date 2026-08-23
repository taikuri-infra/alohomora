#!/usr/bin/env bash
# Alohomora GPU node cloud-init — wireguard listener + tainted k3s agent.
# Rendered by terraform; wg private key was generated on the Mac and baked in.
set -euo pipefail
exec > /var/log/alohomora-bootstrap.log 2>&1

hostnamectl set-hostname ${hostname}

echo "== wireguard =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq wireguard

umask 077
cat > /etc/wireguard/wg0.conf <<'WG'
[Interface]
PrivateKey = ${wg_privkey}
Address = ${wg_ip}/24
ListenPort = 51820
MTU = 1340

%{ for name, peer in lab_peers ~}
[Peer]
# ${name} — behind NAT: no Endpoint, the lab dials us; keepalive holds the door
PublicKey = ${peer.pubkey}
AllowedIPs = ${peer.wg_ip}/32, ${peer.node_ip}/32
%{ endfor ~}
WG

systemctl enable --now wg-quick@wg0
systemctl restart wg-quick@wg0

echo "== k3s agent =="
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<K3S
server: https://10.8.0.11:6443
token: "${k3s_token}"
node-ip: ${wg_ip}
node-label:
  # node-role.kubernetes.io/* is FORBIDDEN for kubelet self-labeling (security);
  # add the cosmetic role after join via kubectl. custom prefixes are fine:
  - alohomora.dev/tier=gpu
node-taint:
  - nvidia.com/gpu=present:NoSchedule
K3S

# agent retries until the lab dials in and the tunnel comes up — that's fine
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${k3s_version}" sh -s - agent || true

echo "bootstrap done"
