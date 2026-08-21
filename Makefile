.PHONY: up down status mesh-test ssh-% provision cluster kube

# full bring-up: VMs + k3s HA + kube-vip + Cilium
cluster: up provision

provision:
	cd ansible && ansible-playbook site.yml

# print how to use the fetched kubeconfig
kube:
	@echo 'export KUBECONFIG=$(CURDIR)/kubeconfig'

up:
	vagrant up

down:
	vagrant destroy -f

status:
	vagrant status

# verify the vmnet mesh network: every node pings every other node + the host
mesh-test:
	@for n in cp1 cp2 cp3 worker1; do \
		echo "== from $$n =="; \
		vagrant ssh $$n -c 'for ip in 192.168.105.211 192.168.105.212 192.168.105.213 192.168.105.221 192.168.105.1; do ping -c1 -W2 $$ip >/dev/null 2>&1 && echo "  $$ip ok" || echo "  $$ip FAIL"; done' 2>/dev/null; \
	done

ssh-%:
	vagrant ssh $*
