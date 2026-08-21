# Runbook 00 — Bootstrap the local 4-node cluster (Phase 0 + 1)

Exact commands used to bring up the Alohomora local lab from zero, verified 2026-08-21.
Result: k3s v1.36.3+k3s1 HA cluster (3 control-plane + 1 worker), Cilium 1.18.1
(kube-proxy-free), kube-vip API VIP, kubectl working from the Mac host.

## 1. One-time host setup (macOS, Apple Silicon)

```bash
brew install qemu vagrant socket_vmnet
vagrant plugin install vagrant-qemu
sudo brew services start socket_vmnet     # vmnet needs root; runs as a launchd service
```

Verify the daemon socket exists:

```bash
ls -la /opt/homebrew/var/run/socket_vmnet
```

## 2. Boot the VMs

```bash
vagrant validate
vagrant up                                 # boots cp1, cp2, cp3, worker1
vagrant status
```

Each VM gets a second NIC (`mesh0`) on the shared vmnet L2 segment `192.168.105.0/24`.
The Mac host is on the same segment as `192.168.105.1` (interface `bridge100`).

## 3. Verify the mesh network

```bash
make mesh-test                             # every node pings every node + the host
ping -c1 192.168.105.211                   # host -> VM
ssh -i .vagrant/machines/cp1/qemu/private_key vagrant@192.168.105.211 hostname
```

All 20 pings must be `ok`. If VMs can't see each other, check that socket_vmnet
is running and that the VMs were created *after* it was started.

## 4. Provision the cluster

```bash
cd ansible
ansible-playbook site.yml --syntax-check   # sanity first
ansible-playbook site.yml
```

What the playbook does, in order:

1. **cp1** — writes `/etc/rancher/k3s/config.yaml` (`cluster-init`, flannel/kube-proxy/
   traefik/servicelb disabled), installs k3s via `curl -sfL https://get.k3s.io | sh -s - server`,
   waits for `/readyz`.
2. **cp2, cp3** (serial) — same config pointing at `https://192.168.105.211:6443`, join
   the embedded etcd cluster.
3. **cp1** — installs helm, `helm upgrade --install cilium cilium/cilium` with
   kube-proxy replacement + L2 announcements + Hubble; waits for all nodes Ready;
   drops kube-vip and the Cilium LB pool manifests into
   `/var/lib/rancher/k3s/server/manifests/` (k3s auto-applies them); waits for the
   VIP `192.168.105.210` to answer; re-points Cilium at the VIP for HA API access.
4. **worker1** — joins as agent via the VIP.
5. Fetches kubeconfig to `./kubeconfig` with the server rewritten to the VIP.

## 5. Verify the cluster

```bash
export KUBECONFIG=$PWD/kubeconfig          # from the repo root
kubectl get nodes                          # 4 nodes, all Ready
kubectl -n kube-system get pods            # cilium on all 4, kube-vip-ds on all 3 CPs
kubectl get --raw /readyz                  # "ok" — API reached via the VIP
ping -c1 192.168.105.210                   # VIP alive
```

## Gotchas hit during bring-up

- **QEMU multicast socket networking does not pass packets on macOS** — interfaces come
  up, ARP never resolves (`Destination Host Unreachable`). Switched to socket_vmnet
  (`-netdev stream,addr.type=unix,addr.path=...`), which is what Lima/Colima use.
- VirtualBox is not an option on Apple Silicon; the lab is Vagrant + vagrant-qemu + HVF.
- Static node IPs are placed high in the subnet (`.211+`) to stay clear of the vmnet
  DHCP range.
