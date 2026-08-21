# Alohomora — local 4-node lab: 3 control-plane + 1 worker
# Provider: vagrant-qemu (QEMU + HVF acceleration on Apple Silicon)
#
# Inter-VM networking: socket_vmnet (same mechanism Lima/Colima use).
# Every VM gets a second NIC (mesh0) attached to the shared vmnet segment.
# The Mac host is on this network too (bridge100, 192.168.105.1) — so
# kubectl from the host reaches the cluster directly.
#
# One-time setup (root needed for vmnet):
#   brew install socket_vmnet
#   sudo brew services start socket_vmnet
#
#   cp1     192.168.105.211   control-plane
#   cp2     192.168.105.212   control-plane
#   cp3     192.168.105.213   control-plane
#   worker1 192.168.105.221   worker
#   (192.168.105.210 reserved for kube-vip API VIP)

NODES = {
  "cp1"     => { ip: "192.168.105.211", mac: "52:54:00:77:00:11", cpus: 2, mem: "4G", ssh_port: 50122 },
  "cp2"     => { ip: "192.168.105.212", mac: "52:54:00:77:00:12", cpus: 2, mem: "4G", ssh_port: 50222 },
  "cp3"     => { ip: "192.168.105.213", mac: "52:54:00:77:00:13", cpus: 2, mem: "4G", ssh_port: 50322 },
  "worker1" => { ip: "192.168.105.221", mac: "52:54:00:77:00:21", cpus: 4, mem: "8G", ssh_port: 50422 },
}

VMNET_SOCK = "/opt/homebrew/var/run/socket_vmnet"

Vagrant.configure("2") do |config|
  config.vm.box = "perk/ubuntu-2204-arm64"
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.boot_timeout = 600

  NODES.each do |name, node|
    config.vm.define name do |vm|
      vm.vm.hostname = name

      vm.vm.provider "qemu" do |qe|
        qe.arch = "aarch64"
        qe.machine = "virt,accel=hvf"
        qe.cpu = "host"
        qe.smp = node[:cpus].to_s
        qe.memory = node[:mem]
        qe.ssh_port = node[:ssh_port].to_s
        qe.extra_qemu_args = [
          "-netdev", "stream,id=mesh0,addr.type=unix,addr.path=#{VMNET_SOCK}",
          "-device", "virtio-net-pci,netdev=mesh0,mac=#{node[:mac]}",
        ]
      end

      vm.vm.provision "shell", inline: <<-SHELL
        cat > /etc/netplan/60-mesh.yaml <<EOF
network:
  version: 2
  ethernets:
    mesh0:
      match:
        macaddress: "#{node[:mac]}"
      set-name: mesh0
      dhcp4: false
      addresses: ["#{node[:ip]}/24"]
EOF
        chmod 600 /etc/netplan/60-mesh.yaml
        netplan apply
        # /etc/hosts entries for all lab nodes
        sed -i '/# alohomora/d' /etc/hosts
        cat >> /etc/hosts <<EOF
#{NODES.map { |n, d| "#{d[:ip]} #{n} # alohomora" }.join("\n")}
EOF
      SHELL
    end
  end
end
