# Talos image build for Hetzner Cloud
#
# Hetzner doesn't support direct disk image uploads. This template:
# 1. Creates a temporary server in rescue mode
# 2. Downloads the Talos raw disk image via Image Factory (with extensions)
# 3. Writes the image to disk with dd
# 4. Snapshots the server disk for use by CAPH
#
# The schematic ID includes the qemu-guest-agent extension.
# If extensions change, regenerate the schematic via https://factory.talos.dev/

packer {
  required_plugins {
    hcloud = {
      source  = "github.com/hetznercloud/hcloud"
      version = "~> 1"
    }
  }
}

variable "talos_version" {
  type        = string
  description = "Talos Linux version (e.g., v1.12.2)"
  default     = "v1.12.2"
}

variable "server_type" {
  type        = string
  description = "Hetzner server type for the temporary build server"
  default     = "cx23"
}

variable "server_location" {
  type        = string
  description = "Hetzner datacenter location"
  default     = "nbg1"
}

variable "arch" {
  type        = string
  description = "CPU architecture (amd64 or arm64)"
  default     = "amd64"
}

# Schematic ID for Talos with qemu-guest-agent extension.
# Generated from: siderolabs/qemu-guest-agent
# Regenerate at https://factory.talos.dev/ if extensions change.
variable "schematic_id" {
  type        = string
  description = "Talos Image Factory schematic ID"
  default     = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}

locals {
  image_url = "https://factory.talos.dev/image/${var.schematic_id}/${var.talos_version}/hcloud-${var.arch}.raw.xz"
}

source "hcloud" "talos" {
  rescue       = "linux64"
  image        = "debian-12"
  location     = var.server_location
  server_type  = var.server_type
  ssh_username = "root"

  snapshot_name = "talos-${var.arch}-${var.talos_version}"
  snapshot_labels = {
    os              = "talos"
    talos_version   = var.talos_version
    arch            = var.arch
    caph-image-name = "talos-${var.arch}-${var.talos_version}"
  }
}

build {
  sources = ["source.hcloud.talos"]

  provisioner "shell" {
    inline = [
      "apt-get install -y wget",
      "wget -O /tmp/talos.raw.xz ${local.image_url}",
      "xz -d -c /tmp/talos.raw.xz | dd of=/dev/sda bs=4M && sync",
    ]
  }
}
