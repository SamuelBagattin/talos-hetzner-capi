# Bootstrap Issues — 2026-02-05

## 1. Packer: `cx22` server type no longer exists

Hetzner renamed their shared x86 server types. `cx22` is gone, replaced by `cx23`.

**Fix:** Updated `packer/hcloud_talosimage.pkr.hcl` default from `cx22` to `cx23`.

## 2. Packer: Snapshot missing `caph-image-name` label

CAPH resolves `imageName` in two ways (see `pkg/services/hcloud/server/server.go:504`):
1. By label: `caph-image-name == <imageName>`
2. By Hetzner API `name` field

Hetzner snapshots don't have a `name` field (always null) — only `description`. The Packer hcloud plugin sets `snapshot_name` as `description`, not `name`. So the API name lookup always fails, and the label lookup also fails because Packer doesn't add the `caph-image-name` label.

**Fix:** Added `caph-image-name` to `snapshot_labels` in `packer/hcloud_talosimage.pkr.hcl`.

## 3. Bootstrap: `wait-cp` deadlock

The `wait-cp` Makefile target waits for `readyReplicas >= 1` on the TalosControlPlane. But nodes stay `NotReady` until Cilium (CNI) is installed, which only happens after `wait-cp` completes. This creates a deadlock.

The control plane is actually initialized (`status.initialized: true`, `status.bootstrapped: true`) — it's just that CAPI doesn't count replicas as "ready" until the corresponding Kubernetes node is `Ready`.

**Fix needed:** Change `wait-cp` to check for `status.initialized == true` or check for the kubeconfig secret existence instead of `readyReplicas`.

## 4. Cilium: `--wait` timeout due to `uninitialized` taint

Cilium is installed with `--wait --timeout 5m`. Hubble Relay and Hubble UI pods can't schedule because all nodes have the `node.cloudprovider.kubernetes.io/uninitialized` taint (only removed by the hcloud CCM, which is installed after Cilium).

Core Cilium pods (agents, operator) tolerate this taint, but Hubble pods don't.

**Fix needed:** Either:
- Install Cilium without `--wait`, or with a more targeted wait (e.g. wait only for the DaemonSet)
- Install hcloud-ccm before Cilium
- Add the `uninitialized` taint toleration to Hubble pods in `cilium-values.yaml`

## 5. hcloud CCM: Can't match nodes to Hetzner servers

The hcloud CCM matches Kubernetes nodes to Hetzner servers by hostname or `providerID`. Neither works:

- **Hostname mismatch:** CAPI Machine names (e.g. `k8s-control-plane-5crlz`) differ from HCloudMachine/server names (e.g. `k8s-control-plane-kvt4m`). Talos sets hostname from `hostname.source: MachineName` (CAPI Machine name), but CAPH names the Hetzner server after the HCloudMachine name. Different random suffixes.
- **No providerID:** Nodes are created without `spec.providerID`. The Talos CCM has `cloud-node-controller` disabled (only runs `node-csr-approval`). CAPI sets providerID on its Machine objects, but nothing propagates it to the actual Kubernetes node objects.

**Fix needed:** Investigate how providerID should flow from CAPI to the workload cluster nodes. Options:
- Enable `cloud-node-controller` in talos-ccm (but it may not know the hcloud server ID)
- Have CAPH or Talos bootstrap provider inject providerID into the Talos machine config
- Use a different `hostname.source` that matches the Hetzner server name
