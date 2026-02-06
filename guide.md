# Kubernetes on Hetzner Cloud with Talos Linux + Cluster API (CAPI)

Control-plane-only Talos Kubernetes cluster on Hetzner Cloud, managed by Cluster API.

## Version Matrix

| Component | Version | CAPI Contract |
|---|---|---|
| Cluster API core | v1.10.10 | v1beta1 |
| CAPH | v1.0.7 | v1beta1 |
| CABPT | v0.6.11 | v1beta1 |
| CACPPT | v0.5.12 | v1beta1 |
| Talos Linux | v1.12.2 | N/A |
| Kubernetes | v1.32.2 | N/A |
| Cilium | 1.18.6 | N/A |
| Hetzner CCM | 1.29.2 | N/A |
| Talos CCM | 0.5.4 | N/A |

**Note**: CAPH ships with kubeadm templates only. There is no official Talos flavor for CAPH. The manifests in this repo combine CAPH infrastructure resources with Talos bootstrap/control-plane resources manually.

---

## Cluster Configuration

| Setting | Value |
|---|---|
| Cluster name | `k8s` |
| Location | nbg1 (Nuremberg) |
| Server type | cx33 (4 vCPU, 8 GB RAM) |
| Control plane replicas | 3 |
| Worker nodes | 0 (control-plane-only, `allowSchedulingOnControlPlanes`) |
| Network CIDR | 10.10.0.0/16 |
| CP subnet | 10.10.64.0/25 |
| Pod CIDR | 10.10.128.0/17 |
| Service CIDR | 10.10.96.0/20 |
| CNI | Cilium (kubeProxyReplacement, Hubble) |
| Kube-proxy | Disabled |
| Cloud provider | External (Hetzner CCM + Talos CCM) |
| Placement group | Spread (control-plane HA) |
| Load balancer | lb11 (ports 6443 + 50000) |

### Talos Strategic Patches Applied

- DHCP on eth0 (public) + eth1 (private)
- Kubelet: `cloud-provider=external`, `rotate-server-certificates`, nodeIP restricted to 10.10.0.0/16
- Host DNS enabled (resolveMemberNames)
- Kubernetes Talos API access from kube-system (os:reader)
- `allowSchedulingOnControlPlanes: true`
- Pod/service subnets matching cluster CIDRs
- CNI: none (Cilium installed separately)
- Kube-proxy: disabled
- etcd advertised on CP subnet (10.10.64.0/25)
- External cloud provider enabled
- OIDC: Hydra issuer at `auth.cluster.samuelbagattin.com`
- Remove `exclude-from-external-load-balancers` label from CP nodes

### CAPH Limitations

- **No firewall management**: CAPH v1.0.7 does not manage Hetzner firewalls. Create them separately via `make firewall` + `make firewall-apply`.
- **No native Talos flavor**: Manifests are crafted manually.
- **SSH keys**: Talos doesn't use SSH. The `sshKeys.hcloud` field is set to an empty list.

---

## Prerequisites

```bash
# macOS
brew install kind helm packer kubectl hcloud
brew install siderolabs/tap/talosctl

# clusterctl
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.10.10/clusterctl-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m) \
  -o /usr/local/bin/clusterctl && chmod +x /usr/local/bin/clusterctl
```

Set the Hetzner token:
```bash
export HCLOUD_TOKEN=$(op item get f3dybczercjvuktbt46hc5tkou --fields "api key" --reveal)
```

---

## Quick Start

```bash
# 1. Build Talos image snapshot (one-time, ~3 min)
make image

# 2. Bootstrap the full cluster (~10-15 min)
make bootstrap

# 3. Create and apply firewall rules
make firewall
make firewall-apply

# 4. (Optional) Pivot to self-managed
make pivot
make clean
```

---

## Project Structure

```
.
├── Makefile                          # Automation for the full lifecycle
├── guide.md                          # This file
├── manifests/
│   ├── cluster.yaml                  # CAPI cluster manifests (Cluster, HetznerCluster, HCloudMachineTemplate, TalosControlPlane)
│   ├── clusterctl.yaml               # clusterctl provider configuration
│   └── machine-health-check.yaml     # MachineHealthCheck for auto-remediation
├── packer/
│   └── hcloud_talosimage.pkr.hcl     # Packer template (Image Factory with qemu-guest-agent)
└── bootstrap/
    ├── cilium-values.yaml            # Cilium Helm values
    ├── hcloud-ccm-values.yaml        # Hetzner CCM Helm values
    └── talos-ccm-values.yaml         # Talos CCM Helm values
```

---

## Detailed Workflow

### 1. Build Talos Image

The Packer template creates a Hetzner snapshot using the Talos Image Factory. The schematic includes the `qemu-guest-agent` extension.

```bash
make image
# Verify
hcloud image list --type snapshot -l os=talos
```

The snapshot name `talos-amd64-v1.12.2` must match the `imageName` in `manifests/cluster.yaml`.

### 2. Bootstrap Cluster

`make bootstrap` runs these steps in order:

1. **kind-create** — Creates a local kind cluster as the CAPI management cluster
2. **capi-init** — Installs CAPI core + CAPH + CABPT + CACPPT controllers
3. **secret** — Creates the `hetzner` secret with the HCloud token
4. **apply** — Applies `manifests/cluster.yaml`
5. **wait-cp** — Waits for at least 1 control plane replica to be ready
6. **kubeconfig** — Extracts the workload cluster kubeconfig
7. **talosconfig** — Extracts the talosconfig from the CABPT-generated secret
8. **cilium** — Installs Cilium CNI on the workload cluster
9. **hcloud-ccm** — Creates the `hcloud` secret in kube-system and installs Hetzner CCM
10. **talos-ccm** — Installs Talos CCM (CSR approval only)
11. **wait-nodes** — Waits for nodes to become Ready

### 3. Firewall Setup

CAPH does not manage Hetzner firewalls. Create them separately:

```bash
# Create the firewall with rules
make firewall

# Apply to cluster servers (run after servers exist)
make firewall-apply
```

This creates rules restricting ports 6443 (K8s API) and 50000 (Talos API) to private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) — matching the existing Twingate VPN access pattern.

### 4. Pivot to Self-Managed

Move CAPI controllers from the kind bootstrap cluster to the workload cluster itself:

```bash
make pivot
make clean  # Delete the kind cluster
```

After pivoting, the workload cluster manages its own lifecycle. The `hetzner` secret and all CAPI resources are moved automatically.

**Note**: Since this is a control-plane-only cluster with `allowSchedulingOnControlPlanes`, CAPI controllers can schedule on CP nodes.

---

## Operations

### Check Cluster Status

```bash
make status

# Or manually
KUBECONFIG=/tmp/k8s.kubeconfig kubectl get nodes -o wide
talosctl --talosconfig /tmp/k8s.talosconfig --nodes <cp-ip> health
```

### Kubernetes Version Upgrade

Update the `version` field in `TalosControlPlane`:
```bash
kubectl edit taloscontrolplane k8s-control-plane
# Change spec.version to the new version
```
CACPPT handles rolling updates automatically (RollingUpdate with maxSurge: 1).

### Talos Version Upgrade

1. Build a new image: `make image TALOS_VERSION=v1.x.y`
2. Update `imageName` in the `HCloudMachineTemplate`
3. Update `talosVersion` in the `TalosControlPlane`
4. Apply changes — CACPPT rolls out new machines

Or upgrade directly via talosctl:
```bash
talosctl --talosconfig /tmp/k8s.talosconfig \
  --nodes <cp-ip> upgrade \
  --image factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.x.y
```

### Scale Control Plane

```bash
kubectl patch taloscontrolplane k8s-control-plane --type merge -p '{"spec":{"replicas":5}}'
```

### etcd Backup

```bash
talosctl --talosconfig /tmp/k8s.talosconfig \
  --nodes <cp-ip> etcd snapshot /tmp/etcd-backup.snapshot
```

### CAPI Resource Backup

```bash
clusterctl move --to-directory=./backup
```

---

## Troubleshooting

### Nodes stuck in NotReady
CNI not installed. Run `make cilium`.

### Nodes have `node.cloudprovider.kubernetes.io/uninitialized` taint
Hetzner CCM not installed or not running. Run `make hcloud-ccm`.

### Image name mismatch
```bash
hcloud image list --type snapshot -l os=talos
```
The `imageName` in `HCloudMachineTemplate` must match the snapshot name exactly.

### CABPT JSON patches breaking
Use `strategicPatches` (not `configPatches`). JSON 6902 patches are not compatible with Talos >= 1.12.

### Controller logs
```bash
# Management cluster
KUBECONFIG=/tmp/k8s-mgmt.kubeconfig kubectl logs -n caph-system deploy/caph-controller-manager -f
KUBECONFIG=/tmp/k8s-mgmt.kubeconfig kubectl logs -n cabpt-system deploy/cabpt-controller-manager -f
KUBECONFIG=/tmp/k8s-mgmt.kubeconfig kubectl logs -n cacppt-system deploy/cacppt-controller-manager -f

# Machine status
KUBECONFIG=/tmp/k8s-mgmt.kubeconfig kubectl get machines -o wide
KUBECONFIG=/tmp/k8s-mgmt.kubeconfig kubectl describe machine <name>
KUBECONFIG=/tmp/k8s-mgmt.kubeconfig kubectl get hcloudmachine -o wide
```

### Hetzner Cloud direct
```bash
hcloud server list
hcloud load-balancer list
hcloud network list
hcloud firewall list
```
