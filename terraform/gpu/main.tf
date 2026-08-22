# Elastic GPU nodes on Verda (ex-DataCrunch, Helsinki) — rent, join, serve, destroy.
#
#   export VERDA_CLIENT_ID=... VERDA_CLIENT_SECRET=...   (console → API keys)
#   ../../scripts/gpu-up.sh          # keys → terraform apply → wireguard peers
#   ../../scripts/gpu-down.sh        # drain nodes → destroy → remove peers
#
# WireGuard keys for GPU nodes are generated LOCALLY (.secrets/wg/gpuN.key) and
# baked into cloud-init — no interactive key exchange, fully non-interactive.

terraform {
  required_providers {
    verda = {
      source  = "verda-cloud/verda"
      version = "~> 1.1"
    }
  }
}

provider "verda" {}

variable "gpu_count" {
  type    = number
  default = 1
}

variable "instance_type" {
  type    = string
  default = "1L40S.20V" # 48GB VRAM, plenty for Qwen 7B-class; override per run
}

variable "image" {
  type    = string
  default = "ubuntu-24.04-cuda-12.8-open-docker" # driver preinstalled — gpu-operator skips driver
}

variable "location" {
  type    = string
  default = "FIN-03" # Helsinki — lowest latency to the lab
}

variable "is_spot" {
  type    = bool
  default = false # flip true for big discounts; fine for short sessions
}

variable "ssh_pubkey_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

locals {
  # gpu1 → 10.8.0.31, gpu2 → 10.8.0.32, ...
  nodes = { for i in range(var.gpu_count) : "gpu${i + 1}" => {
    wg_ip = "10.8.0.${31 + i}"
  } }
  lab_peers = {
    cp1     = { wg_ip = "10.8.0.11", node_ip = "192.168.105.211" }
    cp2     = { wg_ip = "10.8.0.12", node_ip = "192.168.105.212" }
    cp3     = { wg_ip = "10.8.0.13", node_ip = "192.168.105.213" }
    worker1 = { wg_ip = "10.8.0.21", node_ip = "192.168.105.221" }
  }
}

resource "verda_ssh_key" "lab" {
  name       = "alohomora"
  public_key = trimspace(file(pathexpand(var.ssh_pubkey_path)))
}

resource "verda_startup_script" "node" {
  for_each = local.nodes
  name     = "alohomora-${each.key}-bootstrap"
  script = templatefile("${path.module}/templates/bootstrap.sh.tpl", {
    hostname   = each.key
    wg_ip      = each.value.wg_ip
    wg_privkey = trimspace(file("${path.module}/../../.secrets/wg/${each.key}.key"))
    lab_peers = { for name, p in local.lab_peers : name => {
      pubkey  = trimspace(file("${path.module}/../../.secrets/wg/${name}.pub"))
      wg_ip   = p.wg_ip
      node_ip = p.node_ip
    } }
    k3s_token   = trimspace(file("${path.module}/../../.secrets/k3s-token"))
    k3s_version = "v1.36.3+k3s1" # pinned to the lab — no skew
  })
}

resource "verda_instance" "gpu" {
  for_each          = local.nodes
  hostname          = each.key
  description       = "alohomora elastic gpu node"
  instance_type     = var.instance_type
  image             = var.image
  location          = var.location
  is_spot           = var.is_spot
  ssh_key_ids       = [verda_ssh_key.lab.id]
  startup_script_id = verda_startup_script.node[each.key].id
}

output "nodes" {
  value = { for name, inst in verda_instance.gpu : name => {
    ip     = inst.ip
    status = inst.status
    wg_ip  = local.nodes[name].wg_ip
  } }
}
